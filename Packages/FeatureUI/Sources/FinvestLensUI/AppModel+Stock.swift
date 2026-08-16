//
//  AppModel+Stock.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Errors from the Stock Transaction Assistant.
public enum StockEntryError: Error, Equatable {
    case noBook
    case unknownAccount
    case invalidInput
}

@MainActor
extension AppModel {

    // MARK: Typed account lists for the assistant

    /// Security (stock / mutual-fund) accounts.
    public var securityAccountNodes: [AccountNode] {
        postableAccounts.filter { $0.typeName == "Stock" || $0.typeName == "Mutual" }
    }

    /// The **portfolios**: every account that directly parents a security
    /// account — a broker, a super fund, a self-managed pool.
    ///
    /// A portfolio is not a type in the book, because GnuCash has no such type.
    /// It is a shape: someone who holds shares through two brokers files them
    /// under two parents, and those parents are the grouping they already think
    /// in. Derived rather than configured for exactly that reason — there is
    /// nothing to set up, and a book that keeps every holding under one parent
    /// simply has one portfolio.
    ///
    /// Sorted by the name shown, so the tabs and the sidebar agree on order.
    public var portfolioAccounts: [AccountNode] {
        guard let book else { return [] }
        var seen = Set<GncGUID>()
        var out: [AccountNode] = []
        for node in securityAccountNodes {
            guard let parent = book.account(with: node.id)?.parent,
                  let parentNode = accountNode(for: parent.guid),
                  seen.insert(parent.guid).inserted else { continue }
            out.append(parentNode)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The securities held in one portfolio — the commodities of the security
    /// accounts directly beneath it.
    public func securityCommodities(inPortfolio id: GncGUID) -> Set<Commodity> {
        guard let book, let parent = book.account(with: id) else { return [] }
        return Set(parent.children
            .filter { $0.type.isSecurityType }
            .map(\.commodity))
    }

    /// The `AccountNode` for one account, found in the same tree the pickers
    /// read so a portfolio row carries the balance and colour the rest of the
    /// app shows for it.
    private func accountNode(for id: GncGUID) -> AccountNode? {
        func find(_ nodes: [AccountNode]) -> AccountNode? {
            for node in nodes {
                if node.id == id { return node }
                if let children = node.children, let hit = find(children) { return hit }
            }
            return nil
        }
        return find(accountTree)
    }

    /// Cash / settlement accounts (bank, cash, other assets).
    public var settlementAccountNodes: [AccountNode] {
        postableAccounts.filter { ["Bank", "Cash", "Asset"].contains($0.typeName) }
    }

    /// Income accounts (for dividends).
    public var incomeAccountNodes: [AccountNode] {
        postableAccounts.filter { $0.typeName == "Income" }
    }

    /// Expense accounts (for commission / fees).
    public var expenseAccountNodes: [AccountNode] {
        postableAccounts.filter { $0.typeName == "Expense" }
    }

    // MARK: Recording

    /// Records a security transaction built by ``StockTransaction`` and adds it
    /// to the book (`FR-INV-05`).
    ///
    /// - Parameters carry share/price/amount/commission as appropriate for
    ///   `action`; unused ones are ignored. The transaction currency is the
    ///   settlement account's commodity.
    @discardableResult
    public func recordStockTransaction(
        action: StockActionKind,
        securityID: GncGUID?,
        settlementID: GncGUID?,
        incomeID: GncGUID? = nil,
        commissionID: GncGUID? = nil,
        shares: Decimal = 0,
        pricePerShare: Decimal = 0,
        amount: Decimal = 0,
        commission: Decimal = 0,
        splitNew: Decimal = 0,
        splitOld: Decimal = 0,
        date: Date,
        description: String,
        memo: String = "",
        reference: String = ""
    ) throws -> GncGUID {
        guard let book else { throw StockEntryError.noBook }
        let commissionAccount = commissionID.flatMap { book.account(with: $0) }

        let txn: Transaction
        switch action {
        case .buy:
            guard let security = securityID.flatMap({ book.account(with: $0) }),
                  let cash = settlementID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard shares > 0, pricePerShare > 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.buy(
                security: security, cash: cash, commissionAccount: commissionAccount,
                shares: shares, pricePerShare: pricePerShare, commission: commission,
                date: date, currency: cash.commodity, description: description, memo: memo)

        case .sell:
            guard let security = securityID.flatMap({ book.account(with: $0) }),
                  let cash = settlementID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard shares > 0, pricePerShare > 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.sell(
                security: security, cash: cash, commissionAccount: commissionAccount,
                shares: shares, pricePerShare: pricePerShare, commission: commission,
                date: date, currency: cash.commodity, description: description, memo: memo)

        case .dividend:
            guard let income = incomeID.flatMap({ book.account(with: $0) }),
                  let cash = settlementID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard amount > 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.dividend(
                income: income, cash: cash, amount: amount,
                date: date, currency: cash.commodity, description: description, memo: memo)

        case .reinvestDividend:
            guard let income = incomeID.flatMap({ book.account(with: $0) }),
                  let security = securityID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard amount > 0, shares > 0 else { throw StockEntryError.invalidInput }
            // The reinvested dividend is denominated in the income account's
            // currency (the cash that would otherwise have been received).
            txn = StockTransaction.reinvestDividend(
                income: income, security: security, shares: shares, amount: amount,
                date: date, currency: income.commodity, description: description, memo: memo)

        case .split:
            guard let security = securityID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard splitNew > 0, splitOld > 0 else { throw StockEntryError.invalidInput }
            let current = book.costBasis(for: security).remainingQuantity
            guard current > 0 else { throw StockEntryError.invalidInput }
            let added = current * (splitNew / splitOld - 1)
            guard added != 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.stockSplit(
                security: security, addedShares: added,
                date: date, currency: reportCurrency, description: description, memo: memo)

        case .returnOfCapital:
            guard let security = securityID.flatMap({ book.account(with: $0) }),
                  let cash = settlementID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard amount > 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.returnOfCapital(
                security: security, cash: cash, amount: amount,
                date: date, currency: cash.commodity, description: description, memo: memo)
        }

        guard txn.isBalanced else { throw StockEntryError.invalidInput }
        editing([txn.guid], named: "Add Stock Transaction") {
            // The broker's FITID rides in `online_id`, exactly as cash imports
            // stamp it — it is the only thing that lets a re-imported
            // overlapping statement recognise an already-posted trade
            // (investment rows never pass through the cash matcher).
            if !reference.isEmpty {
                txn.splits.first?.kvp["online_id"] = .string(reference)
            }
            book.addTransaction(txn)
        }
        return txn.guid
    }
}
