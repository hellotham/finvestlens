//
//  Appearance.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Persisted appearance-preference keys (shared by the modifier and the
/// settings pane).
public enum AppearanceKey {
    public static let colorScheme = "appearance.colorScheme"
    public static let accent = "appearance.accent"
    public static let textStep = "appearance.textStep"
    public static let registerRowHeight = "appearance.registerRowHeight"
}

/// Theme mode: follow the system, or force light/dark.
public enum ColorSchemePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self { case .system: "Auto"; case .light: "Light"; case .dark: "Dark" }
    }
    public var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

/// The selectable UI accent colours (macOS-style). Each adapts to light/dark for
/// legible contrast in both. Lavender/mauve is the default.
public extension Color {
    /// The app's own theme colour as a concrete `Color`.
    ///
    /// For anything that takes a `ShapeStyle`, use `.tint` — it reads the
    /// `.tint(…)` the app sets in `AppearanceRoot`. This exists only for the
    /// handful of APIs that demand a real `Color` and cannot accept a style,
    /// such as `chartForegroundStyleScale`. **Never `Color.accentColor`**: that
    /// resolves the AccentColor asset, which is deliberately empty, so it
    /// silently falls back to the *system* accent and paints macOS blue into a
    /// lavender app.
    static var appAccent: Color {
        let raw = UserDefaults.standard.string(forKey: AppearanceKey.accent)
        return (AppAccent(rawValue: raw ?? "") ?? .lavender).color
    }

    // MARK: Money that is coloured by its sign
    //
    // **Never `.red` and `.green` for a figure.** Measured 16 Aug 2026 against
    // the backgrounds this app actually draws on — `NSColor` resolved under
    // both appearances, contrast computed to WCAG 2.1's formula:
    //
    // | painted with | light, white row | light, alternating row |
    // |---|---|---|
    // | `systemRed`   | 3.57:1 | 3.27:1 |
    // | `systemGreen` | **2.22:1** | **2.03:1** |
    //
    // WCAG 1.4.3 asks 4.5:1 of body text, and these are body text: a balance,
    // a gain, a percentage. Green was the worst thing on the screen — a
    // positive return, in a report, at half the required contrast. Increase
    // Contrast does not rescue either one; `secondaryLabelColor` and
    // `systemRed` resolve to identical components under
    // `accessibilityHighContrastAqua`, which was checked rather than assumed.
    //
    // The replacements are the palette's own red and a green darkened to match
    // it, and they clear 4.5:1 on every row this app draws:
    //
    // | | light white | light alt | dark | dark alt |
    // |---|---|---|---|---|
    // | `negativeAmount` | 5.39 | 4.93 | 6.20 | 5.44 |
    // | `positiveAmount` | 5.57 | 5.10 | 8.74 | 7.67 |
    //
    // Colour is never the only carrier — every figure keeps its minus sign and
    // its own label, per WCAG 1.4.1. These make the second cue legible too.
    //
    // For a *destructive control* keep the system red (`role: .destructive`):
    // that is a button's platform semantics, not a number's.

    /// A figure that is negative — a debit balance, a loss, a fall.
    static let negativeAmount = Color.dynamic(light: Color(.sRGB, red: 0.78, green: 0.19, blue: 0.19, opacity: 1),
                                              dark: Color(.sRGB, red: 1.00, green: 0.44, blue: 0.44, opacity: 1))

    /// A figure that is positive — a gain, a rise, a surplus.
    static let positiveAmount = Color.dynamic(light: Color(.sRGB, red: 0.09, green: 0.47, blue: 0.22, opacity: 1),
                                              dark: Color(.sRGB, red: 0.40, green: 0.82, blue: 0.50, opacity: 1))
}

public enum AppAccent: String, CaseIterable, Identifiable, Sendable {
    case lavender, blue, teal, green, yellow, orange, pink, red, graphite

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    /// A colour that resolves lighter in dark mode and richer in light mode, so
    /// text/fills keep enough contrast either way.
    public var color: Color {
        switch self {
        case .lavender: Color.dynamic(light: rgb(0.46, 0.36, 0.80), dark: rgb(0.74, 0.64, 0.98))
        case .blue:     Color.dynamic(light: rgb(0.00, 0.48, 1.00), dark: rgb(0.34, 0.64, 1.00))
        case .teal:     Color.dynamic(light: rgb(0.00, 0.52, 0.56), dark: rgb(0.32, 0.80, 0.83))
        case .green:    Color.dynamic(light: rgb(0.15, 0.53, 0.25), dark: rgb(0.40, 0.78, 0.46))
        // Darkened Aug 2026: at their old light values these two measured
        // 2.58:1 and 2.77:1 against the register's selection wash — under
        // WCAG 1.4.11's 3:1 for non-text controls, which matters now that the
        // register's row controls are tinted with the accent. These values
        // measure 3.22:1 on the same background; every other accent already
        // passed.
        case .yellow:   Color.dynamic(light: rgb(0.63, 0.48, 0.00), dark: rgb(0.95, 0.80, 0.32))
        case .orange:   Color.dynamic(light: rgb(0.76, 0.40, 0.00), dark: rgb(1.00, 0.62, 0.26))
        case .pink:     Color.dynamic(light: rgb(0.83, 0.24, 0.54), dark: rgb(1.00, 0.47, 0.71))
        case .red:      Color.dynamic(light: rgb(0.78, 0.19, 0.19), dark: rgb(1.00, 0.44, 0.44))
        case .graphite: Color.dynamic(light: rgb(0.38, 0.38, 0.41), dark: rgb(0.64, 0.64, 0.67))
        }
    }

    private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// The stepped text-size scale (small … large, default in the middle).
///
/// macOS has no Dynamic Type: SwiftUI text does not respond to
/// `dynamicTypeSize` there. So text size is driven by an explicit multiplier
/// applied to font point sizes (see ``ScaledFont`` and `\.appFontScale`), which
/// works identically on every platform.
public enum TextSize {
    /// Five slider steps; index 2 is the (1.0×) default and the mid-point.
    public static let stepCount = 5
    public static let defaultStep = 2

    /// Font-size multiplier for a slider step. Clamps out-of-range steps.
    public static func scale(_ step: Int) -> CGFloat {
        let factors: [CGFloat] = [0.85, 0.92, 1.0, 1.15, 1.30]
        return factors[min(max(step, 0), factors.count - 1)]
    }
}

/// How tall a transaction row is in the register — and, by ``base``, how big
/// everything inside it is, because the register's fonts and glyphs are all
/// multiples of the row.
///
/// **Why the default is computed rather than a number.** A macOS point is
/// nominally 1/72 inch and no real display honours that. Measured on this
/// project's own machine, the built-in display is 1470 × 956 points across
/// 290.6 mm — **128.5 points per inch** — so the 21pt row the register shipped
/// with stands 4.15 mm tall there, against 4.89 mm for the identical row on a
/// 109-points-per-inch desktop monitor. That is a 15% legibility difference
/// the app can measure and the person reading it cannot control. `automatic`
/// closes it.
///
/// `NSScreen.deviceDescription[.resolution]` is the wrong source and looks
/// like the right one: it reports the *nominal* 72 dpi times the backing scale
/// — it returned `{144, 144}` on the 128.5 ppi display above. Physical size
/// comes from `CGDisplayScreenSize`, which reads the display's EDID.
public enum RegisterRowHeight: Int, CaseIterable, Identifiable, Sendable {
    /// Derived from the display — see ``automaticPoints(pointsPerInch:screenHeight:)``.
    case automatic = -1
    /// 21pt: the density the register shipped with before this existed.
    case compact = 0
    /// 24pt: `NSTableView`'s own default `rowHeight`.
    case standard = 1
    case comfortable = 2
    case spacious = 3

    public var id: Int { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .compact: "Compact"
        case .standard: "Standard"
        case .comfortable: "Comfortable"
        case .spacious: "Spacious"
        }
    }

    /// The row height every other register metric is expressed against: fonts,
    /// symbols and the header strip are all scaled by `height / base`, so a
    /// taller row is a bigger row rather than the same small text adrift in
    /// white space. 24pt is AppKit's own `NSTableView.rowHeight` (measured, not
    /// remembered — a bare `NSTableView()` reports 24.0).
    public static let base: CGFloat = 24

    /// Reference density: a desktop display of about 109 points per inch — the
    /// 27-inch class the platform's own metrics were drawn for, where AppKit's
    /// 24pt row stands 5.59 mm tall.
    static let referencePointsPerInch: CGFloat = 109

    /// How far `automatic` corrects towards a row of constant *physical*
    /// height. Full correction is right in isolation and wrong in company:
    /// macOS itself treats a point as a point, so a fully normalised register
    /// would stand visibly out of step with every other app on the same screen
    /// — and would quietly undo the choice of someone running "More Space".
    /// Half-way keeps most of the legibility and the platform's proportions.
    static let correction: CGFloat = 0.5

    /// A register still has to be a register: never so tall that a full-height
    /// window could not show thirty transactions.
    static let minimumRowsPerScreen: CGFloat = 30

    /// The floor and ceiling `automatic` may reach.
    static let range: ClosedRange<CGFloat> = 21...30

    /// Row height in points at 100% Text Size.
    public func points(pointsPerInch: CGFloat?, screenHeight: CGFloat?) -> CGFloat {
        switch self {
        case .compact: 21
        case .standard: 24
        case .comfortable: 27
        case .spacious: 30
        case .automatic: Self.automaticPoints(pointsPerInch: pointsPerInch,
                                              screenHeight: screenHeight)
        }
    }

    /// The display-derived row: correct part-way towards constant physical
    /// size, then refuse to be so tall that too few transactions fit.
    ///
    /// Both inputs are optional because both can be unknowable — a virtual
    /// display, a capture device or a projector may report no physical size at
    /// all, and iOS exposes none. A missing input drops its term rather than
    /// the whole calculation.
    public static func automaticPoints(pointsPerInch: CGFloat?,
                                       screenHeight: CGFloat?) -> CGFloat {
        var height = base
        // Displays that report 0 mm (or something absurd) must not drag the
        // row to the clamp: treat only a plausible density as a measurement.
        if let ppi = pointsPerInch, (30...400).contains(ppi) {
            height = base * (1 + correction * (ppi / referencePointsPerInch - 1))
        }
        if let screenHeight, screenHeight > 0 {
            height = min(height, screenHeight / minimumRowsPerScreen)
        }
        return min(max(height.rounded(), range.lowerBound), range.upperBound)
    }
}

#if canImport(AppKit)
public extension NSScreen {
    /// Logical points per inch, from the display's physical size.
    ///
    /// `nil` when the display reports no usable size — virtual displays, some
    /// projectors and capture devices report 0 mm, and a divide by that is how
    /// a legibility feature becomes a crash.
    var pointsPerInch: CGFloat? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let millimetres = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value)).width
        guard millimetres > 1, frame.width > 0 else { return nil }
        return frame.width / (millimetres / 25.4)
    }
}

public extension RegisterRowHeight {
    /// Resolved against the display a window is actually on, so dragging the
    /// register between a laptop screen and an external monitor re-measures.
    func points(on screen: NSScreen?) -> CGFloat {
        let screen = screen ?? NSScreen.main
        return points(pointsPerInch: screen?.pointsPerInch,
                      screenHeight: screen?.frame.height)
    }
}
#endif

/// Base point sizes for the semantic text styles (macOS metrics). Used by
/// ``ScaledFont`` to produce a crisp, explicitly-scaled font.
enum TextStyleMetrics {
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }

    static func weight(_ style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    /// The point size after the app's Text Size preference **and, on iOS, the
    /// system's Dynamic Type setting** — the two multiply. `Font.system(size:)`
    /// is a fixed size, so before this every label on iOS ignored the person's
    /// text-size setting entirely; routing the preference-adjusted base
    /// through `UIFontMetrics` keeps the app slider *and* honours theirs.
    /// macOS has no Dynamic Type; the preference is the whole story there.
    /// Floors: HIG Accessibility — 10 pt minimum on macOS, 11 pt on iOS.
    static func scaledSize(_ style: Font.TextStyle, appScale: CGFloat) -> CGFloat {
        let base = max(10, size(style) * appScale)
        #if canImport(UIKit)
        return max(11, UIFontMetrics(forTextStyle: uiStyle(style)).scaledValue(for: base))
        #else
        return base
        #endif
    }

    #if canImport(UIKit)
    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
    #endif
}

/// The app-wide font-size multiplier, published through the environment so
/// text re-scales when the user moves the Text Size slider.
private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

public extension EnvironmentValues {
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

/// Applies a semantic text style as an explicitly-scaled system font, so it
/// grows/shrinks with the user's Text Size preference on every platform
/// (including macOS, which ignores Dynamic Type).
struct ScaledFont: ViewModifier {
    @Environment(\.appFontScale) private var scale
    // Read so a Dynamic Type change re-evaluates every scaled font — the
    // UIFontMetrics call reads the live setting, but only an environment
    // dependency makes SwiftUI come back and ask again.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(.system(
            size: TextStyleMetrics.scaledSize(style, appScale: scale),
            weight: weight ?? TextStyleMetrics.weight(style),
            design: design ?? .default))
    }
}

public extension View {
    /// Drop-in replacement for `.font(.<style>)` that honours the app's Text
    /// Size preference. Optional `weight`/`design` mirror `.font(.system(...))`.
    func scaledFont(_ style: Font.TextStyle,
                    weight: Font.Weight? = nil,
                    design: Font.Design? = nil) -> some View {
        modifier(ScaledFont(style: style, weight: weight, design: design))
    }
}

public extension Color {
    /// A colour that resolves differently in light vs dark appearance, so accents
    /// keep contrast in both (context-adaptive).
    static func dynamic(light: Color, dark: Color) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        return light
        #endif
    }
}

/// Applies the persisted appearance (theme, accent, text size) to a view tree.
/// Attach once at the app root.
public struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearanceKey.colorScheme) private var schemeRaw = ColorSchemePreference.system.rawValue
    @AppStorage(AppearanceKey.accent) private var accentRaw = AppAccent.lavender.rawValue
    @AppStorage(AppearanceKey.textStep) private var textStep = TextSize.defaultStep
    @AppStorage(AppDateFormat.orderKey) private var dateOrderRaw = DateOrder.dmy.rawValue

    public init() {}

    private var scheme: ColorSchemePreference { ColorSchemePreference(rawValue: schemeRaw) ?? .system }

    private var fontScale: CGFloat { TextSize.scale(textStep) }

    private var dateFormat: AppDateFormat {
        AppDateFormat(order: DateOrder(rawValue: dateOrderRaw) ?? .dmy)
    }

    public func body(content: Content) -> some View {
        content
            .tint((AppAccent(rawValue: accentRaw) ?? .lavender).color)
            // Explicit scaling — macOS ignores Dynamic Type. Publish the factor
            // for `.scaledFont(...)` and scale the default font so text that
            // relies on the body style (lists, forms, labels) scales too. The
            // default font goes through the same Dynamic-Type-aware sizing as
            // `.scaledFont` — a fixed size here was what disabled the iOS
            // text-size setting for every unstyled label in the app.
            .environment(\.appFontScale, fontScale)
            .environment(\.font, .system(
                size: TextStyleMetrics.scaledSize(.body, appScale: fontScale)))
            // The date-format preference: every displayed date reads this, so a
            // change in Settings re-renders them all (see DateDisplay.swift).
            .environment(\.appDateFormat, dateFormat)
            // Static text is selectable app-wide: figures, names and paths in a
            // finance app are exactly the strings people need to copy out.
            .textSelection(.enabled)
        #if canImport(AppKit)
            // Drive NSApp.appearance directly: unlike preferredColorScheme(nil),
            // this reliably reverts to the system appearance when switching back
            // to Auto within a session.
            .onAppear { Self.applyAppKitAppearance(scheme) }
            .onChange(of: schemeRaw) { Self.applyAppKitAppearance(scheme) }
        #else
            .preferredColorScheme(scheme.colorScheme)
        #endif
    }

    #if canImport(AppKit)
    private static func applyAppKitAppearance(_ preference: ColorSchemePreference) {
        let appearance: NSAppearance? = switch preference {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApplication.shared.appearance = appearance
    }
    #endif
}

public extension View {
    /// Applies the user's persisted appearance preferences.
    func finvestLensAppearance() -> some View { modifier(AppearanceModifier()) }
}


// MARK: - Report identity

/// The centred report masthead every report surface shares — the statement
/// standard (report-redesign §3.2) applied to working documents and
/// interactive reports alike: entity, serif title, period, units line.
struct ReportMasthead: View {
    let entity: String
    let title: String
    let period: String
    let code: String

    var body: some View {
        VStack(spacing: 3) {
            Text(entity)
                .scaledFont(.title3, weight: .semibold)
            Text(title)
                .scaledFont(.title, weight: .bold, design: .serif)
            Text(period)
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
            Text("Amounts in \(code)")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

/// One categorical palette for every multi-series chart (allocation donuts,
/// per-security scatters) — anchored on the accent so charts read as one
/// family instead of SwiftUI's default rainbow.
enum ReportPalette {
    /// Computed, not `static let`: `.appAccent` reads the user's pick at
    /// evaluation time, and a stored array would freeze the first value for
    /// the whole session.
    static var categorical: [Color] {
        [.appAccent, .teal, .indigo, .orange, .purple,
         .pink, .mint, .brown, .cyan, .yellow]
    }
}
