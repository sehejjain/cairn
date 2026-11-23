import SwiftUI
import CairnCore

/// Choose the cards you carry from the bundled catalog, grouped by issuer.
struct CardPickerSheet: View {
    let catalog: RewardCatalog
    @Binding var selection: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var groups: [(issuer: RewardIssuer, cards: [RewardCard])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.issuers.compactMap { issuer in
            let cards = catalog.cards
                .filter { $0.issuer == issuer.id }
                .filter { needle.isEmpty || $0.name.localizedStandardContains(needle)
                    || issuer.name.localizedStandardContains(needle) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return cards.isEmpty ? nil : (issuer, cards)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.issuer.id) { group in
                    Section {
                        ForEach(group.cards) { card in
                            Button { toggle(card.id) } label: { row(card) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        Text(verbatim: group.issuer.name)
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("More cards are added as their rates are checked against each issuer’s site.")
                }
            }
            .cairnListStyle()
            .searchable(text: $query, prompt: Text("Search cards"))
            .navigationTitle("Your Cards")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func row(_ card: RewardCard) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.name)
                Text(feeText(card)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selection.contains(card.id) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(CairnTheme.accent)
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selection.contains(card.id) ? [.isButton, .isSelected] : .isButton)
    }

    private func feeText(_ card: RewardCard) -> LocalizedStringKey {
        let confirmed = !(card.unverifiedFields ?? []).contains("annual_fee")
        if card.annualFee == 0 { return confirmed ? "No annual fee" : "No annual fee (unconfirmed)" }
        let fee = card.annualFee.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        return confirmed ? "\(fee) annual fee" : "\(fee) annual fee (unconfirmed)"
    }

    private func toggle(_ id: String) {
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else {
            selection.append(id)
        }
    }
}
