import SwiftUI
import MapKit
import AppKit

// MARK: - 設定
// 路徑不寫死：優先讀 ~/.fakegps/config（install.sh 寫入），否則在常見位置自動偵測。
// 這讓 App 能在不同使用者 / Homebrew 位置（Apple Silicon 的 /opt/homebrew、Intel 的 /usr/local）通用。
enum Cfg {
    static let helperPath = "/usr/local/libexec/fakegps_tunnel.sh"
    static var stateDir: String { NSHomeDirectory() + "/.fakegps" }
    static var bookmarksFile: String { stateDir + "/bookmarks.json" }

    private static let cfg: [String: String] = {
        var d: [String: String] = [:]
        let path = NSHomeDirectory() + "/.fakegps/config"
        if let s = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in s.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    d[kv[0].trimmingCharacters(in: .whitespaces)] =
                        kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return d
    }()

    private static func resolve(_ key: String, _ candidates: [String]) -> String {
        if let v = cfg[key], FileManager.default.isExecutableFile(atPath: v) { return v }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return candidates.first ?? key
    }

    static var python: String {
        resolve("python", ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"])
    }
    static var ideviceID: String {
        resolve("idevice_id", ["/opt/homebrew/bin/idevice_id", "/usr/local/bin/idevice_id"])
    }
    static var ideviceInfo: String {
        resolve("ideviceinfo", ["/opt/homebrew/bin/ideviceinfo", "/usr/local/bin/ideviceinfo"])
    }
    static var helper: String { cfg["helper"] ?? helperPath }
}

// MARK: - 資料模型
struct Bookmark: Codable, Identifiable, Hashable {
    var name: String
    var lat: Double
    var lon: Double
    var id: String { name }
}

struct SearchHit: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coord: CLLocationCoordinate2D
}

// MARK: - shell 工具
@discardableResult
func runSync(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

func parseRSD(_ line: String) -> (String, String)? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard let r = try? NSRegularExpression(pattern: "^([0-9a-fA-F:]+)\\s+([0-9]+)$") else { return nil }
    let range = NSRange(t.startIndex..., in: t)
    guard let m = r.firstMatch(in: t, range: range),
          let h = Range(m.range(at: 1), in: t),
          let p = Range(m.range(at: 2), in: t) else { return nil }
    return (String(t[h]), String(t[p]))
}

// MARK: - 控制器
@MainActor
final class Controller: ObservableObject {
    @Published var deviceConnected = false
    @Published var deviceName = ""
    @Published var tunnelUp = false
    @Published var simulating = false
    @Published var lastLabel = ""
    @Published var busy = false
    @Published var toast = ""
    @Published var bookmarks: [Bookmark] = []

    private var tunnelProc: Process?
    private var simProc: Process?
    private var rsdHost = ""
    private var rsdPort = ""
    private var timer: Timer?

    init() {
        loadBookmarks()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func udid() -> String? {
        let (rc, out) = runSync(Cfg.ideviceID, ["-l"])
        guard rc == 0 else { return nil }
        let id = out.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        return (id?.isEmpty == false) ? id : nil
    }

    func poll() {
        guard let id = udid() else {
            if deviceConnected { teardown() }   // 手機拔除 → 清狀態
            deviceConnected = false; deviceName = ""
            return
        }
        deviceConnected = true
        if deviceName.isEmpty {
            let (_, n) = runSync(Cfg.ideviceInfo, ["-k", "DeviceName"])
            deviceName = n.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let p = tunnelProc, !p.isRunning { tunnelUp = false }
        if let p = simProc, !p.isRunning { simulating = false }
    }

    private func teardown() {
        simProc?.terminate(); simProc = nil
        tunnelProc = nil
        tunnelUp = false; simulating = false; lastLabel = ""
    }

    func startTunnel() {
        guard let id = udid() else { flash("未偵測到手機"); return }
        guard FileManager.default.fileExists(atPath: Cfg.helper) else {
            flash("未安裝權限 helper"); return
        }
        busy = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", Cfg.helper, id]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(data: h.availableData, encoding: .utf8) ?? ""
            for line in s.split(separator: "\n") {
                if let rsd = parseRSD(String(line)) {
                    Task { @MainActor in self?.onTunnelReady(rsd.0, rsd.1) }
                }
            }
        }
        do { try p.run() } catch { busy = false; flash("啟動 tunnel 失敗"); return }
        tunnelProc = p

        // 逾時保險
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            if self.busy && !self.tunnelUp { self.busy = false; self.flash("tunnel 建立逾時") }
        }
    }

    private func onTunnelReady(_ host: String, _ port: String) {
        guard !tunnelUp else { return }
        rsdHost = host; rsdPort = port
        // 掛 DDI（背景）
        DispatchQueue.global().async {
            _ = runSync(Cfg.python, ["-m", "pymobiledevice3", "mounter", "auto-mount",
                                     "--rsd", host, port])
        }
        tunnelUp = true; busy = false
        flash("tunnel 已建立")
    }

    func setLocation(_ lat: Double, _ lon: Double, _ label: String) {
        guard tunnelUp else { flash("請先連線手機"); return }
        simProc?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Cfg.python)
        p.arguments = ["-m", "pymobiledevice3", "developer", "dvt", "simulate-location",
                       "set", "--rsd", rsdHost, rsdPort, "--", String(lat), String(lon)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { flash("設定失敗"); return }
        simProc = p
        simulating = true
        lastLabel = label
        flash("已設定：\(label)")
    }

    func clear() {
        simProc?.terminate(); simProc = nil
        if tunnelUp {
            DispatchQueue.global().async { [rsdHost, rsdPort] in
                _ = runSync(Cfg.python, ["-m", "pymobiledevice3", "developer", "dvt",
                                         "simulate-location", "clear", "--rsd", rsdHost, rsdPort])
            }
        }
        simulating = false; lastLabel = ""
        flash("已清除，恢復真實 GPS")
    }

    func quitCleanup() {
        simProc?.terminate()
        _ = runSync("/usr/bin/sudo", ["-n", Cfg.helper, "stop"])
    }

    func flash(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            if self?.toast == m { self?.toast = "" }
        }
    }

    // MARK: 書籤
    func loadBookmarks() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Cfg.bookmarksFile)),
              let b = try? JSONDecoder().decode([Bookmark].self, from: d) else { return }
        bookmarks = b
    }
    func saveBookmarks() {
        try? FileManager.default.createDirectory(atPath: Cfg.stateDir,
                                                 withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(bookmarks) {
            try? d.write(to: URL(fileURLWithPath: Cfg.bookmarksFile))
        }
    }
    func addBookmark(_ name: String, _ lat: Double, _ lon: Double) {
        bookmarks.removeAll { $0.name == name }
        bookmarks.append(Bookmark(name: name, lat: lat, lon: lon))
        saveBookmarks()
    }
    func delBookmark(_ name: String) {
        bookmarks.removeAll { $0.name == name }
        saveBookmarks()
    }

    // MARK: 搜尋（Apple Maps）
    func search(_ q: String) async -> [SearchHit] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return resp.mapItems.map { item in
            SearchHit(title: item.name ?? "未命名",
                      subtitle: item.placemark.title ?? "",
                      coord: item.placemark.coordinate)
        }
    }
}

// MARK: - Liquid Glass 輔助
extension View {
    @ViewBuilder
    func glassPanel<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }
    @ViewBuilder
    func glassChip<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.thinMaterial, in: shape)
        }
    }
}

struct GlassButtonStyleCompat: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension View {
    @ViewBuilder
    func glassButton(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.buttonStyle(.glass).tint(tint)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 主畫面
struct ContentView: View {
    @StateObject private var c = Controller()

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var latText = ""
    @State private var lonText = ""
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedLabel = ""
    @State private var camera: MapCameraPosition =
        .region(MKCoordinateRegion(center: .init(latitude: 25.0338, longitude: 121.5645),
                                    span: .init(latitudeDelta: 0.4, longitudeDelta: 0.4)))
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            mapView.ignoresSafeArea()
            panel
                .frame(width: 330)
                .padding(14)
        }
        .frame(minWidth: 940, minHeight: 640)
        .overlay(alignment: .bottom) {
            if !c.toast.isEmpty {
                Text(c.toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .glassChip(Capsule())
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: c.toast)
    }

    // 懸浮玻璃面板
    var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 標題
                HStack(spacing: 8) {
                    Image(systemName: "location.fill.viewfinder")
                        .font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FakeGPS").font(.title2.bold())
                        Text("iOS 位置模擬器").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // 狀態
                VStack(alignment: .leading, spacing: 9) {
                    statusRow(c.deviceConnected ? .green : .red,
                              c.deviceConnected ? "手機：\(c.deviceName)" : "未偵測到手機")
                    statusRow(c.tunnelUp ? .green : .secondary,
                              c.tunnelUp ? "已連線" : "未連線")
                    statusRow(c.simulating ? .green : .secondary,
                              c.simulating ? "模擬中：\(c.lastLabel)" : "未模擬")

                    Button {
                        c.startTunnel()
                    } label: {
                        HStack(spacing: 6) {
                            if c.busy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            }
                            Text(c.busy ? "連線中…" : "連線手機")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                    }
                    .glassButton(tint: .blue)
                    .controlSize(.large)
                    .disabled(!c.deviceConnected || c.tunnelUp || c.busy)

                    if !c.deviceConnected {
                        Label("請插上 iPhone、解鎖並信任這台電腦",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // 書籤
                if !c.bookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("常用地點", systemImage: "star")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        FlowLayout(spacing: 7) {
                            ForEach(c.bookmarks) { b in
                                HStack(spacing: 5) {
                                    Image(systemName: "mappin.circle.fill").foregroundStyle(.blue)
                                    Text(b.name)
                                        .onTapGesture {
                                            pick(b.lat, b.lon, b.name)
                                            c.setLocation(b.lat, b.lon, b.name)
                                        }
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                        .onTapGesture { c.delBookmark(b.name) }
                                }
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .glassChip(Capsule())
                            }
                        }
                    }
                }

                // 搜尋
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("搜尋地點", systemImage: "magnifyingglass")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        if searching { ProgressView().controlSize(.small) }
                    }
                    TextField("鼎泰豐 信義、海老名マルイ、東京駅", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: query) { _, q in scheduleSearch(q) }
                    ForEach(hits) { h in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.title).font(.callout.weight(.medium))
                            if !h.subtitle.isEmpty {
                                Text(h.subtitle).font(.caption2)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .glassChip(RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                        .onTapGesture { pick(h.coord.latitude, h.coord.longitude, h.title) }
                    }
                }

                // 座標
                VStack(alignment: .leading, spacing: 8) {
                    Label("或直接輸入座標", systemImage: "number")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    HStack {
                        TextField("緯度", text: $latText).textFieldStyle(.roundedBorder)
                        TextField("經度", text: $lonText).textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        Button { applySet() } label: {
                            Label("設定到這裡", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 3)
                        }
                        .glassButton(tint: .blue).controlSize(.large).disabled(!c.tunnelUp)

                        Button { addBookmark() } label: {
                            Image(systemName: "star").padding(.vertical, 3)
                        }
                        .glassButton().controlSize(.large)

                        Button { c.clear() } label: {
                            Image(systemName: "location.slash").padding(.vertical, 3)
                        }
                        .glassButton().controlSize(.large).disabled(!c.simulating)
                    }
                    Text("也可直接點地圖任一處選位置")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.never)
        .glassPanel(RoundedRectangle(cornerRadius: 22))
        .frame(maxHeight: .infinity)
    }

    // 地圖
    var mapView: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let p = picked {
                    Marker(pickedLabel.isEmpty ? "選定位置" : pickedLabel, coordinate: p)
                        .tint(.blue)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .onTapGesture { location in
                if let coord = proxy.convert(location, from: .local) {
                    pick(coord.latitude, coord.longitude, "地圖選點")
                }
            }
        }
    }

    func statusRow(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.callout)
            Spacer()
        }
    }

    func pick(_ lat: Double, _ lon: Double, _ label: String) {
        picked = .init(latitude: lat, longitude: lon)
        pickedLabel = label
        latText = String(format: "%.6f", lat)
        lonText = String(format: "%.6f", lon)
        withAnimation {
            camera = .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                                span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        }
    }

    func currentPoint() -> (Double, Double, String)? {
        guard let lat = Double(latText), let lon = Double(lonText) else { return nil }
        let label = (!pickedLabel.isEmpty) ? pickedLabel : "\(lat),\(lon)"
        return (lat, lon, label)
    }

    func applySet() {
        guard let (lat, lon, label) = currentPoint() else { c.flash("請先選地點或輸入座標"); return }
        c.setLocation(lat, lon, label)
    }

    func addBookmark() {
        guard let (lat, lon, label) = currentPoint() else { c.flash("請先選一個地點"); return }
        let alert = NSAlert()
        alert.messageText = "加入書籤"
        alert.informativeText = "輸入書籤名稱"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = label.components(separatedBy: CharacterSet(charactersIn: "·,")).first ?? label
        alert.accessoryView = field
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { c.addBookmark(name, lat, lon); c.flash("已加書籤：\(name)") }
        }
    }

    func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let query = q.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { hits = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await MainActor.run { searching = true }
            let r = await c.search(query)
            if Task.isCancelled { return }
            await MainActor.run { hits = r; searching = false }
        }
    }
}

// MARK: - 簡易 Flow 排版（書籤標籤換行）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x - bounds.minX + s.width > maxW { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller?
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct FakeGPSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("FakeGPS") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
