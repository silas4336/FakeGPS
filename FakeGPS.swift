import SwiftUI
import MapKit
import AppKit

// MARK: - 設定路徑
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
                if kv.count == 2 { d[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
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

// MARK: - 在地語系（讀 @AppStorage("lang")；en 回英文，否則繁中）
func loc(_ zh: String, _ en: String) -> String {
    (UserDefaults.standard.string(forKey: "lang") ?? "zh") == "en" ? en : zh
}

// MARK: - 資料模型
struct Place: Codable, Identifiable, Hashable {
    var name: String; var lat: Double; var lon: Double
    var id: String { "\(name)|\(lat)|\(lon)" }
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
struct SearchHit: Identifiable {
    let id = UUID(); let title: String; let subtitle: String; let coord: CLLocationCoordinate2D
}
enum SpeedMode: Int, CaseIterable {
    case walk, bike, drive
    var label: String { [loc("步行", "Walk"), loc("騎車", "Cycle"), loc("開車", "Drive")][rawValue] }
    var mps: Double { [1.4, 5.5, 13.9][rawValue] }
    var transport: MKDirectionsTransportType { self == .walk ? .walking : .automobile }
}

// MARK: - shell 工具
@discardableResult
func runSync(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
func parseRSD(_ line: String) -> (String, String)? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard let r = try? NSRegularExpression(pattern: "^([0-9a-fA-F:]+)\\s+([0-9]+)$") else { return nil }
    guard let m = r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
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
    @Published var lastCoord: CLLocationCoordinate2D?
    @Published var busy = false
    @Published var toast = ""
    @Published var bookmarks: [Place] = []
    @Published var recents: [Place] = []

    private var tunnelProc, simProc, routeProc: Process?
    private var rsdHost = "", rsdPort = ""
    private var timer: Timer?

    init() {
        bookmarks = load(Cfg.bookmarksFile); recents = load(Cfg.recentsFile)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func udid() -> String? {
        let (rc, out) = runSync(Cfg.ideviceID, ["-l"]); guard rc == 0 else { return nil }
        let id = out.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        return (id?.isEmpty == false) ? id : nil
    }
    func poll() {
        guard udid() != nil else {
            if deviceConnected { teardown() }
            deviceConnected = false; deviceName = ""; return
        }
        deviceConnected = true
        if deviceName.isEmpty {
            let (_, n) = runSync(Cfg.ideviceInfo, ["-k", "DeviceName"]); deviceName = n.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let p = tunnelProc, !p.isRunning { tunnelUp = false }
        if let p = simProc, !p.isRunning { simulating = false }
        if let p = routeProc, !p.isRunning { moving = false; routeProc = nil }
    }
    private func teardown() {
        simProc?.terminate(); routeProc?.terminate(); simProc = nil; routeProc = nil; tunnelProc = nil
        tunnelUp = false; simulating = false; moving = false; lastLabel = ""
    }
    func startTunnel() {
        guard let id = udid() else { flash(loc("未偵測到手機", "No iPhone detected")); return }
        guard FileManager.default.fileExists(atPath: Cfg.helper) else { flash(loc("未安裝權限 helper，請重跑 install.sh", "Helper not installed — re-run install.sh")); return }
        busy = true
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); p.arguments = ["-n", Cfg.helper, id]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(data: h.availableData, encoding: .utf8) ?? ""
            for line in s.split(separator: "\n") where parseRSD(String(line)) != nil {
                let rsd = parseRSD(String(line))!
                Task { @MainActor in self?.onTunnelReady(rsd.0, rsd.1) }
            }
        }
        do { try p.run() } catch { busy = false; flash(loc("啟動 tunnel 失敗", "Failed to start tunnel")); return }
        tunnelProc = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            if self.busy && !self.tunnelUp { self.busy = false; self.flash(loc("tunnel 建立逾時", "Tunnel timed out")) }
        }
    }
    private func onTunnelReady(_ host: String, _ port: String) {
        guard !tunnelUp else { return }
        rsdHost = host; rsdPort = port
        DispatchQueue.global().async { _ = runSync(Cfg.python, ["-m", "pymobiledevice3", "mounter", "auto-mount", "--rsd", host, port]) }
        tunnelUp = true; busy = false; flash(loc("tunnel 已建立", "Tunnel ready"))
    }
    private func pm3(_ tail: [String]) -> [String] {
        ["-m", "pymobiledevice3", "developer", "dvt", "simulate-location"] + tail + ["--rsd", rsdHost, rsdPort]
    }
    func setLocation(_ lat: Double, _ lon: Double, _ label: String) {
        guard tunnelUp, tunnelProc?.isRunning == true else { flash(loc("請先連線手機", "Connect the phone first")); return }
        stopMovingInternal(); simProc?.terminate()
        let p = Process(); p.executableURL = URL(fileURLWithPath: Cfg.python)
        p.arguments = pm3(["set", "--", String(lat), String(lon)])
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { flash(loc("設定失敗", "Failed to set")); return }
        simProc = p; simulating = true; lastLabel = label; lastCoord = .init(latitude: lat, longitude: lon)
        pushRecent(Place(name: label, lat: lat, lon: lon))
        flash(loc("已設定：", "Set: ") + label)
    }
    func clear() {
        stopMovingInternal(); simProc?.terminate(); simProc = nil
        if tunnelUp { let a = pm3(["clear"]); DispatchQueue.global().async { _ = runSync(Cfg.python, a) } }
        simulating = false; lastLabel = ""; flash(loc("已清除，恢復真實 GPS", "Cleared — real GPS restored"))
    }
    func playRoute(_ coords: [CLLocationCoordinate2D], speed: SpeedMode, label: String) {
        guard tunnelUp, tunnelProc?.isRunning == true, coords.count >= 2 else { flash(loc("路線資料不足", "Not enough route data")); return }
        do { try makeTimedGPX(coords, mps: speed.mps).write(toFile: Cfg.routeFile, atomically: true, encoding: .utf8) }
        catch { flash(loc("無法寫入路線檔", "Cannot write route file")); return }
        stopMovingInternal(); simProc?.terminate(); simProc = nil
        let p = Process(); p.executableURL = URL(fileURLWithPath: Cfg.python)
        p.arguments = ["-m", "pymobiledevice3", "developer", "dvt", "simulate-location", "play", Cfg.routeFile, "--rsd", rsdHost, rsdPort]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.moving = false } }
        do { try p.run() } catch { flash(loc("移動失敗", "Failed to move")); return }
        routeProc = p; moving = true; simulating = true; lastLabel = loc("移動中 → ", "Moving → ") + label
        flash(loc("開始移動（", "Moving (") + speed.label + loc("）→ ", ") → ") + label)
    }
    func stopMoving() { stopMovingInternal(); flash(loc("已停止移動", "Stopped moving")) }
    private func stopMovingInternal() { if let p = routeProc, p.isRunning { p.terminate() }; routeProc = nil; moving = false }
    func quitCleanup() { simProc?.terminate(); routeProc?.terminate(); _ = runSync("/usr/bin/sudo", ["-n", Cfg.helper, "stop"]) }
    func flash(_ m: String) {
        toast = m; DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in if self?.toast == m { self?.toast = "" } }
    }
    private func load(_ path: String) -> [Place] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let v = try? JSONDecoder().decode([Place].self, from: d) else { return [] }
        return v
    }
    private func save(_ items: [Place], _ path: String) {
        try? FileManager.default.createDirectory(atPath: Cfg.stateDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: URL(fileURLWithPath: path)) }
    }
    func addBookmark(_ name: String, _ lat: Double, _ lon: Double) {
        bookmarks.removeAll { $0.name == name }; bookmarks.append(Place(name: name, lat: lat, lon: lon)); save(bookmarks, Cfg.bookmarksFile)
    }
    func delBookmark(_ name: String) { bookmarks.removeAll { $0.name == name }; save(bookmarks, Cfg.bookmarksFile) }
    private func pushRecent(_ p: Place) {
        recents.removeAll { abs($0.lat - p.lat) < 1e-5 && abs($0.lon - p.lon) < 1e-5 }
        recents.insert(p, at: 0); if recents.count > 12 { recents = Array(recents.prefix(12)) }; save(recents, Cfg.recentsFile)
    }
    var lastRecent: Place? { recents.first }
    func search(_ q: String) async -> [SearchHit] {
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = q
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return resp.mapItems.map { SearchHit(title: $0.name ?? "?", subtitle: $0.placemark.title ?? "", coord: $0.placemark.coordinate) }
    }
}

// MARK: - GPX
func makeTimedGPX(_ route: [CLLocationCoordinate2D], mps: Double, interval: Double = 1.0) -> String {
    func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
    var cum = [0.0]; for i in 1..<route.count { cum.append(cum[i-1] + dist(route[i-1], route[i])) }
    let total = cum.last ?? 0, step = max(mps * interval, 0.5)
    func interp(_ target: Double) -> CLLocationCoordinate2D {
        if target <= 0 { return route.first! }; if target >= total { return route.last! }
        var i = 1; while i < cum.count && cum[i] < target { i += 1 }
        let segLen = cum[i] - cum[i-1], f = segLen > 0 ? (target - cum[i-1]) / segLen : 0
        let a = route[i-1], b = route[i]
        return .init(latitude: a.latitude + (b.latitude - a.latitude) * f, longitude: a.longitude + (b.longitude - a.longitude) * f)
    }
    let n = min(Int(total / step), 5000), iso = ISO8601DateFormatter(), base = Date()
    var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"FakeGPS\">\n<trk><trkseg>\n"
    for k in 0...max(n, 1) {
        let c = interp(Double(k) * step), t = iso.string(from: base.addingTimeInterval(Double(k) * interval))
        s += "<trkpt lat=\"\(c.latitude)\" lon=\"\(c.longitude)\"><time>\(t)</time></trkpt>\n"
    }
    return s + "</trkseg></trk>\n</gpx>\n"
}
extension MKPolyline {
    var coords: [CLLocationCoordinate2D] {
        var c = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&c, range: NSRange(location: 0, length: pointCount)); return c
    }
}

// MARK: - Liquid Glass
extension View {
    @ViewBuilder func glassPanel<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(.regular, in: shape) }
        else { self.background(.ultraThinMaterial, in: shape).overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1)) }
    }
    @ViewBuilder func glassChip<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(.regular.interactive(), in: shape) } else { self.background(.thinMaterial, in: shape) }
    }
    @ViewBuilder func glassButton(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) { if let tint { self.buttonStyle(.glass).tint(tint) } else { self.buttonStyle(.glass) } }
        else { self.buttonStyle(.borderedProminent) }
    }
}

// MARK: - 主畫面
struct ContentView: View {
    @StateObject private var c = Controller()
    @FocusState private var searchFocused: Bool
    @AppStorage("lang") private var lang = "zh"
    @AppStorage("defaultSpeed") private var defaultSpeed = 0
    @AppStorage("nudgeMeters") private var nudgeMeters = 4.0

    @State private var query = ""
    @State private var searching = false
    @State private var hits: [SearchHit] = []
    @State private var latText = ""
    @State private var lonText = ""
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedLabel = ""
    @State private var routeStart: CLLocationCoordinate2D?
    @State private var routeStartLabel = ""
    @State private var speedSel = 0
    @State private var styleSel = 0
    @State private var camera: MapCameraPosition =
        .region(MKCoordinateRegion(center: .init(latitude: 25.0338, longitude: 121.5645), span: .init(latitudeDelta: 0.4, longitudeDelta: 0.4)))
    @State private var searchTask: Task<Void, Never>?

    private var mapStyle: MapStyle {
        [MapStyle.standard(elevation: .realistic), .hybrid(elevation: .realistic), .imagery(elevation: .realistic)][styleSel]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                mapView.ignoresSafeArea()
                panel
                    .frame(width: 330, height: max(geo.size.height - 60, 240), alignment: .top)
                    .padding(.top, 14).padding(.leading, 14)   // 底部留白 → 露出左下角 Apple Maps logo
                nudgePad.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .overlay(alignment: .bottom) {
            if !c.toast.isEmpty {
                Text(c.toast).font(.callout.weight(.medium)).padding(.horizontal, 18).padding(.vertical, 11)
                    .glassChip(Capsule()).padding(.bottom, 22).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: c.toast)
        .focusable().onKeyPress { handleKey($0) }
        .onAppear { speedSel = defaultSpeed; if let r = c.lastRecent { center(r.coord, zoom: 0.05) } }
    }

    var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill.viewfinder").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FakeGPS").font(.title2.bold())
                        Text(loc("iOS 位置模擬器", "iOS location simulator")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape").font(.title3) }.buttonStyle(.plain).help(loc("設定", "Settings"))
                }
                statusBlock
                if !c.bookmarks.isEmpty { chips(loc("常用地點", "Favorites"), "star", c.bookmarks, deletable: true) }
                if !c.recents.isEmpty { chips(loc("最近使用", "Recents"), "clock", c.recents, deletable: false) }
                searchBlock
                coordBlock
                routeBlock
            }.padding(18)
        }
        .scrollIndicators(.never)
        .glassPanel(RoundedRectangle(cornerRadius: 22))
        .contentShape(RoundedRectangle(cornerRadius: 22))   // 面板攔截點擊，避免穿透到地圖設點
    }

    var statusBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            statusRow(c.deviceConnected ? .green : .red, c.deviceConnected ? loc("手機：", "Phone: ") + c.deviceName : loc("未偵測到手機", "No phone detected"))
            statusRow(c.tunnelUp ? .green : .secondary, c.tunnelUp ? loc("已連線", "Connected") : loc("未連線", "Not connected"))
            statusRow(c.moving ? .orange : (c.simulating ? .green : .secondary),
                      c.moving ? c.lastLabel : (c.simulating ? loc("模擬中：", "Simulating: ") + c.lastLabel : loc("未模擬", "Not simulating")))
            Button { c.startTunnel() } label: {
                HStack(spacing: 6) {
                    if c.busy { ProgressView().controlSize(.small) } else { Image(systemName: "iphone.gen3.radiowaves.left.and.right") }
                    Text(c.busy ? loc("連線中…", "Connecting…") : loc("連線手機", "Connect phone"))
                }.frame(maxWidth: .infinity).padding(.vertical, 3)
            }.glassButton(tint: .blue).controlSize(.large).disabled(!c.deviceConnected || c.tunnelUp || c.busy)
            if !c.deviceConnected {
                Label(loc("請插上 iPhone、解鎖並信任這台電腦", "Plug in iPhone, unlock, and tap Trust"), systemImage: "exclamationmark.triangle")
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
                        Text(b.name).lineLimit(1).onTapGesture { pick(b.lat, b.lon, b.name); c.setLocation(b.lat, b.lon, b.name) }
                        if deletable { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).onTapGesture { c.delBookmark(b.name) } }
                    }.font(.caption).padding(.horizontal, 10).padding(.vertical, 6).glassChip(Capsule())
                }
            }
        }
    }
    var searchBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(loc("搜尋地點", "Search"), systemImage: "magnifyingglass").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer(); if searching { ProgressView().controlSize(.small) }
            }
            TextField(loc("鼎泰豐 信義、東京駅、Eiffel Tower", "e.g. Eiffel Tower, Tokyo Station"), text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused).onChange(of: query) { _, q in scheduleSearch(q) }
            ForEach(hits) { h in
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.title).font(.callout.weight(.medium))
                    if !h.subtitle.isEmpty { Text(h.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                .glassChip(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                .onTapGesture { pick(h.coord.latitude, h.coord.longitude, h.title) }
            }
        }
    }
    var coordBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc("座標", "Coordinates"), systemImage: "number").font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                TextField(loc("緯度", "lat"), text: $latText).textFieldStyle(.roundedBorder)
                TextField(loc("經度", "lon"), text: $lonText).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button { applySet() } label: { Label(loc("設定", "Set"), systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 3) }
                    .glassButton(tint: .blue).controlSize(.large).keyboardShortcut(.return, modifiers: .command)
                Button { addBookmark() } label: { Image(systemName: "star").padding(.vertical, 3) }.glassButton().controlSize(.large)
                Button { c.clear() } label: { Image(systemName: "location.slash").padding(.vertical, 3) }
                    .glassButton().controlSize(.large).disabled(!c.simulating).keyboardShortcut("k", modifiers: .command)
            }
        }
    }
    var routeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc("移動模擬", "Movement"), systemImage: "figure.walk.motion").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("", selection: $speedSel) { ForEach(SpeedMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden()
            // 起點 / 終點 清楚標示
            VStack(alignment: .leading, spacing: 3) {
                routePoint(loc("起點", "Start"), .green,
                           routeStart != nil ? routeStartLabel : (c.simulating ? loc("目前模擬位置", "Current location") : loc("未設定", "not set")))
                routePoint(loc("終點", "End"), .blue, picked != nil ? (pickedLabel.isEmpty ? loc("選取點", "selected point") : pickedLabel) : loc("在地圖選一個點", "pick a point on the map"))
            }
            HStack(spacing: 8) {
                Button { setRouteStart() } label: { Label(loc("選取點設為起點", "Set start"), systemImage: "flag").frame(maxWidth: .infinity).padding(.vertical, 3) }
                    .glassButton().controlSize(.large).disabled(picked == nil)
                Button { startRoute() } label: {
                    Label(c.moving ? loc("停止", "Stop") : loc("開始移動", "Go"), systemImage: c.moving ? "stop.fill" : "play.fill").frame(maxWidth: .infinity).padding(.vertical, 3)
                }.glassButton(tint: c.moving ? .orange : .green).controlSize(.large)
            }
            Text(loc("沿真實道路從起點移動到終點；起點留空則用目前模擬位置。", "Moves along real roads from start to end; leave start empty to use the current location."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    func routePoint(_ tag: String, _ color: Color, _ value: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(tag).font(.caption2.bold()).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            Text(value).font(.caption2).lineLimit(1)
        }
    }
    var nudgePad: some View {
        VStack(spacing: 8) {
            nudgeBtn("chevron.up", 1, 0)
            HStack(spacing: 8) { nudgeBtn("chevron.left", 0, -1); nudgeBtn("scope", 0, 0); nudgeBtn("chevron.right", 0, 1) }
            nudgeBtn("chevron.down", -1, 0)
        }
        .padding(14)
        .glassPanel(RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))   // 整塊攔截點擊，不穿透到地圖
        .opacity(picked == nil ? 0.5 : 1)
    }
    func nudgeBtn(_ icon: String, _ dy: Int, _ dx: Int) -> some View {
        Button { nudge(Double(dy), Double(dx)) } label: {
            Image(systemName: icon).font(.title3.weight(.semibold))
                .frame(width: 50, height: 44)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).disabled(picked == nil && icon != "scope")
    }
    var mapView: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let p = picked { Marker(pickedLabel.isEmpty ? loc("終點", "End") : pickedLabel, coordinate: p).tint(.blue) }
                if let s = routeStart { Marker(loc("起點", "Start"), systemImage: "flag.fill", coordinate: s).tint(.green) }
                ForEach(hits.prefix(8)) { Marker($0.title, coordinate: $0.coord).tint(.gray) }
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
    func center(_ co: CLLocationCoordinate2D, zoom: Double) {
        withAnimation { camera = .region(MKCoordinateRegion(center: co, span: .init(latitudeDelta: zoom, longitudeDelta: zoom))) }
    }
    func pick(_ lat: Double, _ lon: Double, _ label: String, recenter: Bool = true) {
        picked = .init(latitude: lat, longitude: lon); pickedLabel = label
        latText = String(format: "%.6f", lat); lonText = String(format: "%.6f", lon)
        if recenter { center(.init(latitude: lat, longitude: lon), zoom: 0.02) }
    }
    func pickAndReverse(_ coord: CLLocationCoordinate2D) {
        pick(coord.latitude, coord.longitude, loc("地圖選點", "Map point"))
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude)) { pls, _ in
            if let n = pls?.first?.name { Task { @MainActor in if abs((picked?.latitude ?? 0) - coord.latitude) < 1e-6 { pickedLabel = n } } }
        }
    }
    func currentPoint() -> (Double, Double, String)? {
        guard let lat = Double(latText), let lon = Double(lonText) else { return nil }
        return (lat, lon, pickedLabel.isEmpty ? "\(lat),\(lon)" : pickedLabel)
    }
    func applySet() { guard let (a, b, l) = currentPoint() else { c.flash(loc("請先選地點或輸入座標", "Pick a place or enter coordinates")); return }; c.setLocation(a, b, l) }
    func addBookmark() {
        guard let (lat, lon, label) = currentPoint() else { c.flash(loc("請先選一個地點", "Pick a place first")); return }
        let alert = NSAlert(); alert.messageText = loc("加入書籤", "Add bookmark"); alert.informativeText = loc("輸入書籤名稱", "Enter a name")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = label.components(separatedBy: CharacterSet(charactersIn: "·,")).first ?? label
        alert.accessoryView = field; alert.addButton(withTitle: loc("儲存", "Save")); alert.addButton(withTitle: loc("取消", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { c.addBookmark(name, lat, lon); c.flash(loc("已加書籤：", "Bookmarked: ") + name) }
        }
    }
    func setRouteStart() {
        guard let p = picked else { c.flash(loc("先在地圖選一個點當起點", "Pick a point on the map first")); return }
        routeStart = p; routeStartLabel = pickedLabel.isEmpty ? loc("選定點", "selected point") : pickedLabel
        c.flash(loc("起點已設：", "Start set: ") + routeStartLabel)
    }
    func startRoute() {
        if c.moving { c.stopMoving(); return }
        guard c.tunnelUp else { c.flash(loc("請先按「連線手機」", "Tap \"Connect phone\" first")); return }
        guard let dest = picked else { c.flash(loc("請先選一個終點（在地圖點一下）", "Pick an end point (tap the map)")); return }
        guard let start = routeStart ?? c.lastCoord else {
            c.flash(loc("請先設定起點：按「選取點設為起點」，或先設定一個目前位置", "Set a start first: use \"Set start\", or set a current location"))
            return
        }
        let mode = SpeedMode(rawValue: speedSel) ?? .walk
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        req.transportType = mode.transport
        c.flash(loc("計算路線中…", "Calculating route…"))
        MKDirections(request: req).calculate { resp, _ in
            Task { @MainActor in
                let label = pickedLabel.isEmpty ? loc("終點", "end") : pickedLabel
                if let route = resp?.routes.first { c.playRoute(route.polyline.coords, speed: mode, label: label) }
                else { c.playRoute([start, dest], speed: mode, label: label) }
            }
        }
    }
    func nudge(_ dy: Double, _ dx: Double) {
        guard let p = picked else { return }
        if dy == 0 && dx == 0 { center(p, zoom: 0.005); return }
        let d = nudgeMeters / 111_000.0   // 公尺 → 約略緯度度數
        let lat = p.latitude + dy * d, lon = p.longitude + dx * d
        pick(lat, lon, pickedLabel, recenter: false)
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

// MARK: - 設定視窗
struct SettingsView: View {
    @AppStorage("lang") private var lang = "zh"
    @AppStorage("defaultSpeed") private var defaultSpeed = 0
    @AppStorage("nudgeMeters") private var nudgeMeters = 4.0

    var body: some View {
        Form {
            Picker(loc("語言", "Language"), selection: $lang) {
                Text("繁體中文").tag("zh"); Text("English").tag("en")
            }
            Picker(loc("預設移動速度", "Default speed"), selection: $defaultSpeed) {
                ForEach(SpeedMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            VStack(alignment: .leading) {
                Text(loc("微調步距：", "Nudge step: ") + String(format: "%.0f m", nudgeMeters))
                Slider(value: $nudgeMeters, in: 1...50, step: 1)
            }
            Divider()
            HStack {
                Text(loc("版本", "Version")); Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—").foregroundStyle(.secondary)
            }
            Link(loc("專案首頁", "Project page"), destination: URL(string: "https://github.com/silas4336/FakeGPS")!)
        }
        .padding(20).frame(width: 380)
        .navigationTitle(loc("設定", "Settings"))
    }
}

// MARK: - Flow 排版
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300; var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews { let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height) }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width; var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews { let s = v.sizeThatFits(.unspecified)
            if x - bounds.minX + s.width > maxW { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s)); x += s.width + spacing; rowH = max(rowH, s.height) }
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
        Settings { SettingsView() }
    }
}
