//
//  StarterChart.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A default personal chart of accounts for onboarding (`FR-COA-03`,
/// `FR-PLAN-09`). Category names align with ``MerchantHeuristics`` so imported
/// transactions auto-categorise out of the box.
///
/// In the reader's language: a book the app starts for someone is theirs, and
/// GnuCash's own account templates are written in each language it ships in.
/// The heuristics look for a category by the reader's name and then by the
/// English one, so a book started either way is found
/// (``MerchantHeuristics/localizedName(ofCategory:)``).
enum StarterChart {

    /// A node to create: name, type, and index of its parent in the flat list
    /// (`nil` = top level).
    struct Node { let name: String; let type: AccountType; let parent: Int? }

    static let nodes: [Node] = {
        var list: [Node] = []
        func add(_ name: String, _ type: AccountType, parent: Int? = nil) -> Int {
            list.append(Node(name: name, type: type, parent: parent)); return list.count - 1
        }
        let assets = add(String(localized: "Assets"), .asset)
        _ = add(String(localized: "Cheque Account"), .bank, parent: assets)
        _ = add(String(localized: "Savings"), .bank, parent: assets)
        _ = add(String(localized: "Cash"), .cash, parent: assets)

        let liabilities = add(String(localized: "Liabilities"), .liability)
        _ = add(String(localized: "Credit Card"), .credit, parent: liabilities)

        let equity = add(String(localized: "Equity"), .equity)
        _ = add(String(localized: "Opening Balances"), .equity, parent: equity)

        let income = add(String(localized: "Income"), .income)
        for name in [String(localized: "Salary"), String(localized: "Interest"), String(localized: "Other Income")] { _ = add(name, .income, parent: income) }

        let expenses = add(String(localized: "Expenses"), .expense)
        for name in [String(localized: "Groceries"), String(localized: "Dining"), String(localized: "Fuel"), String(localized: "Transport"), String(localized: "Rent"), String(localized: "Utilities"),
                     String(localized: "Phone & Internet"), String(localized: "Subscriptions"), String(localized: "Health"), String(localized: "Insurance"),
                     String(localized: "Shopping"), String(localized: "Entertainment"), String(localized: "Other Expenses")] {
            _ = add(name, .expense, parent: expenses)
        }
        return list
    }()
}

@MainActor
extension AppModel {

    /// Creates the starter chart of accounts in the current book if it is empty
    /// (`FR-COA-03`). Returns the number of accounts created.
    @discardableResult
    public func createStarterAccounts() -> Int {
        guard book != nil else { return 0 }
        var ids: [GncGUID?] = []
        for node in StarterChart.nodes {
            let parentID = node.parent.flatMap { ids[$0] }
            let id = addAccount(name: node.name, type: node.type,
                                commodity: reportCurrency, parentID: parentID)
            ids.append(id)
        }
        return ids.compactMap { $0 }.count
    }
}
