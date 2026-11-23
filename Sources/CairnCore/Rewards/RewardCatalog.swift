import Foundation

// The card-rewards catalog: which cards exist and how each one earns.
//
// This is reference data bundled with the app, not the person's financial
// data, so it never touches SwiftData or CloudKit. Field names on the wire are
// snake_case to match `Rewards/Resources/rewards-catalog.json`.

public enum CardNetwork: String, Codable, Sendable, CaseIterable {
    case visa, mastercard, amex, discover

    public var displayName: String {
        switch self {
        case .visa: "Visa"
        case .mastercard: "Mastercard"
        case .amex: "American Express"
        case .discover: "Discover"
        }
    }
}

public enum RewardCurrencyKind: String, Codable, Sendable {
    case cash, points, miles
}

/// How far a card's rates have been checked against the issuer.
public enum RewardDataStatus: String, Codable, Sendable {
    /// Catalog fields only. No earning rates yet.
    case imported
    /// Rates entered from the issuer's page, waiting for a second person to check them.
    case needsReview = "needs-review"
    /// Rates checked by a second contributor.
    case verified
}

/// Where a fact came from and when someone last checked it.
public struct RewardSource: Codable, Sendable, Hashable {
    public var url: String
    /// ISO date, `YYYY-MM-DD`.
    public var verifiedAt: String
    public var verifiedBy: String

    public init(url: String, verifiedAt: String, verifiedBy: String) {
        self.url = url
        self.verifiedAt = verifiedAt
        self.verifiedBy = verifiedBy
    }

    enum CodingKeys: String, CodingKey {
        case url
        case verifiedAt = "verified_at"
        case verifiedBy = "verified_by"
    }
}

/// A spending category as card issuers define it. Separate from the person's
/// own transaction categories, which they name and organize themselves.
public struct RewardCategory: Codable, Sendable, Identifiable, Hashable {
    /// The root category every purchase falls back to.
    public static let baseID = "base"

    public var id: String
    public var name: String
    public var parent: String?
    /// Merchant Category Codes, single (`"5411"`) or ranges (`"3000-3350"`).
    public var mcc: [String]?
    /// MapKit `MKPointOfInterestCategory` raw values.
    public var mapkit: [String]?

    public init(id: String, name: String, parent: String? = nil, mcc: [String]? = nil, mapkit: [String]? = nil) {
        self.id = id
        self.name = name
        self.parent = parent
        self.mcc = mcc
        self.mapkit = mapkit
    }
}

public struct RewardCurrency: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var kind: RewardCurrencyKind
    /// Neutral default value of one point, in US cents. People set their own.
    public var centsPerPoint: Double

    public init(id: String, name: String, kind: RewardCurrencyKind, centsPerPoint: Double) {
        self.id = id
        self.name = name
        self.kind = kind
        self.centsPerPoint = centsPerPoint
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case centsPerPoint = "cents_per_point"
    }
}

public struct RewardIssuer: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Other names banks and statements use, such as "Amex".
    public var aliases: [String]?
    /// The issuer's card-linked offers program, such as Amex Offers.
    public var offerProgram: String?

    public init(id: String, name: String, aliases: [String]? = nil, offerProgram: String? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.offerProgram = offerProgram
    }

    enum CodingKeys: String, CodingKey {
        case id, name, aliases
        case offerProgram = "offer_program"
    }
}

public struct RewardMerchant: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var domains: [String]?
    public var aliases: [String]?
    public var categories: [String]
    /// Networks accepted in store, when the merchant limits them.
    public var inStoreNetworks: [CardNetwork]?
    /// Networks accepted online, when the merchant limits them.
    public var onlineNetworks: [CardNetwork]?

    public init(
        id: String,
        name: String,
        domains: [String]? = nil,
        aliases: [String]? = nil,
        categories: [String],
        inStoreNetworks: [CardNetwork]? = nil,
        onlineNetworks: [CardNetwork]? = nil
    ) {
        self.id = id
        self.name = name
        self.domains = domains
        self.aliases = aliases
        self.categories = categories
        self.inStoreNetworks = inStoreNetworks
        self.onlineNetworks = onlineNetworks
    }

    enum CodingKeys: String, CodingKey {
        case id, name, domains, aliases, categories
        case inStoreNetworks = "in_store_networks"
        case onlineNetworks = "online_networks"
    }
}

public enum RewardChannel: String, Codable, Sendable {
    case any
    case online
    case inStore = "in-store"
    /// Booked through the card issuer's own travel or shopping portal.
    case issuerPortal = "issuer-portal"
}

public enum RewardCapPeriod: String, Codable, Sendable {
    case month, quarter, year
}

public struct RewardCap: Codable, Sendable, Hashable {
    /// Spend, in whole US dollars, that earns the bonus rate each period.
    public var amount: Int
    public var period: RewardCapPeriod
    /// Multiplier once the cap is reached.
    public var after: Double

    public init(amount: Int, period: RewardCapPeriod, after: Double) {
        self.amount = amount
        self.period = period
        self.after = after
    }
}

/// One way a card earns: a multiplier on some categories or merchants,
/// optionally limited by channel, region, dates, activation, or a spend cap.
public struct RewardRule: Codable, Sendable, Hashable {
    public var id: String?
    public var categories: [String]?
    public var merchants: [String]?
    /// Points per dollar, or percent cash back.
    public var multiplier: Double
    public var channel: RewardChannel?
    /// Only purchases made in the United States qualify.
    public var domesticOnly: Bool?
    public var cap: RewardCap?
    /// First day the rule applies, `YYYY-MM-DD`.
    public var validFrom: String?
    /// Last day the rule applies, `YYYY-MM-DD`.
    public var validTo: String?
    public var requiresActivation: Bool?
    public var note: String?
    public var source: RewardSource?

    public init(
        id: String? = nil,
        categories: [String]? = nil,
        merchants: [String]? = nil,
        multiplier: Double,
        channel: RewardChannel? = nil,
        domesticOnly: Bool? = nil,
        cap: RewardCap? = nil,
        validFrom: String? = nil,
        validTo: String? = nil,
        requiresActivation: Bool? = nil,
        note: String? = nil,
        source: RewardSource? = nil
    ) {
        self.id = id
        self.categories = categories
        self.merchants = merchants
        self.multiplier = multiplier
        self.channel = channel
        self.domesticOnly = domesticOnly
        self.cap = cap
        self.validFrom = validFrom
        self.validTo = validTo
        self.requiresActivation = requiresActivation
        self.note = note
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, categories, merchants, multiplier, channel, cap, note, source
        case domesticOnly = "domestic_only"
        case validFrom = "valid_from"
        case validTo = "valid_to"
        case requiresActivation = "requires_activation"
    }

    /// True for the card's plain rate on everything: `base`, no conditions.
    public var isUnconditionalBase: Bool {
        (categories ?? []).contains(RewardCategory.baseID)
            && (channel ?? .any) == .any
            && domesticOnly != true
            && validFrom == nil && validTo == nil
            && requiresActivation != true
            && cap == nil
    }
}

public enum RewardCreditPeriod: String, Codable, Sendable {
    case month, quarter
    case halfYear = "half-year"
    case year
}

public enum RewardCreditReset: String, Codable, Sendable {
    case calendar
    case cardmemberYear = "cardmember-year"
}

/// A recurring statement credit or benefit.
public struct RewardCredit: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Whole US dollars.
    public var amount: Int
    public var period: RewardCreditPeriod
    public var resets: RewardCreditReset?
    public var merchants: [String]?
    public var enrollment: Bool?
    public var source: RewardSource?
}

public struct RewardCard: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Other names the product appears under in bank account lists.
    public var aliases: [String]?
    public var issuer: String
    public var network: CardNetwork
    public var currency: String
    /// Whole US dollars.
    public var annualFee: Int
    /// Percent of each foreign purchase. Nil when unknown.
    public var foreignTransactionFee: Double?
    public var url: String?
    public var status: RewardDataStatus
    /// Default source for rules that don't carry their own.
    public var ratesSource: RewardSource?
    /// Card-level fields not yet confirmed on the issuer's page, such as `annual_fee`.
    public var unverifiedFields: [String]?
    public var earn: [RewardRule]
    public var credits: [RewardCredit]?

    public init(
        id: String,
        name: String,
        aliases: [String]? = nil,
        issuer: String,
        network: CardNetwork,
        currency: String,
        annualFee: Int,
        foreignTransactionFee: Double? = nil,
        url: String? = nil,
        status: RewardDataStatus,
        ratesSource: RewardSource? = nil,
        unverifiedFields: [String]? = nil,
        earn: [RewardRule],
        credits: [RewardCredit]? = nil
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.issuer = issuer
        self.network = network
        self.currency = currency
        self.annualFee = annualFee
        self.foreignTransactionFee = foreignTransactionFee
        self.url = url
        self.status = status
        self.ratesSource = ratesSource
        self.unverifiedFields = unverifiedFields
        self.earn = earn
        self.credits = credits
    }

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, issuer, network, currency, url, status, earn, credits
        case annualFee = "annual_fee"
        case foreignTransactionFee = "foreign_transaction_fee"
        case ratesSource = "rates_source"
        case unverifiedFields = "unverified_fields"
    }

    /// Stable key for one of this card's rules, used for cap progress and activation.
    public func ruleKey(_ index: Int) -> String {
        "\(id):\(earn[index].id ?? String(index))"
    }
}

/// Everything the card-rewards feature knows, loaded from the app bundle.
public struct RewardCatalog: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var categories: [RewardCategory]
    public var currencies: [RewardCurrency]
    public var issuers: [RewardIssuer]
    public var merchants: [RewardMerchant]
    public var cards: [RewardCard]

    public init(
        schemaVersion: Int = RewardCatalog.currentSchemaVersion,
        categories: [RewardCategory],
        currencies: [RewardCurrency],
        issuers: [RewardIssuer],
        merchants: [RewardMerchant],
        cards: [RewardCard]
    ) {
        self.schemaVersion = schemaVersion
        self.categories = categories
        self.currencies = currencies
        self.issuers = issuers
        self.merchants = merchants
        self.cards = cards
    }

    enum CodingKeys: String, CodingKey {
        case categories, currencies, issuers, merchants, cards
        case schemaVersion = "schema_version"
    }

    public static func decode(_ data: Data) throws -> RewardCatalog {
        try JSONDecoder().decode(RewardCatalog.self, from: data)
    }

    /// The catalog that ships inside CairnCore.
    public static func bundled() throws -> RewardCatalog {
        guard let url = Bundle.module.url(forResource: "rewards-catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    public func card(_ id: String) -> RewardCard? { cards.first { $0.id == id } }
    public func issuer(_ id: String) -> RewardIssuer? { issuers.first { $0.id == id } }
    public func category(_ id: String) -> RewardCategory? { categories.first { $0.id == id } }
}
