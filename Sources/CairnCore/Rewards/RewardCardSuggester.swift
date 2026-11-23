import Foundation

/// A credit-card account the person already tracks in Cairn, reduced to the
/// names needed to recognise the card product. Matching happens on-device.
public struct RewardAccountHint: Sendable, Hashable {
    public var name: String
    public var institution: String?

    public init(name: String, institution: String? = nil) {
        self.name = name
        self.institution = institution
    }
}

/// Suggests catalog cards from account names such as "CHASE FREEDOM UNLIMITED ...1234"
/// or "Gold Card". Suggestions are only shown for the person to confirm.
public struct RewardCardSuggester: Sendable {
    private struct Entry: Sendable {
        var cardID: String
        var issuer: String
        var aliases: Set<String>
    }

    private let aliasesByCard: [Entry]
    private let issuerNames: [String: Set<String>]

    /// Words that say nothing about which product an account is.
    static let genericWords: Set<String> = ["card", "credit", "account", "acct", "ending", "the", "from"]

    public init(catalog: RewardCatalog) {
        var issuerNames: [String: Set<String>] = [:]
        for issuer in catalog.issuers {
            let names = ([issuer.name] + (issuer.aliases ?? [])).map(Self.clean).filter { !$0.isEmpty }
            issuerNames[issuer.id] = Set(names)
        }
        self.issuerNames = issuerNames

        aliasesByCard = catalog.cards.map { card in
            let full = Self.clean(card.name)
            var aliases: Set<String> = [full]
            // "American Express Gold Card" → "gold", then "amex gold".
            for issuerName in issuerNames[card.issuer] ?? [] where full.hasPrefix(issuerName + " ") {
                let distinctive = String(full.dropFirst(issuerName.count + 1))
                aliases.insert(distinctive)
                for other in issuerNames[card.issuer] ?? [] { aliases.insert("\(other) \(distinctive)") }
            }
            for alias in card.aliases ?? [] { aliases.insert(Self.clean(alias)) }
            aliases.remove("")
            return Entry(cardID: card.id, issuer: card.issuer, aliases: aliases)
        }
    }

    /// Card ids that match the accounts, in account order, without repeats.
    public func suggestions(for accounts: [RewardAccountHint]) -> [String] {
        var result: [String] = []
        for account in accounts {
            let name = Self.clean(account.name)
            guard !name.isEmpty else { continue }
            let institution = account.institution.map(Self.clean)
            for entry in aliasesByCard where entry.aliases.contains(name) && !result.contains(entry.cardID) {
                // A bare product name ("gold") from a different bank isn't this card.
                if let institution, !institution.isEmpty,
                   !(issuerNames[entry.issuer] ?? []).contains(where: { institution.contains($0) }) {
                    continue
                }
                result.append(entry.cardID)
            }
        }
        return result
    }

    /// Normalized words with masked numbers and generic words removed.
    static func clean(_ text: String) -> String {
        CardRecommender.normalize(text)
            .split(separator: " ")
            .filter { word in !word.contains(where: \.isNumber) && !genericWords.contains(String(word)) }
            .joined(separator: " ")
    }
}
