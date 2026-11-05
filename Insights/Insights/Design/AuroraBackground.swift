import SwiftUI

/// The signature element: four soft washes of colour hanging from the top
/// edge and fading out by about 40% of the screen, over the canvas.
///
/// Purple is always the anchor. In low recovery the other washes warm toward
/// amber, so the screen's mood changes before a word is read, but it never
/// turns red and never dominates the content.
struct AuroraBackground: View {
    let state: RecoveryState

    /// One wash: where its centre sits (as a share of the screen; negative y is
    /// above the top edge) and its colour at full strength.
    struct Wash {
        let x: Double
        let y: Double
        let color: Color
    }

    // FINAL-PLAN §1, recovered state, exactly as specified
    static let recoveredWashes = [
        Wash(x: 0.16, y: -0.12, color: Color(red: 122 / 255, green: 90 / 255, blue: 248 / 255, opacity: 0.26)),
        Wash(x: 0.55, y: -0.18, color: Color(red: 221 / 255, green: 86 / 255, blue: 159 / 255, opacity: 0.14)),
        Wash(x: 0.88, y: -0.14, color: Color(red: 28 / 255, green: 148 / 255, blue: 192 / 255, opacity: 0.16)),
        Wash(x: 0.38, y: -0.04, color: Color(red: 255 / 255, green: 171 / 255, blue: 64 / 255, opacity: 0.07)),
    ]

    // The plan names the direction (violet-blue to amber-warm, purple kept as
    // anchor) but not the values, so these are a judgement call: same
    // positions, pink and teal warmed to rose and amber, the amber whisper
    // turned up, the purple softened but still leading.
    static let lowRecoveryWashes = [
        Wash(x: 0.16, y: -0.12, color: Color(red: 122 / 255, green: 90 / 255, blue: 248 / 255, opacity: 0.18)),
        Wash(x: 0.55, y: -0.18, color: Color(red: 232 / 255, green: 120 / 255, blue: 96 / 255, opacity: 0.14)),
        Wash(x: 0.88, y: -0.14, color: Color(red: 224 / 255, green: 147 / 255, blue: 43 / 255, opacity: 0.18)),
        Wash(x: 0.38, y: -0.04, color: Color(red: 255 / 255, green: 171 / 255, blue: 64 / 255, opacity: 0.12)),
    ]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // big enough that a wash centred just above the top edge has
            // faded to nothing by about 40% of the way down
            let reach = max(size.width, size.height) * 0.5

            ZStack {
                Theme.canvas
                ForEach(Array(washes.enumerated()), id: \.offset) { _, wash in
                    RadialGradient(
                        colors: [wash.color, wash.color.opacity(0)],
                        center: UnitPoint(x: wash.x, y: wash.y),
                        startRadius: 0,
                        endRadius: reach)
                }
            }
            .animation(.easeInOut(duration: 0.8), value: state)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var washes: [Wash] {
        state == .lowRecovery ? Self.lowRecoveryWashes : Self.recoveredWashes
    }
}

#if DEBUG
#Preview("Recovered") {
    AuroraBackground(state: .recovered)
}

#Preview("Low recovery") {
    AuroraBackground(state: .lowRecovery)
}
#endif
