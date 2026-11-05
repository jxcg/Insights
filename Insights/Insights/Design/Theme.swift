import SwiftUI

/// Every colour, gradient and spacing value the designed screens use, from
/// FINAL-PLAN §1 (direction 14a, Vivid Aurora). Views read from here and never
/// hard-code their own.
///
/// Type is the system font throughout (SF Pro Display at large sizes), so
/// Dynamic Type works and no font files are bundled. Hierarchy comes from size
/// and spacing, never decoration.
///
/// FINAL-PLAN gives colour and structure but no spacing or type scale, and its
/// pixel reference is missing from the repo. The `Spacing` and `Radius` values
/// are judgement calls, to settle when the reference is back.
enum Theme {
    // MARK: Surfaces and text

    static let canvas = Color(hex: 0xFDFDFE)
    static let ink = Color(hex: 0x1C1B22)

    /// three steps of body text, strongest first. Tertiary is below the
    /// WCAG AA contrast line (2.8:1), so it is for icons and decoration,
    /// never for text a user needs to read.
    static let bodyPrimary = Color(hex: 0x4C4956)
    static let bodySecondary = Color(hex: 0x6E6B7B)
    static let bodyTertiary = Color(hex: 0x9B98A7)

    static let accent = Color(hex: 0x5B4FC4)
    static let border = Color(hex: 0xECEAF3)
    static let positive = Color(hex: 0x54796A)

    /// attention and low-recovery colour. Amber, never red: this app notices,
    /// it does not alarm.
    static let amber = Color(hex: 0xE0932B)

    /// amber for text. The spec amber reads at only 2.5:1 on white, too
    /// faint for small type; this darker shade clears WCAG AA (4.5:1) on
    /// every surface. The spec amber stays for outlines and fills.
    static let amberText = Color(hex: 0x9A5B0E)

    /// the lead insight's background
    static let lavender = Color(hex: 0xF3F1FA)

    /// cards: 165°, white for the first 20% easing to a faint lilac
    static let cardGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: 0xFFFFFF), location: 0.2),
            .init(color: Color(hex: 0xF7F5FC), location: 1),
        ],
        // CSS 165° runs top to bottom, leaning slightly right
        startPoint: UnitPoint(x: 0.37, y: 0),
        endPoint: UnitPoint(x: 0.63, y: 1))

    /// today's bar in the week chart
    static let todayBarGradient = LinearGradient(
        colors: [Color(hex: 0x7A5AF8), Color(hex: 0x5B4FC4)],
        startPoint: .top, endPoint: .bottom)

    // MARK: Metric identity

    /// Each tile's own colour. It lives in the label and the drawing only;
    /// the number itself always stays `ink`.
    static func color(for metric: MetricTile.Metric) -> Color {
        switch metric {
        case .sleep: Color(hex: 0x7A5AF8)
        case .hrv: Color(hex: 0x2E7DD1)
        case .restingHeartRate: Color(hex: 0xC75B4A)
        case .steps: Color(hex: 0x3F8F6B)
        }
    }

    static func title(for metric: MetricTile.Metric) -> String {
        switch metric {
        case .sleep: "Sleep"
        case .hrv: "HRV"
        case .restingHeartRate: "Resting HR"
        case .steps: "Steps"
        }
    }

    // MARK: Layout

    enum Spacing {
        static let screenEdge: CGFloat = 20
        static let section: CGFloat = 28
        static let cardPadding: CGFloat = 16
        static let gridGap: CGFloat = 12
        static let rowGap: CGFloat = 10
        static let tight: CGFloat = 4
        static let heroPadding: CGFloat = 20
        static let iconGap: CGFloat = 12
    }

    enum Size {
        static let heroScore: CGFloat = 56
        static let weekChart: CGFloat = 96
        static let tileMinHeight: CGFloat = 140
        static let tileVisual: CGFloat = 24
        static let microBar: CGFloat = 8
        static let insightIcon: CGFloat = 22
        static let insightIconColumn: CGFloat = 28
    }

    enum Radius {
        static let card: CGFloat = 20
        static let tile: CGFloat = 18
        static let row: CGFloat = 14
    }

    /// border width on cards and tiles
    static let hairline: CGFloat = 1

    /// the amber outline on an out-of-range tile
    static let attentionStroke: CGFloat = 1.5

    /// sleep stage bands, deepest strongest
    static let stageOpacity = (deep: 1.0, rem: 0.6, core: 0.3)
}

extension Color {
    /// A colour from a 0xRRGGBB number, as written in the design spec.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}
