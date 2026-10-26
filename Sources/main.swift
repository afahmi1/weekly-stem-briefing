// WeeklyStemBriefing — field-balanced, triple-ranked STEM digest widget.
// swiftc / Command Line Tools, no Xcode, no SwiftUI macros.
import AppKit
import SwiftUI
import Combine

let renderMode = CommandLine.arguments.contains("--render")
let WIDGET_W: CGFloat = 380
let WIDGET_H: CGFloat = 470

// MARK: - Model (flat rows: section / paper / headline) + 3-axis enrichment
struct Row: Codable {
    let type: String
    var text: String?
    var title: String?
    var journal: String?
    var field: String?
    var date: String?
    var cites: Int?
    var score: Double?
    var oa: Bool?
    var doi: String?
    var url: String?
    var ft_kind: String?
    var ft_url: String?
    var ft_host: String?
    var scihub: String?
    var pdf_direct: String?
    var pdf_probe: String?
    var summary: String?
    var abstract: String?
    var source: String?
    var m_score: Int?
    var f_score: Int?
    var p_score: Int?
    var composite: Double?
    var tickers: [String]?

    var readURL: String {
        if let f = ft_url, !f.isEmpty { return f }
        return url ?? ""
    }
    var ftBadge: String? {
        switch ft_kind { case "pdf": return "PDF"; case "page": return "FULL TEXT"; default: return nil }
    }
    var displayField: String { field ?? "" }
}
struct Stat: Codable { let label: String; let value: String }
struct Briefing: Codable {
    var title: String = "Weekly STEM Briefing"
    var subtitle: String = ""
    var generated: String = ""
    var stats: [Stat] = []
    var rows: [Row] = []
}

func dataURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WeeklyStemBriefing/briefing.json")
}

// MARK: - Palette
func fieldColor(_ field: String) -> Color {
    let f = field.lowercased()
    if f.hasPrefix("med") || f.hasPrefix("health") { return Color(red: 0.35, green: 0.82, blue: 0.62) }
    if f.hasPrefix("bio") || f.hasPrefix("immuno") || f.hasPrefix("genetic") || f.hasPrefix("cell") { return Color(red: 0.42, green: 0.78, blue: 0.55) }
    if f.hasPrefix("neuro") || f.hasPrefix("psych") { return Color(red: 0.92, green: 0.55, blue: 0.72) }
    if f.hasPrefix("astro") { return Color(red: 0.72, green: 0.62, blue: 0.98) }
    if f.hasPrefix("phys") { return Color(red: 0.55, green: 0.68, blue: 0.98) }
    if f.hasPrefix("chem") || f.hasPrefix("pharma") { return Color(red: 0.98, green: 0.68, blue: 0.36) }
    if f.hasPrefix("math") { return Color(red: 0.72, green: 0.70, blue: 0.95) }
    if f.hasPrefix("cs") || f.hasPrefix("computer") { return Color(red: 0.45, green: 0.78, blue: 0.95) }
    if f.hasPrefix("mater") || f.hasPrefix("engineer") { return Color(red: 0.85, green: 0.66, blue: 0.95) }
    if f.hasPrefix("earth") || f.hasPrefix("environ") { return Color(red: 0.55, green: 0.80, blue: 0.72) }
    return Color(red: 0.62, green: 0.70, blue: 0.85)
}
let marketColor = Color(red: 0.42, green: 0.84, blue: 0.56)   // M — stock market
let impactColor = Color(red: 0.55, green: 0.68, blue: 0.98)   // F — field impact
let youColor    = Color(red: 0.95, green: 0.60, blue: 0.78)   // Y — personal appeal
let freeGreen = Color(red: 0.45, green: 0.85, blue: 0.6)
let libBlue = Color(red: 0.56, green: 0.76, blue: 0.99)
let sciOrange = Color(red: 0.96, green: 0.60, blue: 0.30)

func prettyDate(_ s: String) -> String {
    let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd"
    if let d = p.date(from: s) { let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d) }
    return String(s.prefix(12))
}
func openURLString(_ s: String) { if !s.isEmpty, let u = URL(string: s) { NSWorkspace.shared.open(u) } }

// MARK: - Store
struct ChatMsg: Identifiable { let id = UUID(); let role: String; let text: String }

final class Store: ObservableObject {
    @Published var data = Briefing()
    @Published var busy = false

    // per-article AI chat
    @Published var chatArticle: Row? = nil
    @Published var chatMessages: [ChatMsg] = []
    @Published var chatBusy = false
    @Published var chatDraft = ""

    // library proxy for paywalled papers (SSO login unlocks the text)
    @Published var library = UserDefaults.standard.string(forKey: "WSBLibrary") ?? "SJSU"
    func setLibrary(_ s: String) {
        library = s; UserDefaults.standard.set(s, forKey: "WSBLibrary"); objectWillChange.send()
    }
    static func proxyPrefix(_ lib: String) -> String {
        lib == "BU" ? "https://ezproxy.bu.edu/login?url="
                    : "https://libaccess.sjlibrary.org/login?url="
    }
    /// Always aim at readable full text — no landing page if we can help it.
    ///   1. resolved free full text (or Sci-Hub) -> open the file directly
    ///   2. publisher's direct PDF endpoint -> through the library proxy
    ///   3. otherwise the DOI/article page, proxied
    func articleURL(_ r: Row) -> String {
        if let k = r.ft_kind, (k == "pdf" || k == "page"), let f = r.ft_url, !f.isEmpty {
            return f                                   // resolved free full text / sci-hub pdf
        }
        if let pd = r.pdf_direct, !pd.isEmpty {
            let enc = pd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pd
            if r.pdf_probe == "verified" { return pd } // already free: no proxy hop
            return Store.proxyPrefix(library) + enc    // proxy unlocks the PDF directly
        }
        let target: String = {
            if let u = r.url, !u.isEmpty { return u }
            if let d = r.doi, !d.isEmpty { return "https://doi.org/\(d)" }
            return ""
        }()
        if target.isEmpty { return r.readURL }
        if r.oa == true { return target }              // genuinely open: no proxy needed
        let enc = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target
        return Store.proxyPrefix(library) + enc        // paywalled: via library login
    }
    func openArticle(_ r: Row) {
        if let u = URL(string: articleURL(r)) { NSWorkspace.shared.open(u) }
    }

    func load() {
        if let d = try? Data(contentsOf: dataURL()),
           let b = try? JSONDecoder().decode(Briefing.self, from: d) { self.data = b }
    }
    func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            // Prefer the research-profile tools (cron keeps them current); fall back to
            // the copy bundled next to the app so a shared install is self-contained.
            let candidates = [
                home.appendingPathComponent(".hermes/profiles/research/tools/weekly_stem_briefing.py"),
                home.appendingPathComponent("WeeklyStemBriefing/tools/weekly_stem_briefing.py"),
            ]
            let script = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path]
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async { self.busy = false; self.load() }
        }
    }

    // MARK: chat
    func openChat(_ r: Row) { chatArticle = r; chatMessages = []; chatBusy = false; chatDraft = "" }
    func closeChat() { chatArticle = nil; chatMessages = []; chatBusy = false; chatDraft = "" }

    func ask(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chatBusy, let art = chatArticle else { return }
        chatMessages.append(ChatMsg(role: "user", text: q))
        chatBusy = true
        let convo = chatMessages
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = Store.runClaude(article: art, transcript: convo)
            DispatchQueue.main.async {
                guard self.chatArticle != nil else { return }   // user may have closed it
                self.chatMessages.append(ChatMsg(role: "ai", text: answer))
                self.chatBusy = false
            }
        }
    }

    static func claudePath() -> String? {
        let home = NSHomeDirectory()
        for c in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    static func runClaude(article: Row, transcript: [ChatMsg]) -> String {
        guard let bin = claudePath() else {
            return "Claude CLI not found. Install it or check ~/.local/bin/claude."
        }
        var p = """
        You are a concise research assistant. Answer the user's question about the ONE \
        scientific paper below, for a biomedical engineer (surgical-robotics field service, \
        interested in med devices, prosthetics, 3D printing). Use the paper details plus your \
        general knowledge. If the abstract is missing or thin, say what can and cannot be \
        inferred and do NOT invent specific numbers or findings. Be direct and brief \
        (a few sentences or tight bullets). Plain text, no markdown headers.

        PAPER
        Title: \(article.title ?? "")
        Journal: \(article.journal ?? "") (\(article.displayField))
        Date: \(article.date ?? "")
        DOI: \(article.doi ?? "")
        Summary: \(article.summary ?? "")
        Abstract: \((article.abstract ?? "").isEmpty ? "(none provided)" : (article.abstract ?? ""))

        CONVERSATION
        """
        for m in transcript {
            p += (m.role == "user" ? "\nQ: " : "\nA: ") + m.text
        }
        p += "\nA:"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["-p", p]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = (env["PATH"] ?? "") + ":\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // claude reads file-based creds under ~/.claude and needs HOME/USER/LOGNAME;
        // a launchd-started accessory app may not inherit all of these.
        env["HOME"] = home
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        proc.environment = env
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
        do { try proc.run() } catch { return "Could not launch Claude: \(error.localizedDescription)" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 150) { if proc.isRunning { proc.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "No answer came back (the model may have timed out). Try again." : s
    }
}

// MARK: - Drag handle (actively moves the window; SwiftUI gestures otherwise
// swallow the drag, and a dense widget has almost no bare background to grab).
struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { self }   // claim the whole strip
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

// MARK: - Backdrop
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
struct WidgetBackdrop: View {
    let tint: Color
    var body: some View {
        ZStack {
            if renderMode { Color(red: 0.075, green: 0.078, blue: 0.09) }
            else { VisualEffect(); Color.black.opacity(0.28) }
            RadialGradient(colors: [tint.opacity(0.30), tint.opacity(0.04), .clear],
                           center: .init(x: 0.9, y: 0.0), startRadius: 6, endRadius: 360)
            LinearGradient(colors: [Color.white.opacity(0.05), .clear, Color.black.opacity(0.18)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - Free-copy tag
@ViewBuilder
func ftTag(_ r: Row, library: String) -> some View {
    if (r.ft_host ?? "").lowercased().contains("sci-hub") {
        // honest label: this text came from Sci-Hub, not from a legitimate OA source
        HStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 6.5, weight: .bold))
            Text("SCI-HUB").font(.system(size: 7.5, weight: .bold)).tracking(0.5)
        }.foregroundStyle(sciOrange)
    } else if let b = r.ftBadge {
        HStack(spacing: 2) {
            Image(systemName: "arrow.down.doc.fill").font(.system(size: 7, weight: .bold))
            Text(b).font(.system(size: 7.5, weight: .bold)).tracking(0.5)
        }.foregroundStyle(freeGreen)
    } else if r.oa == true {
        Text("OPEN").font(.system(size: 7.5, weight: .bold)).tracking(0.5).foregroundStyle(freeGreen)
    } else {
        HStack(spacing: 2) {
            Image(systemName: "lock.open.fill").font(.system(size: 7, weight: .bold))
            Text("via \(library)").font(.system(size: 7.5, weight: .bold)).tracking(0.4)
        }.foregroundStyle(libBlue)
    }
}

// MARK: - Three-axis meters + tickers
struct Meter: View {
    let letter: String; let value: Int; let color: Color
    var body: some View {
        HStack(spacing: 3) {
            Text(letter).font(.system(size: 8, weight: .heavy)).foregroundStyle(color).fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09)).frame(width: 22, height: 3)
                Capsule().fill(color).frame(width: max(2, 22 * CGFloat(value) / 100.0), height: 3)
            }
            Text("\(value)").font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary).fixedSize()
        }.fixedSize()
    }
}
struct TripleMeter: View {
    let m: Int; let f: Int; let p: Int
    var body: some View {
        HStack(spacing: 8) {
            Meter(letter: "M", value: m, color: marketColor)
            Meter(letter: "F", value: f, color: impactColor)
            Meter(letter: "Y", value: p, color: youColor)
        }
    }
}
struct Tickers: View {
    let tickers: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(tickers.prefix(2), id: \.self) { t in
                Text(t).font(.system(size: 7.5, weight: .bold, design: .rounded)).tracking(0.2)
                    .fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Capsule().fill(marketColor.opacity(0.16)))
                    .foregroundStyle(marketColor)
            }
        }
    }
}
struct AskPill: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "sparkles").font(.system(size: 7.5, weight: .bold))
                Text("ASK").font(.system(size: 8, weight: .heavy)).tracking(0.5)
            }
            .foregroundStyle(Color(red: 0.82, green: 0.82, blue: 0.97))
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }.buttonStyle(.plain).fixedSize().help("Ask AI about this paper")
    }
}

// MARK: - Hero (top composite pick)
struct HeroCard: View {
    @ObservedObject var store: Store
    let item: Row
    var body: some View {
        let tint = fieldColor(item.displayField)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("TOP PICK").font(.system(size: 8.5, weight: .heavy)).tracking(1.1).foregroundStyle(tint)
                Text(item.displayField.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let c = item.composite { Text(String(format: "%.0f", c))
                    .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(tint) }
            }
            Text(item.title ?? "").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let s = item.summary, !s.isEmpty {
                Text(s).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(item.journal ?? "").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                Text(prettyDate(item.date ?? "")).font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                ftTag(item, library: store.library)
            }
            HStack(spacing: 8) {
                TripleMeter(m: item.m_score ?? 0, f: item.f_score ?? 0, p: item.p_score ?? 0)
                Spacer(minLength: 0)
                if let t = item.tickers, !t.isEmpty { Tickers(tickers: t) }
                AskPill(action: { store.openChat(item) })
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 0.8))
        .contentShape(Rectangle())
        .onTapGesture { store.openArticle(item) }
    }
}

// MARK: - Paper row
struct PaperRow: View {
    @ObservedObject var store: Store
    let number: Int
    let item: Row
    var body: some View {
        let tint = fieldColor(item.displayField)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.16)).frame(width: 18, height: 18)
                    Text("\(number)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let s = item.summary, !s.isEmpty {
                        Text(s).font(.system(size: 9)).foregroundStyle(.secondary.opacity(0.85))
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text(item.journal ?? "").foregroundStyle(tint).lineLimit(1)
                        Text("·").foregroundStyle(.tertiary); Text(item.displayField)
                        Text("·").foregroundStyle(.tertiary); ftTag(item, library: store.library)
                    }.font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 8) {
                        TripleMeter(m: item.m_score ?? 0, f: item.f_score ?? 0, p: item.p_score ?? 0)
                        Spacer(minLength: 0)
                        if let t = item.tickers, !t.isEmpty { Tickers(tickers: t) }
                        AskPill(action: { store.openChat(item) })
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 3)
            .contentShape(Rectangle()).onTapGesture { store.openArticle(item) }
            Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1).padding(.leading, 28)
        }
    }
}
struct HeadlineRow: View {
    let item: Row
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "newspaper.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                    .frame(width: 18, height: 16, alignment: .center)
                Text(item.title ?? "").font(.system(size: 10.5)).foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 3)
            .contentShape(Rectangle()).onTapGesture { openURLString(item.url ?? "") }
            Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1).padding(.leading, 28)
        }
    }
}
struct SectionLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(1.0).foregroundStyle(.secondary)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }.padding(.top, 10).padding(.bottom, 3).padding(.horizontal, 2)
    }
}

// MARK: - Display assembly
struct Entry: Identifiable { let id: Int; let kind: String; let text: String; let number: Int; let row: Row? }
func buildEntries(_ rows: [Row], heroIndex: Int?) -> [Entry] {
    var out: [Entry] = []; var n = 0; var id = 0
    for (i, r) in rows.enumerated() {
        if r.type == "section" {
            n = 0; out.append(Entry(id: id, kind: "section", text: r.text ?? "", number: 0, row: nil)); id += 1
        } else if r.type == "paper" {
            n += 1
            if i == heroIndex { continue }
            out.append(Entry(id: id, kind: "paper", text: "", number: n, row: r)); id += 1
        } else if r.type == "headline" {
            out.append(Entry(id: id, kind: "headline", text: "", number: 0, row: r)); id += 1
        }
    }
    return out
}

// MARK: - Content
struct ContentView: View {
    @ObservedObject var store: Store
    private var heroIndex: Int? { store.data.rows.firstIndex { $0.type == "paper" } }
    private var hero: Row? { heroIndex.map { store.data.rows[$0] } }
    private var entries: [Entry] {
        let e = buildEntries(store.data.rows, heroIndex: heroIndex)
        return renderMode ? Array(e.prefix(3)) : e
    }
    private var tint: Color { fieldColor(hero?.displayField ?? "stem") }

    var body: some View {
        ZStack {
        VStack(alignment: .leading, spacing: 0) {
            grabber
            header
            if let h = hero { HeroCard(store: store, item: h).padding(.top, 8) }
            Group {
                if renderMode { rows } else { ScrollView(.vertical, showsIndicators: false) { rows } }
            }.padding(.top, 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(.horizontal, 14).padding(.top, 7).padding(.bottom, 10)
        .frame(width: WIDGET_W, height: WIDGET_H)
        .background(WidgetBackdrop(tint: tint))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
            if store.chatArticle != nil {
                ChatView(store: store)
                    .transition(.opacity)
            }
        }
    }

    // top-center grab handle — a real window-drag strip, not just decoration
    private var grabber: some View {
        ZStack {
            Color.white.opacity(0.001)                       // fill the strip so it's all grabbable
            Capsule().fill(Color.white.opacity(0.28)).frame(width: 42, height: 5)
        }
        .frame(maxWidth: .infinity).frame(height: 14)
        .contentShape(Rectangle())
        .overlay(renderMode ? nil : AnyView(DragHandle()))
        .help("Drag to move")
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 7) {
            HStack(alignment: .center, spacing: 7) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.09)).frame(width: 20, height: 20)
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("WEEKLY STEM BRIEFING").font(.system(size: 8.5, weight: .heavy)).tracking(1.2).foregroundStyle(.secondary)
                    Text(store.data.subtitle.replacingOccurrences(of: "Week of ", with: ""))
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.primary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(renderMode ? nil : AnyView(DragHandle()))    // whole bar drags, except the button
            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.busy ? Color.secondary : Color.primary.opacity(0.75))
                    .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.08)))
            }.buttonStyle(.plain).help("Rebuild from live sources")
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(entries) { e in
                switch e.kind {
                case "section":  SectionLabel(text: e.text)
                case "headline": if let r = e.row { HeadlineRow(item: r) }
                default:         if let r = e.row { PaperRow(store: store, number: e.number, item: r) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            // axis legend
            HStack(spacing: 3) { Circle().fill(marketColor).frame(width: 5, height: 5); Text("Market").foregroundStyle(.tertiary) }
            HStack(spacing: 3) { Circle().fill(impactColor).frame(width: 5, height: 5); Text("Field").foregroundStyle(.tertiary) }
            HStack(spacing: 3) { Circle().fill(youColor).frame(width: 5, height: 5); Text("You").foregroundStyle(.tertiary) }
            Spacer()
            Text(store.data.generated.isEmpty ? "—" : "synced \(store.data.generated)")
                .foregroundStyle(.tertiary)
        }.font(.system(size: 8, weight: .medium)).padding(.top, 6)
    }
}

// MARK: - Per-article AI chat
struct ChatBubble: View {
    let msg: ChatMsg
    let tint: Color
    var body: some View {
        HStack {
            if msg.role == "user" { Spacer(minLength: 26) }
            Text(msg.text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .foregroundStyle(msg.role == "user" ? Color.black.opacity(0.85) : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(msg.role == "user" ? tint.opacity(0.85) : Color.white.opacity(0.08)))
                .fixedSize(horizontal: false, vertical: true)
            if msg.role == "ai" { Spacer(minLength: 26) }
        }
    }
}

struct ChatView: View {
    @ObservedObject var store: Store
    private var art: Row? { store.chatArticle }
    private var canSend: Bool {
        !store.chatDraft.trimmingCharacters(in: .whitespaces).isEmpty && !store.chatBusy
    }
    private func send() {
        let q = store.chatDraft; store.chatDraft = ""; store.ask(q)
    }
    private let starters = ["Explain this simply",
                            "Why does it matter to the field/industry?",
                            "What are the weaknesses?"]

    @ViewBuilder
    private func transcript(_ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.chatMessages.isEmpty && !store.chatBusy {
                Text("Ask anything about this paper — what it found, why it matters, the methods, the caveats, or how it ties to your work.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 10)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(starters, id: \.self) { s in
                        Button(action: { store.ask(s) }) {
                            Text(s).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Capsule().fill(tint.opacity(0.14)))
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, 2)
            }
            ForEach(store.chatMessages) { m in ChatBubble(msg: m, tint: tint).id(m.id) }
            if store.chatBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("thinking…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        let tint = fieldColor(art?.displayField ?? "stem")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { store.closeChat() }) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).help("Back to briefing")
                VStack(alignment: .leading, spacing: 1) {
                    Text("ASK ABOUT THIS PAPER").font(.system(size: 8, weight: .heavy)).tracking(1.1).foregroundStyle(tint)
                    Text(art?.title ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            if renderMode {
                transcript(tint).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { transcript(tint) }
                        .onChange(of: store.chatMessages.count) { _ in
                            if let last = store.chatMessages.last?.id {
                                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                            }
                        }
                }.frame(maxHeight: .infinity)
            }

            HStack(spacing: 7) {
                TextField("Ask about this paper…", text: $store.chatDraft, onCommit: send)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09)))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 21))
                        .foregroundStyle(canSend ? tint : Color.secondary.opacity(0.5))
                }.buttonStyle(.plain).disabled(!canSend)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        .frame(width: WIDGET_W, height: WIDGET_H)
        .background(
            ZStack {
                if renderMode { Color(red: 0.07, green: 0.072, blue: 0.085) }
                else { VisualEffect(); Color.black.opacity(0.45) }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - App
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: WidgetWindow!
    var statusItem: NSStatusItem!
    let store = Store()
    let modeKey = "WeeklyStemBriefingDesktopMode"
    var desktopMode: Bool {
        get { UserDefaults.standard.bool(forKey: modeKey) }
        set { UserDefaults.standard.set(newValue, forKey: modeKey); applyLevel() }
    }
    func applyLevel() {
        if desktopMode {
            // pinned to the desktop, behind other windows (per his standing rule)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            // normal, freely draggable, never forced on top
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces]
        }
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Always come up in the freely-draggable normal layer; the user can
        // re-pin to the desktop from the menu if they want it behind windows.
        UserDefaults.standard.set(false, forKey: modeKey)
        store.load()

        // headless self-test of the AI shell-out (exercises the real code path)
        if CommandLine.arguments.contains("--ask-test") {
            let sample = store.data.rows.first(where: { $0.type == "paper" })
                ?? Row(type: "paper", title: "Ultrarapid decision-making in an avian brain",
                       journal: "Science", field: "Neuro")
            print("Q: Why is this interesting to a bird enthusiast? (one sentence)")
            print("A: " + Store.runClaude(article: sample,
                transcript: [ChatMsg(role: "user", text: "Why is this interesting to a bird enthusiast? Answer in one sentence.")]))
            NSApp.terminate(nil); return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > i + 1 {
            let out = CommandLine.arguments[i + 1]
            if CommandLine.arguments.contains("--chat"),
               let first = store.data.rows.first(where: { $0.type == "paper" }) {
                store.chatArticle = first
                store.chatMessages = [
                    ChatMsg(role: "user", text: "Why does it matter to the field/industry?"),
                    ChatMsg(role: "ai", text: "It refines how clinicians grade lesion difficulty before endoscopic removal, which standardizes case selection and training and nudges adoption of endoscopic resection over surgery — relevant to scope makers and surgical-robotics players. Caveat: a scoring-optimization paper, not a new device or an outcomes trial.")]
            }
            let r = ImageRenderer(content: ContentView(store: store).environment(\.colorScheme, .dark)
                .frame(width: WIDGET_W, height: WIDGET_H))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out)); print("rendered \(out)")
            }
            NSApp.terminate(nil); return
        }

        let hosting = NSHostingView(rootView: ContentView(store: store))
        hosting.setFrameSize(NSSize(width: WIDGET_W, height: WIDGET_H))
        window = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: WIDGET_W, height: WIDGET_H),
            styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.isMovableByWindowBackground = true; window.hidesOnDeactivate = false
        applyLevel()
        if let scr = NSScreen.main {
            let f = scr.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.maxX - WIDGET_W - 24, y: f.maxY - WIDGET_H - 24))
        }
        window.orderFront(nil)
        makeStatusItem()
    }

    func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Weekly STEM Briefing")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()
    }
    func rebuildMenu() { statusItem.menu = buildMenu() }
    func buildMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "", state: NSControl.StateValue? = nil) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key); mi.target = self
            if let s = state { mi.state = s }; m.addItem(mi)
        }
        add("Show / Hide widget", #selector(toggleVisible))
        add("Pin to desktop (behind windows)", #selector(toggleDesktop), state: desktopMode ? .on : .off)
        // which university proxy unlocks paywalled papers
        let libItem = NSMenuItem(title: "Library for paywalled papers", action: nil, keyEquivalent: "")
        let lib = NSMenu()
        for name in ["SJSU", "BU"] {
            let it = NSMenuItem(title: name, action: #selector(pickLibrary(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = name
            it.state = (store.library == name) ? .on : .off
            lib.addItem(it)
        }
        libItem.submenu = lib; m.addItem(libItem)
        m.addItem(.separator())
        add("Refresh now", #selector(refreshNow), "r")
        add("Move: top-right", #selector(moveTR))
        add("Move: center", #selector(moveCenter))
        add("Open data folder", #selector(openData))
        m.addItem(.separator())
        add("Quit", #selector(quitApp), "q")
        return m
    }
    @objc func pickLibrary(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { store.setLibrary(name); rebuildMenu() }
    }
    @objc func toggleVisible() {
        if window.isVisible { window.orderOut(nil) }
        else { applyLevel(); window.orderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    @objc func toggleDesktop() {
        desktopMode.toggle(); rebuildMenu(); window.orderFront(nil)
    }
    @objc func refreshNow() { store.refresh() }
    @objc func openData() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WeeklyStemBriefing"))
    }
    private func place(_ pick: (NSRect) -> NSPoint) {
        guard let scr = NSScreen.main else { return }
        window.setFrameOrigin(pick(scr.visibleFrame)); window.orderFront(nil)
    }
    @objc func moveTR() { place { f in NSPoint(x: f.maxX - WIDGET_W - 24, y: f.maxY - WIDGET_H - 24) } }
    @objc func moveCenter() { place { f in NSPoint(x: f.midX - WIDGET_W/2, y: f.midY - WIDGET_H/2) } }
    @objc func quitApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.appearance = NSAppearance(named: .darkAqua)
app.setActivationPolicy(.accessory)
app.run()
