import SwiftUI
import SwiftData
import CairnCore

/// The person's cards and point values for the card-rewards feature. They stay
/// on this device in user defaults: they are not ledger records, so they add no
/// SwiftData or CloudKit field.
enum CardRewardsStorage {
    static let walletKey = "cairn.rewards.cardIDs"
    static let pointValuesKey = "cairn.rewards.pointValues"

    static func cardIDs(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",").map(String.init).filter { seen.insert($0).inserted }
    }

    static func encode(cardIDs: [String]) -> String { cardIDs.joined(separator: ",") }

    /// `currency=cents` pairs, such as `amex-mr=1.5;chase-ur=1.25`.
    static func pointValues(_ raw: String) -> [String: Double] {
        var values: [String: Double] = [:]
        for pair in raw.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Double(parts[1]), value > 0 { values[String(parts[0])] = value }
        }
        return values
    }

    static func encode(pointValues: [String: Double]) -> String {
        pointValues.keys.sorted().compactMap { key in pointValues[key].map { "\(key)=\($0)" } }.joined(separator: ";")
    }
}

/// The bundled rewards catalog, loaded once.
enum CardRewardsCatalog {
    static let recommender: CardRecommender? = (try? RewardCatalog.bundled()).map(CardRecommender.init)
}

/// Ranks the person's cards for a store or category, entirely on-device.
struct CardRewardsView: View {
    @Query private var accounts: [Account]
    @AppStorage(CardRewardsStorage.walletKey) private var walletRaw = ""
    @AppStorage(CardRewardsStorage.pointValuesKey) private var pointValuesRaw = ""

    @State private var merchant = ""
    @State private var categoryID: String?
    @State private var channel = CardPurchaseChannel.inStore
    @State private var abroad = false
    @State private var showingPicker = false

    private let recommender = CardRewardsCatalog.recommender

    private var wallet: [String] { CardRewardsStorage.cardIDs(walletRaw) }
    private var pointValues: [String: Double] { CardRewardsStorage.pointValues(pointValuesRaw) }

    private var purchase: CardPurchase {
        let trimmed = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        return CardPurchase(merchant: trimmed.isEmpty ? nil : trimmed, category: categoryID,
                            channel: channel, abroad: abroad)
    }

    private var categories: [RewardCategory] {
        (recommender?.catalog.categories ?? [])
            .filter { $0.id != RewardCategory.baseID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Catalog cards found among the person's credit-card accounts and not yet added.
    private var suggestions: [RewardCard] {
        guard let recommender else { return [] }
        let hints = accounts
            .filter { $0.accountType == .credit && !$0.isHidden }
            .map { RewardAccountHint(name: $0.displayName, institution: $0.institution?.name) }
        let current = Set(wallet)
        return RewardCardSuggester(catalog: recommender.catalog).suggestions(for: hints)
            .filter { !current.contains($0) }
            .compactMap { recommender.catalog.card($0) }
    }

    var body: some View {
        List {
            if let recommender {
                purchaseSection
                if wallet.isEmpty {
                    emptyWalletSection
                } else {
                    resultsSection(recommender)
                }
                walletSection(recommender)
                pointValuesSection(recommender)
            } else {
                Section {
                    Text("The card catalog couldn’t be loaded.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Best card")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingPicker = true } label: {
                    Label("Edit Cards", systemImage: "creditcard")
                }
                .disabled(recommender == nil)
            }
        }
        .sheet(isPresented: $showingPicker) {
            if let recommender {
                CardPickerSheet(catalog: recommender.catalog, selection: Binding(
                    get: { wallet },
                    set: { walletRaw = CardRewardsStorage.encode(cardIDs: $0) }
                ))
                .cairnLockCover()
            }
        }
    }

    // MARK: - Purchase

    private var purchaseSection: some View {
        Section {
            TextField("Store or website", text: $merchant)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("cardRewardsMerchant")
            Picker("Category", selection: $categoryID) {
                Text("From the store").tag(String?.none)
                ForEach(categories) { category in
                    Text(verbatim: category.name).tag(Optional(category.id))
                }
            }
            Picker("Where", selection: $channel) {
                Text("In store").tag(CardPurchaseChannel.inStore)
                Text("Online").tag(CardPurchaseChannel.online)
            }
            .pickerStyle(.segmented)
            Toggle("Outside the U.S.", isOn: $abroad)
        } header: {
            Text("Purchase")
        }
    }

    // MARK: - Results

    private var emptyWalletSection: some View {
        Section {
            EmptyStateView(
                systemImage: "creditcard",
                title: "Add your cards",
                message: "Choose the cards you carry, and Cairn shows which one earns the most for each purchase.",
                actionTitle: "Choose Cards"
            ) {
                showingPicker = true
            }
            .listRowBackground(Color.clear)
        }
    }

    private func resultsSection(_ recommender: CardRecommender) -> some View {
        let resolution = recommender.resolve(purchase)
        let ranked = recommender.rank(purchase, wallet: wallet,
                                      preferences: CardRewardPreferences(valuations: pointValues))
        return Section {
            ForEach(Array(ranked.enumerated()), id: \.element.id) { index, recommendation in
                CardRecommendationRow(recommendation: recommendation, isBest: index == 0 && recommendation.isUsable)
            }
        } header: {
            Text("Best card")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                matchSummary(resolution, recommender: recommender)
                if ranked.contains(where: { $0.card.status == .needsReview }) {
                    // Keep this localized sentence as one catalog key.
                    // swiftlint:disable:next line_length
                    Text("Rates were read from each issuer’s site and haven’t been double-checked yet. Confirm current terms with the issuer.")
                }
            }
        }
    }

    private func matchSummary(_ resolution: CardPurchaseResolution, recommender: CardRecommender) -> Text {
        let names = resolution.categories.compactMap { recommender.catalog.category($0)?.name }
        let categoryText = names.joined(separator: ", ")
        if let merchant = resolution.merchant {
            return Text("Matched \(merchant.name) · \(categoryText)")
        }
        if resolution.categories == [RewardCategory.baseID] {
            return Text("No store or category matched, so each card’s everyday rate is shown.")
        }
        return Text("Category: \(categoryText)")
    }

    // MARK: - Wallet

    private func walletSection(_ recommender: CardRecommender) -> some View {
        Section {
            ForEach(suggestions) { card in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: card.name)
                        Text("Found in your accounts").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Add") { walletRaw = CardRewardsStorage.encode(cardIDs: wallet + [card.id]) }
                        .buttonStyle(.borderless)
                }
            }
            ForEach(wallet.compactMap { recommender.catalog.card($0) }) { card in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: card.name)
                    Text(verbatim: recommender.catalog.issuer(card.issuer)?.name ?? card.issuer)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                var ids = wallet.filter { recommender.catalog.card($0) != nil }
                ids.remove(atOffsets: offsets)
                walletRaw = CardRewardsStorage.encode(cardIDs: ids)
            }
            Button("Choose Cards…") { showingPicker = true }
        } header: {
            Text("Your cards")
        } footer: {
            Text("Your card choices stay on this device. Cairn never asks for card numbers.")
        }
    }

    // MARK: - Point values

    @ViewBuilder
    private func pointValuesSection(_ recommender: CardRecommender) -> some View {
        let currencies = Set(wallet.compactMap { recommender.catalog.card($0)?.currency })
        let points = recommender.catalog.currencies.filter { currencies.contains($0.id) && $0.kind != .cash }
        if !points.isEmpty {
            Section {
                ForEach(points) { currency in
                    let value = pointValues[currency.id] ?? currency.centsPerPoint
                    Stepper(value: Binding(
                        get: { value },
                        set: { newValue in
                            var values = pointValues
                            values[currency.id] = (newValue * 10).rounded() / 10
                            pointValuesRaw = CardRewardsStorage.encode(pointValues: values)
                        }
                    ), in: 0.1...5, step: 0.1) {
                        LabeledContent {
                            Text("\(value, format: .number.precision(.fractionLength(1)))¢")
                                .monospacedDigit()
                        } label: {
                            Text(verbatim: currency.name)
                        }
                    }
                }
            } header: {
                Text("Point values")
            } footer: {
                Text("What one point is worth to you, in cents. Every program starts at 1¢.")
            }
        }
    }
}

private struct CardRecommendationRow: View {
    let recommendation: CardRecommendation
    let isBest: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: recommendation.card.name)
                        .font(.body.weight(isBest ? .semibold : .regular))
                    if isBest {
                        Text("Best")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(CairnTheme.accent)
                            .background(CairnTheme.accent.opacity(0.14), in: Capsule())
                    }
                }
                earningText.font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(recommendation.notes.enumerated()), id: \.offset) { _, note in
                    if let text = note.text {
                        text.font(.caption).foregroundStyle(note.isWarning ? .orange : .secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if let cents = recommendation.centsPerDollar, recommendation.accepted {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(cents, format: .number.precision(.fractionLength(1)))¢")
                        .font(.title3.weight(isBest ? .semibold : .regular).monospacedDigit())
                    Text("per $1").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var earningText: Text {
        guard let multiplier = recommendation.multiplier else {
            return Text("Earning rates not added yet")
        }
        let rate = multiplier.formatted(.number.precision(.fractionLength(0...2)))
        let earning = recommendation.isCash
            ? Text("\(rate)% cash back")
            : Text("\(rate)× \(recommendation.currencyName)")
        guard let scope = recommendation.matchedScope else {
            return Text("\(earning) on everything else")
        }
        return recommendation.matchedByMerchant
            ? Text("\(earning) at \(scope)")
            : Text("\(earning) · \(scope)")
    }
}

extension CardRecommendation {
    /// Has a value to compare: rates exist and the merchant takes the card.
    var isUsable: Bool { accepted && centsPerDollar != nil }
}

extension CardRecommendationNote {
    var isWarning: Bool {
        switch self {
        case .notAccepted, .foreignTransactionFee, .foreignTransactionFeeUnknown, .capReached: true
        case .needsReview, .activationAvailable: false
        }
    }

    /// Nil for notes shown once for the whole list instead of per card.
    var text: Text? {
        switch self {
        case .needsReview:
            return nil
        case let .notAccepted(merchant, network, inStore):
            return inStore
                ? Text("\(merchant) doesn’t take \(network.displayName) in store")
                : Text("\(merchant) doesn’t take \(network.displayName) online")
        case let .foreignTransactionFee(percent):
            let fee = percent.formatted(.number.precision(.fractionLength(0...2)))
            return Text("Includes a \(fee)% foreign transaction fee")
        case .foreignTransactionFeeUnknown:
            return Text("Foreign transaction fee unknown")
        case let .capReached(amount, period):
            let limit = amount.formatted(.currency(code: "USD").precision(.fractionLength(0)))
            switch period {
            case .month: return Text("Bonus cap of \(limit) a month reached")
            case .quarter: return Text("Bonus cap of \(limit) a quarter reached")
            case .year: return Text("Bonus cap of \(limit) a year reached")
            }
        case let .activationAvailable(multiplier):
            let rate = multiplier.formatted(.number.precision(.fractionLength(0...2)))
            return Text("Activate the \(rate)× bonus to earn more here")
        }
    }
}
