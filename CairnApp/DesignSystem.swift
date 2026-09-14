import SwiftUI
import CairnCore

/// The single source of truth for Cairn's surfaces, color, spacing, and shared
/// components. Screens should reach for these tokens instead of ad-hoc values so
/// the app stays calm and consistent across iPhone, iPad, and Mac.
enum CairnTheme {
    // MARK: Brand & semantic color

    /// The brand teal, from the app icon. Also the app's accent (asset-backed so
    /// it adapts to dark mode).
    static let accent = Color.accentColor
    static let positive = Color("CairnPositive")
    static let negative = Color("CairnNegative")
    static let warning = Color.orange
    static let neutral = Color.secondary

    // MARK: Surfaces

    /// A card / sheet surface that sits above the grouped background.
    static var surface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// The page background behind grouped content and cards.
    static var groupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// A barely-there separator that reads on any surface.
    static let hairline = Color.primary.opacity(0.06)

    // MARK: Geometry

    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let screenMaxWidth: CGFloat = 720

    // MARK: Spacing scale

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

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

// MARK: - Amounts

/// A monetary amount with tabular figures so columns line up and digits do not
/// jitter as values update. Amounts are neutral by default; callers pass a
/// `colorOverride` only when color carries meaning (a delta, a loss).
struct AmountText: View {
    let money: Money
    var showSign: Bool = false
    var font: Font = .body
    var colorOverride: Color?

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(colorOverride ?? .primary)
            .contentTransition(.numericText())
    }

    private var text: String {
        let formatted = money.formatted()
        if showSign, !money.isNegative, !money.isZero {
            return "+" + formatted
        }
        return formatted
    }
}

// MARK: - Surfaces

/// A rounded card surface used for headers and grouped content.
struct Card<Content: View>: View {
    var padding: CGFloat = CairnTheme.Spacing.l
    var cornerRadius: CGFloat = CairnTheme.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                CairnTheme.surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(CairnTheme.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Section headers

/// A quiet section label shared by cards and lists.
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: CairnTheme.Spacing.s)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Category badge

/// The colored glyph that leads a transaction or category row. The fill is a
/// soft tint of the category color and the glyph is the color itself, so it
/// reads clearly in both light and dark mode.
struct CategoryBadge: View {
    let symbolName: String?
    let hex: String?
    var size: CGFloat = 32

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = hex.map(CairnTheme.color(hex:)) ?? CairnTheme.neutral
        ZStack {
            Circle().fill(tint.opacity(colorScheme == .dark ? 0.26 : 0.15))
            Image(systemName: symbolName ?? "circle.dashed")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Trend pill

/// A restrained month-over-month change indicator.
struct TrendPill: View {
    let ratio: Double
    var higherIsBad: Bool = true

    /// Percentages past this are not meaningful at a glance (a small baseline
    /// produces an alarming number), so we clamp the label.
    private let cap = 999

    var body: some View {
        let percent = Int((abs(ratio) * 100).rounded())
        let isUp = ratio >= 0
        let good = higherIsBad ? !isUp : isUp
        let tint = percent == 0 ? CairnTheme.neutral : (good ? CairnTheme.positive : CairnTheme.negative)

        HStack(spacing: 2) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text(percent > cap ? "\(cap)+%" : "\(percent)%")
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Metric

/// A labeled value used inside summary cards.
struct Metric: View {
    let title: String
    let money: Money
    var tint: Color = .primary
    var font: Font = .callout.weight(.semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(money: money, font: font, colorOverride: tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty state

/// Empty-state presentation shared by the main lists.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
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
        padding(CairnTheme.Spacing.l)
            .frame(maxWidth: CairnTheme.screenMaxWidth)
            .frame(maxWidth: .infinity)
    }
}
