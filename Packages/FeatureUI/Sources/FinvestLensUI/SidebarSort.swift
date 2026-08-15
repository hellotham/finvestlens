//
//  SidebarSort.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  How a mode's sidebar is ordered (`FR-NAV-12`).
//  Design: docs/navigation-design.md §4.6.
//

import SwiftUI
import UniformTypeIdentifiers
import FinvestLensEngine

/// How a sidebar section is ordered.
///
/// `manual` is not a criterion but the absence of one: it means "the order I
/// put them in", persisted in the account's own kvp so it survives a round trip
/// through GnuCash. Dragging is only offered under `manual` — dropping something
/// *between* two rows of a sorted list is a promise the sort would break on the
/// next redraw.
public enum SidebarSort: String, CaseIterable, Identifiable, Sendable {
    case manual, name, code, balance, type, opened

    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .manual: "Manual Order"
        case .name: "Name"
        case .code: "Account Code"
        case .balance: "Balance"
        case .type: "Type"
        case .opened: "First Transaction"
        }
    }

    /// Shown beside "First Transaction". The book has no opening-date field, so
    /// "opened" is derived from the earliest posting — which the UI has to say
    /// rather than imply (navigation-design §4.6).
    public var note: LocalizedStringKey? {
        switch self {
        case .opened: "Derived from the earliest transaction — the book records no opening date."
        default: nil
        }
    }

    /// Whether rows may be dragged under this order.
    ///
    /// Nothing reads this yet: the drag is off until the between-siblings
    /// reorder exists (see `ModeSidebar.draggableAccountRow`). It stays because
    /// it is the rule that gates it, not because it is wired.
    public var allowsDragging: Bool { self == .manual }

    /// The one definition of where a mode's sort is stored. The sidebar reads
    /// the same key through `@AppStorage`, so it must not be spelled twice.
    public static func storageKey(for mode: AppMode) -> String {
        "sidebar.sort.\(mode.rawValue)"
    }

    /// The criteria Accounts offers — all of them. Balance, code and the first
    /// transaction are facts about an *account*, so the other modes' lists keep
    /// the order their collections already have; a sort control over them would
    /// mostly offer criteria that cannot run.
    public static let accountCases: [SidebarSort] = allCases
}

@MainActor
extension AppModel {

    /// The sort in force for a mode. Desk state, per mode: how you arrange a
    /// list is not an accounting fact, and Accounts wanting balance order says
    /// nothing about how Planning should be arranged.
    public func sidebarSort(for mode: AppMode) -> SidebarSort {
        SidebarSort(rawValue:
            UserDefaults.standard.string(forKey: SidebarSort.storageKey(for: mode)) ?? "")
            ?? .manual
    }

    public func setSidebarSort(_ sort: SidebarSort, for mode: AppMode) {
        UserDefaults.standard.set(sort.rawValue, forKey: SidebarSort.storageKey(for: mode))
    }

    /// Orders one level of the account tree.
    ///
    /// Applied per level rather than to a flattened list: a tree sorted whole
    /// would reorder children against accounts that are not their siblings, and
    /// the manual order is stored per parent.
    public func sorted(_ nodes: [AccountNode], by sort: SidebarSort) -> [AccountNode] {
        let ordered: [AccountNode]
        switch sort {
        case .manual:
            // Accounts never dragged carry no slot, and fall to the end in the
            // order the book already has them — so turning manual order on
            // changes nothing until something is actually moved.
            ordered = nodes.enumerated().sorted { a, b in
                let x = manualOrder(of: a.element.id) ?? Int.max
                let y = manualOrder(of: b.element.id) ?? Int.max
                if x != y { return x < y }
                return a.offset < b.offset
            }.map(\.element)
        case .name:
            ordered = nodes.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .code:
            // An account with no code sorts after those that have one, rather
            // than ahead of everything under an empty string.
            ordered = nodes.sorted { a, b in
                let x = accountCode(a.id) ?? ""
                let y = accountCode(b.id) ?? ""
                if x.isEmpty != y.isEmpty { return y.isEmpty }
                if x != y { return x.localizedStandardCompare(y) == .orderedAscending }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .balance:
            ordered = nodes.sorted { $0.balance > $1.balance }
        case .type:
            ordered = nodes.sorted { a, b in
                if a.typeName != b.typeName { return a.typeName < b.typeName }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .opened:
            ordered = nodes.sorted { a, b in
                let x = firstTransactionDate(of: a.id) ?? .distantFuture
                let y = firstTransactionDate(of: b.id) ?? .distantFuture
                if x != y { return x < y }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        // Children follow the same rule, level by level.
        return ordered.map { node in
            guard let children = node.children else { return node }
            var copy = node
            copy.children = sorted(children, by: sort)
            return copy
        }
    }

    func manualOrder(of id: GncGUID) -> Int? {
        book?.account(with: id)?.sidebarOrder
    }

    func accountCode(_ id: GncGUID) -> String? {
        book?.account(with: id)?.code
    }

    /// The earliest posting in an account, memoised on the book revision: the
    /// sidebar asks per row on every body pass, and the answer only changes
    /// when the book does.
    func firstTransactionDate(of id: GncGUID) -> Date? {
        if firstPostingRevision != bookRevision {
            firstPostingCache = [:]
            firstPostingRevision = bookRevision
            for transaction in book?.transactions ?? [] {
                for split in transaction.splits {
                    guard let account = split.account else { continue }
                    let existing = firstPostingCache[account.guid]
                    if existing == nil || transaction.datePosted < existing! {
                        firstPostingCache[account.guid] = transaction.datePosted
                    }
                }
            }
        }
        return firstPostingCache[id]
    }

    /// Moves `id` to sit at `position` among its siblings, writing the whole
    /// level's order so the result does not depend on what was there before.
    ///
    /// A book edit, and undoable — the order round-trips through GnuCash XML in
    /// the account's kvp, so it is part of the document rather than desk state.
    public func reorderAccount(_ id: GncGUID, to position: Int) {
        guard let book, let account = book.account(with: id) else { return }
        let parent = account.parent ?? book.rootAccount
        var siblings = parent.children
        guard let from = siblings.firstIndex(where: { $0.guid == id }) else { return }
        let clamped = min(max(position, 0), siblings.count - 1)
        guard clamped != from else { return }
        // Scoped to the accounts it touches. `editingWholeBook` serialises the
        // whole book to GnuCash XML for its undo snapshot — 46k transactions for
        // a change of a dozen integers, and the whole-book snapshot CLAUDE.md
        // says undo must never take.
        editingAccounts(siblings.map(\.guid), named: "Reorder Accounts") {
            let moved = siblings.remove(at: from)
            siblings.insert(moved, at: clamped)
            for (index, sibling) in siblings.enumerated() {
                sibling.sidebarOrder = index
            }
        }
    }
}

/// What a dragged sidebar row carries.
///
/// A `Transferable` of our own rather than a plain string: the drop handler must
/// be able to tell an account being dragged within the sidebar from any text the
/// system happens to offer, or dropping a URL onto the tree would silently
/// re-parent nothing and look broken.
struct AccountDragPayload: Codable, Transferable, Sendable {
    let id: GncGUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .finvestLensAccountRow)
    }
}

extension UTType {
    static let finvestLensAccountRow = UTType(exportedAs: "com.hellotham.finvestlens.account-row")
}
