// Thermocline v1.1 design tokens for SwiftUI. iOS 17+, macOS 14+, watchOS 10+. No dependencies.
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum Thermocline {

    // MARK: Colors (dynamic light/dark; watchOS uses dark values)
    public enum Palette {
        static func hex(_ v: UInt32) -> (r: Double, g: Double, b: Double) {
            (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
        /// One light/dark hex pair. Single source for both dynamic and explicit-scheme resolution.
        public struct Token {
            public let light: UInt32, dark: UInt32
            public init(light: UInt32, dark: UInt32) { self.light = light; self.dark = dark }
            /// Dynamic color (follows system appearance; watchOS is always dark).
            public var color: Color { Palette.make(light: light, dark: dark) }
            /// Fixed color for an explicit scheme. Works on every platform, including light on watchOS.
            public func color(for scheme: ColorScheme) -> Color {
                let c = Palette.hex(scheme == .dark ? dark : light)
                return Color(red: c.r, green: c.g, blue: c.b)
            }
        }
        public static let bgToken = Token(light: 0xE4E0D7, dark: 0x13181D)
        public static let surface1Token = Token(light: 0xEEEAE1, dark: 0x1A2026)
        public static let surface2Token = Token(light: 0xF5F1E7, dark: 0x22272B)
        public static let textToken = Token(light: 0x13181D, dark: 0xEBE7DE)
        public static let text3Token = Token(light: 0x645C64, dark: 0x9D959D)
        /// Text on any accent fill.
        public static let onAccentToken = Token(light: 0xEBE7DE, dark: 0x13181D)
        public static let chestnutToken = Token(light: 0x693D24, dark: 0xD0986A)
        public static let plumToken = Token(light: 0x6C3D6B, dark: 0xB985B7)
        static func make(light: UInt32, dark: UInt32) -> Color {
            #if os(watchOS)
            let c = hex(dark)
            return Color(red: c.r, green: c.g, blue: c.b)
            #elseif canImport(UIKit)
            return Color(UIColor { trait in
                let c = hex(trait.userInterfaceStyle == .dark ? dark : light)
                return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            })
            #elseif canImport(AppKit)
            return Color(NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let c = hex(isDark ? dark : light)
                return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
            })
            #else
            let c = hex(dark)
            return Color(red: c.r, green: c.g, blue: c.b)
            #endif
        }
    }

    public static let bg         = Palette.bgToken.color
    public static let surface1   = Palette.surface1Token.color
    public static let surface2   = Palette.surface2Token.color
    public static let surface3   = Palette.make(light: 0xDCD8CF, dark: 0x2A3036)
    public static let text       = Palette.textToken.color
    public static let text2      = Palette.make(light: 0x474047, dark: 0xB5AEA5)
    public static let text3      = Palette.text3Token.color
    public static let lead       = Accent.crown.color
    public static let onLead     = Accent.crown.onColor
    public static let link       = Palette.make(light: 0x186377, dark: 0x6FB3D0)
    public static let macawMid   = Palette.make(light: 0x2D8591, dark: 0x37949D)
    /// Macaw gold. Once per view.
    public static let spark      = Accent.crown.spark
    public static let danger     = Palette.make(light: 0xCE0A04, dark: 0xE62F10)
    public static let success    = Palette.make(light: 0x4B6801, dark: 0xA3C54F)
    public static let secondary  = Palette.chestnutToken.color
    public static let warm       = Palette.make(light: 0xA73B00, dark: 0xED732D)
    public static let plum       = Palette.plumToken.color
    /// Hairlines: text color at 10% / 18%.
    public static let line       = text.opacity(0.10)
    public static let lineStrong = text.opacity(0.18)

    // MARK: Accent (v1.1). Public `lead`, `onLead`, `spark` stay crown; `link` stays standalone.
    public enum Accent: String, CaseIterable, Identifiable {
        case crown, wing, gold, cheek, chestnut, plum, green
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .crown: return "Crown"
            case .wing: return "Wing"
            case .gold: return "Gold"
            case .cheek: return "Cheek"
            case .chestnut: return "Chestnut"
            case .plum: return "Plum"
            case .green: return "Green"
            }
        }
        /// Bird and feather the color was measured from.
        public var source: String {
            switch self {
            case .crown: return "Blue-and-gold macaw crown / deep wing"
            case .wing: return "Blue-and-gold macaw sky-lit wing"
            case .gold: return "Blue-and-gold macaw chest"
            case .cheek: return "Zebra finch cheek"
            case .chestnut: return "Zebra finch chestnut flank"
            case .plum: return "Gouldian finch purple chest"
            case .green: return "Gouldian finch green back"
            }
        }
        public var token: Palette.Token {
            switch self {
            case .crown: return .init(light: 0x186377, dark: 0x6BCDC2)
            case .wing: return .init(light: 0x02516A, dark: 0x6FB3D0)
            case .gold: return .init(light: 0x875300, dark: 0xF4B21F)
            case .cheek: return .init(light: 0xA73B00, dark: 0xED732D)
            case .chestnut: return Palette.chestnutToken
            case .plum: return Palette.plumToken
            case .green: return .init(light: 0x4B6801, dark: 0xA3C54F)
            }
        }
        public var sparkToken: Palette.Token {
            self == .gold ? .init(light: 0x18887F, dark: 0x6BCDC2) : .init(light: 0xAE6B00, dark: 0xF4B21F)
        }
        /// Secondary is chestnut, unless the accent is chestnut; then plum.
        public var secondary: Color { (self == .chestnut ? Palette.plumToken : Palette.chestnutToken).color }
        /// Dynamic (system appearance; watchOS always dark).
        public var color: Color { token.color }
        public var onColor: Color { Palette.onAccentToken.color }
        public var spark: Color { sparkToken.color }
        /// Explicit-scheme resolvers for previews, thumbnails and watchOS light.
        public func color(for scheme: ColorScheme) -> Color { token.color(for: scheme) }
        public func onColor(for scheme: ColorScheme) -> Color { Palette.onAccentToken.color(for: scheme) }
        public func spark(for scheme: ColorScheme) -> Color { sparkToken.color(for: scheme) }
        public func secondary(for scheme: ColorScheme) -> Color {
            (self == .chestnut ? Palette.plumToken : Palette.chestnutToken).color(for: scheme)
        }
    }

    /// Appearance mode choice. `.system` follows the device.
    public enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }
        /// nil for system; pass to `.preferredColorScheme`.
        public var colorScheme: ColorScheme? {
            switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
        }
    }

    // MARK: Radius, Space
    public enum Radius {
        public static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 18, xl: CGFloat = 28
        public static let full: CGFloat = 9999
    }
    public enum Space {
        public static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        public static let s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48, s8: CGFloat = 64, s9: CGFloat = 96
    }

    // MARK: Motion (120/200/320ms, no bounce)
    public enum Motion {
        public static let micro = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.12)
        public static let standard = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.20)
        public static let large = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
        public static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.20)
    }

    // MARK: Fonts (Geist / JetBrains Mono if registered, else system; scales with Dynamic Type)
    public enum Font {
        static func isRegistered(_ name: String) -> Bool {
            #if canImport(UIKit)
            return UIFont(name: name, size: 12) != nil
            #elseif canImport(AppKit)
            return NSFont(name: name, size: 12) != nil
            #else
            return false
            #endif
        }
        public static func ui(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular, relativeTo style: SwiftUI.Font.TextStyle = .body) -> SwiftUI.Font {
            let name = weight == .regular ? "Geist-Regular" : (weight == .semibold || weight == .bold ? "Geist-SemiBold" : "Geist-Medium")
            if isRegistered(name) { return .custom(name, size: size, relativeTo: style) }
            return .system(size: size, weight: weight)
        }
        public static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular, relativeTo style: SwiftUI.Font.TextStyle = .body) -> SwiftUI.Font {
            let name = weight == .regular ? "JetBrainsMono-Regular" : "JetBrainsMono-Medium"
            if isRegistered(name) { return .custom(name, size: size, relativeTo: style) }
            return .system(size: size, weight: weight, design: .monospaced)
        }
        public static var body: SwiftUI.Font { ui(15) }
        public static var headline: SwiftUI.Font { ui(24, weight: .medium, relativeTo: .title2) }
        public static var display: SwiftUI.Font { ui(44, weight: .medium, relativeTo: .largeTitle) }
        /// 11pt mono label; apply `.textCase(.uppercase).tracking(1.3)` at the call site.
        public static var label: SwiftUI.Font { mono(11, weight: .medium, relativeTo: .caption) }
        public static var data: SwiftUI.Font { mono(13, relativeTo: .footnote) }
    }
}

// MARK: - Accent environment
private struct ThermoclineAccentKey: EnvironmentKey { static let defaultValue: Thermocline.Accent = .crown }
public extension EnvironmentValues {
    var thermoclineAccent: Thermocline.Accent {
        get { self[ThermoclineAccentKey.self] }
        set { self[ThermoclineAccentKey.self] = newValue }
    }
}

// MARK: - Glass (one layer at a time)
public struct ThermoclineGlass: ViewModifier {
    var radius: CGFloat
    var thin: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            // Reduce Transparency: solid surface plus hairline, no material.
            content
                .background(Thermocline.surface1, in: shape)
                .overlay(shape.strokeBorder(Thermocline.lineStrong, lineWidth: 1))
        } else {
            content
                .background(thin ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial), in: shape)
                .overlay(shape.strokeBorder(Thermocline.text.opacity(0.12), lineWidth: 1))
        }
    }
}

public extension View {
    func thermoclineGlass(radius: CGFloat = Thermocline.Radius.md, thin: Bool = false) -> some View {
        modifier(ThermoclineGlass(radius: radius, thin: thin))
    }
    /// Sets the Thermocline accent for this view subtree (FinchBars lead, LateralLine and HorizonEyeMark spark).
    func thermoclineAccent(_ accent: Thermocline.Accent) -> some View {
        environment(\.thermoclineAccent, accent)
    }
}

// MARK: - Lateral line divider: five pores then a hairline
public struct LateralLine: View {
    public var sparkLast = false
    @Environment(\.thermoclineAccent) private var accent
    @Environment(\.colorScheme) private var scheme
    public init(sparkLast: Bool = false) { self.sparkLast = sparkLast }
    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { i in
                    Circle().fill(sparkLast && i == 4 ? accent.spark(for: scheme) : Thermocline.text3)
                        .frame(width: 3, height: 3)
                }
            }
            Rectangle().fill(Thermocline.lineStrong).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Finch bars: 2pt on, 2pt off progress
public struct FinchBars: View {
    public var progress: Double
    public var height: CGFloat = 8
    @Environment(\.thermoclineAccent) private var accent
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(progress: Double, height: CGFloat = 8) { self.progress = progress; self.height = height }
    public var body: some View {
        GeometryReader { geo in
            let n = max(Int(geo.size.width / 4), 1)
            let filled = Int((Double(n) * min(max(progress, 0), 1)).rounded())
            HStack(spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    Rectangle()
                        .fill(i < filled ? accent.color(for: scheme) : Thermocline.text3.opacity(0.35))
                        .frame(width: 2)
                }
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : Thermocline.Motion.large, value: progress)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((progress * 100).rounded())) percent"))
    }
}

// MARK: - Horizon-eye mark: circle, horizon line, spark dot right of center
public struct HorizonEyeMark: View {
    public var monochrome = false
    @Environment(\.thermoclineAccent) private var accent
    @Environment(\.colorScheme) private var scheme
    public init(monochrome: Bool = false) { self.monochrome = monochrome }
    public var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, cx = w / 2, cy = h / 2
            let r = min(h * 0.355, w * 0.21)
            let lw = max(h * 0.058, 1)
            let ink = GraphicsContext.Shading.color(Thermocline.text)
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)), with: ink, lineWidth: lw)
            var line = Path()
            line.move(to: CGPoint(x: w * 0.045, y: cy)); line.addLine(to: CGPoint(x: w * 0.955, y: cy))
            ctx.stroke(line, with: ink, style: StrokeStyle(lineWidth: lw, lineCap: .round))
            let dr = r * 0.26
            ctx.fill(Path(ellipseIn: CGRect(x: cx + r * 0.48 - dr, y: cy - dr, width: 2 * dr, height: 2 * dr)),
                     with: .color(monochrome ? Thermocline.text : accent.spark(for: scheme)))
        }
        .aspectRatio(44.0 / 26.0, contentMode: .fit)
        .accessibilityLabel("Thermocline")
    }
}


// MARK: - Previews: theme thumbnail, mode thumbnail, accent swatch

/// Mini scene: canvas, card, accent bubble, resolved for an explicit scheme.
private struct ThermoclineMiniScene: View {
    let accent: Thermocline.Accent
    let scheme: ColorScheme
    var body: some View {
        let P = Thermocline.Palette.self
        ZStack(alignment: .topLeading) {
            P.bgToken.color(for: scheme)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(P.surface2Token.color(for: scheme))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(P.textToken.color(for: scheme).opacity(0.18), lineWidth: 0.5))
                .frame(width: 30, height: 14)
                .offset(x: 5, y: 6)
            Capsule()
                .fill(accent.color(for: scheme))
                .frame(width: 24, height: 10)
                .offset(x: 27, y: 24)
        }
    }
}

/// ~56x40 continuous mini preview of the Thermocline theme in one explicit scheme and accent.
public struct ThermoclineThemeThumbnail: View {
    public var accent: Thermocline.Accent
    public var colorScheme: ColorScheme
    public init(accent: Thermocline.Accent, colorScheme: ColorScheme) {
        self.accent = accent; self.colorScheme = colorScheme
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Thermocline.Radius.sm, style: .continuous)
        ThermoclineMiniScene(accent: accent, scheme: colorScheme)
            .frame(width: 56, height: 40)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Thermocline.Palette.textToken.color(for: colorScheme).opacity(0.18), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Thermocline, \(accent.displayName) accent, \(colorScheme == .dark ? "dark" : "light")")
    }
}

private struct ThermoclineDiagonal: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        return p
    }
}

/// ~56x40 mode preview. `.light` / `.dark` render that scheme; `.system` splits diagonally (light top-left, dark bottom-right).
public struct ModeThumbnail: View {
    public var mode: Thermocline.Mode
    public var accent: Thermocline.Accent
    public init(mode: Thermocline.Mode, accent: Thermocline.Accent = .crown) {
        self.mode = mode; self.accent = accent
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Thermocline.Radius.sm, style: .continuous)
        Group {
            switch mode {
            case .light: ThermoclineMiniScene(accent: accent, scheme: .light)
            case .dark: ThermoclineMiniScene(accent: accent, scheme: .dark)
            case .system:
                ZStack {
                    ThermoclineMiniScene(accent: accent, scheme: .dark)
                    ThermoclineMiniScene(accent: accent, scheme: .light).clipShape(ThermoclineDiagonal())
                }
            }
        }
        .frame(width: 56, height: 40)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Thermocline.line.opacity(1.8), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.displayName) mode")
    }
}

/// 28pt accent circle inside a 44x44 rectangular hit area. Wrap in a Button at the call site.
/// Selection: text-color ring plus checkmark (never color alone); exposes the selected trait.
public struct AccentSwatch: View {
    public var accent: Thermocline.Accent
    public var selected: Bool
    @Environment(\.colorScheme) private var scheme
    public init(accent: Thermocline.Accent, selected: Bool) { self.accent = accent; self.selected = selected }
    public var body: some View {
        ZStack {
            Circle().fill(accent.color(for: scheme)).frame(width: 28, height: 28)
            if selected {
                Circle().strokeBorder(Thermocline.Palette.textToken.color(for: scheme), lineWidth: 2)
                    .frame(width: 36, height: 36)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent.onColor(for: scheme))
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accent.displayName), \(accent.source)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
