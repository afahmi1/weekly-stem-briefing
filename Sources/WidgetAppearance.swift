import AppKit
import Combine
import SwiftUI

// The mode is global; Classic uses the old field colors instead of the Thermocline accent.
enum WidgetTheme: String, CaseIterable, Identifiable {
    case thermocline, classic
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct WidgetAppearance: Equatable {
    var theme: WidgetTheme = .thermocline
    var mode: Thermocline.Mode = .system
    var accent: Thermocline.Accent = .crown

    var windowAppearance: NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var summary: String {
        ([theme.title, mode.displayName] + (theme == .thermocline ? [accent.displayName] : []))
            .joined(separator: " · ")
    }
}

final class AppearanceStore: ObservableObject {
    private static let themeKey = "widget.appearance.theme"
    private static let modeKey = "widget.appearance.mode"
    private static let accentKey = "widget.appearance.accent"
    private let defaults: UserDefaults?

    @Published var appearance: WidgetAppearance {
        didSet {
            defaults?.set(appearance.theme.rawValue, forKey: Self.themeKey)
            defaults?.set(appearance.mode.rawValue, forKey: Self.modeKey)
            defaults?.set(appearance.accent.rawValue, forKey: Self.accentKey)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        appearance = WidgetAppearance(
            theme: defaults.string(forKey: Self.themeKey).flatMap(WidgetTheme.init(rawValue:)) ?? .thermocline,
            mode: defaults.string(forKey: Self.modeKey).flatMap(Thermocline.Mode.init(rawValue:)) ?? .system,
            accent: defaults.string(forKey: Self.accentKey).flatMap(Thermocline.Accent.init(rawValue:)) ?? .crown)
    }

    init(appearance: WidgetAppearance) {
        self.appearance = appearance
        defaults = nil
    }

    static func test() -> Bool {
        let domain = "weekly-stem.appearance-test.\(UUID())"
        guard let defaults = UserDefaults(suiteName: domain) else { return false }
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppearanceStore(defaults: defaults)
        guard store.appearance == WidgetAppearance(), store.appearance.windowAppearance == nil else { return false }
        let sample = WidgetAppearance(theme: .classic, mode: .light, accent: .plum)
        store.appearance = sample
        guard AppearanceStore(defaults: defaults).appearance == sample,
              sample.windowAppearance?.name == .aqua else { return false }
        store.appearance.theme = .thermocline
        guard AppearanceStore(defaults: defaults).appearance.accent == .plum else { return false }
        for key in [themeKey, modeKey, accentKey] { defaults.set("invalid", forKey: key) }
        return AppearanceStore(defaults: defaults).appearance == WidgetAppearance()
    }
}

private struct WidgetThemeKey: EnvironmentKey { static let defaultValue = WidgetTheme.thermocline }
extension EnvironmentValues {
    var widgetTheme: WidgetTheme {
        get { self[WidgetThemeKey.self] }
        set { self[WidgetThemeKey.self] = newValue }
    }
}

extension View {
    func widgetOpenAction(label: String, action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .focusable()
            .onKeyPress(.return) { action(); return .handled }
            .onKeyPress(.space) { action(); return .handled }
            .accessibilityAction(named: Text(label), action)
    }

    func widgetAppearance(_ appearance: WidgetAppearance, scheme: ColorScheme) -> some View {
        environment(\.widgetTheme, appearance.theme)
            .thermoclineAccent(appearance.accent)
            .tint(appearance.theme == .thermocline ? appearance.accent.color(for: scheme) : nil)
    }
}

struct StyledWidget<Content: View>: View {
    @ObservedObject var store: AppearanceStore
    @Environment(\.colorScheme) private var scheme
    var content: Content

    var body: some View {
        let resolved = store.appearance.mode.colorScheme ?? scheme
        content.widgetAppearance(store.appearance, scheme: resolved)
            .environment(\.colorScheme, resolved)
    }
}

/// Shared color/type treatment, read from the current view environment, not saved defaults.
@propertyWrapper
struct WidgetStyle: DynamicProperty {
    @Environment(\.widgetTheme) private var theme
    @Environment(\.thermoclineAccent) private var accent
    @Environment(\.colorScheme) private var scheme
    var wrappedValue: WidgetPalette { WidgetPalette(theme: theme, accent: accent, scheme: scheme) }
}

struct WidgetPalette {
    let theme: WidgetTheme
    let accent: Thermocline.Accent
    let scheme: ColorScheme
    var isThermocline: Bool { theme == .thermocline }
    var isDark: Bool { scheme == .dark }
    var canvas: Color { Thermocline.Palette.bgToken.color(for: scheme) }
    var surface: Color { Thermocline.Palette.surface1Token.color(for: scheme) }
    var raised: Color { Thermocline.Palette.surface2Token.color(for: scheme) }
    var ink: Color { isThermocline ? Thermocline.Palette.textToken.color(for: scheme) : .primary }
    var muted: Color { isThermocline ? Thermocline.Palette.text3Token.color(for: scheme) : .secondary }
    var primary: AnyShapeStyle { isThermocline ? AnyShapeStyle(ink) : AnyShapeStyle(.primary) }
    var secondary: AnyShapeStyle { isThermocline ? AnyShapeStyle(muted) : AnyShapeStyle(.secondary) }
    var tertiary: AnyShapeStyle { isThermocline ? AnyShapeStyle(muted) : AnyShapeStyle(.tertiary) }
    var lead: Color { accent.color(for: scheme) }
    var onLead: Color { accent.onColor(for: scheme) }
    var chrome: Color { isThermocline ? ink : (isDark ? .white : .black) }

    func classicInk(_ color: Color) -> Color {
        guard !isDark, let srgb = NSColor(color).usingColorSpace(.sRGB),
              let darker = srgb.blended(withFraction: 0.56, of: .black) else { return color }
        return Color(darker)
    }

    func field(_ field: String) -> Color { isThermocline ? lead : classicInk(fieldColor(field)) }
    func label(_ classicSize: CGFloat, _ weight: Font.Weight = .medium, size: CGFloat = 10) -> Font {
        isThermocline ? Thermocline.Font.mono(size, weight: .medium, relativeTo: .caption) : .system(size: classicSize, weight: weight)
    }
    func data(_ classicSize: CGFloat, _ weight: Font.Weight, size: CGFloat = 10) -> Font {
        isThermocline ? Thermocline.Font.mono(size, weight: weight, relativeTo: .caption) : .system(size: classicSize, weight: weight, design: .rounded)
    }
    func ui(_ classicSize: CGFloat, _ weight: Font.Weight = .regular, size: CGFloat) -> Font {
        isThermocline ? Thermocline.Font.ui(size, weight: weight) : .system(size: classicSize, weight: weight)
    }
}

struct AppearancePicker: View {
    static let popoverWidth: CGFloat = 356
    @ObservedObject var store: AppearanceStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @WidgetStyle private var style

    private var value: WidgetAppearance { store.appearance }
    private var selection: Color { style.isThermocline ? style.lead : .accentColor }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize && !renderMode {
                ScrollView { groups }.frame(maxHeight: 540)
            } else { groups }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(style.primary)
        .background(style.isThermocline ? style.surface : Color(nsColor: .windowBackgroundColor))
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").font(.headline).accessibilityAddTraits(.isHeader)
            section("Theme") {
                LazyVGrid(columns: columns(2), spacing: 4) {
                    ForEach(WidgetTheme.allCases) { theme in
                        option(theme.title, selected: value.theme == theme, isDefault: theme == .thermocline,
                               action: { store.appearance.theme = theme }) {
                            if theme == .thermocline {
                                ThermoclineThemeThumbnail(accent: value.accent, colorScheme: scheme)
                            } else { ClassicThumbnail(mode: scheme == .light ? .light : .dark) }
                        }
                    }
                }
            }
            section("Mode") {
                LazyVGrid(columns: columns(3), spacing: 4) {
                    ForEach(Thermocline.Mode.allCases) { mode in
                        option(mode.displayName, selected: value.mode == mode, isDefault: mode == .system,
                               action: { store.appearance.mode = mode }) {
                            if style.isThermocline { ModeThumbnail(mode: mode, accent: value.accent) }
                            else { ClassicThumbnail(mode: mode) }
                        }
                    }
                }
            }
            section("Accent") {
                if style.isThermocline {
                    LazyVGrid(columns: columns(4), spacing: 4) {
                        ForEach(Thermocline.Accent.allCases) { accent in
                            option(accent.displayName, selected: value.accent == accent, isDefault: accent == .crown,
                                   showsCheck: false, action: { store.appearance.accent = accent }) {
                                AccentSwatch(accent: accent, selected: value.accent == accent)
                            }
                            .help(accent.source)
                        }
                    }
                } else {
                    Text("Classic keeps its field colors. Your Thermocline accent is saved.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
    }

    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top), count: typeSize.isAccessibilitySize ? 2 : count)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func option<Preview: View>(_ title: String, selected: Bool, isDefault: Bool,
                                       showsCheck: Bool = true, action: @escaping () -> Void,
                                       @ViewBuilder preview: () -> Preview) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                preview().accessibilityHidden(true)
                HStack(spacing: 3) {
                    if selected && showsCheck { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(selection) }
                    Text(title).font(.caption.weight(selected ? .semibold : .regular))
                }
                .multilineTextAlignment(.center)
                if showsCheck || isDefault {
                    Text("Default").font(.caption2).foregroundStyle(style.secondary)
                        .opacity(isDefault ? 1 : 0).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(style.chrome.opacity(style.isDark ? 0.06 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection.opacity(selected ? 0.80 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDefault ? "\(title), default" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ClassicThumbnail: View {
    let mode: Thermocline.Mode

    var body: some View {
        ZStack {
            scene(dark: mode != .light)
            if mode == .system { scene(dark: false).clipShape(Diagonal()) }
        }
        .frame(width: 56, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func scene(dark: Bool) -> some View {
        let palette = WidgetPalette(theme: .classic, accent: .crown, scheme: dark ? .dark : .light)
        let tint = palette.field("neuro")
        return ZStack(alignment: .topLeading) {
            dark ? Color(red: 0.075, green: 0.078, blue: 0.09) : Color(white: 0.93)
            RadialGradient(colors: [tint.opacity(0.30), .clear], center: .topTrailing, startRadius: 0, endRadius: 55)
            RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(0.42)))
                .frame(width: 34, height: 16).offset(x: 5, y: 6)
            Capsule().fill(tint).frame(width: 21, height: 4).offset(x: 26, y: 28)
        }
    }

    private struct Diagonal: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: rect.width, y: 0))
                p.addLine(to: CGPoint(x: 0, y: rect.height))
                p.closeSubpath()
            }
        }
    }
}
