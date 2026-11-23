import SwiftUI

/// Device-local visibility preferences for optional Cairn surfaces. These are
/// presentation choices, so they do not add a CloudKit field or sync between
/// devices.
enum AppFeature: String, CaseIterable, Identifiable {
    case budgeting
    case cardRewards

    var id: String { rawValue }

    var storageKey: String { "cairn.feature.\(rawValue).enabled" }

    var defaultEnabled: Bool { true }

    var title: LocalizedStringKey {
        switch self {
        case .budgeting: "Show budgeting"
        case .cardRewards: "Show card rewards"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .budgeting: "Show budget cards, links, and exports. Saved limits stay on device if you turn this off."
        case .cardRewards: "Show which of your cards earns the most at a store. Your card choices stay on this device."
        }
    }

    var systemImage: String {
        switch self {
        case .budgeting: "chart.pie.fill"
        case .cardRewards: "creditcard.fill"
        }
    }
}
