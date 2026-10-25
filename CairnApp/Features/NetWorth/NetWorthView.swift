import SwiftUI
import SwiftData
import Charts
import CairnCore

/// Full net-worth history: a scrubbable chart, the change over the selected
/// range, and the assets/liabilities split.
struct NetWorthView: View {
    @Query private var accounts: [Account]
    @Query private var settings: [AppSettings]
    @Query private var chartTransactions: [LedgerTransaction]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var range: RangeOption = .ninetyDays
    @State private var selectedDate: Date?
    @ScaledMetric(relativeTo: .body) private var chartHeight = 220.0

    init() {
        _chartTransactions = Query(filter: NetWorthMath.transactionPredicate(days: 365))
    }

    enum RangeOption: String, CaseIterable, Identifiable {
        case thirtyDays, ninetyDays, sixMonths, oneYear
        var id: String { rawValue }
        var title: String {
            switch self {
            case .thirtyDays: "1M"
            case .ninetyDays: "3M"
            case .sixMonths: "6M"
            case .oneYear: "1Y"
            }
        }
        var longTitle: LocalizedStringKey {
            switch self {
            case .thirtyDays: "Last 30 days"
            case .ninetyDays: "Last 90 days"
            case .sixMonths: "Last 6 months"
            case .oneYear: "Last year"
            }
        }
        var days: Int {
            switch self {
            case .thirtyDays: 30
            case .ninetyDays: 90
            case .sixMonths: 182
            case .oneYear: 365
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if totals.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.line.uptrend.xyaxis",
                        title: "Nothing to chart yet",
                        message: "Connect a bank and sync to build your net worth history."
                    )
                } else {
                    #if os(macOS)
                    FlowColumns(primaryFraction: 0.6, minimumColumnWidth: 320) {
                        VStack(alignment: .leading, spacing: 24) {
                            chartCard
                            breakdownCard
                            if totals.count > 1 { currenciesCard }
                        }
                    } secondary: {
                        accountsCard
                    }
                    #else
                    chartCard
                    breakdownCard
                    if totals.count > 1 {
                        currenciesCard
                    }
                    accountsCard
                    #endif
                }
            }
            .cairnScreen(maxWidth: pageMaxWidth)
        }
        .cairnCanvas()
        .navigationTitle("Net Worth")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Data

    private var pageMaxWidth: CGFloat {
        #if os(macOS)
        CairnTheme.desktopMaxWidth
        #else
        CairnTheme.screenMaxWidth
        #endif
    }

    private var totals: [CurrencyTotal] { NetWorthMath.totals(accounts: accounts) }

    private var currency: Currency {
        NetWorthMath.primaryCurrency(totals: totals, home: NetWorthMath.homeCurrency(settings: settings))
    }

    private var currentTotal: Int64 {
        totals.first { $0.currency == currency }?.totalMinorUnits ?? 0
    }

    private var series: [(date: Date, balanceMinorUnits: Int64)] {
        NetWorthMath.series(accounts: accounts, currency: currency, transactions: chartTransactions, days: range.days)
    }

    private var selectedPoint: (date: Date, balanceMinorUnits: Int64)? {
        guard let selectedDate else { return nil }
        let day = Calendar.current.startOfDay(for: selectedDate)
        return series.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    // MARK: - Chart

    private var chartCard: some View {
        let points = series
        let change = NetWorthMath.change(in: points)
        let shown = selectedPoint?.balanceMinorUnits ?? currentTotal

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    chartDate
                    AmountText(
                        money: Money(minorUnits: shown, currency: currency),
                        font: .cairnHero,
                        deemphasizeFraction: true,
                        animatesChanges: false
                    )
                    .accessibilityIdentifier("netWorthHistoryAmount")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { changeDescription(change) }
                        VStack(alignment: .leading, spacing: 8) { changeDescription(change) }
                    }
                }

                rangePicker
                chart(points)
                    .frame(height: chartHeight)
                    .accessibilityIdentifier("netWorthHistoryChart")
                Text("Balance history is derived from transactions, not investment performance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .animation(reduceMotion ? nil : CairnTheme.Motion.standard, value: range)
    }

    private var chartDate: some View {
        Group {
            if let selectedPoint {
                Text(selectedPoint.date.formatted(date: .abbreviated, time: .omitted))
            } else {
                Text("Today")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .contentTransition(.opacity)
    }

    private var rangePicker: some View {
        SegmentedPicker(options: RangeOption.allCases, selection: $range) { LocalizedStringKey($0.title) }
            .frame(maxWidth: 280)
    }

    @ViewBuilder
    private func changeDescription(_ change: (delta: Int64, ratio: Double?)) -> some View {
        if let ratio = change.ratio {
            TrendPill(ratio: ratio, higherIsBad: false)
        }
        Text(changeSentence(change.delta))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func chart(_ points: [(date: Date, balanceMinorUnits: Int64)]) -> some View {
        let values = points.map { NetWorthMath.doubleValue($0.balanceMinorUnits, currency: currency) }
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let pad = max((maxValue - minValue) * 0.15, 1)

        return Chart {
            ForEach(points, id: \.date) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Balance", NetWorthMath.doubleValue(point.balanceMinorUnits, currency: currency))
                )
                .foregroundStyle(CairnTheme.accent)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            if let selected = selectedPoint {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("Selected", selected.date),
                    y: .value("Balance", NetWorthMath.doubleValue(selected.balanceMinorUnits, currency: currency))
                )
                .symbolSize(90)
                .foregroundStyle(CairnTheme.accent)
                PointMark(
                    x: .value("Selected", selected.date),
                    y: .value("Balance", NetWorthMath.doubleValue(selected.balanceMinorUnits, currency: currency))
                )
                .symbolSize(30)
                .foregroundStyle(CairnTheme.surface)
            }
        }
        .chartYScale(domain: (minValue - pad)...(maxValue + pad))
        .flowChartSelection($selectedDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), anchor: .top)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(CairnTheme.hairline)
                AxisValueLabel(anchor: .leading) {
                    if let amount = value.as(Double.self) {
                        Text(compact(amount)).foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedPoint?.date)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Net worth over time"))
        .accessibilityValue(Text(verbatim: summary(points)))
        .accessibilityChartDescriptor(chartDescriptor(points))
        .accessibilityAdjustableAction { direction in
            let dates = points.map(\.date)
            guard !dates.isEmpty else { return }
            let index = selectedDate.flatMap { selected in dates.firstIndex(of: selected) }
            switch direction {
            case .increment: selectedDate = dates[min((index ?? -1) + 1, dates.count - 1)]
            case .decrement: selectedDate = dates[max((index ?? dates.count) - 1, 0)]
            @unknown default: break
            }
        }
    }

    /// A spoken summary of the range, since the line itself is visual.
    private func summary(_ points: [(date: Date, balanceMinorUnits: Int64)]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        let start = Money(minorUnits: first.balanceMinorUnits, currency: currency).formatted()
        let end = Money(minorUnits: last.balanceMinorUnits, currency: currency).formatted()
        return "\(start) to \(end)"
    }

    /// The VoiceOver chart rotor and audio graph for the net-worth line.
    private func chartDescriptor(
        _ points: [(date: Date, balanceMinorUnits: Int64)]
    ) -> AccessibleChart {
        AccessibleChart(
            title: String(localized: "Net worth over time"),
            summary: summary(points),
            xTitle: String(localized: "Date"),
            yTitle: String(localized: "Balance"),
            lines: [
                .init(
                    name: String(localized: "Net worth"),
                    isContinuous: true,
                    points: points.map {
                        (
                            x: $0.date.timeIntervalSince1970,
                            y: NetWorthMath.doubleValue($0.balanceMinorUnits, currency: currency)
                        )
                    }
                )
            ],
            describesX: { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) },
            describesY: { $0.formatted(.currency(code: currency.code)) }
        )
    }

    // MARK: - Breakdown

    private var breakdownCard: some View {
        let split = NetWorthMath.assetsAndLiabilities(accounts: accounts, currency: currency)
        let total = split.assets + split.liabilities
        let assetShare = total > 0 ? Double(split.assets) / Double(total) : 1

        return FlowSection {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("Assets & liabilities")

                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        Capsule()
                            .fill(CairnTheme.positive)
                            .frame(width: max(6, proxy.size.width * assetShare))
                        if split.liabilities > 0 {
                            Capsule().fill(CairnTheme.negative)
                        }
                    }
                }
                .frame(height: 8)

                HStack(spacing: 12) {
                    StatTile(title: "Assets", systemImage: "arrow.up.right", tint: CairnTheme.positive) {
                        AmountText(money: Money(minorUnits: split.assets, currency: currency), font: .callout.weight(.semibold))
                    }
                    StatTile(title: "Liabilities", systemImage: "arrow.down.right", tint: CairnTheme.negative) {
                        AmountText(
                            money: Money(minorUnits: split.liabilities, currency: currency),
                            font: .callout.weight(.semibold)
                        )
                    }
                }
            }
        }
    }

    private var currenciesCard: some View {
        FlowSection {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("Other currencies", subtitle: "Totals are kept per currency. Exchange rates are not used.")
                ForEach(totals.filter { $0.currency != currency }) { total in
                    HStack {
                        Text(total.currency.displayLabel)
                            .font(.callout)
                        Spacer()
                        AmountText(
                            money: Money(minorUnits: total.totalMinorUnits, currency: total.currency),
                            font: .callout.weight(.semibold)
                        )
                    }
                }
            }
        }
    }

    private var accountsCard: some View {
        let included = NetWorthMath.included(accounts).filter { $0.currency == currency }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Included accounts", trailing: "\(included.count)")
            RowGroup {
                ForEach(Array(included.enumerated()), id: \.element.persistentModelID) { index, account in
                    NavigationLink {
                        AccountDetailView(account: account)
                    } label: {
                        AccountRow(account: account)
                    }
                    .buttonStyle(.plain)
                    if index < included.count - 1 { RowDivider() }
                }
            }
        }
    }

    // MARK: - Helpers

    private func changeSentence(_ delta: Int64) -> String {
        let money = Money(minorUnits: abs(delta), currency: currency)
        let period = range.title == "1Y" ? "past year" : "past \(range.days) days"
        if delta == 0 { return "No change over the \(period)" }
        return "\(delta > 0 ? "Up" : "Down") \(money.formatted()) over the \(period)"
    }

    private func compact(_ value: Double) -> String {
        Money(minorUnits: Int64(value * pow(10, Double(currency.exponent))), currency: currency).compactFormatted()
    }
}
