import SwiftUI
import CairnCore

/// A compact monthly plan that puts budget progress, upcoming commitments,
/// and personal tracking in one adaptive layout.
struct PlanOverview: View {
    var budgetingEnabled = true
    let snapshot: BudgetSnapshot?
    let currency: Currency
    let monthKey: String
    let isLoading: Bool
    let loadFailed: Bool
    let retry: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let categoryLimit = 5

    private var plannedLines: [BudgetLine] {
        guard let snapshot else { return [] }
        return snapshot.lines.filter { $0.plannedMinorUnits != nil }
    }

    private var shortlist: [BudgetLine] {
        let lines = plannedLines
        let overPlan = lines.filter { ($0.remainingMinorUnits ?? 0) < 0 }
            .sorted {
                let firstOverage = MinorUnits.absClamped($0.remainingMinorUnits ?? 0)
                let secondOverage = MinorUnits.absClamped($1.remainingMinorUnits ?? 0)
                if firstOverage != secondOverage { return firstOverage > secondOverage }
                if $0.category.sortOrder != $1.category.sortOrder {
                    return $0.category.sortOrder < $1.category.sortOrder
                }
                return $0.category.name.localizedStandardCompare($1.category.name) == .orderedAscending
            }
        let onPlan = lines.filter { ($0.remainingMinorUnits ?? 0) >= 0 }
            .sorted {
                if $0.spentMinorUnits != $1.spentMinorUnits { return $0.spentMinorUnits > $1.spentMinorUnits }
                if $0.category.sortOrder != $1.category.sortOrder {
                    return $0.category.sortOrder < $1.category.sortOrder
                }
                return $0.category.name.localizedStandardCompare($1.category.name) == .orderedAscending
            }
        return Array((overPlan + onPlan).prefix(categoryLimit))
    }

    private var monthLabel: String {
        guard let date = BudgetCalculator.startOfMonth(monthKey) else { return monthKey }
        return date.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        if budgetingEnabled {
            FlowColumns(primaryFraction: 0.58, minimumColumnWidth: 320) {
                VStack(alignment: .leading, spacing: 28) {
                    budgetSection
                    if snapshot != nil { categorySection }
                }
            } secondary: {
                trackingColumn
            }
        } else {
            trackingColumn
        }
    }

    private var trackingColumn: some View {
        VStack(alignment: .leading, spacing: 28) {
            FlowSection { FlowUpcomingPayments(currency: currency, limit: 3) }
            PersonalTrackingEntryPoints(showsFundDetails: true)
            FlowSection {
                NavigationLink { ForecastView() } label: {
                    FlowLinkRow(title: "Cash-flow forecast", symbol: "chart.xyaxis.line")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var budgetSection: some View {
        FlowSection {
            VStack(alignment: .leading, spacing: 16) {
                ScreenSectionHeader("Monthly plan") {
                    NavigationLink {
                        BudgetView(initialMonthKey: monthKey, initialCurrency: currency)
                    } label: {
                        Text("Edit limits").font(.subheadline).frame(minHeight: 44)
                    }
                }

                if isLoading && snapshot == nil {
                    ProgressView("Loading plan…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else if loadFailed && snapshot == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your monthly plan couldn’t be loaded.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Try again", action: retry)
                    }
                } else if let snapshot {
                    budgetSummary(snapshot)
                } else {
                    Text("Your monthly plan isn’t available yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                NavigationLink { InsightsView() } label: {
                    FlowLinkRow(title: "Spending detail", symbol: "chart.pie")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("spendingDetails")
            }
        }
    }

    @ViewBuilder
    private func budgetSummary(_ data: BudgetSnapshot) -> some View {
        if data.plannedMinorUnits > 0 {
            VStack(alignment: .leading, spacing: 14) {
                summaryMetrics(data)
                FlowBudgetRuler(
                    spent: data.budgetedSpentMinorUnits,
                    planned: data.plannedMinorUnits,
                    currency: data.currency
                )
                Text("\(monthLabel) · Across your planned categories.")
                    .font(.caption).foregroundStyle(.secondary)
                if data.unbudgetedMinorUnits > 0 {
                    let outsideLimits = Money(
                        minorUnits: data.unbudgetedMinorUnits,
                        currency: data.currency
                    ).formatted()
                    Text("\(outsideLimits) outside category limits")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set category limits to build a monthly plan.")
                    .font(.body.weight(.medium))
                Text("Track upcoming payments, funds, and shared expenses here while you set it up.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func summaryMetrics(_ data: BudgetSnapshot) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                remainingMetric(data)
                plannedMetric(data)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                remainingMetric(data)
                Spacer(minLength: 8)
                plannedMetric(data)
            }
        }
    }

    private func remainingMetric(_ data: BudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(data.remainingMinorUnits < 0 ? "Over plan" : "Left in category limits")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AmountText(
                money: Money(minorUnits: MinorUnits.absClamped(data.remainingMinorUnits), currency: data.currency),
                font: .cairnHero,
                colorOverride: data.remainingMinorUnits < 0 ? CairnTheme.negative : nil,
                deemphasizeFraction: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func plannedMetric(_ data: BudgetSnapshot) -> some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
            Text("Budgeted spending").font(.caption).foregroundStyle(.secondary)
            Text(Money(minorUnits: data.budgetedSpentMinorUnits, currency: data.currency).formatted())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
            Text("of \(Money(minorUnits: data.plannedMinorUnits, currency: data.currency).formatted())")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }

    private var categorySection: some View {
        FlowSection {
            VStack(alignment: .leading, spacing: 14) {
                ScreenSectionHeader("Category limits") {
                    NavigationLink {
                        BudgetView(initialMonthKey: monthKey, initialCurrency: currency)
                    } label: {
                        Text("See all").font(.subheadline).frame(minHeight: 44)
                    }
                }

                if plannedLines.isEmpty {
                    Text("No category limits yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(shortlist) { line in
                            categoryRow(line)
                            if line.id != shortlist.last?.id { Divider().padding(.leading, 42) }
                        }
                    }
                    if plannedLines.count > shortlist.count {
                        Text("Showing \(shortlist.count) of \(plannedLines.count) categories. See all to view every limit.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func categoryRow(_ line: BudgetLine) -> some View {
        let remaining = line.remainingMinorUnits ?? 0
        let used = Money(minorUnits: line.spentMinorUnits, currency: currency).formatted()
        let planned = Money(minorUnits: line.plannedMinorUnits ?? 0, currency: currency).formatted()
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        CategoryBadge(symbolName: line.category.symbolName, hex: line.category.colorHex, size: 32)
                        Text(line.category.name).font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    categoryAmounts(used: used, planned: planned, remaining: remaining)
                }
            } else {
                HStack(spacing: 10) {
                    CategoryBadge(symbolName: line.category.symbolName, hex: line.category.colorHex, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.category.name).font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(used) used of \(planned)")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    categoryRemaining(remaining)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.category.name)
        .accessibilityValue(categoryAccessibilityValue(line, remaining: remaining))
    }

    private func categoryAmounts(used: String, planned: String, remaining: Int64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(used) used of \(planned)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            categoryRemaining(remaining)
        }
    }

    private func categoryRemaining(_ remaining: Int64) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(Money(minorUnits: MinorUnits.absClamped(remaining), currency: currency).formatted())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
            Text(remaining < 0 ? "over" : "left")
                .font(.caption).foregroundStyle(remaining < 0 ? CairnTheme.warning : .secondary)
        }
    }

    private func categoryAccessibilityValue(_ line: BudgetLine, remaining: Int64) -> String {
        let planned = Money(minorUnits: line.plannedMinorUnits ?? 0, currency: currency).formatted()
        let spent = Money(minorUnits: line.spentMinorUnits, currency: currency).formatted()
        let amount = Money(minorUnits: MinorUnits.absClamped(remaining), currency: currency).formatted()
        return String(localized: "\(spent) used of \(planned), \(amount) \(remaining < 0 ? "over" : "left")")
    }
}
