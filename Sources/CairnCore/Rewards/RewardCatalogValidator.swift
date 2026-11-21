import Foundation

public struct RewardCatalogIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case error, warning
    }

    public var severity: Severity
    public var location: String
    public var message: String

    public init(severity: Severity, location: String, message: String) {
        self.severity = severity
        self.location = location
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(location): \(message)" }
}

/// Checks the rewards catalog for broken references and rates we can't stand
/// behind. The test suite runs it against the bundled catalog.
public enum RewardCatalogValidator {
    /// Sources older than this many days produce a warning.
    public static let staleAfterDays = 180

    public static func validate(_ catalog: RewardCatalog, today: String) -> [RewardCatalogIssue] {
        var issues: [RewardCatalogIssue] = []
        func error(_ location: String, _ message: String) {
            issues.append(RewardCatalogIssue(severity: .error, location: location, message: message))
        }
        func warning(_ location: String, _ message: String) {
            issues.append(RewardCatalogIssue(severity: .warning, location: location, message: message))
        }

        func checkIDs(_ ids: [String], _ kind: String) {
            var seen = Set<String>()
            for id in ids {
                if !isSlug(id) { error("\(kind)/\(id)", "id must be lowercase letters, digits, and dashes") }
                if !seen.insert(id).inserted { error("\(kind)/\(id)", "duplicate id") }
            }
        }
        checkIDs(catalog.categories.map(\.id), "categories")
        checkIDs(catalog.currencies.map(\.id), "currencies")
        checkIDs(catalog.issuers.map(\.id), "issuers")
        checkIDs(catalog.merchants.map(\.id), "merchants")
        checkIDs(catalog.cards.map(\.id), "cards")

        let categories = Dictionary(catalog.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currencies = Set(catalog.currencies.map(\.id))
        let issuers = Set(catalog.issuers.map(\.id))
        let merchants = Set(catalog.merchants.map(\.id))

        checkCategories(catalog.categories, categories, error: error)

        for currency in catalog.currencies where !(currency.centsPerPoint > 0 && currency.centsPerPoint < 100) {
            error("currencies/\(currency.id)", "cents_per_point must be between 0 and 100")
        }

        for merchant in catalog.merchants {
            let location = "merchants/\(merchant.id)"
            if merchant.categories.isEmpty { error(location, "needs at least one category") }
            for category in merchant.categories where categories[category] == nil {
                error(location, "unknown category `\(category)`")
            }
            for domain in merchant.domains ?? [] where !isDomain(domain) {
                error(location, "domain `\(domain)` should look like example.com")
            }
        }

        for card in catalog.cards {
            let location = "cards/\(card.id)"
            if !issuers.contains(card.issuer) { error(location, "unknown issuer `\(card.issuer)`") }
            if !currencies.contains(card.currency) { error(location, "unknown currency `\(card.currency)`") }
            if card.annualFee < 0 { error(location, "annual_fee can't be negative") }
            if let fee = card.foreignTransactionFee, !(0...10).contains(fee) {
                error(location, "foreign_transaction_fee is a percent between 0 and 10")
            }
            if let rates = card.ratesSource {
                checkSource(rates, "\(location).rates_source", today: today, error: error, warning: warning)
            }
            if card.status != .imported {
                if card.earn.isEmpty { error(location, "status `\(card.status.rawValue)` needs earning rules") }
                if !card.earn.contains(where: \.isUnconditionalBase) {
                    error(location, "needs an unconditional rule on `base` (its rate on everything else)")
                }
            }
            checkRules(card, location: location, categories: categories, merchants: merchants, today: today,
                       error: error, warning: warning)
        }
        return issues
    }

    private static func checkCategories(
        _ list: [RewardCategory],
        _ categories: [String: RewardCategory],
        error: (String, String) -> Void
    ) {
        if categories[RewardCategory.baseID] == nil { error("categories", "missing the root category `base`") }
        for category in list {
            let location = "categories/\(category.id)"
            if category.id == RewardCategory.baseID, category.parent != nil {
                error(location, "`base` can't have a parent")
            }
            if let parent = category.parent {
                if categories[parent] == nil { error(location, "unknown parent `\(parent)`") }
                var seen: Set<String> = [category.id]
                var current: String? = parent
                while let next = current {
                    if !seen.insert(next).inserted {
                        error(location, "parent chain loops")
                        break
                    }
                    current = categories[next]?.parent
                }
            }
            for code in category.mcc ?? [] where code.wholeMatch(of: /\d{4}(-\d{4})?/) == nil {
                error(location, "MCC `\(code)` must be four digits or a range like 3000-3350")
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func checkRules(
        _ card: RewardCard,
        location: String,
        categories: [String: RewardCategory],
        merchants: Set<String>,
        today: String,
        error: (String, String) -> Void,
        warning: (String, String) -> Void
    ) {
        var ruleIDs = Set<String>()
        for (index, rule) in card.earn.enumerated() {
            let ruleLocation = "\(location).earn[\(rule.id ?? String(index))]"
            if let id = rule.id, !ruleIDs.insert(id).inserted { error(ruleLocation, "duplicate rule id") }
            if (rule.categories ?? []).isEmpty && (rule.merchants ?? []).isEmpty {
                error(ruleLocation, "needs categories or merchants")
            }
            for category in rule.categories ?? [] where categories[category] == nil {
                error(ruleLocation, "unknown category `\(category)`")
            }
            for merchant in rule.merchants ?? [] where !merchants.contains(merchant) {
                error(ruleLocation, "unknown merchant `\(merchant)`")
            }
            if !(rule.multiplier > 0 && rule.multiplier <= 100) {
                error(ruleLocation, "multiplier must be between 0 and 100")
            }
            if let cap = rule.cap {
                if cap.amount <= 0 { error(ruleLocation, "cap amount must be positive") }
                if cap.after < 0 { error(ruleLocation, "cap `after` can't be negative") }
                if cap.after > rule.multiplier { warning(ruleLocation, "rate after the cap is higher than the bonus") }
            }
            for (name, value) in [("valid_from", rule.validFrom), ("valid_to", rule.validTo)] {
                if let value, !isISODate(value) { error(ruleLocation, "\(name) must be YYYY-MM-DD") }
            }
            if let from = rule.validFrom, let end = rule.validTo, from > end {
                error(ruleLocation, "valid_from is after valid_to")
            }
            if let source = rule.source {
                checkSource(source, "\(ruleLocation).source", today: today, error: error, warning: warning)
            } else if card.ratesSource == nil && card.status != .imported {
                error(ruleLocation, "no source: add `source` to the rule or `rates_source` to the card")
            }
        }

        var creditIDs = Set<String>()
        for credit in card.credits ?? [] {
            let creditLocation = "\(location).credits[\(credit.id)]"
            if !creditIDs.insert(credit.id).inserted { error(creditLocation, "duplicate credit id") }
            if credit.amount <= 0 { error(creditLocation, "amount must be positive") }
            for merchant in credit.merchants ?? [] where !merchants.contains(merchant) {
                error(creditLocation, "unknown merchant `\(merchant)`")
            }
        }
    }

    private static func checkSource(
        _ source: RewardSource,
        _ location: String,
        today: String,
        error: (String, String) -> Void,
        warning: (String, String) -> Void
    ) {
        if !source.url.hasPrefix("https://") { error(location, "url must start with https://") }
        if source.verifiedBy.trimmingCharacters(in: .whitespaces).isEmpty { error(location, "verified_by is empty") }
        guard isISODate(source.verifiedAt) else {
            error(location, "verified_at must be YYYY-MM-DD")
            return
        }
        if source.verifiedAt > today { error(location, "verified_at is in the future") }
        if let age = days(from: source.verifiedAt, to: today), age > staleAfterDays {
            warning(location, "last verified \(age) days ago")
        }
    }

    static func isSlug(_ text: String) -> Bool {
        text.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil
    }

    static func isDomain(_ text: String) -> Bool {
        text == text.lowercased() && !text.contains("/") && !text.hasPrefix("www.") && text.contains(".")
    }

    static func isISODate(_ text: String) -> Bool {
        guard text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return false }
        return date(text) != nil
    }

    static func days(from start: String, to end: String) -> Int? {
        guard let first = date(start), let last = date(end) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: first, to: last).day
    }

    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text)
    }
}
