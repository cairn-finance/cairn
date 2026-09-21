import Accessibility
import SwiftUI

/// A Swift Charts accessibility descriptor so VoiceOver can summarise a chart
/// and offer its audio graph. All of Cairn's charts plot numeric series, so a
/// single representable covers the net-worth line and the Insights pace and
/// trend charts.
///
/// The chart's own `accessibilityLabel` / `accessibilityValue` still apply; this
/// adds the rotors ("Chart details", "Audio graph") that VoiceOver exposes for
/// charts.
struct AccessibleChart: AXChartDescriptorRepresentable {
    /// One plotted series. `isContinuous` is true for lines and areas, false
    /// for bars and points.
    struct Line {
        let name: String
        let isContinuous: Bool
        let points: [(x: Double, y: Double)]
    }

    let title: String
    let summary: String?
    let xTitle: String
    let yTitle: String
    let lines: [Line]
    let describesX: (Double) -> String
    let describesY: (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let xs = lines.flatMap { $0.points.map(\.x) }
        let ys = lines.flatMap { $0.points.map(\.y) }

        let xAxis = AXNumericDataAxisDescriptor(
            title: xTitle,
            range: (xs.min() ?? 0)...(xs.max() ?? 1),
            gridlinePositions: [],
            valueDescriptionProvider: describesX
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: yTitle,
            range: (ys.min() ?? 0)...(ys.max() ?? 1),
            gridlinePositions: [],
            valueDescriptionProvider: describesY
        )
        let series = lines.map { line in
            AXDataSeriesDescriptor(
                name: line.name,
                isContinuous: line.isContinuous,
                dataPoints: line.points.map { AXDataPoint(x: $0.x, y: $0.y) }
            )
        }
        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series
        )
    }
}
