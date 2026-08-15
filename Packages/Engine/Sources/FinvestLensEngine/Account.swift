//
//  Account.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A node in the chart of accounts.
///
/// Accounts form a tree rooted at ``Book/rootAccount``. Each account is
/// denominated in a ``Commodity`` and carries a stable ``GncGUID``. Accounts do
/// not hold their splits directly; balances are computed by the ``Book`` that
/// owns the transactions (see `Book.balance(of:)`). This keeps ownership acyclic
/// (`Book → Transaction → Split → Account`).
public final class Account {

    /// Stable identity, preserved across GnuCash round-trips.
    public let guid: GncGUID
    public var name: String
    public var type: AccountType
    public var code: String
    public var accountDescription: String
    public var notes: String
    public var commodity: Commodity

    /// A placeholder account holds no postings directly (a grouping node).
    public var isPlaceholder: Bool
    /// Hidden accounts are excluded from most default views.
    public var isHidden: Bool

    /// Preserved key-value slots (including keys not modelled natively).
    public var kvp: KvpFrame

    /// The account's display colour, stored in GnuCash's `color` slot (e.g.
    /// `"rgb(144,144,238)"` or `"#8fbc8f"`), so it round-trips untouched.
    /// GnuCash's "Not Set" sentinel reads as `nil`.
    public var color: String? {
        get {
            guard case let .string(text)? = kvp[Self.colorKey],
                  !text.isEmpty, text != "Not Set" else { return nil }
            return text
        }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespaces)
            kvp[Self.colorKey] = (cleaned?.isEmpty ?? true) ? nil : .string(cleaned!)
        }
    }
    private static let colorKey = "color"

    /// The bank's own identifier for this account, as carried by its statement
    /// files — GnuCash's `online_id` slot, so a book shared with GnuCash keeps
    /// working in both and the slot round-trips untouched.
    ///
    /// Written once, when a statement is imported here; matched against on
    /// every later import so the same account is chosen without asking
    /// (`xaccAccountSetOnlineID`, `gnucash/import-export/import-account-matcher.cpp`).
    public var onlineID: String? {
        get {
            guard case let .string(text)? = kvp[Self.onlineIDKey], !text.isEmpty else { return nil }
            return text
        }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespaces)
            kvp[Self.onlineIDKey] = (cleaned?.isEmpty ?? true) ? nil : .string(cleaned!)
        }
    }
    private static let onlineIDKey = "online_id"

    /// Where this account sits among its siblings when the sidebar is sorted by
    /// hand (`FR-NAV-12`).
    ///
    /// In the account's own kvp so it round-trips like everything else. GnuCash
    /// has no such slot and will ignore it, which is the right failure mode: a
    /// book edited there comes back with the order intact and GnuCash never had
    /// to understand it. `nil` clears the slot rather than writing a sentinel,
    /// so an account never sorted by hand carries nothing at all.
    public var sidebarOrder: Int? {
        get {
            if case let .int64(n)? = kvp[Self.sidebarOrderKey] { return Int(n) }
            return nil
        }
        set {
            kvp[Self.sidebarOrderKey] = newValue.map { .int64(Int64($0)) }
        }
    }
    private static let sidebarOrderKey = "finvestlens-sidebar-order"

    /// Whether this account is flagged for tax reporting (GnuCash's `tax-related`
    /// slot, stored as an integer 1/0 so it round-trips untouched). Setting it
    /// `false` clears the slot rather than writing a 0, matching GnuCash.
    public var taxRelated: Bool {
        get {
            if case let .int64(n)? = kvp[Self.taxRelatedKey] { return n != 0 }
            return false
        }
        set { kvp[Self.taxRelatedKey] = newValue ? .int64(1) : nil }
    }
    private static let taxRelatedKey = "tax-related"

    /// The account's tax category code (GnuCash's `tax-US/code`, e.g. an ATO or
    /// TXF line code). Held in the `tax-US` frame so it survives a round-trip.
    public var taxCode: String? {
        get {
            if case let .frame(frame)? = kvp[Self.taxFrameKey],
               case let .string(code)? = frame[Self.taxCodeKey], !code.isEmpty {
                return code
            }
            return nil
        }
        set {
            var frame: KvpFrame
            if case let .frame(existing)? = kvp[Self.taxFrameKey] { frame = existing }
            else { frame = KvpFrame() }
            let cleaned = newValue?.trimmingCharacters(in: .whitespaces)
            frame[Self.taxCodeKey] = (cleaned?.isEmpty ?? true) ? nil : .string(cleaned!)
            kvp[Self.taxFrameKey] = frame.isEmpty ? nil : .frame(frame)
        }
    }
    private static let taxFrameKey = "tax-US"
    private static let taxCodeKey = "code"

    /// Whether this is one of GnuCash's holding accounts for postings that have
    /// nowhere else to go — `Imbalance-<CUR>` or `Orphan-<CUR>`, as created by
    /// ``Scrub``.
    ///
    /// They are typed `.bank`, so type alone cannot tell them apart from a real
    /// account, but no money sits in them: they are a to-do list. Anything
    /// choosing an account *for* the user should look past them.
    public var isImbalanceOrOrphan: Bool {
        name.hasPrefix("Imbalance") || name.hasPrefix("Orphan")
    }

    /// Whether postings here are "parked" rather than categorised: the
    /// ``isImbalanceOrOrphan`` holding accounts plus the placeholder names
    /// imported books accumulate from years of hand-categorising elsewhere
    /// ("Unspecified", "Uncategorised", "Unknown").
    ///
    /// This is the one wash-account predicate — the import matcher, the
    /// Uncategorised review, and Smart Categorise all share it, so an account
    /// can never be wash to one of them and invisible to the others.
    public var isWash: Bool {
        if isImbalanceOrOrphan { return true }
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered == "unspecified" || lowered == "uncategorised"
            || lowered == "uncategorized" || lowered == "unknown"
    }

    /// The parent account, or `nil` for the root. Weak to avoid a retain cycle.
    public private(set) weak var parent: Account?
    /// Child accounts, owned strongly by this account.
    public private(set) var children: [Account]

    public init(
        guid: GncGUID = .random(),
        name: String,
        type: AccountType,
        commodity: Commodity,
        code: String = "",
        description: String = "",
        notes: String = "",
        isPlaceholder: Bool = false,
        isHidden: Bool = false,
        kvp: KvpFrame = KvpFrame()
    ) {
        self.guid = guid
        self.name = name
        self.type = type
        self.commodity = commodity
        self.code = code
        self.accountDescription = description
        self.notes = notes
        self.isPlaceholder = isPlaceholder
        self.isHidden = isHidden
        self.kvp = kvp
        self.children = []
    }

    // MARK: Tree structure

    /// `true` if this is a root account (no parent, `.root` type).
    public var isRoot: Bool { parent == nil && type == .root }

    /// Adds `child` under this account, reparenting it if necessary.
    @discardableResult
    public func addChild(_ child: Account) -> Account {
        child.parent?.removeChild(child)
        child.parent = self
        children.append(child)
        return child
    }

    /// Adds `child` at a specific position among the children (reparenting it if
    /// necessary). Used to restore an account to its exact former slot when a
    /// move is undone; the index is clamped to the current bounds.
    @discardableResult
    public func addChild(_ child: Account, at index: Int) -> Account {
        child.parent?.removeChild(child)
        child.parent = self
        children.insert(child, at: min(max(0, index), children.count))
        return child
    }

    /// Removes `child` if it is a direct child of this account.
    public func removeChild(_ child: Account) {
        guard child.parent === self else { return }
        children.removeAll { $0 === child }
        child.parent = nil
    }

    /// All descendant accounts (depth-first, excluding `self`).
    public var descendants: [Account] {
        children.flatMap { [$0] + $0.descendants }
    }

    /// Fully-qualified name, colon-delimited from the top-most non-root ancestor.
    public var fullName: String {
        guard let parent, !parent.isRoot else { return name }
        return parent.fullName + ":" + name
    }
}

extension Account: Identifiable {
    public var id: GncGUID { guid }
}

extension Account: Equatable, Hashable {
    public static func == (lhs: Account, rhs: Account) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
