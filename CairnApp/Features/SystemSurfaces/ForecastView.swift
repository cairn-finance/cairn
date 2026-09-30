import CairnCore
import SwiftUI

/// Explains the aggregate status shown by widgets and forecast alerts.
struct ForecastView: View {
    @Environment(AppModel.self) private var model
    @State private var balances: [ForecastBalance] = []
    @State private var isLoading = true

    private var currencies: [Currency] {
        Array(Set(balances.map(\.currency))).sorted { $0.stableIdentifier < $1.stableIdentifier }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if balances.isEmpty {
                    ContentUnavailableView(
                        "No forecast yet", systemImage: "chart.xyaxis.line",
                        description: Text("Add an account with a saved balance to see your cash-flow forecast.")
                    )
                } else {
                    ForEach(currencies, id: \.self) { currency in
                        forecastCard(currency)
                    }
                }
                RowGroup {
                    NavigationLink {
                        RecurringView()
                    } label: {
                        Label("Review confirmed plans", systemImage: "calendar.badge.clock")
                            .padding()
                    }
                    RowDivider()
                    NavigationLink {
                        ConnectionHealthView()
                    } label: {
                        Label("Check connection health", systemImage: "heart.text.square")
                            .padding()
                    }
                }
                // swiftlint:disable:next line_length
                FootnoteText("This estimate uses saved account balances and confirmed bill and income plans. It excludes unplanned spending, keeps currencies separate, and does not move money.")
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Cash-flow forecast")
        .task { await reload() }
        .refreshable {
            await model.syncAll(force: true)
            await reload()
        }
    }

    private func reload() async {
        balances = await model.forecast(days: 30)
        isLoading = false
    }

    @ViewBuilder
    private func forecastCard(_ currency: Currency) -> some View {
        let points = balances.filter { $0.currency == currency }
        if let lowest = points.min(by: { $0.balanceMinorUnits < $1.balanceMinorUnits }), let end = points.last {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeader("Next 30 days · \(currency.code)")
                    Text(lowest.balanceMinorUnits < 0 ? "A shortfall is forecast" : "Balances stay above zero")
                        .font(.headline)
                        .foregroundStyle(lowest.balanceMinorUnits < 0 ? CairnTheme.negative : CairnTheme.positive)
                    Text("Lowest projected balance")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    AmountText(
                        money: Money(minorUnits: lowest.balanceMinorUnits, currency: currency),
                        font: .title.weight(.semibold)
                    )
                    Text(lowest.date, format: .dateTime.month(.wide).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Text("At 30 days")
                        Spacer()
                        AmountText(
                            money: Money(minorUnits: end.balanceMinorUnits, currency: currency),
                            font: .body.weight(.medium)
                        )
                    }
                    if points.contains(where: \.uncertainty) {
                        // swiftlint:disable:next line_length
                        Label("Some balances are stale or plans have not yet matched a payment. Check connection health and confirmed plans.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(CairnTheme.warning)
                    }
                }
            }
        }
    }
}
