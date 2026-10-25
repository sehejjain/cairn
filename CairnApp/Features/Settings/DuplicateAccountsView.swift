import SwiftUI
import SwiftData
import CairnCore

/// Lets a person review and explicitly combine repeated SimpleFIN account rows.
struct DuplicateAccountsView: View {
    @Environment(AppModel.self) private var model
    @Query private var accounts: [Account]

    @State private var pendingRepair: DuplicateAccountRepair?
    @State private var showingConfirmation = false
    @State private var isMerging = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var duplicateGroups: [DuplicateAccountGroup] {
        var grouped: [DuplicateAccountKey: [Account]] = [:]
        for account in accounts
        where account.sourceRaw == AccountSource.simpleFIN.rawValue
            && !account.bankAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let institution = account.institution else { continue }
            let key = DuplicateAccountKey(
                institutionID: institution.persistentModelID,
                bankAccountID: account.bankAccountID
            )
            grouped[key, default: []].append(account)
        }

        return grouped.compactMap { key, copies in
            guard copies.count > 1 else { return nil }
            let institutionName = copies.first?.institution?.name ?? "Institution"
            return DuplicateAccountGroup(
                key: key,
                institutionName: institutionName.isEmpty ? "Institution" : institutionName,
                accounts: copies.sorted(by: accountOrder)
            )
        }
        .sorted {
            if $0.institutionName != $1.institutionName {
                return $0.institutionName.localizedStandardCompare($1.institutionName) == .orderedAscending
            }
            return $0.key.bankAccountID.localizedStandardCompare($1.key.bankAccountID) == .orderedAscending
        }
    }

    private var isSyncing: Bool { model.syncState == .syncing }

    var body: some View {
        List {
            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(CairnTheme.positive)
                }
            }

            if duplicateGroups.isEmpty {
                Section {
                    Label("No duplicate accounts found", systemImage: "checkmark.circle")
                        .font(.headline)
                    Text("Cairn checks repeated SimpleFIN account IDs within the same institution. "
                        + "Account names alone do not identify duplicates.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(duplicateGroups) { group in
                        duplicateGroupRow(group)
                    }
                } header: {
                    Text("Review copies")
                } footer: {
                    Text("The most recently synced copy is kept. Review and combine copies on one device at a time.")
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Duplicate Accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            "Combine duplicate accounts?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            if let repair = pendingRepair {
                Button("Combine copies") { combine(repair) }
                    .accessibilityIdentifier("duplicateAccounts.confirmCombine")
            }
            Button("Cancel", role: .cancel) { pendingRepair = nil }
        } message: {
            Text("Cairn keeps transaction history and account edits. "
                + "If iCloud Sync is on, this change reaches your other devices. "
                + "Use one device for this repair.")
        }
        .alert(
            "Couldn’t combine accounts",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: model.syncState) { _, newValue in
            if newValue == .syncing {
                pendingRepair = nil
                showingConfirmation = false
            }
        }
    }

    private func duplicateGroupRow(_ group: DuplicateAccountGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIcon(systemImage: "building.columns.fill", tint: CairnTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.institutionName)
                        .font(.headline)
                    Text("\(group.accounts.count) copies")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            ForEach(group.accounts, id: \.persistentModelID) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .lineLimit(2)
                        Text(account.currency.code.isEmpty ? "Unknown currency" : account.currency.code)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if let date = account.lastSyncedAt {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not synced")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 38)
            }

            Button("Combine copies") {
                pendingRepair = DuplicateAccountRepair(
                    survivorID: group.survivor.persistentModelID,
                    duplicateIDs: group.duplicates.map(\.persistentModelID)
                )
                showingConfirmation = true
            }
            .buttonStyle(.bordered)
            .disabled(isSyncing || isMerging)
            .accessibilityIdentifier("duplicateAccounts.combineCopies")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func combine(_ repair: DuplicateAccountRepair) {
        guard !isSyncing, !isMerging else { return }
        isMerging = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let mergedCount = try await model.consolidateDuplicateAccounts(
                    keeping: repair.survivorID,
                    duplicates: repair.duplicateIDs
                )
                statusMessage = "Combined \(mergedCount + 1) copies into one account."
            } catch {
                errorMessage = error.localizedDescription
            }
            pendingRepair = nil
            isMerging = false
        }
    }

    private func accountOrder(_ lhs: Account, _ rhs: Account) -> Bool {
        let leftDate = lhs.lastSyncedAt ?? .distantPast
        let rightDate = rhs.lastSyncedAt ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
    }
}

private struct DuplicateAccountRepair {
    let survivorID: PersistentIdentifier
    let duplicateIDs: [PersistentIdentifier]
}

private struct DuplicateAccountKey: Hashable {
    let institutionID: PersistentIdentifier
    let bankAccountID: String
}

private struct DuplicateAccountGroup: Identifiable {
    let key: DuplicateAccountKey
    let institutionName: String
    let accounts: [Account]

    var id: DuplicateAccountKey { key }
    var survivor: Account { accounts[0] }
    var duplicates: [Account] { Array(accounts.dropFirst()) }
}
