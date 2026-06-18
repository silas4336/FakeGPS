import SwiftUI
import MapKit
import AppKit

// MARK: - 設定
// 路徑不寫死：優先讀 ~/.fakegps/config（install.sh 寫入），否則在常見位置自動偵測。
enum Cfg {
    static let helperPath = "/usr/local/libexec/fakegps_tunnel.sh"
    static var stateDir: String { NSHomeDirectory() + "/.fakegps" }
    static var bookmarksFile: String { stateDir + "/bookmarks.json" }
    static var recentsFile: String { stateDir + "/recents.json" }
    static var routeFile: String { stateDir + "/route.gpx" }

    private static let cfg: [String: String] = {
        var d: [String: String] = [:]
        if let s = try? String(contentsOfFile: NSHomeDirectory() + "/.fakegps/config", encoding: .utf8) {
            for line in s.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    d[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
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
    static var python: String { resolve("python", ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]) }
    static var ideviceID: String { resolve("idevice_id", ["/opt/homebrew/bin/idevice_id", "/usr/local/bin/idevice_id"]) }
    static var ideviceInfo: String { resolve("ideviceinfo", ["/opt/homebrew/bin/ideviceinfo", "/usr/local/bin/ideviceinfo"]) }
    static var helper: String { cfg["helper"] ?? helperPath }
}

// MARK: - 資料模型
struct Place: Codable, Identifiable, Hashable {
    var name: String
    var lat: Double
    var lon: Double
    var id: String { "\(name)|\(lat)|\(lon)" }
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct SearchHit: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coord: CLLocationCoordinate2D
}

enum SpeedMode: Int, CaseIterable {
    case walk, bike, drive
    var label: String { ["步行", "騎車", "開車"][rawValue] }
    var mps: Double { [1.4, 5.5, 13.9][rawValue] }       // 公尺/秒
    var transport: MKDirectionsTransportType { self == .walk ? .walking : .automobile }
}

// MARK: - shell 工具
@discardableResult
func runSync(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
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
          let h = Range(m.range(at: 1), in: t), let p = Range(m.range(at: 2), in: t) else { return nil }
    return (String(t[h]), String(t[p]))
}

// MARK: - 控制器
@MainActor
final class Controller: ObservableObject {
    @Published var deviceConnected = false
    @Published var deviceName = ""
    @Published var tunnelUp = false
    @Published var simulating = false
    @Published var moving = false
    @Published var lastLabel = ""
    @Published var busy = false
    @Published var toast = ""
    @Published var bookmarks: [Place] = []
    @Published var recents: [Place] = []

    private var tunnelProc: Process?
    private var simProc: Process?
    private var routeProc: Process?
    private var rsdHost = ""
    private var rsdPort = ""
    private var timer: Timer?

    init() {
        bookmarks = load(Cfg.bookmarksFile)
        recents = load(Cfg.recentsFile)
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
        guard udid() != nil else {
            if deviceConnected { teardown() }
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
        if let p = routeProc, !p.isRunning { moving = false; routeProc = nil }
    }

    private func teardown() {
        simProc?.terminate(); simProc = nil
        routeProc?.terminate(); routeProc = nil
        tunnelProc = nil
        tunnelUp = false; simulating = false; moving = false; lastLabel = ""
    }

    func startTunnel() {
        guard let id = udid() else { flash("未偵測到手機"); return }
        guard FileManager.default.fileExists(atPath: Cfg.helper) else { flash("未安裝權限 helper，請重跑 install.sh"); return }
        busy = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", Cfg.helper, id]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            if self.busy && !self.tunnelUp { self.busy = false; self.flash("tunnel 建立逾時") }
        }
    }

    private func onTunnelReady(_ host: String, _ port: String) {
        guard !tunnelUp else { return }
        rsdHost = host; rsdPort = port
        DispatchQueue.global().async {
            _ = runSync(Cfg.python, ["-m", "pymobiledevice3", "mounter", "auto-mount", "--rsd", host, port])
        }
        tunnelUp = true; busy = false
        flash("tunnel 已建立")
    }

    private func pm3Args(_ tail: [String]) -> [String] {
        ["-m", "pymobiledevice3", "developer", "dvt", "simulate-location"] + tail + ["--rsd", rsdHost, rsdPort]
    }

    func setLocation(_ lat: Double, _ lon: Double, _ label: String) {
        guard tunnelUp, pid(tunnelProc) else { flash("請先連線手機"); return }
        stopMovingInternal()
        simProc?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Cfg.python)
        p.arguments = pm3Args(["set", "--", String(lat), String(lon)])
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { flash("設定失敗"); return }
        simProc = p
        simulating = true; lastLabel = label
        pushRecent(Place(name: label, lat: lat, lon: lon))
        flash("已設定：\(label)")
    }

    func clear() {
        stopMovingInternal()
        simProc?.terminate(); simProc = nil
        if tunnelUp { let a = pm3Args(["clear"]); DispatchQueue.global().async { _ = runSync(Cfg.python, a) } }
        simulating = false; lastLabel = ""
        flash("已清除，恢復真實 GPS")
    }

    // 路線移動：吃一串座標，依速度產生帶時間戳的 GPX 後 play
    func playRoute(_ coords: [CLLocationCoordinate2D], speed: SpeedMode, label: String) {
        guard tunnelUp, pid(tunnelProc), coords.count >= 2 else { flash("路線資料不足"); return }
        let gpx = makeTimedGPX(coords, mps: speed.mps)
        do { try gpx.write(toFile: Cfg.routeFile, atomically: true, encoding: .utf8) }
        catch { flash("無法寫入路線檔"); return }
        stopMovingInternal()
        simProc?.terminate(); simProc = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Cfg.python)
        p.arguments = ["-m", "pymobiledevice3", "developer", "dvt", "simulate-location",
                       "play", Cfg.routeFile, "--rsd", rsdHost, rsdPort]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.moving = false } }
        do { try p.run() } catch { flash("移動失敗"); return }
        routeProc = p
        moving = true; simulating = true; lastLabel = "移動中 → \(label)"
        flash("開始移動（\(speed.label)）→ \(label)")
    }

    func stopMoving() { stopMovingInternal(); flash("已停止移動") }
    private func stopMovingInternal() {
        if let p = routeProc, p.isRunning { p.terminate() }
        routeProc = nil; moving = false
    }

    func quitCleanup() {
        simProc?.terminate(); routeProc?.terminate()
        _ = runSync("/usr/bin/sudo", ["-n", Cfg.helper, "stop"])
    }

    func flash(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in if self?.toast == m { self?.toast = "" } }
    }
    private func pid(_ p: Process?) -> Bool { p?.isRunning ?? false }

    // MARK: 書籤 / 最近
    private func load(_ path: String) -> [Place] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let v = try? JSONDecoder().decode([Place].self, from: d) else { return [] }
        return v
    }
    private func save(_ items: [Place], _ path: String) {
        try? FileManager.default.createDirectory(atPath: Cfg.stateDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: URL(fileURLWithPath: path)) }
    }
    func addBookmark(_ name: String, _ lat: Double, _ lon: Double) {
        bookmarks.removeAll { $0.name == name }
        bookmarks.append(Place(name: name, lat: lat, lon: lon))
        save(bookmarks, Cfg.bookmarksFile)
    }
    func delBookmark(_ name: String) { bookmarks.removeAll { $0.name == name }; save(bookmarks, Cfg.bookmarksFile) }
    private func pushRecent(_ p: Place) {
        recents.removeAll { abs($0.lat - p.lat) < 1e-5 && abs($0.lon - p.lon) < 1e-5 }
        recents.insert(p, at: 0)
        if recents.count > 12 { recents = Array(recents.prefix(12)) }
        save(recents, Cfg.recentsFile)
    }
    var lastRecent: Place? { recents.first }

    // MARK: 搜尋（Apple Maps）
    func search(_ q: String) async -> [SearchHit] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return resp.mapItems.map {
            SearchHit(title: $0.name ?? "未命名", subtitle: $0.placemark.title ?? "", coord: $0.placemark.coordinate)
        }
    }
}

// MARK: - GPX（依速度配時間戳）
func makeTimedGPX(_ route: [CLLocationCoordinate2D], mps: Double, interval: Double = 1.0) -> String {
    // 沿路線等距取樣：每 interval 秒前進 mps*interval 公尺
    func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
    var cum = [0.0]
    for i in 1..<route.count { cum.append(cum[i-1] + dist(route[i-1], route[i])) }
    let total = cum.last ?? 0
    let step = max(mps * interval, 0.5)
    func interp(_ target: Double) -> CLLocationCoordinate2D {
        if target <= 0 { return route.first! }
        if target >= total { return route.last! }
        var i = 1
        while i < cum.count && cum[i] < target { i += 1 }
        let segLen = cum[i] - cum[i-1]
        let f = segLen > 0 ? (target - cum[i-1]) / segLen : 0
        let a = route[i-1], b = route[i]
        return .init(latitude: a.latitude + (b.latitude - a.latitude) * f,
                     longitude: a.longitude + (b.longitude - a.longitude) * f)
    }
    let n = min(Int(total / step), 5000)
    let iso = ISO8601DateFormatter()
    let base = Date()
    var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"FakeGPS\">\n<trk><trkseg>\n"
    for k in 0...max(n, 1) {
        let c = interp(Double(k) * step)
        let t = iso.string(from: base.addingTimeInterval(Double(k) * interval))
        s += "<trkpt lat=\"\(c.latitude)\" lon=\"\(c.longitude)\"><time>\(t)</time></trkpt>\n"
    }
    s += "</trkseg></trk>\n</gpx>\n"
    return s
}

extension MKPolyline {
    var coords: [CLLocationCoordinate2D] {
        var c = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&c, range: NSRange(location: 0, length: pointCount))
        return c
    }
}

// MARK: - Liquid Glass 輔助
extension View {
    @ViewBuilder func glassPanel<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(.regular, in: shape) }
        else { self.background(.ultraThinMaterial, in: shape).overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1)) }
    }
    @ViewBuilder func glassChip<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(.regular.interactive(), in: shape) }
        else { self.background(.thinMaterial, in: shape) }
    }
    @ViewBuilder func glassButton(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint { self.buttonStyle(.glass).tint(tint) } else { self.buttonStyle(.glass) }
        } else { self.buttonStyle(.borderedProminent) }
    }
}

// MARK: - 主畫面
struct ContentView: View {
    @StateObject private var c = Controller()
    @FocusState private var searchFocused: Bool

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var latText = ""
    @State private var lonText = ""
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedLabel = ""
    @State private var routeStart: CLLocationCoordinate2D?
    @State private var routeStartLabel = ""
    @State private var speedSel = 0
    @State private var styleSel = 0
    @State private var camera: MapCameraPosition =
        .region(MKCoordinateRegion(center: .init(latitude: 25.0338, longitude: 121.5645),
                                    span: .init(latitudeDelta: 0.4, longitudeDelta: 0.4)))
    @State private var searchTask: Task<Void, Never>?

    private var mapStyle: MapStyle {
        [MapStyle.standard(elevation: .realistic), .hybrid(elevation: .realistic), .imagery(elevation: .realistic)][styleSel]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            mapView.ignoresSafeArea()
            panel.frame(width: 340).padding(14)
            // 微調搖桿（右下）
            nudgePad.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(20)
        }
        .frame(minWidth: 980, minHeight: 680)
        .overlay(alignment: .bottom) {
            if !c.toast.isEmpty {
                Text(c.toast).font(.callout.weight(.medium))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .glassChip(Capsule()).padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: c.toast)
        .focusable()
        .onKeyPress { press in handleKey(press) }
        .onAppear { if let r = c.lastRecent { center(r.coord, zoom: 0.05) } }
    }

    // 懸浮玻璃面板
    var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill.viewfinder").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FakeGPS").font(.title2.bold())
                        Text("iOS 位置模擬器").font(.caption).foregroundStyle(.secondary)
                    }
                }

                statusBlock
                if !c.bookmarks.isEmpty { chips("常用地點", "star", c.bookmarks, deletable: true) }
                if !c.recents.isEmpty { chips("最近使用", "clock", c.recents, deletable: false) }
                searchBlock
                coordBlock
                routeBlock
            }
            .padding(18)
        }
        .scrollIndicators(.never)
        .glassPanel(RoundedRectangle(cornerRadius: 22))
        .frame(maxHeight: .infinity)
    }

    var statusBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            statusRow(c.deviceConnected ? .green : .red, c.deviceConnected ? "手機：\(c.deviceName)" : "未偵測到手機")
            statusRow(c.tunnelUp ? .green : .secondary, c.tunnelUp ? "已連線" : "未連線")
            statusRow(c.moving ? .orange : (c.simulating ? .green : .secondary),
                      c.moving ? c.lastLabel : (c.simulating ? "模擬中：\(c.lastLabel)" : "未模擬"))
            Button { c.startTunnel() } label: {
                HStack(spacing: 6) {
                    if c.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "iphone.gen3.radiowaves.left.and.right") }
                    Text(c.busy ? "連線中…" : "連線手機")
                }.frame(maxWidth: .infinity).padding(.vertical, 3)
            }
            .glassButton(tint: .blue).controlSize(.large)
            .disabled(!c.deviceConnected || c.tunnelUp || c.busy)
            if !c.deviceConnected {
                Label("請插上 iPhone、解鎖並信任這台電腦", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    func chips(_ title: String, _ icon: String, _ items: [Place], deletable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption.bold()).foregroundStyle(.secondary)
            FlowLayout(spacing: 7) {
                ForEach(items) { b in
                    HStack(spacing: 5) {
                        Image(systemName: deletable ? "mappin.circle.fill" : "clock.arrow.circlepath").foregroundStyle(.blue)
                        Text(b.name).lineLimit(1)
                            .onTapGesture { pick(b.lat, b.lon, b.name); c.setLocation(b.lat, b.lon, b.name) }
                        if deletable {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                .onTapGesture { c.delBookmark(b.name) }
                        }
                    }
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 6).glassChip(Capsule())
                }
            }
        }
    }

    var searchBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("搜尋地點", systemImage: "magnifyingglass").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if searching { ProgressView().controlSize(.small) }
            }
            TextField("鼎泰豐 信義、海老名マルイ、東京駅", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onChange(of: query) { _, q in scheduleSearch(q) }
            ForEach(hits) { h in
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.title).font(.callout.weight(.medium))
                    if !h.subtitle.isEmpty { Text(h.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                .glassChip(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                .onTapGesture { pick(h.coord.latitude, h.coord.longitude, h.title) }
            }
        }
    }

    var coordBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("座標", systemImage: "number").font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                TextField("緯度", text: $latText).textFieldStyle(.roundedBorder)
                TextField("經度", text: $lonText).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button { applySet() } label: {
                    Label("設定", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 3)
                }.glassButton(tint: .blue).controlSize(.large).disabled(!c.tunnelUp).keyboardShortcut(.return, modifiers: .command)
                Button { addBookmark() } label: { Image(systemName: "star").padding(.vertical, 3) }.glassButton().controlSize(.large)
                Button { c.clear() } label: { Image(systemName: "location.slash").padding(.vertical, 3) }
                    .glassButton().controlSize(.large).disabled(!c.simulating).keyboardShortcut("k", modifiers: .command)
            }
        }
    }

    var routeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("移動模擬", systemImage: "figure.walk.motion").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("", selection: $speedSel) {
                ForEach(SpeedMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }.pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 8) {
                Button { setRouteStart() } label: {
                    Label(routeStart == nil ? "設為起點" : "起點已設", systemImage: "flag")
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                }.glassButton().controlSize(.large)
                Button { startRoute() } label: {
                    Label(c.moving ? "停止" : "開始移動", systemImage: c.moving ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                }.glassButton(tint: c.moving ? .orange : .green).controlSize(.large).disabled(!c.tunnelUp)
            }
            Text(routeStart == nil ? "先「設為起點」，再選終點後按開始（沿真實道路移動）"
                                   : "起點：\(routeStartLabel) → 選終點後開始")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // 微調搖桿
    var nudgePad: some View {
        VStack(spacing: 6) {
            nudgeBtn("chevron.up", 1, 0)
            HStack(spacing: 6) { nudgeBtn("chevron.left", 0, -1); nudgeBtn("scope", 0, 0); nudgeBtn("chevron.right", 0, 1) }
            nudgeBtn("chevron.down", -1, 0)
        }
        .padding(10).glassPanel(RoundedRectangle(cornerRadius: 16))
        .opacity(picked == nil ? 0.45 : 1)
    }
    func nudgeBtn(_ icon: String, _ dy: Int, _ dx: Int) -> some View {
        Button { nudge(Double(dy), Double(dx)) } label: {
            Image(systemName: icon).frame(width: 26, height: 22)
        }.buttonStyle(.plain).disabled(picked == nil && icon != "scope")
    }

    var mapView: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let p = picked {
                    Marker(pickedLabel.isEmpty ? "選定位置" : pickedLabel, coordinate: p).tint(.blue)
                }
                if let s = routeStart { Marker("起點", systemImage: "flag.fill", coordinate: s).tint(.green) }
                ForEach(hits.prefix(8)) { h in
                    Marker(h.title, coordinate: h.coord).tint(.gray)
                }
            }
            .mapStyle(mapStyle)
            .onTapGesture { loc in if let coord = proxy.convert(loc, from: .local) { pickAndReverse(coord) } }
            .overlay(alignment: .topTrailing) {
                Picker("", selection: $styleSel) {
                    Image(systemName: "map").tag(0); Image(systemName: "globe.americas").tag(1); Image(systemName: "mountain.2").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 130).padding(10).glassChip(Capsule()).padding(12)
            }
        }
    }

    func statusRow(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) { Circle().fill(color).frame(width: 9, height: 9); Text(text).font(.callout).lineLimit(1); Spacer() }
    }

    // MARK: 行為
    func center(_ co: CLLocationCoordinate2D, zoom: Double) {
        withAnimation { camera = .region(MKCoordinateRegion(center: co, span: .init(latitudeDelta: zoom, longitudeDelta: zoom))) }
    }
    func pick(_ lat: Double, _ lon: Double, _ label: String, recenter: Bool = true) {
        picked = .init(latitude: lat, longitude: lon); pickedLabel = label
        latText = String(format: "%.6f", lat); lonText = String(format: "%.6f", lon)
        if recenter { center(.init(latitude: lat, longitude: lon), zoom: 0.02) }
    }
    func pickAndReverse(_ coord: CLLocationCoordinate2D) {
        pick(coord.latitude, coord.longitude, "地圖選點")
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude)) { pls, _ in
            if let n = pls?.first?.name { Task { @MainActor in
                if abs((picked?.latitude ?? 0) - coord.latitude) < 1e-6 { pickedLabel = n } } }
        }
    }
    func currentPoint() -> (Double, Double, String)? {
        guard let lat = Double(latText), let lon = Double(lonText) else { return nil }
        return (lat, lon, pickedLabel.isEmpty ? "\(lat),\(lon)" : pickedLabel)
    }
    func applySet() { guard let (a, b, l) = currentPoint() else { c.flash("請先選地點或輸入座標"); return }; c.setLocation(a, b, l) }
    func addBookmark() {
        guard let (lat, lon, label) = currentPoint() else { c.flash("請先選一個地點"); return }
        let alert = NSAlert(); alert.messageText = "加入書籤"; alert.informativeText = "輸入書籤名稱"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = label.components(separatedBy: CharacterSet(charactersIn: "·,")).first ?? label
        alert.accessoryView = field; alert.addButton(withTitle: "儲存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { c.addBookmark(name, lat, lon); c.flash("已加書籤：\(name)") }
        }
    }
    func setRouteStart() {
        guard let p = picked else { c.flash("先在地圖選一個點當起點"); return }
        routeStart = p; routeStartLabel = pickedLabel.isEmpty ? "選定點" : pickedLabel
        c.flash("起點已設：\(routeStartLabel)")
    }
    func startRoute() {
        if c.moving { c.stopMoving(); return }
        guard let dest = picked else { c.flash("請選一個終點"); return }
        let start = routeStart ?? dest
        let mode = SpeedMode(rawValue: speedSel)!
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        req.transportType = mode.transport
        c.flash("計算路線中…")
        MKDirections(request: req).calculate { resp, _ in
            Task { @MainActor in
                if let route = resp?.routes.first {
                    c.playRoute(route.polyline.coords, speed: mode, label: pickedLabel.isEmpty ? "終點" : pickedLabel)
                } else {
                    c.playRoute([start, dest], speed: mode, label: "終點")   // 無路線則走直線
                }
            }
        }
    }
    func nudge(_ dy: Double, _ dx: Double) {
        guard let p = picked else { return }
        if dy == 0 && dx == 0 { center(p, zoom: 0.005); return }   // scope = 置中
        let d = 0.00004                                            // 約 4 公尺/步
        let lat = p.latitude + dy * d, lon = p.longitude + dx * d
        pick(lat, lon, pickedLabel, recenter: false)              // 不重新置中，避免畫面跳動
        if c.simulating { c.setLocation(lat, lon, pickedLabel) }
    }
    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if searchFocused { return .ignored }
        switch press.key {
        case .upArrow: nudge(1, 0); return .handled
        case .downArrow: nudge(-1, 0); return .handled
        case .leftArrow: nudge(0, -1); return .handled
        case .rightArrow: nudge(0, 1); return .handled
        default: return .ignored
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

// MARK: - Flow 排版
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
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
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
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct FakeGPSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("FakeGPS") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
