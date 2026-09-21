import SwiftUI
import Charts
import CairnCore

// MARK: - Theme tokens

/// The single source of truth for Cairn's color, surfaces, geometry, motion,
/// and shared components. Screens reach for these tokens instead of ad-hoc
/// values so the app feels like one considered object on iPhone, iPad, and Mac.
///
/// The visual language is "private ledger": deep ink hero surfaces for the one
/// number that matters, quiet off-white cards for everything else, tabular
/// figures throughout, and motion that is quick but never showy.
enum CairnTheme {
    // MARK: Brand & semantic color

    /// The brand teal from the app icon; asset-backed so it adapts to dark mode.
    static let accent = Color.accentColor
    static let positive = Color("CairnPositive")
    static let negative = Color("CairnNegative")
    static let warning = Color.orange
    static let neutral = Color.secondary

    /// Deep ink used for hero surfaces. Reads as confident and calm rather than
    /// loud, and lets the teal accent glow against it.
    static let ink = Color(red: 0.043, green: 0.141, blue: 0.188)        // #0B2430
    static let inkLight = Color(red: 0.086, green: 0.298, blue: 0.376)   // #164C60
    static let inkGlow = Color(red: 0.247, green: 0.776, blue: 0.871)    // #3FC6DE
    static let cream = Color(red: 0.957, green: 0.945, blue: 0.918)      // #F4F1EA

    /// The hero gradient: ink at the top-left, lighter teal-ink bottom-right.
    static var inkGradient: LinearGradient {
        LinearGradient(
            colors: [ink, inkLight],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Surfaces

    /// A card surface that sits above the page background.
    static var surface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// A subtle inset surface used inside cards (tiles, chips, wells).
    static var surfaceInset: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    /// The page background behind cards.
    static var canvas: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// A barely-there separator that reads on any surface.
    static let hairline = Color.primary.opacity(0.06)
    /// A slightly stronger stroke for outlined controls.
    static let outline = Color.primary.opacity(0.10)

    // MARK: Geometry

    static let cardRadius: CGFloat = 22
    static let tileRadius: CGFloat = 14
    static let controlRadius: CGFloat = 12
    static let screenMaxWidth: CGFloat = 720

    // MARK: Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Motion

    enum Motion {
        /// Selection changes, toggles, chips.
        static let quick = Animation.snappy(duration: 0.28, extraBounce: 0.05)
        /// Content swaps and layout changes.
        static let standard = Animation.smooth(duration: 0.38)
        /// Numbers rolling in.
        static let numeric = Animation.smooth(duration: 0.5)
    }

    // MARK: Helpers

    static func color(hex: String) -> Color {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else {
            return .gray
        }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Typography

extension Font {
    /// The large hero figure. Tight and confident.
    static let cairnHero = Font.system(.largeTitle, design: .default, weight: .semibold)
    /// A secondary figure inside a hero or summary.
    static let cairnDisplay = Font.system(.title, design: .default, weight: .semibold)
    /// Section labels above cards.
    static let cairnLabel = Font.system(.caption, weight: .semibold)
}

// MARK: - Amounts

/// A monetary amount with tabular figures so columns line up and digits do not
/// jitter as values update. Amounts are neutral by default; callers pass a
/// `colorOverride` only when color carries meaning (a delta, a loss).
struct AmountText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let money: Money
    var showSign: Bool = false
    var font: Font = .body
    var colorOverride: Color?
    /// When true, the fractional part is rendered smaller and lighter, which
    /// makes large hero figures read faster.
    var deemphasizeFraction: Bool = false

    var body: some View {
        Group {
            if deemphasizeFraction, let split = splitFraction() {
                Text("\(Text(split.whole))\(Text(split.fraction).foregroundStyle(.secondary).fontWeight(.medium))")
            } else {
                Text(text)
            }
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(colorOverride ?? .primary)
        .contentTransition(.numericText(value: Double(money.minorUnits)))
        .animation(reduceMotion ? nil : CairnTheme.Motion.numeric, value: money.minorUnits)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityLabel(text)
    }

    private var text: String {
        let formatted = money.formatted()
        if showSign, !money.isNegative, !money.isZero {
            return "+" + formatted
        }
        return formatted
    }

    /// Splits "$12,345.67" into ("$12,345", ".67") using the locale's decimal
    /// separator. Returns nil for zero-decimal currencies or unusual formats.
    private func splitFraction() -> (whole: String, fraction: String)? {
        guard money.currency.exponent > 0 else { return nil }
        let full = text
        let separator = Locale.autoupdatingCurrent.decimalSeparator ?? "."
        guard let range = full.range(of: separator, options: .backwards) else { return nil }
        let whole = String(full[full.startIndex..<range.lowerBound])
        let fraction = String(full[range.lowerBound...])
        // Bail if there's a trailing currency symbol after the fraction.
        guard fraction.count <= money.currency.exponent + 1 else { return nil }
        return (whole, fraction)
    }
}

extension Money {
    /// A short axis-friendly form, e.g. "$1.2K".
    func compactFormatted() -> String {
        let value = NSDecimalNumber(decimal: decimal).doubleValue
        if currency.isCustom {
            return value.formatted(.number.notation(.compactName).precision(.fractionLength(0)))
        }
        return value.formatted(
            .currency(code: currency.code).notation(.compactName).precision(.fractionLength(0...1))
        )
    }
}

// MARK: - Surfaces

/// A rounded card surface. Light mode uses a soft, wide shadow; dark mode uses
/// an elevated surface with a hairline so the card still separates from the
/// page without a muddy shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = CairnTheme.Spacing.l
    var cornerRadius: CGFloat = CairnTheme.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: cornerRadius)
    }
}

/// The ink hero surface for the one number that matters on a screen.
struct HeroCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background {
                ZStack {
                    CairnTheme.inkGradient
                    // A soft glow in the corner gives the surface depth without
                    // competing with the figure.
                    RadialGradient(
                        colors: [CairnTheme.inkGlow.opacity(0.35), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 320
                    )
                    RadialGradient(
                        colors: [Color.white.opacity(0.06), .clear],
                        center: .bottomLeading,
                        startRadius: 0,
                        endRadius: 260
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CairnTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CairnTheme.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: CairnTheme.ink.opacity(0.28), radius: 22, y: 10)
    }
}

extension View {
    /// The standard card surface treatment.
    func cardSurface(cornerRadius: CGFloat = CairnTheme.cardRadius) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

private struct CardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(CairnTheme.surface, in: shape)
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 14, y: 5)
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.03), radius: 2, y: 1)
    }
}

// MARK: - Section labels

/// A quiet uppercase label that sits above a card or list group.
struct SectionLabel: View {
    let title: LocalizedStringKey
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .textCase(.uppercase)
                .font(.cairnLabel)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer(minLength: CairnTheme.Spacing.s)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// A titled row inside a card, with an optional trailing action.
struct CardHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

// MARK: - Glyphs

/// The colored glyph that leads a transaction or category row. A rounded
/// square with a soft tint of the category color; the glyph is the color
/// itself, so it reads in both light and dark mode.
struct CategoryBadge: View {
    let symbolName: String?
    let hex: String?
    var size: CGFloat = 40

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = hex.map(CairnTheme.color(hex:)) ?? CairnTheme.neutral
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
            Image(systemName: symbolName ?? "circle.dashed")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A presentation for the kind of account, so checking, savings, and cards
/// are distinguishable at a glance.
struct AccountGlyphStyle {
    let symbol: String
    let tint: Color

    static func forAccount(_ account: Account) -> AccountGlyphStyle {
        switch account.accountType {
        case .checking: AccountGlyphStyle(symbol: "banknote.fill", tint: CairnTheme.accent)
        case .savings: AccountGlyphStyle(symbol: "leaf.fill", tint: Color(red: 0.20, green: 0.62, blue: 0.42))
        case .credit: AccountGlyphStyle(symbol: "creditcard.fill", tint: Color(red: 0.37, green: 0.36, blue: 0.90))
        case .investment: AccountGlyphStyle(symbol: "chart.line.uptrend.xyaxis", tint: Color(red: 0.62, green: 0.36, blue: 0.87))
        case .loan: AccountGlyphStyle(symbol: "building.2.fill", tint: Color(red: 0.86, green: 0.53, blue: 0.20))
        case .cash: AccountGlyphStyle(symbol: "dollarsign.circle.fill", tint: Color(red: 0.24, green: 0.66, blue: 0.62))
        case .other:
            AccountGlyphStyle(
                symbol: account.isManual ? "square.and.pencil" : "building.columns.fill",
                tint: CairnTheme.accent
            )
        }
    }
}

struct AccountGlyph: View {
    let account: Account
    var size: CGFloat = 42
    /// Render as a frosted tile for the ink hero surface.
    var onInk: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = AccountGlyphStyle.forAccount(account)
        if onInk {
            Image(systemName: style.symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(CairnTheme.inkGlow)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .accessibilityHidden(true)
        } else {
            tile(style)
        }
    }

    private func tile(_ style: AccountGlyphStyle) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            style.tint.opacity(colorScheme == .dark ? 0.30 : 0.18),
                            style.tint.opacity(colorScheme == .dark ? 0.16 : 0.09),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: style.symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(style.tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Trend pill

/// A restrained month-over-month change indicator.
struct TrendPill: View {
    let ratio: Double
    var higherIsBad: Bool = true
    /// Render for a dark hero surface.
    var onInk: Bool = false

    /// Percentages past this are not meaningful at a glance (a small baseline
    /// produces an alarming number), so we clamp the label.
    private let cap = 999

    var body: some View {
        let percent = Int((abs(ratio) * 100).rounded())
        let isUp = ratio >= 0
        let good = higherIsBad ? !isUp : isUp
        let tint: Color = percent == 0
            ? (onInk ? .white.opacity(0.8) : CairnTheme.neutral)
            : (good ? CairnTheme.positive : CairnTheme.negative)

        HStack(spacing: 3) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
            if percent > cap {
                Text("\(cap)+%")
                    .monospacedDigit()
            } else {
                Text((Double(percent) / 100).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(onInk ? .white : tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(onInk ? tint.opacity(0.55) : tint.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The spoken form: direction and magnitude, since the arrow and the color
    /// alone don't convey it to VoiceOver.
    private var accessibilityText: Text {
        let percent = min(Int((abs(ratio) * 100).rounded()), cap)
        if percent == 0 { return Text("No change") }
        return ratio >= 0 ? Text("Up \(percent) percent") : Text("Down \(percent) percent")
    }
}

// MARK: - Metrics

/// A labeled value used inside summary cards.
struct Metric: View {
    let title: LocalizedStringKey
    let money: Money
    var tint: Color = .primary
    var font: Font = .callout.weight(.semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(money: money, font: font, colorOverride: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small inset tile with a label and a figure, used in stat grids.
struct StatTile<Value: View>: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var tint: Color = .secondary
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(CairnTheme.surfaceInset, in: RoundedRectangle(cornerRadius: CairnTheme.tileRadius, style: .continuous))
    }
}

// MARK: - Chips & segmented selection

/// A compact capsule chip. Selected chips fill with the accent; unselected
/// ones sit on an inset surface.
struct Chip: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isSelected: Bool = false
    var tint: Color = CairnTheme.accent

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? tint : CairnTheme.surfaceInset, in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : CairnTheme.outline, lineWidth: 1))
        .contentShape(Capsule())
        .animation(CairnTheme.Motion.quick, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A capsule segmented control with a sliding selection indicator.
struct SegmentedPicker<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> LocalizedStringKey
    /// Render on the ink hero surface.
    var onInk: Bool = false

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(reduceMotion ? nil : CairnTheme.Motion.quick) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.footnote.weight(selected ? .semibold : .medium))
                        .foregroundStyle(foreground(selected: selected))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(onInk ? Color.white.opacity(0.22) : CairnTheme.surface)
                                    .shadow(color: .black.opacity(onInk ? 0 : 0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(onInk ? Color.white.opacity(0.10) : CairnTheme.surfaceInset, in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }

    private func foreground(selected: Bool) -> Color {
        if onInk { return selected ? .white : .white.opacity(0.7) }
        return selected ? .primary : .secondary
    }
}

// MARK: - Sparkline

/// A tiny axis-free line chart for cards and rows. When `selection` is bound,
/// pressing and holding (or dragging) shows a vertical rule and dot at the
/// nearest point, and reports that point's index.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = CairnTheme.accent
    var lineWidth: CGFloat = 1.8
    var showsArea: Bool = true
    /// When set, the chart becomes interactive and writes the dragged
    /// point's index here. The default no-op binding leaves it static.
    var selection: Binding<Int?> = .constant(nil)

    var body: some View {
        let domain = yDomain
        return Chart(Array(values.enumerated()), id: \.offset) { index, value in
            if showsArea {
                // Fill down to the bottom of the visible domain, not to zero,
                // so the area never spills past the chart's frame.
                AreaMark(
                    x: .value("i", index),
                    yStart: .value("floor", domain.lowerBound),
                    yEnd: .value("v", value)
                )
                    .foregroundStyle(
                        LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.catmullRom)
            }
            LineMark(x: .value("i", index), y: .value("v", value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)

            if let picked = pickedIndex {
                RuleMark(x: .value("i", picked))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("i", picked), y: .value("v", values[picked]))
                    .symbolSize(70)
                    .foregroundStyle(tint)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.clipped() }
        .chartXSelection(value: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Trend"))
        .accessibilityValue(accessibilityValueText)
    }

    /// A spoken summary of the plotted range, since the line is purely visual.
    private var accessibilityValueText: Text {
        guard let first = values.first, let last = values.last else { return Text(verbatim: "") }
        let delta = abs(last - first).formatted(.number.precision(.fractionLength(0)))
        if last > first { return Text("Up \(delta)") }
        if last < first { return Text("Down \(delta)") }
        return Text("No change")
    }

    /// The selected index, clamped to the data that's actually plotted.
    private var pickedIndex: Int? {
        guard let index = selection.wrappedValue, values.indices.contains(index) else { return nil }
        return index
    }

    private var yDomain: ClosedRange<Double> {
        guard let min = values.min(), let max = values.max() else { return 0...1 }
        if min == max { return (min - 1)...(max + 1) }
        let pad = (max - min) * 0.12
        return (min - pad)...(max + pad)
    }
}

// MARK: - Empty state

/// Empty-state presentation shared by the main lists.
struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(CairnTheme.accent.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(CairnTheme.accent)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.cairnProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

// MARK: - Button styles

/// A press feedback style for card-like tappable surfaces: a slight scale and
/// dim, so the whole card feels physical without a highlight color.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// The prominent call-to-action: a full-width, ink-filled capsule.
struct CairnProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background(
                CairnTheme.inkGradient
                    .opacity(isEnabled ? 1 : 0.45),
                in: Capsule()
            )
            .shadow(color: CairnTheme.ink.opacity(isEnabled ? 0.25 : 0), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A quiet secondary button.
struct CairnSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(CairnTheme.surfaceInset, in: Capsule())
            .overlay(Capsule().strokeBorder(CairnTheme.outline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableCardStyle {
    static var pressableCard: PressableCardStyle { PressableCardStyle() }
}

extension ButtonStyle where Self == CairnProminentButtonStyle {
    static var cairnProminent: CairnProminentButtonStyle { CairnProminentButtonStyle() }
}

extension ButtonStyle where Self == CairnSecondaryButtonStyle {
    static var cairnSecondary: CairnSecondaryButtonStyle { CairnSecondaryButtonStyle() }
}

// MARK: - Settings-style rows

/// A colored rounded-square icon that leads a settings row.
struct SettingsIcon: View {
    let systemImage: String
    var tint: Color = CairnTheme.accent

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row with a leading icon, a title, and trailing content.
struct IconRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let systemImage: String
    var tint: Color = CairnTheme.accent
    @ViewBuilder var trailing: Trailing

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        systemImage: String,
        tint: Color = CairnTheme.accent,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Small explanatory text under a group of controls.
struct FootnoteText: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Status pill

/// A small inline status such as "Synced 2m ago" or "Pending".
struct StatusPill: View {
    let text: LocalizedStringKey
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
        .lineLimit(1)
    }
}

// MARK: - View helpers

extension View {
    /// `insetGrouped` is iOS-only; macOS uses the standard inset list.
    @ViewBuilder
    func cairnListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// Consistent page padding and max width for scroll-based screens.
    func cairnScreen() -> some View {
        padding(.horizontal, CairnTheme.Spacing.l)
            .padding(.top, CairnTheme.Spacing.s)
            .padding(.bottom, CairnTheme.Spacing.xxl)
            .frame(maxWidth: CairnTheme.screenMaxWidth)
            .frame(maxWidth: .infinity)
    }

    /// The page background for scroll screens.
    func cairnCanvas() -> some View {
        background(CairnTheme.canvas.ignoresSafeArea())
    }

    /// Hides the default list row chrome so a card can be placed in a `List`.
    func cairnCardRow() -> some View {
        listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// Standard row insets for content rows in a grouped list.
    func cairnRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    /// Fades and lifts content in when it first appears.
    func cairnAppear(delay: Double = 0) -> some View {
        modifier(AppearModifier(delay: delay))
    }
}

private struct AppearModifier: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                withAnimation(CairnTheme.Motion.standard.delay(delay)) { shown = true }
            }
    }
}

// MARK: - Formatting helpers

extension String {
    /// nil when empty, for `??` chains.
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Date {
    /// "Today", "Yesterday", or "Mon, Sep 8".
    var cairnDayLabel: LocalizedStringKey {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return LocalizedStringKey(
                formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            )
        }
        return LocalizedStringKey(formatted(.dateTime.month(.abbreviated).day().year()))
    }
}
