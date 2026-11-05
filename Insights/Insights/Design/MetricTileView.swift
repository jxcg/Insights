import SwiftUI

/// One square of the metric grid: label in the metric's colour, the number in
/// ink, a quiet comparison, and the metric's own small drawing.
///
/// Out-of-range metrics get the attention treatment: an amber outline and an
/// amber caption. Nothing else on the screen uses amber this way.
struct MetricTileView: View {
    let tile: MetricTile

    private var metricColor: Color { Theme.color(for: tile.metric) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(Theme.title(for: tile.metric))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(metricColor)

            if let value = tile.value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                    Text(tile.unit)
                        .font(.subheadline)
                        .foregroundStyle(Theme.bodySecondary)
                }
            } else {
                Text("No data yet")
                    .font(.title3)
                    .foregroundStyle(Theme.bodySecondary)
            }

            if let caption = tile.caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(tile.needsAttention ? Theme.amberText : Theme.bodySecondary)
            }

            Spacer(minLength: Theme.Spacing.rowGap)

            MetricVisualView(visual: tile.visual, color: metricColor)
                .frame(height: Theme.Size.tileVisual)
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.tileMinHeight, alignment: .topLeading)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: Theme.Radius.tile))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile)
                .strokeBorder(
                    tile.needsAttention ? Theme.amber : Theme.border,
                    lineWidth: tile.needsAttention ? Theme.attentionStroke : Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityHint(tile.needsAttention ? "Outside your usual range" : "")
    }
}

/// The small drawing under a tile's number.
struct MetricVisualView: View {
    let visual: MetricTile.Visual
    let color: Color

    var body: some View {
        switch visual {
        case .sleepStages(let deep, let rem, let core):
            StageStrip(deep: deep, rem: rem, core: core, color: color)
        case .sparkline(let points):
            Sparkline(points: points)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case .progress(let share):
            ProgressBar(share: share, color: color)
        case .empty:
            Color.clear
        }
    }
}

/// Last night as three bands, deepest strongest.
private struct StageStrip: View {
    let deep: Double
    let rem: Double
    let core: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let total = max(deep + rem + core, 0.0001)
            HStack(spacing: 2) {
                band(share: deep / total, opacity: Theme.stageOpacity.deep, width: geometry.size.width)
                band(share: rem / total, opacity: Theme.stageOpacity.rem, width: geometry.size.width)
                band(share: core / total, opacity: Theme.stageOpacity.core, width: geometry.size.width)
            }
        }
        .frame(height: Theme.Size.microBar)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func band(share: Double, opacity: Double, width: CGFloat) -> some View {
        Capsule()
            .fill(color.opacity(opacity))
            // the two gaps between bands come out of the total width
            .frame(width: max(0, (width - 4) * share))
    }
}

/// Recent days as a line, scaled to fill the space whatever the units.
struct Sparkline: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2,
              let low = points.min(), let high = points.max() else {
            return path
        }
        // a flat week draws as a flat line through the middle
        let range = high - low
        let stepX = rect.width / CGFloat(points.count - 1)

        for (index, value) in points.enumerated() {
            let share = range > 0 ? (value - low) / range : 0.5
            let point = CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.maxY - CGFloat(share) * rect.height)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// Progress toward a goal. Past the goal it simply stays full.
private struct ProgressBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(max(share, 0), 1)))
            }
        }
        .frame(height: Theme.Size.microBar)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

#if DEBUG
#Preview {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Spacing.gridGap) {
        MetricTileView(tile: MetricTile(
            metric: .sleep, value: "7.2", unit: "h", caption: "usually 7.4 h",
            visual: .sleepStages(deep: 0.18, rem: 0.22, core: 0.6), needsAttention: false))
        MetricTileView(tile: MetricTile(
            metric: .hrv, value: "58", unit: "ms", caption: "usually 55",
            visual: .sparkline([52, 55, 54, 57, 56, 59, 58]), needsAttention: false))
        MetricTileView(tile: MetricTile(
            metric: .restingHeartRate, value: "62", unit: "bpm", caption: "usually 54",
            visual: .sparkline([54, 53, 55, 54, 56, 58, 62]), needsAttention: true))
        MetricTileView(tile: MetricTile(
            metric: .steps, value: nil, unit: "steps", caption: "goal 10,000",
            visual: .empty, needsAttention: false))
    }
    .padding()
    .background(Theme.canvas)
}
#endif
