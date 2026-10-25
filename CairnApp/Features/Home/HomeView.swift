import SwiftUI
import SwiftData
import CairnCore

/// Flow separates daily decisions, planning, and the balance sheet while
/// sharing the same currency-scoped data and existing editing destinations.
struct HomeView: View {
    enum Destination { case today, plan, wealth }
    var destination: Destination = .today

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppFeature.budgeting.storageKey) private var budgetingEnabled = AppFeature.budgeting.defaultEnabled
    @Query(sort: \Institution.name) private var institutions: [Institution]
    @Query(
        filter: #Predicate<Account> { $0.isHidden == false },
        sort: [SortDescriptor(\Account.displayOrder)]
    )
    private var accounts: [Account]
    @Query private var settings: [AppSettings]
    @Query private var categories: [CairnSchemaV4.Category]
    @Query private var budgetSettings: [CategoryBudget]
    @Query private var budgetSmoothingPlans: [BudgetSmoothingPlan]

    @State private var showingConnect = false
    @State private var showingManualAccount = false
    @State private var budgetTransactions: [BudgetTransaction] = []
    @State private var spendingHistory: [FlowChartPoint] = []
    @State private var spendingSelection: Date?
    @State private var budgetReloadToken = 0
    @State private var didLoadBudgetSummary = false
    @State private var budgetLoadFailed = false
    @State private var spendingLoadFailed = false
    @State private var loadedSummaryScope: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if model.isOffline {
                    OfflineNoticeView()
                        .cairnAppear()
                }
                if accounts.isEmpty {
                    emptyState
                    PersonalTrackingEntryPoints(showsFundDetails: destination == .plan)
                } else {
                    switch destination {
                    case .today: todayContent
                    case .plan: planContent
                    case .wealth: wealthContent
                    }
                }
            }
            .cairnScreen(maxWidth: pageMaxWidth)
        }
        .cairnScrollEdge()
        .cairnCanvas()
        .navigationTitle(destination == .today ? "Today" : destination == .plan ? "Plan" : "Wealth")
        .toolbar { toolbarContent }
        .task(id: budgetReloadKey) {
            guard destination != .wealth else { return }
            await loadBudgetSummary()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                budgetReloadToken &+= 1
            }
        }
        .refreshable { await model.syncAll(force: true) }
        .sheet(isPresented: $showingConnect) {
            AddConnectionSheet { showingConnect = false }
                .cairnLockCover()
        }
        .sheet(isPresented: $showingManualAccount) {
            ManualAccountSheet()
                .cairnLockCover()
        }
    }

    // MARK: - Sections

    private var pageMaxWidth: CGFloat {
        #if os(macOS)
        CairnTheme.desktopMaxWidth
        #else
        CairnTheme.screenMaxWidth
        #endif
    }

    private var todayContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            todayHeader
            #if os(macOS)
            FlowColumns(minimumColumnWidth: 360) {
                spendingSummary
            } secondary: {
                NetWorthHero(accounts: accounts, settings: settings)
            }
            FlowColumns(minimumColumnWidth: 320) {
                FlowSection { FlowUpcomingPayments(currency: budgetCurrency) }
            } secondary: {
                FlowSection {
                    planLink
                    SyncIssueCard()
                    syncStatus
                }
            }
            #else
            spendingSummary
            FlowSection {
                NetWorthHero(accounts: accounts, settings: settings, compact: true)
            }
            FlowUpcomingPayments(currency: budgetCurrency)
            planLink
            SyncIssueCard()
            syncStatus
            #endif
        }
    }

    private var todayHeader: some View {
        HStack {
            Label("Cairn", systemImage: "mountain.2")
                .foregroundStyle(CairnTheme.accent)
            Spacer()
            Text(Date.now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var planLink: some View {
        NavigationLink { HomeView(destination: .plan) } label: {
            FlowLinkRow(title: "Your plan", symbol: "calendar", subtitle: "Budgets, funds, and shared expenses")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("todayPlanEntry")
    }

    private var planContent: some View {
        PlanOverview(budgetingEnabled: budgetingEnabled,
                     snapshot: budgetingEnabled ? budgetSnapshot : nil,
                     currency: budgetCurrency, monthKey: budgetMonthKey,
                     isLoading: !didLoadBudgetSummary, loadFailed: budgetLoadFailed,
                     retry: { budgetReloadToken &+= 1 })
    }

    private var wealthContent: some View {
        #if os(macOS)
        FlowColumns(primaryFraction: 0.52, minimumColumnWidth: 360) {
            wealthSummary
        } secondary: {
            wealthAccounts
        }
        #else
        VStack(alignment: .leading, spacing: 28) {
            wealthSummary
            wealthAccounts
        }
        #endif
    }

    private var wealthSummary: some View {
        VStack(alignment: .leading, spacing: 28) {
            NetWorthHero(accounts: accounts, settings: settings)
            FlowSection {
                NavigationLink { InvestmentsView() } label: {
                    FlowLinkRow(title: "Investments", symbol: "chart.line.uptrend.xyaxis",
                                subtitle: "Reported positions and account balances")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("investmentDetails")
            }
        }
    }

    private var wealthAccounts: some View {
        VStack(alignment: .leading, spacing: 28) {
            ScreenSectionHeader("Accounts") {
                Text(accounts.count, format: .number).font(.subheadline).foregroundStyle(.secondary)
            }
            institutionsSection
            SyncIssueCard()
            syncStatus
        }
    }

    private var budgetDestination: some View {
        BudgetView(initialMonthKey: budgetMonthKey, initialCurrency: budgetCurrency)
    }

    @ViewBuilder
    private var spendingSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            if spendingLoadFailed {
                ContentUnavailableView("Spending unavailable", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                Button("Retry") { budgetReloadToken &+= 1 }
            } else if didLoadBudgetSummary {
                let selected = FlowChartPoint.nearest(to: spendingSelection, in: spendingHistory)
                VStack(alignment: .leading, spacing: 5) {
                    Text(selected == nil ? "Spent this month" : "Spent through")
                        .font(.subheadline).foregroundStyle(.secondary)
                    AmountText(money: Money(minorUnits: selected?.minorUnits ?? spendingHistory.last?.minorUnits ?? 0,
                                            currency: budgetCurrency),
                               font: destination == .today ? .cairnHero : .cairnDisplay,
                               deemphasizeFraction: true, animatesChanges: false)
                        .accessibilityIdentifier("spendingHeadlineAmount")
                    Group {
                        if let selected {
                            Text(selected.date, format: .dateTime.month(.abbreviated).day().year())
                        } else {
                            Text(Date.now, format: .dateTime.month(.wide).year())
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                if budgetingEnabled, let summary = budgetSnapshot, summary.plannedMinorUnits > 0 {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("Planned categories").font(.subheadline.weight(.medium))
                            Spacer(minLength: 8)
                            remainingText(summary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Planned categories").font(.subheadline.weight(.medium))
                            remainingText(summary)
                        }
                    }
                    FlowBudgetRuler(spent: summary.budgetedSpentMinorUnits, planned: summary.plannedMinorUnits,
                                    currency: summary.currency)
                    if summary.unbudgetedMinorUnits > 0 {
                        let unplanned = Money(minorUnits: summary.unbudgetedMinorUnits, currency: summary.currency).formatted()
                        Text("\(unplanned) outside planned categories")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if budgetingEnabled, budgetLoadFailed {
                    HStack {
                        Text("Budget progress unavailable").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { budgetReloadToken &+= 1 }.frame(minHeight: 44)
                    }
                } else if budgetingEnabled {
                    NavigationLink { budgetDestination } label: {
                        Label("Set category limits", systemImage: "plus.circle").font(.subheadline)
                    }
                    .frame(minHeight: 44)
                }
                if destination == .today {
                    FlowLineChart(points: spendingHistory, currency: budgetCurrency,
                                  title: "Spending this month", includesZero: true, compact: compactCharts,
                                  selection: $spendingSelection)
                        .accessibilityIdentifier("todaySpendingChart")
                }
            } else {
                ProgressView("Loading spending").frame(maxWidth: .infinity, minHeight: 100)
            }
            NavigationLink { InsightsView() } label: {
                FlowLinkRow(title: "Spending detail", symbol: "chart.pie")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("spendingDetails")
        }
    }

    private var compactCharts: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    private func remainingText(_ summary: BudgetSnapshot) -> some View {
        let amount = Money(minorUnits: MinorUnits.absClamped(summary.remainingMinorUnits), currency: summary.currency).formatted()
        return Text(summary.remainingMinorUnits < 0 ? "\(amount) over plan" : "\(amount) remaining")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(summary.remainingMinorUnits < 0 ? CairnTheme.negative : CairnTheme.accent)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var budgetCurrency: Currency {
        accounts.first(where: { $0.currency == homeCurrency })?.currency
            ?? accounts.first(where: { $0.currency.code == homeCurrency.code })?.currency
            ?? accounts.first?.currency
            ?? homeCurrency
    }

    private var budgetMonthKey: String {
        BudgetCalculator.monthKey(for: .now, timeZone: budgetTimeZone)
    }

    private var budgetTimeZone: TimeZone {
        budgetSettings
            .filter { $0.currency == budgetCurrency }
            .sorted {
                if $0.monthKey != $1.monthKey { return $0.monthKey < $1.monthKey }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }
            .compactMap { TimeZone(identifier: $0.timeZoneIdentifier) }
            .first ?? .current
    }

    private var budgetReloadKey: String {
        let editStamp = budgetSettings.map(\.modifiedAt).max()?.timeIntervalSince1970 ?? 0
        let smoothingStamp = budgetSmoothingPlans
            .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            .map { "\($0.uuid.uuidString):\($0.modifiedAt.timeIntervalSince1970)" }
            .joined(separator: ",")
        let accountStamp = accounts.filter { $0.currency == budgetCurrency }
            .map(\.bankAccountID).sorted().joined(separator: ",")
        let categoryStamp = categories.map { "\($0.uuid.uuidString):\($0.name):\($0.isArchived)" }
            .joined(separator: ",")
        return [
            String(budgetReloadToken),
            budgetMonthKey,
            budgetCurrency.stableIdentifier,
            String(editStamp),
            smoothingStamp,
            accountStamp,
            categoryStamp
        ].joined(separator: "-")
    }

    private var budgetSnapshot: BudgetSnapshot? {
        guard didLoadBudgetSummary, !budgetLoadFailed else { return nil }
        return makeBudgetSnapshot(budgetTransactions)
    }

    private func makeBudgetSnapshot(_ transactions: [BudgetTransaction]) -> BudgetSnapshot {
        let categoryValues = categories.map {
            BudgetCategory(
                uuid: $0.uuid,
                name: $0.name,
                colorHex: $0.colorHex,
                symbolName: $0.symbolName,
                sortOrder: $0.sortOrder,
                isArchived: $0.isArchived
            )
        }
        let settingValues = budgetSettings.map {
            BudgetSetting(
                uuid: $0.uuid,
                categoryUUID: $0.categoryUUID,
                currency: $0.currency,
                monthKey: $0.monthKey,
                amountMinorUnits: $0.amountMinorUnits,
                isMonthOverride: $0.isMonthOverride,
                isEnabled: $0.isEnabled,
                timeZoneIdentifier: $0.timeZoneIdentifier,
                modifiedAt: $0.modifiedAt
            )
        }
        return BudgetCalculator.snapshot(
            transactions: transactions,
            categories: categoryValues,
            settings: settingValues,
            monthKey: budgetMonthKey,
            currency: budgetCurrency,
            timeZone: budgetTimeZone
        )
    }

    private func loadBudgetSummary() async {
        let scope = "\(budgetCurrency.stableIdentifier):\(budgetMonthKey)"
        // A background save must not remove the chart under an active drag.
        // Currency or month changes still hide the old scope while loading.
        if loadedSummaryScope != scope { didLoadBudgetSummary = false }
        budgetLoadFailed = false
        spendingLoadFailed = false
        let visible = accounts.filter { $0.currency == budgetCurrency }
        guard !visible.isEmpty,
              let start = BudgetCalculator.startOfMonth(budgetMonthKey, timeZone: budgetTimeZone) else {
            budgetTransactions = []
            spendingHistory = []
            didLoadBudgetSummary = true
            loadedSummaryScope = scope
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = budgetTimeZone
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let scopes = visible.map { BudgetAccountScope(bankAccountID: $0.bankAccountID) }
        let container = model.container
        let fetcher = await Task.detached(priority: .utility) {
            BudgetFetcher(modelContainer: container)
        }.value
        let insightsFetcher = await Task.detached(priority: .utility) {
            InsightsFetcher(modelContainer: container)
        }.value
        let insightScopes = visible.map {
            InsightAccountScope(bankAccountID: $0.bankAccountID, displayName: $0.displayName)
        }
        let spendingStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        async let spendingRows = insightsFetcher.insightTransactions(scopes: insightScopes, earliest: spendingStart)
        do {
            let result = try await fetcher.budgetTransactions(
                scopes: scopes,
                from: start,
                to: end,
                timeZone: budgetTimeZone
            )
            guard !Task.isCancelled else { return }
            budgetTransactions = result
        } catch {
            guard !Task.isCancelled else { return }
            budgetTransactions = []
            budgetLoadFailed = true
        }
        do {
            let rows = try await spendingRows
            guard !Task.isCancelled else { return }
            updateSpendingHistory(rows)
        } catch {
            guard !Task.isCancelled else { return }
            spendingHistory = []
            spendingLoadFailed = true
        }
        didLoadBudgetSummary = true
        loadedSummaryScope = scope
    }

    /// Actual spending uses the same ledger calculator as Spending detail.
    /// Budget smoothing affects the plan ruler, never the cash-spending line.
    private func updateSpendingHistory(_ rows: [InsightTransaction]) {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        spendingHistory = InsightsCalculator.cumulativeSpending(transactions: rows, month: start).compactMap { point in
            guard let date = calendar.date(byAdding: .day, value: point.day - 1, to: start) else { return nil }
            return FlowChartPoint(date: date, minorUnits: point.amountMinorUnits)
        }
    }

    private var syncStatus: some View {
        HStack(spacing: 10) {
            switch model.syncState {
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case let .failed(message):
                if model.syncProblemIsJustOffline {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(CairnTheme.warning)
                    Text("Sync paused while offline")
                        .accessibilityHint(message)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CairnTheme.warning)
                    Text("Last sync had a problem")
                        .accessibilityHint(message)
                }
            case let .waiting(title, detail, _):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(title)
                    .accessibilityHint(detail)
            case .idle, .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(CairnTheme.positive)
                if let date = lastSync {
                    Text("Updated \(date, format: .relative(presentation: .named))")
                } else {
                    Text("Not synced yet")
                }
            }
            Spacer()
            if model.remainingBudget < SyncEngine.dailyRequestLimit / 4 {
                StatusPill(text: "^[\(model.remainingBudget) sync](inflect: true) left today", tint: CairnTheme.warning)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .animation(CairnTheme.Motion.quick, value: model.syncState)
    }

    private var lastSync: Date? {
        institutions.compactMap(\.lastSyncDate).max() ?? accounts.compactMap(\.lastSyncedAt).max()
    }

    /// The currency the net-worth hero leads with, so the recurring summary
    /// matches it rather than mixing currencies.
    private var homeCurrency: Currency {
        NetWorthMath.primaryCurrency(
            totals: NetWorthMath.totals(accounts: accounts),
            home: NetWorthMath.homeCurrency(settings: settings)
        )
    }

    private var homeRecurring: [RecurringSeries] {
        model.recurringSeries.filter { $0.currency == homeCurrency }
    }

    private var institutionsSection: some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
            ForEach(institutions) { institution in
                let institutionAccounts = accounts.filter {
                    $0.institution?.persistentModelID == institution.persistentModelID
                }
                if !institutionAccounts.isEmpty {
                    accountGroup(
                        title: institution.name.isEmpty ? "Institution" : LocalizedStringKey(institution.name),
                        trailing: institutionTrailing(institution),
                        accounts: institutionAccounts,
                        institution: institution
                    )
                }
            }

            if !walletAccounts.isEmpty {
                accountGroup(title: "Apple Wallet", trailing: walletTrailing, accounts: walletAccounts)
            }

            if !manualAccounts.isEmpty {
                accountGroup(title: "Manual accounts", trailing: nil, accounts: manualAccounts)
            }
        }
    }

    private func institutionTrailing(_ institution: Institution) -> String? {
        if institution.lastSyncError != nil { return "Needs attention" }
        guard let date = institution.lastSyncDate else { return "Not synced yet" }
        return date.formatted(.relative(presentation: .named))
    }

    private func accountGroup(
        title: LocalizedStringKey,
        trailing: String?,
        accounts: [Account],
        institution: Institution? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            accountHeaderLayout {
                HStack(spacing: 8) {
                    if let institution {
                        InstitutionLogo(
                            organizationURL: institution.orgURL,
                            displayName: institution.name.isEmpty ? String(localized: "Institution") : institution.name,
                            size: 26
                        )
                    }
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: CairnTheme.Spacing.s)
                }
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            RowGroup {
                ForEach(accounts) { account in
                    AccountGroupEntry(
                        account: account,
                        isLast: account.persistentModelID == accounts.last?.persistentModelID
                    )
                }
            }
        }
    }

    private var accountHeaderLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(alignment: .leading, spacing: CairnTheme.Spacing.xs))
        } else {
            AnyLayout(HStackLayout(alignment: .center, spacing: CairnTheme.Spacing.s))
        }
    }

    private var emptyState: some View {
        VStack(spacing: CairnTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(CairnTheme.accent)
                        .accessibilityHidden(true)
                    Text("Welcome to Cairn")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Connect a bank, read Apple Wallet, or add an account by hand. Everything stays on your devices.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SetupActions()
        }
        .padding(.top, 8)
        .cairnAppear()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showingConnect = true
                } label: {
                    Label("Add a Connection", systemImage: "plus")
                }
                Button {
                    showingManualAccount = true
                } label: {
                    Label("Add Manual Account", systemImage: "square.and.pencil")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            SyncButton()
        }
    }

    private var manualAccounts: [Account] {
        accounts.filter { $0.institution == nil && $0.source == .manual }
    }

    private var walletAccounts: [Account] {
        accounts.filter { $0.source == .financeKit }
    }

    /// Wallet data can only be refreshed on iPhone/iPad, so a Mac shows when it
    /// arrived rather than a live sync. A note keeps it from looking stale.
    private var walletTrailing: String? {
        #if os(macOS)
        return "Updates on your iPhone"
        #else
        guard let date = walletAccounts.compactMap(\.lastSyncedAt).max() else { return nil }
        return date.formatted(.relative(presentation: .named))
        #endif
    }
}

/// One account row plus its trailing hairline, emitted as a single view so the
/// list never has to build two elements to place a divider.
private struct AccountGroupEntry: View {
    let account: Account
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                AccountDetailView(account: account)
            } label: {
                AccountRow(account: account)
            }
            .buttonStyle(.plain)
            if !isLast {
                RowDivider()
            }
        }
    }
}

/// The sync toolbar button, which spins its arrows while a sync runs.
struct SyncButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.syncAll(force: true) }
        } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, isActive: model.syncState == .syncing)
        }
        .disabled(model.syncState == .syncing)
        .sensoryFeedback(.success, trigger: model.syncState == .success)
    }
}

/// The current net worth, 30-day change, and transaction-derived history.
struct NetWorthHero: View {
    let accounts: [Account]
    let settings: [AppSettings]
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var chartTransactions: [LedgerTransaction]
    @State private var selection: Date?

    init(accounts: [Account], settings: [AppSettings], compact: Bool = false) {
        self.accounts = accounts
        self.settings = settings
        self.compact = compact
        _chartTransactions = Query(filter: NetWorthMath.transactionPredicate(days: 30))
    }

    private var totals: [CurrencyTotal] { NetWorthMath.totals(accounts: accounts) }
    private var currency: Currency {
        NetWorthMath.primaryCurrency(totals: totals, home: NetWorthMath.homeCurrency(settings: settings))
    }
    private var total: Int64 {
        totals.first { $0.currency == currency }?.totalMinorUnits ?? 0
    }
    private var series: [(date: Date, balanceMinorUnits: Int64)] {
        NetWorthMath.series(accounts: accounts, currency: currency, transactions: chartTransactions, days: 30)
    }
    private var chartPoints: [FlowChartPoint] {
        series.map { FlowChartPoint(date: $0.date, minorUnits: $0.balanceMinorUnits) }
    }
    var body: some View {
        let change = NetWorthMath.change(in: series)
        let split = NetWorthMath.assetsAndLiabilities(accounts: accounts, currency: currency)
        let selected = FlowChartPoint.nearest(to: selection, in: chartPoints)

        VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
            NavigationLink {
                NetWorthView()
            } label: {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
                    HStack {
                        Text("Net worth")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Group {
                            if dynamicTypeSize.isAccessibilitySize {
                                Label("History", systemImage: "arrow.up.right")
                                    .labelStyle(.iconOnly)
                            } else {
                                Label("History", systemImage: "arrow.up.right")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(CairnTheme.accent)
                    }
                    AmountText(
                        money: Money(minorUnits: selected?.minorUnits ?? total, currency: currency),
                        font: compact ? .cairnDisplay : .cairnHero,
                        deemphasizeFraction: true,
                        animatesChanges: false
                    )
                    .accessibilityIdentifier("netWorthHeadlineAmount")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("netWorthDetails")
            .accessibilityHint("Shows your net-worth history and account breakdown")

            ZStack(alignment: .leading) {
                let date = (selected?.date ?? .now).formatted(date: .abbreviated, time: .omitted)
                Text("Balance on \(date)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .opacity(selected == nil ? 0 : 1)
                    .accessibilityHidden(selected == nil)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: CairnTheme.Spacing.s) { changeDescription(change) }
                    VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) { changeDescription(change) }
                }
                .opacity(selected == nil ? 1 : 0)
                .accessibilityHidden(selected != nil)
            }

            FlowLineChart(
                points: chartPoints,
                currency: currency, title: "Net worth history", compact: compact, selection: $selection
            )
            .accessibilityIdentifier("netWorthChart")
            if !compact {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        heroMetric("Assets", Money(minorUnits: split.assets, currency: currency))
                        heroMetric("Liabilities", Money(minorUnits: -split.liabilities, currency: currency))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 12) {
                        heroMetric("Assets", Money(minorUnits: split.assets, currency: currency))
                        heroMetric("Liabilities", Money(minorUnits: -split.liabilities, currency: currency))
                    }
                }
                Text("Balance history is derived from transactions, not investment performance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if totals.count > 1 {
                Text("Plus balances in ^[\(totals.count - 1) other currency](inflect: true)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, CairnTheme.Spacing.s)
    }

    @ViewBuilder
    private func changeDescription(_ change: (delta: Int64, ratio: Double?)) -> some View {
        if change.delta == 0 {
            Text("No change in 30 days")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Label {
                AmountText(
                    money: Money(minorUnits: change.delta, currency: currency),
                    showSign: true,
                    font: .subheadline,
                    colorOverride: change.delta < 0 ? CairnTheme.negative : CairnTheme.positive
                )
            } icon: {
                Image(systemName: change.delta < 0 ? "arrow.down.right" : "arrow.up.right")
            }
            .foregroundStyle(change.delta < 0 ? CairnTheme.negative : CairnTheme.positive)
            Text("in the last 30 days")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func heroMetric(_ title: LocalizedStringKey, _ money: Money) -> some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AmountText(money: money, font: .headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

}
