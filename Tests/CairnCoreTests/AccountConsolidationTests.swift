import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Stored account repairs")
@MainActor
struct AccountConsolidationTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func store() throws -> (ModelContainer, SyncEngine) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, SyncEngine(modelContainer: result.container))
    }

    private func institution(in context: ModelContext) -> Institution {
        let institution = Institution(bankConnectionID: "connection", name: "Bank", credentialID: UUID())
        context.insert(institution)
        return institution
    }

    private func account(in context: ModelContext, owner: Institution, id: String = "account") -> Account {
        let account = Account(bankAccountID: id, name: "Brokerage")
        account.institution = owner
        context.insert(account)
        return account
    }

    private func transaction(in context: ModelContext, account: Account, id: String) -> LedgerTransaction {
        let transaction = LedgerTransaction(bankTransactionID: id, payeeDescription: id, amountMinorUnits: -100)
        transaction.postedDate = date
        transaction.accountIDIndex = account.bankAccountID
        transaction.account = account
        context.insert(transaction)
        return transaction
    }

    @Test("Stored blank position currencies inherit only an account with the same scale")
    func blankCurrencyRepairPreservesAmounts() async throws {
        let (container, engine) = try store()
        let context = container.mainContext
        let owner = institution(in: context)
        let usd = account(in: context, owner: owner)
        let jpy = account(in: context, owner: owner, id: "jpy")
        jpy.apply(currency: Currency(code: "JPY", exponent: 0))
        let wallet = account(in: context, owner: owner, id: "wallet")
        wallet.sourceRaw = AccountSource.financeKit.rawValue
        let blank = Holding(holdingID: "blank", currency: Currency(code: " \n"))
        blank.marketValueMinorUnits = 123_456
        blank.costBasisMinorUnits = 100_000
        blank.hasCostBasis = true
        blank.purchasePriceMinorUnits = 10_000
        blank.hasPurchasePrice = true
        blank.account = usd
        let differentScale = Holding(holdingID: "different-scale", currency: Currency(code: ""))
        differentScale.account = jpy
        let explicit = Holding(holdingID: "explicit", currency: Currency(code: "EUR"))
        explicit.account = usd
        let walletBlank = Holding(holdingID: "wallet", currency: Currency(code: ""))
        walletBlank.account = wallet
        let orphan = Holding(holdingID: "orphan", currency: Currency(code: ""))
        for holding in [blank, differentScale, explicit, walletBlank, orphan] { context.insert(holding) }
        try context.save()
        let id = blank.persistentModelID

        #expect(try await engine.repairBlankHoldingCurrencies() == 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Holding>())
        let repaired = try #require(rows.first { $0.holdingID == "blank" })
        #expect(repaired.persistentModelID == id)
        #expect(repaired.currency == .usd)
        #expect(repaired.marketValueMinorUnits == 123_456)
        #expect(repaired.costBasisMinorUnits == 100_000 && repaired.hasCostBasis)
        #expect(repaired.purchasePriceMinorUnits == 10_000 && repaired.hasPurchasePrice)
        #expect(rows.first { $0.holdingID == "different-scale" }?.currency.code == "")
        #expect(rows.first { $0.holdingID == "explicit" }?.currency.code == "EUR")
        #expect(rows.first { $0.holdingID == "wallet" }?.currency.code == "")
        #expect(rows.first { $0.holdingID == "orphan" }?.currency.code == "")
        #expect(try await engine.repairBlankHoldingCurrencies() == 0)
    }

    @Test("Reviewed copies retain history, edits, latest balances and latest positions", arguments: [true, false])
    func consolidationPreservesRelationships(userChoiceOnKeptCopy: Bool) async throws {
        let (container, engine) = try store()
        let context = container.mainContext
        let owner = institution(in: context)
        let kept = account(in: context, owner: owner)
        let extra = account(in: context, owner: owner)
        kept.lastSyncedAt = date
        kept.balanceMinorUnits = 100
        extra.lastSyncedAt = date.addingTimeInterval(60)
        extra.balanceMinorUnits = 200
        extra.availableBalanceMinorUnits = 150
        extra.hasAvailableBalance = true
        extra.customDisplayName = "Long-term savings"
        extra.includeInNetWorth = false
        let common = transaction(in: context, account: kept, id: "common")
        common.isIgnored = true
        common.isTransferUserSet = userChoiceOnKeptCopy
        common.isTransfer = !userChoiceOnKeptCopy
        let duplicateCommon = transaction(in: context, account: extra, id: "common")
        duplicateCommon.note = "Keep this note"
        duplicateCommon.isTransferUserSet = !userChoiceOnKeptCopy
        duplicateCommon.isTransfer = userChoiceOnKeptCopy
        let tag = Tag(name: "Trip")
        let sameNamedTag = Tag(name: "Trip")
        context.insert(tag)
        context.insert(sameNamedTag)
        common.tags = [sameNamedTag]
        duplicateCommon.tags = [tag]
        _ = transaction(in: context, account: kept, id: "kept-only")
        let moved = transaction(in: context, account: extra, id: "extra-only")
        moved.note = "Original history"
        let oldPosition = Holding(holdingID: "position")
        oldPosition.marketValueMinorUnits = 100
        oldPosition.account = kept
        let freshPosition = Holding(holdingID: "position")
        freshPosition.marketValueMinorUnits = 200
        freshPosition.costBasisMinorUnits = 150
        freshPosition.hasCostBasis = true
        freshPosition.account = extra
        context.insert(oldPosition)
        context.insert(freshPosition)
        let oldAnchor = BalanceSnapshot(day: date, balanceMinorUnits: 100)
        oldAnchor.account = kept
        let freshAnchor = BalanceSnapshot(day: date, balanceMinorUnits: 200)
        freshAnchor.account = extra
        let history = BalanceSnapshot(day: date.addingTimeInterval(-86_400), balanceMinorUnits: 50)
        history.account = extra
        for anchor in [oldAnchor, freshAnchor, history] { context.insert(anchor) }
        try context.save()
        let keptID = kept.persistentModelID
        let extraID = extra.persistentModelID

        #expect(try await engine.consolidateDuplicateAccounts(keeping: keptID, duplicates: [extraID]) == 1)
        let reloaded = ModelContext(container)
        let accounts = try reloaded.fetch(FetchDescriptor<Account>())
        let account = try #require(accounts.first)
        #expect(accounts.count == 1 && account.persistentModelID == keptID)
        #expect(account.institution?.persistentModelID == owner.persistentModelID)
        #expect(account.customDisplayName == "Long-term savings" && !account.includeInNetWorth)
        #expect(account.balanceMinorUnits == 200 && account.availableBalanceMinorUnits == 150)
        #expect(account.hasAvailableBalance && account.currency == .usd)
        let transactions = try reloaded.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(transactions.count == 3)
        #expect(transactions.allSatisfy { $0.account?.persistentModelID == keptID })
        let commonAfter = try #require(transactions.first { $0.bankTransactionID == "common" })
        #expect(commonAfter.note == "Keep this note" && commonAfter.isIgnored)
        #expect(commonAfter.isTransferUserSet && !commonAfter.isTransfer)
        #expect(Set(commonAfter.tags?.map(\.persistentModelID) ?? [])
            == [tag.persistentModelID, sameNamedTag.persistentModelID])
        #expect(transactions.first { $0.bankTransactionID == "extra-only" }?.note == "Original history")
        let positions = try reloaded.fetch(FetchDescriptor<Holding>())
        #expect(positions.count == 1 && positions.first?.marketValueMinorUnits == 200)
        #expect(positions.first?.costBasisMinorUnits == 150 && positions.first?.hasCostBasis == true)
        let anchors = try reloaded.fetch(FetchDescriptor<BalanceSnapshot>())
        #expect(anchors.count == 2)
        #expect(anchors.first { $0.day == date }?.balanceMinorUnits == 200)
        #expect(anchors.allSatisfy { $0.account?.persistentModelID == keptID })
        await #expect(throws: SyncEngine.AccountConsolidationError.self) {
            try await engine.consolidateDuplicateAccounts(keeping: keptID, duplicates: [extraID])
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Account>()) == 1)
    }

    @Test("Consolidation rejects a different bank identity, owner or source")
    func identityScopeIsExact() async throws {
        let (container, engine) = try store()
        let context = container.mainContext
        let owner = institution(in: context)
        let otherOwner = institution(in: context)
        let kept = account(in: context, owner: owner)
        let differentID = account(in: context, owner: owner, id: "different")
        let differentOwner = account(in: context, owner: otherOwner)
        let manual = account(in: context, owner: owner)
        manual.sourceRaw = AccountSource.manual.rawValue
        try context.save()
        for extra in [differentID, differentOwner, manual] {
            await #expect(throws: SyncEngine.AccountConsolidationError.self) {
                try await engine.consolidateDuplicateAccounts(
                    keeping: kept.persistentModelID, duplicates: [extra.persistentModelID]
                )
            }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Account>()) == 4)
    }

    @Test("All copies are checked before any conflicting edit is removed")
    func conflictsLeaveEveryCopyIntact() async throws {
        let (container, engine) = try store()
        let context = container.mainContext
        let owner = institution(in: context)
        let kept = account(in: context, owner: owner)
        let first = account(in: context, owner: owner)
        let second = account(in: context, owner: owner)
        transaction(in: context, account: first, id: "same").note = "First edit"
        transaction(in: context, account: second, id: "same").note = "Other edit"
        try context.save()
        await #expect(throws: SyncEngine.AccountConsolidationError.self) {
            try await engine.consolidateDuplicateAccounts(
                keeping: kept.persistentModelID, duplicates: [first.persistentModelID, second.persistentModelID]
            )
        }
        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<Account>()) == 3)
        #expect(Set(try reloaded.fetch(FetchDescriptor<LedgerTransaction>()).compactMap(\.note))
            == ["First edit", "Other edit"])
    }

    @Test("Different currency scales and reused transaction ids are kept separate")
    func monetaryConflictsAreNotRelabeledOrDiscarded() async throws {
        let (container, engine) = try store()
        let context = container.mainContext
        let owner = institution(in: context)
        let kept = account(in: context, owner: owner)
        let foreign = account(in: context, owner: owner)
        foreign.apply(currency: Currency(code: "JPY", exponent: 0))
        let reusedID = account(in: context, owner: owner)
        let differentScale = account(in: context, owner: owner)
        _ = transaction(in: context, account: kept, id: "same")
        transaction(in: context, account: reusedID, id: "same").amountMinorUnits = -200
        transaction(in: context, account: differentScale, id: "same").currencyExponent = 0
        try context.save()
        for extra in [foreign, reusedID, differentScale] {
            await #expect(throws: SyncEngine.AccountConsolidationError.self) {
                try await engine.consolidateDuplicateAccounts(
                    keeping: kept.persistentModelID, duplicates: [extra.persistentModelID]
                )
            }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Account>()) == 4)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LedgerTransaction>()) == 3)
    }
}
