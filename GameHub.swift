// Game Hub: lanzador gaming para .app de juegos nativos en macOS (pensado para los de nxnative y MacNativeGames).
// Biblioteca leída de <raíz>/library.json; ajustes por juego en settings.json (misma carpeta). La raíz es GAMEHUB_ROOT o
// ~/Library/Application Support/GameHub. Las rutas relativas de library.json se resuelven desde la raíz.
// Las .app de nxnative con lanzador Mach-O respetan DM_FULLSCREEN / DM_UPSCALE / DM_HUD / DM_FRAMEGEN si llegan en el entorno:
// este lanzador los pasa con NSWorkspace.OpenConfiguration.environment (entradas con "tweakable": true). Las demás .app solo se abren.
import SwiftUI
import AppKit
import GameController
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin

// MARK: - Datos

struct GameEntry: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var subtitle: String
    var app: String
    var bundle: String
    var art: String
    var accent: String
    var tweakable: Bool
    var tags: [String]
    var note: String?
    var clip: String?
    var playlog: String?
}

struct GameSettings: Codable, Hashable {
    var fullscreen = true
    var upscale = true
    var overlay = true
    var framegen = false
    var lastPlayed: Date?
    var seconds: Double = 0
}

struct PlayStats: Equatable { var seconds: Double = 0; var sessions = 0; var last: Date? = nil }

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

// MARK: - Estado

@MainActor
final class Store: ObservableObject {
    @Published var games: [GameEntry] = []
    @Published var settings: [String: GameSettings] = [:]
    @Published var selected: String = ""
    @Published var running: String? = nil
    @Published var showOptions = false
    @Published var message: String? = nil
    @Published var stats: [String: PlayStats] = [:]
    @Published var visible = true
    var quiet: Bool { running != nil || !visible }   // con un juego abierto o la ventana oculta, el lanzador no anima nada (no le quita GPU ni CPU al juego)
    private var startedAt: Date?
    private var tickCount = 0
    private var timer: Timer?
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GAMEHUB_ROOT"] ?? (NSHomeDirectory() + "/Library/Application Support/GameHub"))
    private var libURL: URL { root.appendingPathComponent("library.json") }
    private var setURL: URL { root.appendingPathComponent("settings.json") }

    init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func resolve(_ p: String?) -> String? {   // "~" y rutas relativas a la raíz
            guard let p, !p.isEmpty else { return p }
            let e = (p as NSString).expandingTildeInPath
            return e.hasPrefix("/") ? e : root.appendingPathComponent(e).path
        }
        if let d = try? Data(contentsOf: libURL), let g = try? JSONDecoder().decode([GameEntry].self, from: d) {
            games = g.map { var x = $0; x.app = resolve(x.app) ?? x.app; x.art = resolve(x.art) ?? x.art; x.clip = resolve(x.clip); x.playlog = resolve(x.playlog); return x }
        }
        if let d = try? Data(contentsOf: setURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let s = try? dec.decode([String: GameSettings].self, from: d) { settings = s }
        }
        selected = games.first?.id ?? ""
        reloadStats()
        refreshRunning()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visible = NSApp.occlusionState.contains(.visible) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshRunning() } }
    }

    var current: GameEntry? { games.first { $0.id == selected } }
    func settings(for id: String) -> GameSettings { settings[id] ?? GameSettings() }
    func binding(_ id: String, _ kp: WritableKeyPath<GameSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.settings(for: id)[keyPath: kp] }, set: { var s = self.settings(for: id); s[keyPath: kp] = $0; self.settings[id] = s; self.save() })
    }
    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(settings) { try? d.write(to: setURL) }
    }

    func move(_ delta: Int) {
        guard !games.isEmpty, let i = games.firstIndex(where: { $0.id == selected }) else { return }
        selected = games[(i + delta + games.count) % games.count].id
    }

    // Juego en ejecución: buscamos la app de cada entrada; el tiempo de juego se suma al cerrarse
    // Tiempo jugado: las sesiones que anota el propio juego al cerrarse (playtime.log: "<epoch inicio> <segundos>"); sin log, cuenta este lanzador
    func reloadStats() {
        var out: [String: PlayStats] = [:]
        for g in games {
            var st = PlayStats()
            if let path = g.playlog, let txt = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in txt.split(separator: "\n") {
                    let f = line.split(separator: " ")
                    if f.count == 2, let t = Double(f[0]), let sec = Double(f[1]) { st.seconds += sec; st.sessions += 1; st.last = Date(timeIntervalSince1970: t + sec) }
                }
            } else { let s = settings(for: g.id); st.seconds = s.seconds; st.last = s.lastPlayed; st.sessions = s.seconds > 0 ? 1 : 0 }
            out[g.id] = st
        }
        if out != stats { stats = out }   // sin cambios no se vuelve a dibujar todo
    }
    // Estadísticas con la sesión en curso incluida
    func liveStats(_ id: String) -> PlayStats {
        var st = stats[id] ?? PlayStats()
        if running == id, let t = startedAt { st.seconds += max(0, Date().timeIntervalSince(t)); st.last = Date() }
        return st
    }
    var totalSeconds: Double { games.reduce(0) { $0 + liveStats($1.id).seconds } }
    var maxSeconds: Double { max(games.map { liveStats($0.id).seconds }.max() ?? 0, 1) }

    func refreshRunning() {
        var found: String? = nil
        for g in games where !NSRunningApplication.runningApplications(withBundleIdentifier: g.bundle).isEmpty { found = g.id; break }
        if found != running {
            if let old = running, let t = startedAt, games.first(where: { $0.id == old })?.playlog == nil {
                var s = settings(for: old); s.seconds += Date().timeIntervalSince(t); s.lastPlayed = Date(); settings[old] = s; save()
            }
            running = found; startedAt = found == nil ? nil : Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.reloadStats() }   // el juego anota su sesión al cerrarse
        }
        tickCount += 1; if tickCount % 10 == 0 { reloadStats() }
    }

    func play(_ g: GameEntry) {
        if let r = running {
            message = r == g.id ? "Ya está en ejecución" : "Cierra \(games.first { $0.id == r }?.name ?? "el otro juego") primero: comparten GPU y audio"
            clearMessageSoon(); return
        }
        guard FileManager.default.fileExists(atPath: g.app) else { message = "No encuentro la app: \(g.app)"; clearMessageSoon(); return }
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        if g.tweakable {
            let s = settings(for: g.id)
            cfg.environment = ["DM_FULLSCREEN": s.fullscreen ? "1" : "0", "DM_UPSCALE": s.upscale ? "1" : "0", "DM_HUD": s.overlay ? "1" : "0", "DM_FRAMEGEN": s.framegen ? "1" : "0"]
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: g.app), configuration: cfg) { _, err in
            if let err { Task { @MainActor in self.message = "No se pudo abrir: \(err.localizedDescription)"; self.clearMessageSoon() } }
        }
        message = "Iniciando \(g.name)…"; clearMessageSoon(8)
    }

    func stop(_ g: GameEntry) {
        for a in NSRunningApplication.runningApplications(withBundleIdentifier: g.bundle) {
            a.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if !a.isTerminated { a.forceTerminate() } }
        }
    }

    private func clearMessageSoon(_ s: Double = 3.5) {
        let m = message
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { if self.message == m { self.message = nil } }
    }
}

// MARK: - Utilidades de formato

func playTime(_ s: Double) -> String {
    if s < 60 { return "Sin tiempo de juego" }
    let m = Int(s / 60); return m < 60 ? "\(m) min jugados" : String(format: "%d h %02d min jugados", m / 60, m % 60)
}
func shortTime(_ s: Double) -> String {
    if s < 60 { return "Nuevo" }
    let m = Int(s / 60); return m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min")
}
func lastPlayed(_ d: Date?) -> String {
    guard let d else { return "Nunca jugado" }
    let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "es"); f.unitsStyle = .full
    return "Último: " + f.localizedString(for: d, relativeTo: Date())
}
func chipName() -> String {
    var n = 0; sysctlbyname("machdep.cpu.brand_string", nil, &n, nil, 0)
    guard n > 0 else { return "Mac" }
    var b = [CChar](repeating: 0, count: n); sysctlbyname("machdep.cpu.brand_string", &b, &n, nil, 0)
    return String(cString: b)
}
func freeSpace(_ u: URL) -> String {   // espacio libre del volumen donde está la biblioteca
    if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let c = v.volumeAvailableCapacityForImportantUsage {
        return String(format: "%.0f GB libres", Double(c) / 1e9)
    }
    return "Espacio no disponible"
}
// Portadas: se decodifican una sola vez como miniatura y quedan en memoria (antes se leían del SSD en cada movimiento del mouse)
@MainActor var artCache: [String: NSImage] = [:]
@MainActor func artImage(_ path: String) -> NSImage? {
    if let c = artCache[path] { return c }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 720, kCGImageSourceShouldCacheImmediately: true]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    artCache[path] = img; return img
}
@MainActor var clipCache: [String: Bool] = [:]
@MainActor func clipExists(_ path: String) -> Bool {   // un solo acceso al disco por clip
    if let c = clipCache[path] { return c }
    let e = FileManager.default.fileExists(atPath: path); clipCache[path] = e; return e
}
// Fondo: la portada muy difuminada, calculada una vez y guardada como bitmap
@MainActor var blurCache: [String: NSImage] = [:]
@MainActor let ciCtx = CIContext()
@MainActor func blurredArt(_ path: String) -> NSImage? {
    if let c = blurCache[path] { return c }
    guard let base = artImage(path), let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let ci = CIImage(cgImage: cg)
    let f = CIFilter.gaussianBlur(); f.inputImage = ci.clampedToExtent(); f.radius = Float(max(ci.extent.width, ci.extent.height) / 9)
    guard let out = f.outputImage?.cropped(to: ci.extent), let res = ciCtx.createCGImage(out, from: ci.extent) else { return nil }
    let r = NSImage(cgImage: res, size: NSSize(width: res.width, height: res.height))
    blurCache[path] = r; return r
}

// Posición del cursor: vive aparte para que moverlo solo redibuje el fondo y la portada, no toda la pantalla
@MainActor final class CursorModel: ObservableObject {
    @Published var cursor = CGPoint.zero            // -1...1 respecto al centro de la ventana
    @Published var absolute = CGPoint(x: 640, y: 300)
    private var last: TimeInterval = 0
    func move(_ p: CGPoint, _ size: CGSize) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last > 1.0 / 40 else { return }   // 40 Hz bastan; el resorte suaviza
        let c = CGPoint(x: max(-1, min(1, (p.x / max(size.width, 1) - 0.5) * 2)), y: max(-1, min(1, (p.y / max(size.height, 1) - 0.5) * 2)))
        guard abs(c.x - cursor.x) > 0.004 || abs(c.y - cursor.y) > 0.004 else { return }
        last = now
        absolute = p
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) { cursor = c }
    }
}

// MARK: - Vistas

struct Chip: View {
    let text: String; var tint: Color = .white
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.14))).overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
    }
}

// Clip de gameplay en bucle, sin sonido (AVPlayerLooper)
final class PlayerNSView: NSView {
    private let queue = AVQueuePlayer(); private var looper: AVPlayerLooper?
    init(url: URL) {
        super.init(frame: .zero)
        let layer = AVPlayerLayer(player: queue); layer.videoGravity = .resizeAspectFill
        self.layer = layer; wantsLayer = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url)); queue.isMuted = true; queue.play()
    }
    required init?(coder: NSCoder) { nil }
    deinit { queue.pause() }
}
struct ClipView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PlayerNSView { PlayerNSView(url: url) }
    func updateNSView(_ v: PlayerNSView, context: Context) {}
}

// Motas de luz que suben despacio (ambiente)
struct Motes: View {
    let tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                for i in 0..<48 {
                    let a = Double(i)
                    let fx = abs((sin(a * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1))
                    let fy = abs((sin(a * 78.233) * 12345.6789).truncatingRemainder(dividingBy: 1))
                    let fr = abs((sin(a * 39.346) * 24634.6345).truncatingRemainder(dividingBy: 1))
                    let speed = 10 + fr * 22
                    let y = size.height - (t * speed + fy * size.height).truncatingRemainder(dividingBy: size.height + 40) + 20
                    let x = fx * size.width + sin(t * (0.2 + fr * 0.4) + a) * 26
                    let r = 1.2 + fr * 2.8
                    let alpha = 0.12 + fr * 0.30
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color((i % 3 == 0 ? tint : Color.white).opacity(alpha)))
                }
            }
        }.allowsHitTesting(false)
    }
}

struct HoverButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : hover ? 1.06 : 1)
            .brightness(hover ? 0.08 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

struct Card: View {
    let game: GameEntry; let selected: Bool; let running: Bool; let seconds: Double; let maxSeconds: Double; let onHoverSelect: () -> Void
    @State private var tilt: CGPoint? = nil      // -1...1 dentro de la portada
    @State private var inside = false
    var body: some View {
        let accent = Color(hex: game.accent)
        let tx = tilt?.x ?? 0, ty = tilt?.y ?? 0
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = artImage(game.art) { Image(nsImage: img).resizable().scaledToFill() }
                    else { Rectangle().fill(accent.opacity(0.4)) }
                }
                .frame(width: 168, height: 168).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    // brillo que sigue al cursor
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(RadialGradient(colors: [.white.opacity(tilt == nil ? 0 : 0.32), .clear], center: UnitPoint(x: 0.5 + tx * 0.5, y: 0.5 + ty * 0.5), startRadius: 4, endRadius: 120))
                        .allowsHitTesting(false)
                )
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(selected || tilt != nil ? accent : Color.white.opacity(0.12), lineWidth: selected || tilt != nil ? 3 : 1))
                .shadow(color: selected || tilt != nil ? accent.opacity(0.65) : .black.opacity(0.4), radius: selected || tilt != nil ? 26 : 8, y: 6)
                .rotation3DEffect(.degrees(tx * 13), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                .rotation3DEffect(.degrees(-ty * 13), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let t = CGPoint(x: (max(-1, min(1, (p.x / 168 - 0.5) * 2)) * 20).rounded() / 20, y: (max(-1, min(1, (p.y / 168 - 0.5) * 2)) * 20).rounded() / 20)
                        if t != tilt { tilt = t }
                        if !inside { inside = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { if inside { onHoverSelect() } } }
                    case .ended: tilt = nil; inside = false
                    }
                }
                if running {
                    Circle().fill(Color.green).frame(width: 14, height: 14).overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 2)).padding(10)
                }
                HStack(spacing: 4) { Image(systemName: "clock.fill").font(.system(size: 9, weight: .bold)); Text(shortTime(seconds)).font(.system(size: 11, weight: .bold, design: .rounded)) }
                    .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.62))).padding(8)
                    .frame(width: 168, height: 168, alignment: .bottomLeading).allowsHitTesting(false)
            }
            Text(game.name).font(.system(size: 13, weight: selected ? .bold : .medium, design: .rounded)).foregroundStyle(selected ? .white : .white.opacity(0.7))
                .lineLimit(2).multilineTextAlignment(.center).frame(width: 168, height: 36, alignment: .top)
            // barra de tiempo jugado, relativa al juego más jugado
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 120, height: 4)
                Capsule().fill(accent).frame(width: max(seconds >= 60 ? 6 : 0, 120 * min(1, seconds / maxSeconds)), height: 4)
            }.offset(y: -4)
        }
        .scaleEffect(tilt != nil ? 1.13 : selected ? 1.07 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: tilt != nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.8), value: tilt?.x)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.8), value: tilt?.y)
    }
}

struct OptionsSheet: View {
    @ObservedObject var store: Store; let game: GameEntry
    var body: some View {
        let accent = Color(hex: game.accent)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Opciones · \(game.name)").font(.system(size: 22, weight: .heavy, design: .rounded))
                Spacer()
                Button("Listo") { store.showOptions = false }.keyboardShortcut(.defaultAction).tint(accent)
            }
            if game.tweakable {
                HStack(alignment: .center, spacing: 16) { row("Pantalla completa", "Abre el juego a pantalla completa (el monitor cambia a su modo de 120 Hz si lo tiene)."); Spacer(minLength: 12); Toggle("", isOn: store.binding(game.id, \.fullscreen)).labelsHidden().toggleStyle(.switch) }
                HStack(alignment: .center, spacing: 16) { row("Escalado MetalFX", "Escala la imagen del juego al tamaño de la ventana. No es resolución de render nativa."); Spacer(minLength: 12); Toggle("", isOn: store.binding(game.id, \.upscale)).labelsHidden().toggleStyle(.switch) }
                HStack(alignment: .center, spacing: 16) { row("Overlay de FPS", "Caja arriba a la derecha con FPS y pipelines; la tecla 1 la cambia dentro del juego."); Spacer(minLength: 12); Toggle("", isOn: store.binding(game.id, \.overlay)).labelsHidden().toggleStyle(.switch) }
                HStack(alignment: .center, spacing: 16) { row("Interpolación 60 → 120 (experimental)", "Dibuja un frame intermedio entre cada par. Más fluido, con +8 ms de retardo y posibles defectos en humo y partículas."); Spacer(minLength: 12); Toggle("", isOn: store.binding(game.id, \.framegen)).labelsHidden().toggleStyle(.switch) }
                Text("Los cambios se aplican la próxima vez que pulses Jugar.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(game.note ?? "Este juego tiene sus propias opciones dentro de la app (teclas 1 a 7).").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .toggleStyle(.switch).padding(28).frame(width: 560, height: game.tweakable ? 440 : 220).preferredColorScheme(.dark)
    }
    func row(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(d).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RootView: View {
    @ObservedObject var store: Store
    @FocusState private var focused: Bool
    @State private var cm = CursorModel()               // @State (no @StateObject): mover el mouse no redibuja esta vista
    @State private var size = CGSize(width: 1280, height: 800)

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                if let g = store.current { hero(g).id(g.id).transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 40)), removal: .opacity)) } else { empty }
                shelf
                footer
            }
            if let m = store.message {
                VStack { Spacer(); Text(m).font(.system(size: 14, weight: .semibold, design: .rounded)).padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.75))).overlay(Capsule().stroke(.white.opacity(0.2))).padding(.bottom, 64) }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
        .background { BackgroundView(store: store, cm: cm, size: size) }
        .clipped()
        .preferredColorScheme(.dark)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
        .onContinuousHover { phase in
            if case .active(let p) = phase { cm.move(p, size) }
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { store.move(-1); return .handled }
        .onKeyPress(.rightArrow) { store.move(1); return .handled }
        .onKeyPress(.return) { if let g = store.current { store.play(g) }; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "oO")) { _ in store.showOptions = true; return .handled }
        .sheet(isPresented: $store.showOptions) { if let g = store.current { OptionsSheet(store: store, game: g) } }
        .animation(.easeInOut(duration: 0.35), value: store.selected)
    }

    var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            Text("GAME HUB").font(.system(size: 20, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(.white)
            Spacer()
            if store.totalSeconds >= 60 { Chip(text: "Total jugado: \(shortTime(store.totalSeconds))", tint: Color(hex: "3DDC84")) }
            Chip(text: chipName() + " · Metal")
            Chip(text: freeSpace(store.root))
        }.padding(.horizontal, 36).padding(.top, 30).padding(.bottom, 8)
    }

    func hero(_ g: GameEntry) -> some View {
        let accent = Color(hex: g.accent), s = store.settings(for: g.id), isRunning = store.running == g.id
        let go = Color(hex: "3DDC84")
        return HStack(alignment: .center, spacing: 46) {
            VStack(alignment: .leading, spacing: 14) {
                Text(g.subtitle.uppercased()).font(.system(size: 13, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(accent)
                Text(g.name).font(.system(size: 54, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                HStack(spacing: 8) { ForEach(g.tags, id: \.self) { Chip(text: $0, tint: .white.opacity(0.9)) }
                    if g.tweakable && s.framegen { Chip(text: "120 Hz interpolado", tint: .orange) } }
                Text(heroPlay(store.liveStats(g.id), running: isRunning)).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7)).padding(.top, 2)
                HStack(spacing: 14) {
                    Button { isRunning ? store.stop(g) : store.play(g) } label: {
                        HStack(spacing: 10) { Image(systemName: isRunning ? "stop.fill" : "play.fill"); Text(isRunning ? "CERRAR JUEGO" : "JUGAR") }
                            .font(.system(size: 18, weight: .heavy, design: .rounded)).tracking(1.5).foregroundStyle(.black)
                            .padding(.horizontal, 36).padding(.vertical, 15)
                            .background(Capsule().fill(isRunning ? Color.red.opacity(0.9) : go))
                            .shadow(color: (isRunning ? Color.red : go).opacity(0.55), radius: 20, y: 6)
                    }.buttonStyle(HoverButtonStyle())
                    Button { store.showOptions = true } label: {
                        HStack(spacing: 8) { Image(systemName: "slider.horizontal.3"); Text("Opciones") }
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 15)
                            .background(Capsule().fill(.white.opacity(0.14))).overlay(Capsule().stroke(.white.opacity(0.28)))
                    }.buttonStyle(HoverButtonStyle())
                }.padding(.top, 8)
            }
            Spacer(minLength: 0)
            ArtCardView(game: g, cm: cm)
        }.padding(.horizontal, 64).frame(maxHeight: .infinity)
    }

    func heroPlay(_ st: PlayStats, running: Bool) -> String {
        if running { return "Jugando ahora  ·  \(playTime(st.seconds)) en total" }
        if st.seconds < 60 { return "Aún sin jugar" }
        let ses = st.sessions == 1 ? "1 sesión" : "\(st.sessions) sesiones"
        return "\(lastPlayed(st.last))  ·  \(playTime(st.seconds))  ·  \(ses)"
    }

    var empty: some View {
        VStack(spacing: 8) {
            Text("No hay juegos en la biblioteca").font(.title2.bold())
            Text("Crea \(store.root.appendingPathComponent("library.json").path)").foregroundStyle(.secondary)
            Text("(hay un ejemplo en examples/library.example.json)").font(.footnote).foregroundStyle(.secondary)
        }.frame(maxHeight: .infinity)
    }

    var shelf: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 30) {
                    ForEach(store.games) { g in
                        Card(game: g, selected: g.id == store.selected, running: g.id == store.running, seconds: store.liveStats(g.id).seconds, maxSeconds: store.maxSeconds, onHoverSelect: { store.selected = g.id }).id(g.id)
                            .onTapGesture { store.selected = g.id }
                            .onTapGesture(count: 2) { store.selected = g.id; store.play(g) }
                    }
                }.padding(.horizontal, 64).padding(.vertical, 26)
            }
            .onChange(of: store.selected) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }.frame(height: 270)
    }

    var footer: some View {
        HStack(spacing: 26) {
            hint("←  →", "Elegir"); hint("↩", "Jugar"); hint("O", "Opciones")
            Spacer()
            Text("Mando: cruceta · A jugar · X opciones").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }.padding(.horizontal, 40).padding(.vertical, 14).background(.black.opacity(0.35))
    }
    func hint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 12, weight: .bold, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.14)))
            Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

struct BackgroundView: View {
    @ObservedObject var store: Store
    @ObservedObject var cm: CursorModel
    let size: CGSize
    var body: some View {
        let g = store.current, cursor = cm.cursor, cursorAbs = cm.absolute
        return ZStack {
            LinearGradient(colors: [Color(hex: "0B0E17"), Color(hex: "151A2B")], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let g {
                Group {
                    if !store.quiet, let c = g.clip, clipExists(c) {
                        ClipView(url: URL(fileURLWithPath: c)).id(c).opacity(0.62).transition(.opacity)
                    } else if let img = blurredArt(g.art) {
                        Color.clear.overlay { Image(nsImage: img).resizable().interpolation(.high).scaledToFill().opacity(0.55) }.clipped()
                    }
                }
                .scaleEffect(1.14)
                .offset(x: -cursor.x * 26, y: -cursor.y * 16)   // parallax: el fondo se desplaza en sentido contrario al cursor
                RadialGradient(colors: [Color(hex: g.accent).opacity(0.30), .clear], center: .topTrailing, startRadius: 40, endRadius: 760)
                // luz que sigue al cursor (sin modo de mezcla: .plusLighter obligaba a recomponer el vídeo entero en cada movimiento)
                RadialGradient(colors: [Color(hex: g.accent).opacity(0.22), .clear], center: UnitPoint(x: cursorAbs.x / max(size.width, 1), y: cursorAbs.y / max(size.height, 1)), startRadius: 0, endRadius: 360)
                if !store.quiet { Motes(tint: Color(hex: g.accent)) }
            }
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .center)
        }.ignoresSafeArea()
    }
}

// Portada grande: se inclina hacia el cursor; la sombra de color es estática (una vista aparte que no cambia con el cursor)
struct ArtGlow: View, Equatable {
    let accent: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Color.black).frame(width: 300, height: 300)
            .shadow(color: accent.opacity(0.6), radius: 50, y: 16)
    }
}
struct ArtCardView: View {
    let game: GameEntry
    @ObservedObject var cm: CursorModel
    var body: some View {
        let accent = Color(hex: game.accent), cursor = cm.cursor
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        let glare = LinearGradient(colors: [Color.white.opacity(0.22), Color.clear],
                                   startPoint: UnitPoint(x: 0.5 - cursor.x * 0.5, y: 0.5 - cursor.y * 0.5),
                                   endPoint: UnitPoint(x: 1.0 + cursor.x * 0.5, y: 1.0 + cursor.y * 0.5))
        let base = Group {
            if let img = artImage(game.art) { Image(nsImage: img).resizable().scaledToFill() } else { Rectangle().fill(accent.opacity(0.4)) }
        }.frame(width: 300, height: 300).clipShape(shape)
        let lit = base
            .overlay(shape.fill(glare).allowsHitTesting(false))
            .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 1.5))
        let tiltY = lit.rotation3DEffect(.degrees(cursor.x * 11), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        let tiltX = tiltY.rotation3DEffect(.degrees(-cursor.y * 9), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        return ZStack { ArtGlow(accent: accent).equatable(); tiltX.offset(x: cursor.x * 8, y: cursor.y * 6) }.frame(width: 300, height: 300)
    }
}

// MARK: - Mando

@MainActor
final class PadNav {
    let store: Store
    init(_ s: Store) {
        store = s
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { MainActor.assumeIsolated { self?.attach(c) } }
        }
        for c in GCController.controllers() { attach(c) }
    }
    private func attach(_ c: GCController) {
        guard let p = c.extendedGamepad else { return }
        p.dpad.left.pressedChangedHandler = { [weak self] _, _, on in if on { Task { @MainActor in self?.store.move(-1) } } }
        p.dpad.right.pressedChangedHandler = { [weak self] _, _, on in if on { Task { @MainActor in self?.store.move(1) } } }
        p.leftThumbstick.left.pressedChangedHandler = { [weak self] _, _, on in if on { Task { @MainActor in self?.store.move(-1) } } }
        p.leftThumbstick.right.pressedChangedHandler = { [weak self] _, _, on in if on { Task { @MainActor in self?.store.move(1) } } }
        p.buttonA.pressedChangedHandler = { [weak self] _, _, on in
            if on { Task { @MainActor in if let s = self?.store, let g = s.current, !s.showOptions { s.play(g) } } }
        }
        p.buttonX.pressedChangedHandler = { [weak self] _, _, on in if on { Task { @MainActor in self?.store.showOptions.toggle() } } }
        p.buttonB.pressedChangedHandler = { [weak self] _, _, on in if on { Task { @MainActor in self?.store.showOptions = false } } }
    }
}

// MARK: - App

@main
struct GameHubApp: App {
    @StateObject private var store = Store()
    @MainActor static var padNav: PadNav?

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // Prueba sin ventana: renderiza la vista a PNG y sale
            let out = args[i + 1]; let sel = i + 2 < args.count ? args[i + 2] : nil
            let opts = args.contains("--options")
            Task { @MainActor in
                let s = Store(); if let sel, s.games.contains(where: { $0.id == sel }) { s.selected = sel }
                let content: AnyView = opts && s.current != nil ? AnyView(OptionsSheet(store: s, game: s.current!).background(Color(hex: "1B1F2E"))) : AnyView(RootView(store: s).frame(width: 1280, height: 800))
                // Se dibuja la vista real (con ScrollView) en una ventana sin mostrar
                let host = NSHostingView(rootView: content); host.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false); win.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 600_000_000)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Game Hub") {
            RootView(store: store).onAppear { if GameHubApp.padNav == nil { GameHubApp.padNav = PadNav(store) } }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
    }
}
