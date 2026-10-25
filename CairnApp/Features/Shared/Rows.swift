import SwiftUI
import CairnCore

/// One account inside an institution card.
struct AccountRow: View {
    let account: Account
    var showsChevron: Bool = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: CairnTheme.Spacing.m) {
                    AccountGlyph(account: account, size: 38)
                    VStack(alignment: .leading, spacing: 8) {
                        accountDescription
                        accountAmount(alignment: .leading)
                    }
                    if showsChevron { chevron }
                }
            } else {
                HStack(alignment: .center, spacing: CairnTheme.Spacing.m) {
                    AccountGlyph(account: account, size: 38)
                    accountDescription
                    Spacer(minLength: CairnTheme.Spacing.s)
                    accountAmount(alignment: .trailing)
                    if showsChevron { chevron }
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private var accountDescription: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.displayName)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountAmount(alignment: Alignment) -> some View {
        AmountText(
            money: account.balance,
            font: .body.weight(.medium),
            colorOverride: account.balance.isNegative ? CairnTheme.negative : nil
        )
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: alignment)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// "Checking", "Manual · Cash", or the currency when the type is unknown,
    /// so the line under the name always says something useful.
    private var subtitle: String {
        var parts: [String] = []
        if account.isManual { parts.append(String(localized: "Manual")) }
        if account.accountType != .other { parts.append(String(localized: "\(account.accountType.displayName)")) }
        if account.accountType == .other || account.currency.code != "USD" || account.currency.isCustom {
            parts.append(String(localized: "\(account.currency.displayLabel)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// One transaction in any list. The merchant leads; category and account sit
/// underneath in a quiet line; the amount is neutral for spending and green
/// for money in, so income is visible without the list turning into a
/// rainbow.
struct TransactionRow: View {
    @AppStorage("cairn.compactTransactions") private var compactAll = false
    @AppStorage(MerchantNormalizer.removeProcessorPrefixesKey)
    private var removePaymentProcessorPrefixes = true
    let transaction: LedgerTransaction
    /// Show the account name under the merchant (hide inside account detail).
    var showsAccount: Bool = true
    var showsChevron: Bool = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var compact: Bool { compactAll || transaction.autoCompact }
    private var displayName: String {
        MerchantNormalizer.displayName(
            transaction.displayDescription,
            removingPaymentProcessorPrefixes: removePaymentProcessorPrefixes
        )
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: CairnTheme.Spacing.m) {
                    transactionBadge
                    VStack(alignment: .leading, spacing: 8) {
                        transactionDescription
                        transactionAmount(alignment: .leading)
                    }
                    if showsChevron { chevron }
                }
            } else {
                HStack(alignment: .top, spacing: CairnTheme.Spacing.m) {
                    transactionBadge
                    transactionDescription
                    Spacer(minLength: CairnTheme.Spacing.xs)
                    transactionAmount(alignment: .trailing)
                    if showsChevron { chevron }
                }
            }
        }
        .padding(.vertical, compact ? 7 : 11)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private var transactionBadge: some View {
        CategoryBadge(
            symbolName: transaction.countsAsTransfer && transaction.effectiveCategory == nil
                ? "arrow.left.arrow.right"
                : transaction.effectiveCategory?.symbolName,
            hex: transaction.effectiveCategory?.colorHex ?? (transaction.countsAsTransfer ? "#32ADE6" : nil),
            size: compact ? 32 : 38
        )
        .opacity(transaction.isIgnored ? 0.5 : 1)
    }

    private var transactionDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayName.isEmpty ? "No description" : displayName)
                .font(.body)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(transaction.isIgnored, color: .secondary)
                .foregroundStyle(transaction.isIgnored ? .secondary : .primary)
            if hasMetadata { transactionMetadata }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transactionMetadata: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                if transaction.isPending {
                    StatusPill(text: "Pending", systemImage: "clock", tint: CairnTheme.warning)
                }
                if let metadataText {
                    metadataText
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.body)
        } else {
            HStack(spacing: 5) {
                if transaction.isPending {
                    StatusPill(text: "Pending", systemImage: "clock", tint: CairnTheme.warning)
                }
                if let metadataText {
                    metadataText
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.subheadline)
        }
    }

    private var metadataText: Text? {
        var parts: [Text] = []
        if !compact, let categoryLabel { parts.append(Text(categoryLabel)) }
        if showsAccount, let accountName = transaction.account?.displayName { parts.append(Text(accountName)) }
        if !transaction.effectiveTags.isEmpty { parts.append(Text(tagSummary(transaction.effectiveTags))) }
        return parts.dropFirst().reduce(parts.first) { result, part in
            result.map { $0 + Text(" · ") + part }
        }
    }

    private var hasMetadata: Bool {
        transaction.isPending || metadataText != nil
    }

    private func transactionAmount(alignment: Alignment) -> some View {
        AmountText(
            money: transaction.amount,
            showSign: true,
            font: .body.weight(.medium),
            colorOverride: amountColor
        )
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: alignment)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private var amountColor: Color? {
        if transaction.isIgnored { return .secondary }
        if transaction.countsAsTransfer { return .secondary }
        return transaction.amount.isNegative ? nil : CairnTheme.positive
    }

    /// The category, or "Transfer" when the row is money movement and has no
    /// category of its own.
    private var categoryLabel: LocalizedStringKey? {
        if let category = transaction.effectiveCategory {
            return LocalizedStringKey(category.name)
        }
        return transaction.countsAsTransfer ? "Transfer" : "Uncategorized"
    }

    /// Up to two tag names, then a count, so one row never grows unbounded.
    private func tagSummary(_ tags: [Tag]) -> String {
        let shown = tags.prefix(2).map { "#\($0.name)" }
        let extra = tags.count - shown.count
        return shown.joined(separator: " ") + (extra > 0 ? " +\(extra)" : "")
    }
}

/// One transaction drawn from an immutable snapshot. This is the row the
/// windowed lists use: it reads no SwiftData state while diffing, so a single
/// categorized transaction cannot invalidate unrelated rows.
struct TransactionValueRow: View {
    @AppStorage("cairn.compactTransactions") private var compactAll = false
    @AppStorage(MerchantNormalizer.removeProcessorPrefixesKey)
    private var removePaymentProcessorPrefixes = true
    let row: TransactionRowValue
    var showsAccount: Bool = true
    var showsChevron: Bool = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var compact: Bool { compactAll || row.isCompact }
    private var displayName: String {
        MerchantNormalizer.displayName(
            row.displayName ?? row.payeeDescription,
            removingPaymentProcessorPrefixes: removePaymentProcessorPrefixes
        )
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: CairnTheme.Spacing.m) {
                    transactionBadge
                    VStack(alignment: .leading, spacing: 8) {
                        transactionDescription
                        transactionAmount(alignment: .leading)
                    }
                    if showsChevron { chevron }
                }
            } else {
                HStack(alignment: .top, spacing: CairnTheme.Spacing.m) {
                    transactionBadge
                    transactionDescription
                    Spacer(minLength: CairnTheme.Spacing.xs)
                    transactionAmount(alignment: .trailing)
                    if showsChevron { chevron }
                }
            }
        }
        .padding(.vertical, compact ? 7 : 11)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private var transactionBadge: some View {
        CategoryBadge(
            symbolName: row.countsAsTransfer && row.categoryName == nil
                ? "arrow.left.arrow.right"
                : row.categorySymbolName,
            hex: row.categoryColorHex ?? (row.countsAsTransfer ? "#32ADE6" : nil),
            size: compact ? 32 : 38
        )
        .opacity(row.isIgnored ? 0.5 : 1)
    }

    private var transactionDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayName.isEmpty ? "No description" : displayName)
                .font(.body)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(row.isIgnored, color: .secondary)
                .foregroundStyle(row.isIgnored ? .secondary : .primary)
            if hasMetadata { transactionMetadata }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transactionMetadata: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                if row.isPending {
                    StatusPill(text: "Pending", systemImage: "clock", tint: CairnTheme.warning)
                }
                if let metadataText {
                    metadataText
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.body)
        } else {
            HStack(spacing: 5) {
                if row.isPending {
                    StatusPill(text: "Pending", systemImage: "clock", tint: CairnTheme.warning)
                }
                if let metadataText {
                    metadataText
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.subheadline)
        }
    }

    private var metadataText: Text? {
        var parts: [Text] = []
        if !compact, let categoryLabel { parts.append(Text(categoryLabel)) }
        if showsAccount, let accountName = row.accountName { parts.append(Text(accountName)) }
        if !row.tagNames.isEmpty { parts.append(Text(tagSummary(row.tagNames))) }
        return parts.dropFirst().reduce(parts.first) { result, part in
            result.map { $0 + Text(" · ") + part }
        }
    }

    private var hasMetadata: Bool {
        row.isPending || metadataText != nil
    }

    private func transactionAmount(alignment: Alignment) -> some View {
        AmountText(
            money: row.amount,
            showSign: true,
            font: .body.weight(.medium),
            colorOverride: amountColor
        )
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: alignment)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private var amountColor: Color? {
        if row.isIgnored { return .secondary }
        if row.countsAsTransfer { return .secondary }
        return row.amountMinorUnits < 0 ? nil : CairnTheme.positive
    }

    /// The category, or "Transfer" when the row is money movement and has no
    /// category of its own.
    private var categoryLabel: String? {
        if let name = row.categoryName { return name }
        return row.countsAsTransfer ? "Transfer" : "Uncategorized"
    }

    /// Up to two tag names, then a count, so one row never grows unbounded.
    private func tagSummary(_ names: [String]) -> String {
        let shown = names.prefix(2).map { "#\($0)" }
        let extra = names.count - shown.count
        return shown.joined(separator: " ") + (extra > 0 ? " +\(extra)" : "")
    }
}

/// A vertical stack of rows inside a card, separated by hairlines that stop
/// short of the leading glyph, like a well-set table.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .cardSurface()
    }
}

/// A hairline that lines up with row text rather than the glyph.
struct RowDivider: View {
    var leadingInset: CGFloat = 68

    var body: some View {
        Rectangle()
            .fill(CairnTheme.hairline)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

/// One investment position: the ticker or name, shares and cost basis, the
/// market value as of the last sync, and the gain since purchase when the bank
/// reported a cost basis.
struct HoldingRow: View {
    let holding: Holding

    var body: some View {
        HStack(alignment: .top, spacing: CairnTheme.Spacing.m) {
            badge

            VStack(alignment: .leading, spacing: 3) {
                Text(holding.displayLabel)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                AmountText(
                    money: holding.marketValue,
                    font: .body.weight(.semibold)
                )
                .fixedSize(horizontal: true, vertical: false)

                if let gain = holding.gain {
                    HStack(spacing: 4) {
                        Text(gainText(gain))
                        if let percent = gainPercent {
                            Text(percent)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(gain.minorUnits < 0 ? CairnTheme.negative : CairnTheme.positive)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(CairnTheme.accent.opacity(0.12))
                .frame(width: 40, height: 40)
            if let symbol = holding.symbol, !symbol.isEmpty {
                Text(symbol.uppercased().prefix(4))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CairnTheme.accent)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            } else {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CairnTheme.accent)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if holding.symbol?.isEmpty == false, !holding.name.isEmpty {
            parts.append(holding.name)
        }
        if let shares = holding.shares {
            let count = shares.formatted(.number.precision(.fractionLength(0...4)))
            parts.append("\(count) \(shares == 1 ? String(localized: "share") : String(localized: "shares"))")
        }
        if let cost = holding.costBasis {
            parts.append(String(localized: "Cost \(cost.formatted())"))
        }
        return parts.joined(separator: " · ")
    }

    private func gainText(_ gain: Money) -> String {
        let formatted = gain.formatted()
        return gain.minorUnits > 0 ? "+\(formatted)" : formatted
    }

    private var gainPercent: String? {
        guard let cost = holding.costBasis, cost.minorUnits > 0, let gain = holding.gain else { return nil }
        let ratio = Double(gain.minorUnits) / Double(cost.minorUnits)
        return ratio.formatted(.percent.precision(.fractionLength(1)))
    }
}
