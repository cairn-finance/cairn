import Foundation

/// Reconstructs historical balances from the current balance and the
/// transactions in the fetched window, so a brand-new install still shows a
/// meaningful net-worth chart on day one.
///
/// `balance(on: d) = currentBalance - sum(amounts posted after d)`
public enum BalanceHistory {
    public struct Entry: Sendable, Hashable {
        public let date: Date
        public let amountMinorUnits: Int64
        public init(date: Date, amountMinorUnits: Int64) {
            self.date = date
            self.amountMinorUnits = amountMinorUnits
        }
    }

    /// The balance as it stood at the end of `day`.
    public static func balance(
        asOf day: Date,
        currentBalanceMinorUnits: Int64,
        transactions: [Entry],
        calendar: Calendar = .current
    ) -> Int64 {
        let cutoff = day
        let laterSum = transactions
            .filter { $0.date > cutoff }
            .reduce(Int64(0)) { $0 + $1.amountMinorUnits }
        return currentBalanceMinorUnits - laterSum
    }

    /// A daily series from `start` through `end` inclusive, ordered ascending.
    public static func dailyBalances(
        from start: Date,
        through end: Date,
        currentBalanceMinorUnits: Int64,
        transactions: [Entry],
        calendar: Calendar = .current
    ) -> [(date: Date, balanceMinorUnits: Int64)] {
        guard start <= end else { return [] }

        // Sort descending once and accumulate, rather than re-summing per day.
        let sorted = transactions.sorted { $0.date > $1.date }
        var result: [(date: Date, balanceMinorUnits: Int64)] = []

        var running = currentBalanceMinorUnits
        var index = 0
        var day = calendar.startOfDay(for: end)
        let firstDay = calendar.startOfDay(for: start)

        while day >= firstDay {
            // Add back everything posted after this day (i.e. moving backward in
            // time, undo each transaction).
            while index < sorted.count, sorted[index].date > endOfDay(day, calendar: calendar) {
                running -= sorted[index].amountMinorUnits
                index += 1
            }
            result.append((day, running))
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        return result.reversed()
    }

    private static func endOfDay(_ day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001) ?? start
    }
}
