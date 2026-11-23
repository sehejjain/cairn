import Foundation

public enum CardPurchaseChannel: String, Codable, Sendable, CaseIterable {
    case inStore = "in-store"
    case online
}

/// What the person is about to buy. Any field may be missing; the recommender
/// resolves what it can and falls back to each card's base rate.
public struct CardPurchase: Codable, Sendable, Hashable {
    /// A store name, website or URL, as typed or seen on a statement.
    public var merchant: String?
    /// An explicit reward category id, when the person picked one.
    public var category: String?
    /// A MapKit `MKPointOfInterestCategory` raw value for the place they're at.
    public var mapkitCategory: String?
    public var channel: CardPurchaseChannel
    /// Set when booking through an issuer's own portal (for example `chase` for Chase Travel).
    public var portalIssuer: String?
    public var abroad: Bool
    /// `YYYY-MM-DD`. Defaults to today.
    public var date: String?

    public init(
        merchant: String? = nil,
        category: String? = nil,
        mapkitCategory: String? = nil,
        channel: CardPurchaseChannel = .inStore,
        portalIssuer: String? = nil,
        abroad: Bool = false,
        date: String? = nil
    ) {
        self.merchant = merchant
        self.category = category
        self.mapkitCategory = mapkitCategory
        self.channel = channel
        self.portalIssuer = portalIssuer
        self.abroad = abroad
        self.date = date
    }

    enum CodingKeys: String, CodingKey {
        case merchant, category, channel, abroad, date
        case mapkitCategory = "mapkit_category"
        case portalIssuer = "portal_issuer"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        merchant = try container.decodeIfPresent(String.self, forKey: .merchant)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        mapkitCategory = try container.decodeIfPresent(String.self, forKey: .mapkitCategory)
        channel = try container.decodeIfPresent(CardPurchaseChannel.self, forKey: .channel) ?? .inStore
        portalIssuer = try container.decodeIfPresent(String.self, forKey: .portalIssuer)
        abroad = try container.decodeIfPresent(Bool.self, forKey: .abroad) ?? false
        date = try container.decodeIfPresent(String.self, forKey: .date)
    }

    /// Portal bookings are always online.
    var effectiveChannel: CardPurchaseChannel { portalIssuer != nil ? .online : channel }
}

/// The person's own settings that change the math.
public struct CardRewardPreferences: Sendable, Hashable {
    /// Reward currency id → the person's value of one point, in US cents.
    public var valuations: [String: Double]
    /// Rule key (`card-id:rule-id`) → spend toward its cap this period, in US cents.
    public var capSpendMinorUnits: [String: Int64]
    /// Rule keys the person has activated (rotating categories).
    public var activated: Set<String>

    public init(
        valuations: [String: Double] = [:],
        capSpendMinorUnits: [String: Int64] = [:],
        activated: Set<String> = []
    ) {
        self.valuations = valuations
        self.capSpendMinorUnits = capSpendMinorUnits
        self.activated = activated
    }
}

public enum CardMatchConfidence: String, Sendable {
    case high, medium, low
}

/// What the recommender understood the purchase to be.
public struct CardPurchaseResolution: Sendable {
    public var merchant: RewardMerchant?
    public var categories: [String]
    public var confidence: CardMatchConfidence
}

/// Something worth telling the person about a card's result.
public enum CardRecommendationNote: Sendable, Hashable {
    case needsReview
    case notAccepted(merchant: String, network: CardNetwork, inStore: Bool)
    case foreignTransactionFee(percent: Double)
    case foreignTransactionFeeUnknown
    case capReached(amount: Int, period: RewardCapPeriod)
    case activationAvailable(multiplier: Double)
}

public struct CardRecommendation: Sendable, Identifiable {
    public var id: String { card.id }
    public var card: RewardCard
    public var rule: RewardRule?
    public var ruleKey: String?
    public var multiplier: Double?
    /// Value earned per dollar, in US cents, after the person's point value and
    /// any foreign transaction fee. Nil when the card has no usable rates.
    public var centsPerDollar: Double?
    /// The reward currency's display name, such as "Membership Rewards".
    public var currencyName: String
    public var isCash: Bool
    /// What the matched rule covered: a merchant name, a category name, or nil for everything else.
    public var matchedScope: String?
    public var matchedByMerchant: Bool
    /// False when the merchant doesn't take this card's network.
    public var accepted: Bool
    public var notes: [CardRecommendationNote]
}

/// Ranks a person's cards for one purchase. Pure, synchronous, and on-device.
public struct CardRecommender: Sendable {
    public let catalog: RewardCatalog
    private let categoriesByID: [String: RewardCategory]
    private let currenciesByID: [String: RewardCurrency]
    private let cardsByID: [String: RewardCard]
    private let merchantsByDomain: [String: RewardMerchant]
    private let merchantsByName: [String: RewardMerchant]
    private let categoryByMapKit: [String: String]

    public init(catalog: RewardCatalog) {
        self.catalog = catalog
        categoriesByID = Dictionary(catalog.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        currenciesByID = Dictionary(catalog.currencies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cardsByID = Dictionary(catalog.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var byDomain: [String: RewardMerchant] = [:]
        var byName: [String: RewardMerchant] = [:]
        for merchant in catalog.merchants {
            for domain in merchant.domains ?? [] where byDomain[domain.lowercased()] == nil {
                byDomain[domain.lowercased()] = merchant
            }
            for name in [merchant.name] + (merchant.aliases ?? []) {
                let key = Self.normalize(name)
                if !key.isEmpty, byName[key] == nil { byName[key] = merchant }
            }
        }
        merchantsByDomain = byDomain
        merchantsByName = byName

        var byMapKit: [String: String] = [:]
        for category in catalog.categories {
            for raw in category.mapkit ?? [] where byMapKit[raw] == nil { byMapKit[raw] = category.id }
        }
        categoryByMapKit = byMapKit
    }

    // MARK: - Resolving the purchase

    public func resolve(_ purchase: CardPurchase) -> CardPurchaseResolution {
        var merchant: RewardMerchant?
        var confidence = CardMatchConfidence.low
        if let query = purchase.merchant?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            if let host = Self.host(from: query), let match = merchantMatching(host: host) {
                merchant = match
                confidence = .high
            } else if let match = merchantsByName[Self.normalize(query)] {
                merchant = match
                confidence = .high
            } else if let match = merchantByPrefix(of: query) {
                merchant = match
                confidence = .medium
            }
        }

        if let explicit = purchase.category, categoriesByID[explicit] != nil {
            return CardPurchaseResolution(merchant: merchant, categories: [explicit], confidence: .high)
        }
        if let merchant {
            return CardPurchaseResolution(merchant: merchant, categories: merchant.categories, confidence: confidence)
        }
        if let raw = purchase.mapkitCategory, let category = categoryByMapKit[raw] {
            return CardPurchaseResolution(merchant: nil, categories: [category], confidence: .medium)
        }
        return CardPurchaseResolution(merchant: nil, categories: [RewardCategory.baseID], confidence: .low)
    }

    /// The host of a URL or bare domain, without `www.`; nil for plain names.
    static func host(from query: String) -> String? {
        let lower = query.lowercased()
        var candidate: String
        if lower.contains("://") {
            guard let host = URL(string: lower)?.host else { return nil }
            candidate = host
        } else {
            guard !lower.contains(" "), lower.contains(".") else { return nil }
            candidate = String(lower.split(separator: "/").first ?? "")
        }
        if candidate.hasPrefix("www.") { candidate.removeFirst(4) }
        return candidate.isEmpty ? nil : candidate
    }

    /// Exact domain match, then each parent domain (`shop.example.com` → `example.com`).
    private func merchantMatching(host: String) -> RewardMerchant? {
        var current = host
        while current.contains(".") {
            if let match = merchantsByDomain[current] { return match }
            guard let dot = current.firstIndex(of: ".") else { break }
            current = String(current[current.index(after: dot)...])
        }
        return nil
    }

    /// Statement-style names such as "STARBUCKS #1234 SEATTLE": the longest
    /// known name the query starts with.
    private func merchantByPrefix(of query: String) -> RewardMerchant? {
        let normalized = Self.normalize(query)
        let matches = merchantsByName.filter { normalized.hasPrefix($0.key + " ") }
        let best = matches.max { lhs, rhs in
            lhs.key.count != rhs.key.count ? lhs.key.count < rhs.key.count : lhs.key > rhs.key
        }
        return best?.value
    }

    /// Lowercase, accents folded, apostrophes dropped, other punctuation as spaces.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var out = ""
        var pendingSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(character)
            } else if character == "'" || character == "\u{2019}" {
                continue
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// The category and its ancestors, nearest first, excluding `base`.
    func lineage(of id: String) -> [String] {
        var out: [String] = []
        var current: String? = id
        while let category = current, category != RewardCategory.baseID, out.count < 32, !out.contains(category) {
            out.append(category)
            current = categoriesByID[category]?.parent
        }
        return out
    }

    // MARK: - Ranking

    /// Every card in `wallet`, best first. Cards the merchant won't take sort last.
    public func rank(
        _ purchase: CardPurchase,
        wallet: [String],
        preferences: CardRewardPreferences = CardRewardPreferences(),
        today: String? = nil
    ) -> [CardRecommendation] {
        let resolution = resolve(purchase)
        let date = purchase.date ?? today ?? Self.isoToday()
        var distance: [String: Int] = [:]
        for category in resolution.categories {
            for (depth, ancestor) in lineage(of: category).enumerated() {
                distance[ancestor] = min(distance[ancestor] ?? .max, depth)
            }
        }
        let context = Context(purchase: purchase, resolution: resolution, distance: distance,
                              preferences: preferences, date: date)
        return wallet
            .compactMap { cardsByID[$0] }
            .map { evaluate($0, context) }
            .sorted(by: Self.isRankedBefore)
    }

    static func isRankedBefore(_ lhs: CardRecommendation, _ rhs: CardRecommendation) -> Bool {
        if lhs.accepted != rhs.accepted { return lhs.accepted }
        switch (lhs.centsPerDollar, rhs.centsPerDollar) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.card.name.localizedStandardCompare(rhs.card.name) == .orderedAscending
        }
    }

    private struct Context {
        var purchase: CardPurchase
        var resolution: CardPurchaseResolution
        var distance: [String: Int]
        var preferences: CardRewardPreferences
        var date: String
    }

    private struct Candidate {
        var index: Int
        var specificity: Int
        var multiplier: Double
        var category: String?
        var capped: Bool
    }

    private func evaluate(_ card: RewardCard, _ context: Context) -> CardRecommendation {
        var notes: [CardRecommendationNote] = []
        let accepted = isAccepted(card, context.purchase, context.resolution.merchant, notes: &notes)
        if card.status == .needsReview { notes.append(.needsReview) }
        let currency = currenciesByID[card.currency]
        var recommendation = CardRecommendation(
            card: card, rule: nil, ruleKey: nil, multiplier: nil, centsPerDollar: nil,
            currencyName: currency?.name ?? card.currency, isCash: currency?.kind == .cash,
            matchedScope: nil, matchedByMerchant: false, accepted: accepted, notes: notes
        )

        var best: Candidate?
        var hints: [CardRecommendationNote] = []
        for (index, rule) in card.earn.enumerated() {
            guard let candidate = candidate(for: rule, at: index, of: card, context, hints: &hints) else { continue }
            if let current = best,
               (candidate.specificity, candidate.multiplier) <= (current.specificity, current.multiplier) {
                continue
            }
            best = candidate
        }
        guard let best else {
            recommendation.notes += hints
            return recommendation
        }

        let rule = card.earn[best.index]
        let centsPerPoint = context.preferences.valuations[card.currency] ?? currency?.centsPerPoint ?? 1.0
        var cents = best.multiplier * centsPerPoint
        if context.purchase.abroad {
            if let fee = card.foreignTransactionFee {
                cents -= fee
                if fee > 0 { recommendation.notes.append(.foreignTransactionFee(percent: fee)) }
            } else {
                recommendation.notes.append(.foreignTransactionFeeUnknown)
            }
        }
        if best.capped, let cap = rule.cap {
            recommendation.notes.append(.capReached(amount: cap.amount, period: cap.period))
        }
        recommendation.notes += hints

        recommendation.rule = rule
        recommendation.ruleKey = card.ruleKey(best.index)
        recommendation.multiplier = best.multiplier
        recommendation.centsPerDollar = cents
        if best.specificity == Self.merchantSpecificity, let merchant = context.resolution.merchant {
            recommendation.matchedScope = merchant.name
            recommendation.matchedByMerchant = true
        } else if let id = best.category {
            recommendation.matchedScope = categoriesByID[id]?.name
        }
        return recommendation
    }

    private static let merchantSpecificity = 1000

    /// The rule's specificity and effective multiplier for this purchase, or nil
    /// when it doesn't apply. Specificity: merchant > nearest category > ancestor > base.
    private func candidate(
        for rule: RewardRule,
        at index: Int,
        of card: RewardCard,
        _ context: Context,
        hints: inout [CardRecommendationNote]
    ) -> Candidate? {
        var specificity: Int?
        var matchedCategory: String?
        if let merchant = context.resolution.merchant, rule.merchants?.contains(merchant.id) == true {
            specificity = Self.merchantSpecificity
        }
        for category in rule.categories ?? [] {
            if category == RewardCategory.baseID {
                specificity = max(specificity ?? 0, 0)
            } else if let depth = context.distance[category], 100 - depth > (specificity ?? -1) {
                specificity = 100 - depth
                matchedCategory = category
            }
        }
        guard let specificity else { return nil }

        if let from = rule.validFrom, context.date < from { return nil }
        if let end = rule.validTo, context.date > end { return nil }
        guard Self.channel(rule.channel ?? .any, matches: context.purchase, card: card) else { return nil }
        if rule.domesticOnly == true && context.purchase.abroad { return nil }

        let key = card.ruleKey(index)
        if rule.requiresActivation == true && !context.preferences.activated.contains(key) {
            hints.append(.activationAvailable(multiplier: rule.multiplier))
            return nil
        }

        var multiplier = rule.multiplier
        var capped = false
        if let cap = rule.cap, let spent = context.preferences.capSpendMinorUnits[key],
           spent >= Int64(cap.amount) * 100 {
            multiplier = cap.after
            capped = true
        }
        return Candidate(index: index, specificity: specificity, multiplier: multiplier,
                         category: matchedCategory, capped: capped)
    }

    private func isAccepted(
        _ card: RewardCard,
        _ purchase: CardPurchase,
        _ merchant: RewardMerchant?,
        notes: inout [CardRecommendationNote]
    ) -> Bool {
        guard let merchant else { return true }
        let inStore = purchase.effectiveChannel == .inStore
        guard let allowed = inStore ? merchant.inStoreNetworks : merchant.onlineNetworks,
              !allowed.contains(card.network) else { return true }
        notes.append(.notAccepted(merchant: merchant.name, network: card.network, inStore: inStore))
        return false
    }

    static func channel(_ channel: RewardChannel, matches purchase: CardPurchase, card: RewardCard) -> Bool {
        switch channel {
        case .any: true
        case .online: purchase.effectiveChannel == .online
        case .inStore: purchase.effectiveChannel == .inStore
        case .issuerPortal: purchase.portalIssuer == card.issuer
        }
    }

    static func isoToday() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
