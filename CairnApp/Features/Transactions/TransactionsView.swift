import SwiftUI
import SwiftData
import CairnCore

/// Every transaction across every account, with search and one-tap filters.
///
/// The list is fed by ``TransactionsFeed``: a bounded window fetched with
/// `fetchLimit`, snapshotted to value rows, and expanded as the reader scrolls.
/// Search is debounced and the filter runs before the window is drawn.
struct TransactionsView: View {
    @Environment(AppModel.self) private var model

    @Query(
        sort: [
            SortDescriptor(\CairnSchemaV4.Category.sortOrder),
            SortDescriptor(\CairnSchemaV4.Category.createdAt),
        ]
    )
    private var categories: [CairnSchemaV4.Category]
    @Query(sort: \Tag.name)
    private var tags: [Tag]
    @Query(sort: [SortDescriptor(\Account.displayOrder)])
    private var accounts: [Account]
    @Query private var reviewTransactions: [LedgerTransaction]

    @State private var feed: TransactionsFeed?
    @State private var filter = TransactionFilter()
    @State private var searchText = ""

    enum QuickFilter: String, CaseIterable, Identifiable {
        case all, spending, income, pending, uncategorized
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .spending: "Spending"
            case .income: "Income"
            case .pending: "Pending"
            case .uncategorized: "Needs category"
            }
        }
        var systemImage: String? {
            switch self {
            case .all: nil
            case .spending: "arrow.up.right"
            case .income: "arrow.down.left"
            case .pending: "clock"
            case .uncategorized: "questionmark.circle"
            }
        }

        var query: TransactionFilter.Quick {
            switch self {
            case .all: .all
            case .spending: .spending
            case .income: .income
            case .pending: .pending
            case .uncategorized: .uncategorized
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                reviewInboxEntryPoint
                filterBar
                if let feed {
                    if feed.rows.isEmpty {
                        emptyState(feed)
                    } else {
                        TransactionDayList(
                            sections: feed.sections,
                            showsMonthHeaders: true,
                            onReachEnd: { feed.loadMore() }
                        )
                    }
                }
            }
            .cairnScreen(maxWidth: activityWidth)
            .animation(CairnTheme.Motion.standard, value: feed?.rows.count ?? 0)
        }
        .cairnScrollEdge()
        .cairnCanvas()
        .navigationTitle("Activity")
        .searchable(text: $searchText, prompt: "Merchant, note, tag, or category")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                filtersMenu
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { SharedExpensesView() } label: {
                    Label("Shared expenses", systemImage: "person.2")
                }
            }
        }
        .task {
            if feed == nil {
                feed = TransactionsFeed(container: model.container, filter: filter)
            }
        }
        // Debounce typing: cancel the pending update when the text changes
        // again, so the query only rebuilds after a pause.
        .task(id: searchText) {
            try? await Task.sleep(for: SearchDebounce.interval)
            guard !Task.isCancelled else { return }
            filter.searchText = SearchDebounce.normalize(searchText)
        }
        .onChange(of: filter) { _, newValue in
            feed?.filter = newValue
        }
        .onChange(of: model.historyProgressRevision) { _, _ in
            feed?.reload()
        }
        .onChange(of: model.syncState) { _, state in
            if state != .syncing { feed?.reload() }
        }
        .onChange(of: reviewTransactions.count) { _, _ in
            feed?.reload()
        }
    }

    private var reviewInboxEntryPoint: some View {
        let count = ReviewInboxItem.items(from: reviewTransactions.map { $0.rowValue() }).count
        return NavigationLink {
            ReviewInboxView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.full")
                    .font(.body.weight(.medium))
                    .foregroundStyle(CairnTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(CairnTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review inbox")
                        .font(.body.weight(.medium))
                    if count == 0 {
                        Text("All caught up")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("^[\(count) transaction](inflect: true) to review")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if count > 0 {
                    Text(count.formatted())
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(CairnTheme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(CairnTheme.accent.opacity(0.10), in: Capsule())
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reviewInboxEntry")
        .accessibilityHint(count == 0 ? "Review recently added transactions" : "Review \(count) transactions that need attention")
    }

    private var activityWidth: CGFloat {
        #if os(macOS)
        1_280
        #else
        920
        #endif
    }

    // MARK: - Filters

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(QuickFilter.allCases) { quick in
                        if filter.quick == quick.query {
                            quickFilterButton(quick)
                                .buttonStyle(.glassProminent)
                                .tint(CairnTheme.accent)
                        } else {
                            quickFilterButton(quick)
                                .buttonStyle(.glass(.regular))
                                .foregroundStyle(.primary)
                        }
                    }
                    if let categoryFilter {
                        activeFilterChip(
                            categoryFilter.name,
                            systemImage: categoryFilter.symbolName,
                            tint: CairnTheme.color(hex: categoryFilter.colorHex)
                        ) {
                            filter.categoryID = nil
                        }
                    }
                    if let accountFilter {
                        activeFilterChip(accountFilter.displayName, systemImage: "building.columns", tint: CairnTheme.accent) {
                            filter.accountID = nil
                        }
                    }
                    if let tagFilter {
                        activeFilterChip(
                            tagFilter.name,
                            systemImage: "tag.fill",
                            tint: CairnTheme.color(hex: tagFilter.colorHex)
                        ) {
                            filter.tagID = nil
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: filter.quick)
    }

    private func quickFilterButton(_ quick: QuickFilter) -> some View {
        Button {
            withAnimation(CairnTheme.Motion.quick) { filter.quick = quick.query }
        } label: {
            HStack(spacing: 5) {
                if let systemImage = quick.systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                Text(quick.title)
                    .font(.subheadline.weight(filter.quick == quick.query ? .semibold : .medium))
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
        }
        .accessibilityAddTraits(filter.quick == quick.query ? .isSelected : [])
    }

    private func activeFilterChip(_ title: String, systemImage: String, tint: Color, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption.weight(.semibold))
                Text(title).font(.subheadline.weight(.semibold))
                Image(systemName: "xmark").font(.caption2.weight(.bold)).opacity(0.7)
            }
            .foregroundStyle(tint)
            .frame(minHeight: 44)
        }
        .buttonStyle(.glass(.regular))
        .tint(tint)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private var categoryFilter: CairnSchemaV4.Category? {
        categories.first { $0.persistentModelID == filter.categoryID }
    }

    private var accountFilter: Account? {
        accounts.first { $0.persistentModelID == filter.accountID }
    }

    private var tagFilter: Tag? {
        tags.first { $0.persistentModelID == filter.tagID }
    }

    private var filtersMenu: some View {
        Menu {
            Picker("Category", selection: categorySelection) {
                Text("All Categories").tag(CairnSchemaV4.Category?.none)
                ForEach(categories.filter { !$0.isArchived }) { category in
                    Label(category.name, systemImage: category.symbolName).tag(CairnSchemaV4.Category?.some(category))
                }
            }
            .pickerStyle(.menu)
            Picker("Account", selection: accountSelection) {
                Text("All Accounts").tag(Account?.none)
                ForEach(accounts) { account in
                    Text(account.displayName).tag(Account?.some(account))
                }
            }
            .pickerStyle(.menu)
            if !tags.isEmpty {
                Picker("Tag", selection: tagSelection) {
                    Text("All Tags").tag(Tag?.none)
                    ForEach(tags) { tag in
                        Text(tag.name).tag(Tag?.some(tag))
                    }
                }
                .pickerStyle(.menu)
            }
            if filter.isActive {
                Divider()
                Button("Clear Filters", systemImage: "xmark.circle") { clearFilters() }
            }
        } label: {
            Label(
                "Filter",
                systemImage: categoryFilter != nil || accountFilter != nil
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
    }

    private var categorySelection: Binding<CairnSchemaV4.Category?> {
        Binding(
            get: { categoryFilter },
            set: { filter.categoryID = $0?.persistentModelID }
        )
    }

    private var accountSelection: Binding<Account?> {
        Binding(
            get: { accountFilter },
            set: { filter.accountID = $0?.persistentModelID }
        )
    }

    private var tagSelection: Binding<Tag?> {
        Binding(
            get: { tagFilter },
            set: { filter.tagID = $0?.persistentModelID }
        )
    }

    private func clearFilters() {
        withAnimation(CairnTheme.Motion.quick) {
            filter = TransactionFilter()
            searchText = ""
        }
    }

    private var emptyMessage: LocalizedStringKey {
        "Try a different search or clear the filters."
    }

    // MARK: - Empty states

    @ViewBuilder
    private func emptyState(_ feed: TransactionsFeed) -> some View {
        if feed.isStoreEmpty {
            GetStartedEmptyState(
                systemImage: "list.bullet.rectangle",
                title: "No activity yet",
                message: "Sync a bank, add a manual account, or import a CSV to see transactions here."
            )
        } else {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "Nothing matches",
                message: emptyMessage,
                actionTitle: filter.isActive ? "Clear filters" : nil
            ) {
                clearFilters()
            }
        }
    }
}
