// Offscreen snapshots bypass the normal app lifecycle, window creation, and auto-refresh.
import AppKit
import SwiftUI

enum SnapshotError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownTheme(String)
    case unknownMode(String)
    case unknownAccent(String)
    case renderFailed
    case pngEncodeFailed
    case writeFailed(String, Error)

    var description: String {
        switch self {
        case .missingValue(let f):        return "flag \(f) requires a value"
        case .unknownTheme(let v):        return "unknown --theme '\(v)' (expected thermocline|classic)"
        case .unknownMode(let v):         return "unknown --mode '\(v)' (expected system|light|dark)"
        case .unknownAccent(let v):       return "unknown --accent '\(v)' (no such Thermocline.Accent)"
        case .renderFailed:               return "ImageRenderer produced no image"
        case .pngEncodeFailed:            return "PNG encoding failed"
        case .writeFailed(let p, let e):  return "could not write \(p): \(e.localizedDescription)"
        }
    }
}

@MainActor
enum WidgetSnapshots {
    static let renderFlags = ["--render", "--render-appearance", "--render-settings"]
    static let appearanceFlags = ["--theme", "--mode", "--accent"]

    /// Selects snapshot-safe views (ScrollView and AppKit views do not render offscreen).
    static var isRenderRequested: Bool {
        CommandLine.arguments.contains { renderFlags.contains($0) || appearanceFlags.contains($0) }
    }

    /// nil -> no snapshot requested, proceed with normal launch.
    /// non-nil -> snapshot handled; the parent should `exit(code)` with this value.
    static func runIfRequested() -> Int32? {
        let args = CommandLine.arguments
        guard args.contains(where: { renderFlags.contains($0) || appearanceFlags.contains($0) }) else {
            return nil
        }

        // No Dock icon, window, or auto-refresh.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        do {
            if let path = try value("--render", in: args) {
                return try renderContent(to: path, args: args, fixture: args.contains("--fixture"))
            }
            if let path = try value("--render-appearance", in: args) {
                return try renderContent(to: path, args: args, fixture: true)
            }
            if let path = try value("--render-settings", in: args) {
                return try renderSettings(to: path, args: args)
            }
            // Appearance flags were given with no render target.
            FileHandle.standardError.write("snapshot: --theme/--mode/--accent require --render, --render-appearance or --render-settings\n".data(using: .utf8)!)
            return 2
        } catch let error as SnapshotError {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            switch error {
            case .missingValue, .unknownTheme, .unknownMode, .unknownAccent: return 2
            default: return 1
            }
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - Renderers

    private static func renderContent(to path: String, args: [String], fixture: Bool) throws -> Int32 {
        let store = Store()
        store.data = fixture ? Self.fixtureBriefing() : liveBriefing()
        applyChat(args: args, store: store)

        let appearance = try parseAppearance(args: args)
        let scheme = appearance.mode.colorScheme ?? .dark
        NSApp.appearance = (scheme == .light) ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)

        let view = ContentView(store: store)
            .widgetAppearance(appearance, scheme: scheme)
            .frame(width: contentSize().width, height: contentSize().height)
            .environment(\.colorScheme, scheme)
        try renderPNG(view, to: path)
        return 0
    }

    private static func renderSettings(to path: String, args: [String]) throws -> Int32 {
        let appearance = try parseAppearance(args: args)
        let scheme = appearance.mode.colorScheme ?? .dark
        NSApp.appearance = (scheme == .light) ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)

        let store = AppearanceStore(appearance: appearance)
        let view = AppearancePicker(store: store)
            .widgetAppearance(appearance, scheme: scheme)
            .frame(width: settingsSize().width, height: settingsSize().height)
            .environment(\.colorScheme, scheme)
        try renderPNG(view, to: path)
        return 0
    }

    /// Baseline live data: read the briefing off disk (read-only). Never rebuilds, never
    /// auto-refreshes, never touches the network — that is the parent's job, and only in the
    /// real app, not the snapshot path.
    private static func liveBriefing() -> Briefing {
        let store = Store()
        store.load()
        return store.data
    }

    private static func applyChat(args: [String], store: Store) {
        guard args.contains("--chat"),
              let first = store.data.rows.first(where: { $0.type == "paper" }) else { return }
        store.chatArticle = first
        store.chatMessages = [
            ChatMsg(role: "user", text: "Why does it matter to the field/industry?"),
            ChatMsg(role: "ai", text: "It refines how clinicians grade lesion difficulty before endoscopic removal, which standardizes case selection and training and nudges adoption of endoscopic resection over surgery — relevant to scope makers and surgical-robotics players. Caveat: a scoring-optimization paper, not a new device or an outcomes trial.")
        ]
    }

    private static func renderPNG<V: View>(_ view: V, to path: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { throw SnapshotError.renderFailed }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngEncodeFailed
        }
        let url = URL(fileURLWithPath: path)
        do { try png.write(to: url) } catch { throw SnapshotError.writeFailed(path, error) }
        print("rendered \(path)")
    }

    // MARK: - Appearance parsing

    private static func parseAppearance(args: [String]) throws -> WidgetAppearance {
        let themeRaw  = (try value("--theme", in: args) ?? "thermocline").lowercased()
        let modeRaw   = (try value("--mode", in: args) ?? "system").lowercased()
        let accentRaw = (try value("--accent", in: args) ?? "crown").lowercased()
        guard let theme = WidgetTheme(rawValue: themeRaw) else {
            throw SnapshotError.unknownTheme(themeRaw)
        }
        guard let mode = Thermocline.Mode(rawValue: modeRaw) else {
            throw SnapshotError.unknownMode(modeRaw)
        }
        guard let accent = Thermocline.Accent(rawValue: accentRaw) else {
            throw SnapshotError.unknownAccent(accentRaw)
        }
        return WidgetAppearance(theme: theme, mode: mode, accent: accent)
    }

    // MARK: - Helpers

    private static func value(_ flag: String, in args: [String]) throws -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
            throw SnapshotError.missingValue(flag)
        }
        return args[i + 1]
    }

    private static func size(defaultWidth: CGFloat, defaultHeight: CGFloat) -> CGSize {
        if let env = ProcessInfo.processInfo.environment["WIDGET_RENDER_SIZE"] {
            let bits = env.split(separator: "x")
            if let w = Double(bits.first ?? ""),
               bits.count > 1, let h = Double(bits[1]), (1...2048).contains(w), (1...2048).contains(h) {
                return CGSize(width: w, height: h)
            }
        }
        return CGSize(width: defaultWidth, height: defaultHeight)
    }
    private static func contentSize() -> CGSize { size(defaultWidth: WIDGET_W, defaultHeight: WIDGET_H) }
    private static func settingsSize() -> CGSize { size(defaultWidth: AppearancePicker.popoverWidth, defaultHeight: 440) }

    // MARK: - Deterministic synthetic fixture

    /// A realistic, fully synthetic briefing so appearance renders are byte-for-byte
    /// reproducible and never depend on live data, network, or the wall clock. Dates are
    /// pinned to a fixed past year so `prettyDate` always prints the year (no Date() drift).
    static func fixtureBriefing() -> Briefing {
        func row(_ type: String,
                 text: String? = nil, title: String? = nil, journal: String? = nil,
                 field: String? = nil, date: String? = nil, cites: Int? = nil,
                 score: Double? = nil, oa: Bool? = nil, doi: String? = nil,
                 summary: String? = nil,
                 m: Int? = nil, f: Int? = nil, p: Int? = nil, composite: Double? = nil) -> Row {
            Row(type: type, text: text, title: title, journal: journal, field: field,
                date: date, cites: cites, score: score, oa: oa, doi: doi, url: nil,
                ft_kind: "page", ft_url: doi.map { "https://doi.org/\($0)" }, ft_host: "doi.org",
                scihub: nil, pdf_direct: nil, pdf_probe: nil, summary: summary,
                abstract: nil, source: "openalex", m_score: m, f_score: f, p_score: p,
                composite: composite, tickers: nil)
        }

        return Briefing(
            title: "Weekly STEM Briefing",
            subtitle: "Mar 4 – 11, 2024",
            generated: "2024-03-11 08:00",
            window: Window(start: "2024-03-04", end: "2024-03-11"),
            stats: [
                Stat(label: "Papers", value: "14"),
                Stat(label: "Fields", value: "11"),
                Stat(label: "Open access", value: "8"),
            ],
            rows: [
                row("section", text: "Neuroscience"),
                row("paper",
                    title: "Ultrarapid decision-making in an avian brain",
                    journal: "Science", field: "Neuro", date: "2024-03-08",
                    cites: 128, score: 9.7, oa: true, doi: "10.1126/science.abc1234",
                    summary: "Zebrafinches integrate two sensory cues in under a hundred milliseconds, a speed previously thought exclusive to mammals.",
                    m: 62, f: 91, p: 88, composite: 81.3),
                row("section", text: "Physics"),
                row("paper",
                    title: "Entanglement distribution over 120 km of deployed fiber",
                    journal: "Nature Photonics", field: "Physics", date: "2024-03-07",
                    cites: 74, score: 8.9, oa: false, doi: "10.1038/s41566-024-01400-0",
                    summary: "A repeater node preserves entanglement fidelity across a metropolitan span.",
                    m: 71, f: 86, p: 34, composite: 63.3),
                row("section", text: "Materials"),
                row("paper",
                    title: "A biodegradable hydrogel actuator with nerve-like response",
                    journal: "Advanced Materials", field: "Materials", date: "2024-03-06",
                    cites: 41, score: 8.2, oa: true, doi: "10.1002/adma.202309999",
                    summary: "Salt-driven swelling mimics proprioceptive feedback for soft robotics.",
                    m: 55, f: 72, p: 80, composite: 69.7),
                row("section", text: "Headlines"),
                row("headline", title: "Quantum repeaters clear a fiber milestone"),
            ]
        )
    }
}
