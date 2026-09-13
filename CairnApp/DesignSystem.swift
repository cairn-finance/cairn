import SwiftUI
import CairnCore

/// A small set of shared visual building blocks so the app feels consistent and
/// crisp across iPhone, iPad, and Mac.
enum CairnTheme {
    static let positive = Color.green
    static let negative = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let neutral = Color.secondary

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

/// A monetary amount with tabular figures so columns line up and digits do not
/// jitter as values update.
struct AmountText: View {
    let money: Money
    var showSign: Bool = false
    var font: Font = .body
    var colorOverride: Color?

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(colorOverride ?? tint)
            .contentTransition(.numericText())
    }

    private var text: String {
        let formatted = money.formatted()
        if showSign, !money.isNegative, !money.isZero {
            return "+" + formatted
        }
        return formatted
    }

    private var tint: Color {
        if money.isZero { return CairnTheme.neutral }
        return money.isNegative ? CairnTheme.negative : CairnTheme.positive
    }
}

/// A rounded card surface used for headers and grouped content.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Empty-state presentation shared by the main lists.
struct EmptyStateView: View {    let systemImage: String
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
}
