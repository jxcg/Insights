import SwiftUI

/// One insight: an SF Symbol, the sentence, and a quiet line of evidence.
///
/// The lead row stands out with an accent icon on lavender; the rest stay
/// grey on the card gradient. These are the only icons in the app's designed
/// screens.
struct InsightRowView: View {
    let insight: Insight
    let isLead: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.iconGap) {
            Image(systemName: insight.symbol)
                // 22 pt regular draws close to the spec's 1.8 pt stroke
                .font(.system(size: Theme.Size.insightIcon, weight: .regular))
                .foregroundStyle(isLead ? Theme.accent : Theme.bodyTertiary)
                .frame(width: Theme.Size.insightIconColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(insight.sentence)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.evidence)
                    .font(.footnote)
                    .foregroundStyle(Theme.bodySecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.cardPadding)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .fill(isLead ? AnyShapeStyle(Theme.lavender) : AnyShapeStyle(Theme.cardGradient))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .strokeBorder(Theme.border, lineWidth: isLead ? 0 : Theme.hairline)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: Theme.Spacing.rowGap) {
        InsightRowView(
            insight: Insight(
                sentence: "Your resting heart rate was 62 bpm yesterday, above your usual 54 bpm.",
                evidence: "62 bpm · usually 54 bpm", symbol: "heart", tone: .cautionary),
            isLead: true)
        InsightRowView(
            insight: Insight(
                sentence: "HRV (SDNN) tends to be higher on days with a longer night's sleep.",
                evidence: "Pattern across the past 90 days", symbol: "link", tone: .neutral),
            isLead: false)
    }
    .padding()
    .background(Theme.canvas)
}
#endif
