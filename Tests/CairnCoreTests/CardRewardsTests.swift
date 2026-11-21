import Foundation
import Testing
@testable import CairnCore

/// A small made-up world: two banks, three cards, a few merchants.
private enum RewardsFixture {
    static let source = RewardSource(url: "https://example.com/card", verifiedAt: "2026-11-01", verifiedBy: "test")

    static func card(
        _ id: String,
        issuer: String,
        network: CardNetwork,
        currency: String,
        fxFee: Double? = 0,
        status: RewardDataStatus = .verified,
        earn: [RewardRule]
    ) -> RewardCard {
        RewardCard(id: id, name: id, issuer: issuer, network: network, currency: currency, annualFee: 0,
                   foreignTransactionFee: fxFee, status: status, ratesSource: source, earn: earn)
    }

    static func catalog() -> RewardCatalog {
        RewardCatalog(
            categories: [
                RewardCategory(id: "base", name: "Everything else"),
                RewardCategory(id: "dining", name: "Restaurants and dining", mapkit: ["MKPOICategoryRestaurant"]),
                RewardCategory(id: "groceries", name: "Grocery stores"),
                RewardCategory(id: "supermarkets", name: "Supermarkets", parent: "groceries",
                               mapkit: ["MKPOICategoryFoodMarket"]),
                RewardCategory(id: "superstores", name: "Superstores"),
                RewardCategory(id: "travel", name: "Travel"),
                RewardCategory(id: "hotels", name: "Hotels", parent: "travel"),
            ],
            currencies: [
                RewardCurrency(id: "cash", name: "Cash back", kind: .cash, centsPerPoint: 1),
                RewardCurrency(id: "pts", name: "Test Points", kind: .points, centsPerPoint: 1),
            ],
            issuers: [
                RewardIssuer(id: "bank-a", name: "Bank A"),
                RewardIssuer(id: "bank-b", name: "Bank B"),
            ],
            merchants: [
                RewardMerchant(id: "club", name: "Club Warehouse", domains: ["clubwarehouse.com"],
                               categories: ["base"], inStoreNetworks: [.visa]),
                RewardMerchant(id: "joes", name: "Joe's Café", domains: ["joes.example"], aliases: ["Joes Coffee"],
                               categories: ["dining"]),
                RewardMerchant(id: "megamart", name: "MegaMart", domains: ["megamart.com"], categories: ["superstores"]),
            ],
            cards: [
                card("a-travel", issuer: "bank-a", network: .amex, currency: "pts", earn: [
                    RewardRule(id: "portal", categories: ["travel"], multiplier: 10, channel: .issuerPortal),
                    RewardRule(id: "travel", categories: ["travel"], multiplier: 5),
                    RewardRule(id: "hotels", categories: ["hotels"], multiplier: 2),
                    RewardRule(id: "grocery", categories: ["supermarkets"], multiplier: 4, domesticOnly: true,
                               cap: RewardCap(amount: 1000, period: .year, after: 1)),
                    RewardRule(id: "base", categories: ["base"], multiplier: 1),
                ]),
                card("b-cash", issuer: "bank-b", network: .visa, currency: "cash", fxFee: nil, earn: [
                    RewardRule(id: "dining", categories: ["dining"], multiplier: 3),
                    RewardRule(id: "groceries", categories: ["groceries"], multiplier: 3),
                    RewardRule(id: "joes", merchants: ["joes"], multiplier: 6),
                    RewardRule(id: "q4", categories: ["superstores"], multiplier: 5, validFrom: "2026-10-01",
                               validTo: "2026-12-31", requiresActivation: true),
                    RewardRule(id: "base", categories: ["base"], multiplier: 1.5),
                ]),
                card("c-imported", issuer: "bank-b", network: .mastercard, currency: "cash",
                     status: .imported, earn: []),
            ]
        )
    }

    static let recommender = CardRecommender(catalog: catalog())
    static let today = "2026-11-21"

    static func top(
        _ purchase: CardPurchase,
        _ wallet: [String],
        _ preferences: CardRewardPreferences = CardRewardPreferences()
    ) -> CardRecommendation? {
        recommender.rank(purchase, wallet: wallet, preferences: preferences, today: today).first
    }
}

@Suite("Card rewards: resolving the purchase")
struct CardPurchaseResolutionTests {
    let recommender = RewardsFixture.recommender

    @Test func matchesMerchantByURLAndSubdomain() {
        let resolution = recommender.resolve(CardPurchase(merchant: "https://shop.megamart.com/cart?id=1"))
        #expect(resolution.merchant?.id == "megamart")
        #expect(resolution.confidence == .high)
    }

    @Test func matchesBareDomain() {
        #expect(recommender.resolve(CardPurchase(merchant: "www.ClubWarehouse.com")).merchant?.id == "club")
    }

    @Test func matchesNamesIgnoringCaseAccentsAndApostrophes() {
        #expect(recommender.resolve(CardPurchase(merchant: "JOE'S CAFE")).merchant?.id == "joes")
        #expect(recommender.resolve(CardPurchase(merchant: "joes coffee")).merchant?.id == "joes")
    }

    @Test func matchesStatementStyleNamesWithMediumConfidence() {
        let resolution = recommender.resolve(CardPurchase(merchant: "MEGAMART #0042 PORTLAND OR"))
        #expect(resolution.merchant?.id == "megamart")
        #expect(resolution.confidence == .medium)
    }

    @Test func usesMapKitCategoryWhenNoMerchant() {
        let resolution = recommender.resolve(CardPurchase(mapkitCategory: "MKPOICategoryFoodMarket"))
        #expect(resolution.categories == ["supermarkets"])
        #expect(resolution.confidence == .medium)
    }

    @Test func explicitCategoryWinsButKeepsMerchant() {
        let resolution = recommender.resolve(CardPurchase(merchant: "megamart.com", category: "dining"))
        #expect(resolution.categories == ["dining"])
        #expect(resolution.merchant?.id == "megamart")
    }

    @Test func unknownMerchantFallsBackToBase() {
        let resolution = recommender.resolve(CardPurchase(merchant: "Somewhere Unknown"))
        #expect(resolution.merchant == nil)
        #expect(resolution.categories == ["base"])
        #expect(resolution.confidence == .low)
    }
}

@Suite("Card rewards: choosing each card's rule")
struct CardRuleSelectionTests {
    @Test func childCategoryRuleBeatsParentRule() {
        // 2x on hotels is more specific than 5x on travel, so it applies.
        #expect(RewardsFixture.top(CardPurchase(category: "hotels"), ["a-travel"])?.multiplier == 2)
        #expect(RewardsFixture.top(CardPurchase(category: "travel"), ["a-travel"])?.multiplier == 5)
    }

    @Test func parentRuleCoversChildCategory() {
        let rec = RewardsFixture.top(CardPurchase(category: "supermarkets"), ["b-cash"])
        #expect(rec?.multiplier == 3)
        #expect(rec?.matchedScope == "Grocery stores")
    }

    @Test func merchantRuleBeatsCategoryRule() {
        let rec = RewardsFixture.top(CardPurchase(merchant: "joes.example"), ["b-cash"])
        #expect(rec?.multiplier == 6)
        #expect(rec?.matchedByMerchant == true)
        #expect(rec?.matchedScope == "Joe's Café")
        #expect(rec?.isCash == true)
    }

    @Test func issuerPortalRuleNeedsThatIssuersPortal() {
        #expect(RewardsFixture.top(CardPurchase(category: "travel", portalIssuer: "bank-a"), ["a-travel"])?.multiplier == 10)
        #expect(RewardsFixture.top(CardPurchase(category: "travel", portalIssuer: "bank-b"), ["a-travel"])?.multiplier == 5)
    }

    @Test func domesticOnlyRuleIsSkippedAbroad() {
        let ranked = RewardsFixture.recommender.rank(
            CardPurchase(category: "supermarkets", abroad: true), wallet: ["a-travel", "b-cash"],
            today: RewardsFixture.today
        )
        let travel = ranked.first { $0.card.id == "a-travel" }
        let cash = ranked.first { $0.card.id == "b-cash" }
        #expect(travel?.multiplier == 1)
        #expect(cash?.multiplier == 3)
        #expect(cash?.notes.contains(.foreignTransactionFeeUnknown) == true)
    }

    @Test func reachedCapFallsBackToAfterRate() {
        let preferences = CardRewardPreferences(capSpendMinorUnits: ["a-travel:grocery": 100_000])
        let rec = RewardsFixture.top(CardPurchase(category: "supermarkets"), ["a-travel"], preferences)
        #expect(rec?.multiplier == 1)
        #expect(rec?.notes.contains(.capReached(amount: 1000, period: .year)) == true)

        let underCap = CardRewardPreferences(capSpendMinorUnits: ["a-travel:grocery": 99_999])
        #expect(RewardsFixture.top(CardPurchase(category: "supermarkets"), ["a-travel"], underCap)?.multiplier == 4)
    }

    @Test func rotatingBonusNeedsActivationAndDates() {
        let notActivated = RewardsFixture.top(CardPurchase(merchant: "MegaMart", date: "2026-11-15"), ["b-cash"])
        #expect(notActivated?.multiplier == 1.5)
        #expect(notActivated?.notes.contains(.activationAvailable(multiplier: 5)) == true)

        let activated = CardRewardPreferences(activated: ["b-cash:q4"])
        let during = RewardsFixture.top(CardPurchase(merchant: "MegaMart", date: "2026-11-15"), ["b-cash"], activated)
        let after = RewardsFixture.top(CardPurchase(merchant: "MegaMart", date: "2027-01-05"), ["b-cash"], activated)
        #expect(during?.multiplier == 5)
        #expect(after?.multiplier == 1.5)
    }
}

@Suite("Card rewards: ranking the wallet")
struct CardRankingTests {
    let recommender = RewardsFixture.recommender
    let today = RewardsFixture.today

    @Test func cardsTheMerchantRefusesSortLast() {
        let inStore = recommender.rank(CardPurchase(merchant: "Club Warehouse"), wallet: ["a-travel", "b-cash"],
                                       today: today)
        #expect(inStore.map(\.card.id) == ["b-cash", "a-travel"])
        #expect(inStore.last?.accepted == false)
        #expect(inStore.last?.notes.contains(.notAccepted(merchant: "Club Warehouse", network: .amex, inStore: true)) == true)

        let online = recommender.rank(CardPurchase(merchant: "Club Warehouse", channel: .online),
                                      wallet: ["a-travel", "b-cash"], today: today)
        #expect(online.allSatisfy { $0.accepted })
    }

    @Test func personalPointValuesChangeTheWinner() {
        let dining = CardPurchase(category: "dining")
        #expect(recommender.rank(dining, wallet: ["a-travel", "b-cash"], today: today).first?.card.id == "b-cash")
        let ranked = recommender.rank(dining, wallet: ["a-travel", "b-cash"],
                                      preferences: CardRewardPreferences(valuations: ["pts": 4.0]), today: today)
        #expect(ranked.first?.card.id == "a-travel")
        #expect(ranked.first?.centsPerDollar == 4.0)
    }

    @Test func foreignTransactionFeeIsSubtracted() {
        var catalog = RewardsFixture.catalog()
        catalog.cards[1].foreignTransactionFee = 3
        let rec = CardRecommender(catalog: catalog)
            .rank(CardPurchase(category: "dining", abroad: true), wallet: ["b-cash"], today: today).first
        #expect(rec?.centsPerDollar == 0)
        #expect(rec?.notes.contains(.foreignTransactionFee(percent: 3)) == true)
    }

    @Test func cardsWithoutRatesSortLastWithNoValue() {
        let ranked = recommender.rank(CardPurchase(category: "dining"), wallet: ["c-imported", "a-travel"], today: today)
        #expect(ranked.map(\.card.id) == ["a-travel", "c-imported"])
        #expect(ranked.last?.centsPerDollar == nil)
    }

    @Test func unknownWalletIDsAreIgnored() {
        #expect(recommender.rank(CardPurchase(), wallet: ["nope", "a-travel"], today: today).map(\.card.id) == ["a-travel"])
    }
}

@Suite("Card rewards: catalog validation")
struct RewardCatalogValidationTests {
    @Test func fixtureIsValid() {
        let errors = RewardCatalogValidator.validate(RewardsFixture.catalog(), today: RewardsFixture.today)
            .filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test func catchesBrokenReferencesAndMissingBaseRule() {
        var catalog = RewardsFixture.catalog()
        catalog.cards.append(catalog.cards[0])
        catalog.cards[1].earn.append(RewardRule(categories: ["not-a-category"], multiplier: 2))
        catalog.cards[1].earn.removeAll { $0.id == "base" }
        let messages = RewardCatalogValidator.validate(catalog, today: RewardsFixture.today).map(\.description)
        #expect(messages.contains { $0.contains("cards/a-travel") && $0.contains("duplicate id") })
        #expect(messages.contains { $0.contains("unknown category `not-a-category`") })
        #expect(messages.contains { $0.contains("cards/b-cash") && $0.contains("unconditional rule on `base`") })
    }

    @Test func warnsAboutStaleSources() {
        let issues = RewardCatalogValidator.validate(RewardsFixture.catalog(), today: "2027-09-01")
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("days ago") })
    }

    @Test func rejectsBadDatesAndURLs() {
        var catalog = RewardsFixture.catalog()
        catalog.cards[0].ratesSource = RewardSource(url: "http://example.com", verifiedAt: "2026-13-01", verifiedBy: "x")
        let messages = RewardCatalogValidator.validate(catalog, today: RewardsFixture.today).map(\.message)
        #expect(messages.contains("url must start with https://"))
        #expect(messages.contains("verified_at must be YYYY-MM-DD"))
    }
}

/// The catalog that ships in the app.
@Suite("Card rewards: bundled catalog")
struct BundledRewardCatalogTests {
    @Test func loadsAndHasNoErrors() throws {
        let catalog = try RewardCatalog.bundled()
        #expect(!catalog.cards.isEmpty)
        let errors = RewardCatalogValidator.validate(catalog, today: CardRecommender.isoToday())
            .filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test func everyCardWithRatesCitesTheIssuer() throws {
        for card in try RewardCatalog.bundled().cards where card.status != .imported {
            let host = card.ratesSource.flatMap { URL(string: $0.url)?.host } ?? ""
            #expect(!host.isEmpty, "\(card.id) has no rates source")
        }
    }

    struct Golden: CustomTestStringConvertible, Sendable {
        var name: String
        var wallet: [String]
        var purchase: CardPurchase
        var preferences = CardRewardPreferences()
        var expectTop: String
        var testDescription: String { name }
    }

    /// Real purchases with the card a points-maxxer would pick. Every point is
    /// worth 1 cent unless a case says otherwise. Add a case with every data fix.
    static let golden: [Golden] = [
        Golden(name: "Dinner out", wallet: ["amex-gold", "capital-one-savor", "citi-double-cash"],
               purchase: CardPurchase(category: "dining"), expectTop: "amex-gold"),
        Golden(name: "Dinner out, valuing Membership Rewards at 0.6 cents", wallet: ["amex-gold", "capital-one-savor"],
               purchase: CardPurchase(category: "dining"),
               preferences: CardRewardPreferences(valuations: ["amex-mr": 0.6]), expectTop: "capital-one-savor"),
        Golden(name: "Whole Foods by name", wallet: ["amex-gold", "citi-strata-premier", "capital-one-savor"],
               purchase: CardPurchase(merchant: "Whole Foods"), expectTop: "amex-gold"),
        Golden(name: "Supermarket abroad (Gold's 4x is U.S. only)",
               wallet: ["amex-gold", "citi-strata-premier", "citi-double-cash"],
               purchase: CardPurchase(category: "supermarkets", abroad: true), expectTop: "citi-strata-premier"),
        Golden(name: "Supermarket after Gold's $25,000 cap", wallet: ["amex-gold", "citi-double-cash"],
               purchase: CardPurchase(category: "supermarkets"),
               preferences: CardRewardPreferences(capSpendMinorUnits: ["amex-gold:us-supermarkets": 2_500_000]),
               expectTop: "citi-double-cash"),
        Golden(name: "Walmart is a superstore, not a grocery store",
               wallet: ["amex-gold", "capital-one-savor", "citi-double-cash"],
               purchase: CardPurchase(merchant: "walmart.com"), expectTop: "citi-double-cash"),
        Golden(name: "Costco in store only takes Visa", wallet: ["amex-gold", "chase-freedom-unlimited", "citi-double-cash"],
               purchase: CardPurchase(merchant: "Costco"), expectTop: "chase-freedom-unlimited"),
        Golden(name: "CVS by statement alias", wallet: ["chase-freedom-unlimited", "citi-double-cash", "amex-gold"],
               purchase: CardPurchase(merchant: "CVS Pharmacy"), expectTop: "chase-freedom-unlimited"),
        Golden(name: "Filling up at Shell", wallet: ["citi-strata-premier", "citi-double-cash", "chase-freedom-unlimited"],
               purchase: CardPurchase(merchant: "Shell"), expectTop: "citi-strata-premier"),
        Golden(name: "EV charger found through Apple Maps", wallet: ["citi-strata-premier", "citi-double-cash"],
               purchase: CardPurchase(mapkitCategory: "MKPOICategoryEVCharger"), expectTop: "citi-strata-premier"),
        Golden(name: "Netflix subscription", wallet: ["capital-one-savor", "amex-gold", "citi-double-cash"],
               purchase: CardPurchase(merchant: "netflix.com", channel: .online), expectTop: "capital-one-savor"),
        Golden(name: "Flight bought on delta.com", wallet: ["amex-gold", "chase-freedom-unlimited", "capital-one-savor"],
               purchase: CardPurchase(merchant: "https://www.delta.com/flight-search", channel: .online),
               expectTop: "amex-gold"),
        Golden(name: "Hotel booked directly with Marriott", wallet: ["citi-strata-premier", "amex-gold", "citi-double-cash"],
               purchase: CardPurchase(merchant: "marriott.com", channel: .online), expectTop: "citi-strata-premier"),
        Golden(name: "Hotel booked through Citi Travel", wallet: ["amex-gold", "citi-double-cash", "citi-strata-premier"],
               purchase: CardPurchase(category: "hotels", portalIssuer: "citi"), expectTop: "citi-strata-premier"),
        Golden(name: "Hotel through Chase Travel", wallet: ["chase-freedom-unlimited", "citi-double-cash", "amex-gold"],
               purchase: CardPurchase(category: "hotels", portalIssuer: "chase"), expectTop: "chase-freedom-unlimited"),
        Golden(name: "Store we don't know falls back to base rates",
               wallet: ["chase-freedom-unlimited", "citi-double-cash", "amex-gold"],
               purchase: CardPurchase(merchant: "Joe's Hardware"), expectTop: "citi-double-cash"),
    ]

    @Test(arguments: golden)
    func goldenPurchase(_ test: Golden) throws {
        let recommender = CardRecommender(catalog: try RewardCatalog.bundled())
        for id in test.wallet { #expect(recommender.catalog.card(id) != nil, "unknown card \(id)") }
        let ranked = recommender.rank(test.purchase, wallet: test.wallet, preferences: test.preferences,
                                      today: RewardsFixture.today)
        let top = ranked.first { $0.accepted && $0.centsPerDollar != nil }
        #expect(top?.card.id == test.expectTop,
                "\(ranked.map { "\($0.card.id)=\($0.centsPerDollar ?? -1)" })")
    }
}

@Suite("Card rewards: suggestions from accounts")
struct RewardCardSuggesterTests {
    let suggester: RewardCardSuggester

    init() throws {
        suggester = RewardCardSuggester(catalog: try RewardCatalog.bundled())
    }

    @Test func recognisesStatementStyleAccountNames() {
        let accounts = [
            RewardAccountHint(name: "CHASE FREEDOM UNLIMITED ...1234", institution: "JPMorgan Chase Bank"),
            RewardAccountHint(name: "Citi Double Cash® Card - 5678"),
            RewardAccountHint(name: "Amex Gold"),
            RewardAccountHint(name: "Capital One Savor", institution: "Capital One"),
        ]
        #expect(suggester.suggestions(for: accounts) ==
                ["chase-freedom-unlimited", "citi-double-cash", "amex-gold", "capital-one-savor"])
    }

    @Test func bareProductNameNeedsTheRightBank() {
        #expect(suggester.suggestions(for: [RewardAccountHint(name: "Gold Card", institution: "American Express")])
                == ["amex-gold"])
        #expect(suggester.suggestions(for: [RewardAccountHint(name: "Gold Card", institution: "Chase")]).isEmpty)
    }

    @Test func otherProductsDoNotMatch() {
        let accounts = [
            RewardAccountHint(name: "Delta SkyMiles Gold Card", institution: "American Express"),
            RewardAccountHint(name: "SavorOne", institution: "Capital One"),
            RewardAccountHint(name: "Checking ...0001", institution: "Chase"),
        ]
        #expect(suggester.suggestions(for: accounts).isEmpty)
    }

    @Test func doesNotRepeatCards() {
        let accounts = [RewardAccountHint(name: "Amex Gold"), RewardAccountHint(name: "American Express Gold Card")]
        #expect(suggester.suggestions(for: accounts) == ["amex-gold"])
    }
}
