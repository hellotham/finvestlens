//
//  CheckRepair.swift
//  FinvestLens — FeatureUI
//
//  GnuCash-style Check & Repair (`FR-IMP-08`): after a GnuCash import — or
//  on demand from the Book menu — inconsistencies are tallied and offered
//  for one-click cleanup. Nothing is changed until the user chooses to.
//  Also home to the GnuCash account-colour parsing (`color` slot).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// What Check & Repair found, for review before anything is touched.
public struct CleanupProposal: Identifiable, Sendable {
    public let id = UUID()
    /// Transactions that move no money (zero-value "Opening Balance" stubs).
    public var emptyCount = 0
    /// Splits with no account.
    public var orphanCount = 0
    /// Transactions whose splits don't sum to zero.
    public var unbalancedCount = 0
    /// Transactions with a single (non-zero) split.
    public var degenerateCount = 0
    /// Transactions posted in a year nobody could have meant, with the years
    /// themselves — the year *is* the finding, and there are never many.
    ///
    /// Reported, never repaired: which year was intended exists only in the
    /// owner's head, and a wrong guess moves real money to a real period. The
    /// same reason `--cash-account` is required rather than inferred.
    public var implausibleDates: [Int] = []
    /// Import summary shown when the proposal follows a GnuCash import.
    public var importNote: String?

    public var isEmpty: Bool {
        emptyCount + orphanCount + unbalancedCount + degenerateCount
            + implausibleDates.count == 0
    }

    /// Whether Clean Up would actually do anything — false when the only
    /// findings are ones the app refuses to guess at, so the button can say so
    /// instead of promising a repair it will not perform.
    public var hasRepairableIssues: Bool {
        emptyCount + orphanCount + unbalancedCount + degenerateCount > 0
    }
}

extension AppModel {

    /// Tallies the open book's issues, or `nil` when there is nothing to fix.
    func cleanupProposal(importNote: String? = nil) -> CleanupProposal? {
        guard let book else { return nil }
        var proposal = CleanupProposal(importNote: importNote)
        for issue in Scrub.check(book) {
            switch issue {
            case .emptyTransaction: proposal.emptyCount += 1
            case .orphanSplit: proposal.orphanCount += 1
            case .unbalancedTransaction: proposal.unbalancedCount += 1
            case .degenerateTransaction: proposal.degenerateCount += 1
            case let .implausibleDate(_, date):
                proposal.implausibleDates.append(DatePlausibility.year(of: date))
            }
        }
        return proposal.isEmpty ? nil : proposal
    }

    /// Book ▸ Check & Repair: present findings, or report a clean bill.
    public func checkAndRepair() {
        guard isOpen else { return }
        if let proposal = cleanupProposal() {
            pendingCleanup = proposal
        } else {
            infoMessage = "No inconsistencies found — the book is clean."
        }
    }

    /// Applies the repairs (remove empties, house orphans, post imbalances)
    /// and reports what was done.
    public func applyCleanup() {
        guard let book else { return }
        // One `editingWholeBook` around the whole scrub, so the repairs undo as
        // a single action however many transactions they touched — and because
        // the scrub also files orphans under new accounts.
        var cleaned: Scrub.CleanupSummary?
        editingWholeBook(named: "Repair Book") {
            cleaned = Scrub.clean(book)
        }
        guard let summary = cleaned else { return }
        pendingCleanup = nil
        var parts: [String] = []
        if summary.emptiesRemoved > 0 { parts.append("removed \(summary.emptiesRemoved) empty transaction(s)") }
        if summary.orphansAssigned > 0 { parts.append("filed \(summary.orphansAssigned) split(s) under Orphan") }
        if summary.transactionsBalanced > 0 { parts.append("balanced \(summary.transactionsBalanced) transaction(s) via Imbalance") }
        infoMessage = parts.isEmpty
            ? "Nothing needed fixing."
            : "Clean-up complete: " + parts.joined(separator: ", ") + "."
    }

    // MARK: Account colours

    /// The GnuCash colour string of an account, if set.
    public func accountColor(_ id: GncGUID) -> String? {
        book?.account(with: id)?.color
    }

    /// Sets (or clears, with `nil`) an account's colour.
    public func setAccountColor(_ id: GncGUID, colorString: String?) {
        guard let book, let account = book.account(with: id),
              account.color != colorString else { return }
        editingWholeBook(named: "Change Account Colour") {
            account.color = colorString
        }
    }
}

// MARK: - GnuCash colour strings

/// Parses and writes GnuCash account-colour strings: `rgb(144,144,238)`,
/// `#8fbc8f`, `#fff`, and GTK's 16-bit `#rrrrggggbbbb`.
enum GnuCashColor {

    static func color(from text: String) -> Color? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("rgb") {
            let numbers = trimmed.drop(while: { $0 != "(" }).dropFirst()
                .prefix(while: { $0 != ")" })
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 3 else { return nil }
            return Color(.sRGB, red: numbers[0] / 255, green: numbers[1] / 255,
                         blue: numbers[2] / 255)
        }
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            let perChannel = hex.count / 3
            guard [1, 2, 4].contains(perChannel), hex.count == perChannel * 3,
                  hex.allSatisfy({ $0.isHexDigit }) else { return nil }
            let max = Double(1 << (perChannel * 4)) - 1
            var channels: [Double] = []
            var cursor = hex.startIndex
            for _ in 0..<3 {
                let next = hex.index(cursor, offsetBy: perChannel)
                channels.append(Double(Int(hex[cursor..<next], radix: 16) ?? 0) / max)
                cursor = next
            }
            return Color(.sRGB, red: channels[0], green: channels[1], blue: channels[2])
        }
        return nil
    }

    /// Serialises a colour in the `rgb(r,g,b)` form GnuCash writes.
    static func gnuCashString(from color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        #if os(macOS)
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        converted.getRed(&red, green: &green, blue: &blue, alpha: nil)
        #else
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil)
        #endif
        func clamp(_ v: CGFloat) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
        return "rgb(\(clamp(red)),\(clamp(green)),\(clamp(blue)))"
    }
}

// MARK: - Sheet

/// Review-and-confirm sheet for Check & Repair findings.
public struct CheckRepairSheet: View {
    @Bindable var model: AppModel
    let proposal: CleanupProposal
    @Environment(\.dismiss) private var dismiss

    public init(model: AppModel, proposal: CleanupProposal) {
        self.model = model
        self.proposal = proposal
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let note = proposal.importNote {
                    Section {
                        Label(note, systemImage: "square.and.arrow.down")
                    }
                }
                Section("Inconsistencies found") {
                    if proposal.emptyCount > 0 {
                        row(count: proposal.emptyCount, icon: "tray",
                            title: "Empty transactions",
                            detail: "Move no money — typically “Opening Balance” stubs GnuCash leaves for accounts created without a balance. Cleaning removes them.")
                    }
                    if proposal.orphanCount > 0 {
                        row(count: proposal.orphanCount, icon: "questionmark.folder",
                            title: "Splits without an account",
                            detail: "Cleaning files them under an Orphan account, as GnuCash does.")
                    }
                    if proposal.unbalancedCount > 0 {
                        row(count: proposal.unbalancedCount, icon: "scalemass",
                            title: "Unbalanced transactions",
                            detail: "Cleaning posts the difference to an Imbalance account, as GnuCash does.")
                    }
                    if proposal.degenerateCount > 0 {
                        row(count: proposal.degenerateCount, icon: "rectangle.dashed",
                            title: "Single-split transactions",
                            detail: "Cleaning adds the balancing Imbalance split.")
                    }
                    if !proposal.implausibleDates.isEmpty {
                        row(count: proposal.implausibleDates.count, icon: "calendar.badge.exclamationmark",
                            title: "Transactions in an impossible year",
                            detail: "Posted in \(yearList). A mistyped year still balances and still reconciles — it just leaves the period it belongs to, so it disappears from every report that bounds by date. Search for the year to find them. Cleaning leaves these alone: only you know which year was meant.")
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("The same repairs as GnuCash’s Check & Repair. Nothing changes unless you choose Clean Up — you can also run this later from Book ▸ Repair Book.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Repair Book")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep As Is") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clean Up") { model.applyCleanup() }
                        // Nothing here is repairable when the only finding is a
                        // date the app refuses to guess at; an enabled button
                        // would promise a repair it will not perform.
                        .disabled(!proposal.hasRepairableIssues)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    /// The offending years, deduplicated and ordered — "1525", or "0025 and
    /// 1525" — so the reader has something to search for.
    private var yearList: String {
        Set(proposal.implausibleDates).sorted()
            .map { String(format: "%04d", $0) }
            .formatted(.list(type: .and))
    }

    /// `title` and `detail` are `LocalizedStringKey`, not `String`.
    ///
    /// They were `String`, which is the trap CLAUDE.md ▸ Localization names:
    /// `Text(detail)` then picks the *verbatim* initializer, the compiler emits
    /// no key, and the catalog audit comes back green because there is nothing
    /// to be missing. Every row of this sheet was English in all eight
    /// languages. `\(Text(title))` keeps the count and title in one string so
    /// translators can reorder them.
    private func row(count: Int, icon: String,
                     title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) \(Text(title))").scaledFont(.body, weight: .medium)
                Text(detail).scaledFont(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}
