//
//  RegisterGrid.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  One transaction, drawn one way, in every state it can be in.
//
//  A register line has two independent axes, and this file is the single
//  layout that covers all four combinations:
//
//    * **compact** or **expanded** — one line, or the transaction opened out
//      into its splits (Auto-Split, the Journal, and Edit Transaction).
//    * **at rest** or **editable** — whether its cells are text or fields.
//
//  Auto-Split and Journal are therefore not separate views: they are the
//  expanded row at rest, and editing one of their transactions only makes the
//  cells live. Nothing moves.
//
//  **Nothing may move when a cell becomes editable.** Every cell reserves the
//  same box whether it is showing text or a field, and editing adds no lines:
//  Add/Remove Split live in the Balance column of a split line (blank there
//  anyway), the out-of-balance warning takes the Balance cell of the
//  transaction line, and there are no Save/Cancel buttons — ⏎ saves, ⎋ cancels.
//
//  Split lines use GnuCash's own column mapping, so the grid never breaks:
//  Action under Date, Account under Description, Memo under Transfer, and the
//  leg's own amount under Amount.
//

import SwiftUI
import FinvestLensEngine

// MARK: - Column metric

/// Column widths as clamped proportions of the register's measured width, so
/// the grid rescales continuously as the window resizes: every column grows
/// with available space up to a cap, never shrinks below what its content
/// needs, and Description (the one unconstrained column) takes the rest.
///
/// Shared by every surface that draws a transaction, so a row looks the same
/// wherever it appears.
struct RegisterMetrics: Equatable {
    /// The width of the grid, quantised by the caller so a live resize does not
    /// recompute on every pixel.
    var width: CGFloat
    /// The app's Dynamic-Type-ish scale (Settings ▸ Appearance).
    var scale: CGFloat = 1

    // Responsive folds. Nothing is ever clipped: as width shrinks, columns
    // *fold into extra lines* of the surviving columns rather than truncate —
    // Account/Transfer under the description, then Balance under the amount,
    // then Date under the description. The thresholds guarantee the remaining
    // columns' minimum widths always fit.
    var showsSide: Bool { width >= 640 * scale }
    var showsBalance: Bool { width >= 500 * scale }
    var showsDate: Bool { width >= 380 * scale }

    private func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(value, lo * scale), hi * scale)
    }

    var date: CGFloat { clamp(width * 0.09, 74, 120) }
    var account: CGFloat { clamp(width * 0.14, 70, 240) }
    var transfer: CGFloat { clamp(width * 0.16, 80, 300) }
    var reconcile: CGFloat { 24 * scale }
    var amount: CGFloat { clamp(width * 0.10, 78, 160) }
    var balance: CGFloat { clamp(width * 0.11, 86, 170) }

    /// The edit handle's column, between Date and Description. A column of its
    /// own rather than something floating inside the description: it is always
    /// laid out, so a row gaining or losing it moves nothing.
    var handle: CGFloat { 22 * scale }

    /// The indent a split line's account sits at, under the description.
    var splitIndent: CGFloat { 14 * scale }
    /// Horizontal padding inside a row, matching the list's own inset.
    var rowInset: CGFloat { 8 }

    // A cell reserves the same box whether it is text or a field. These are the
    // numbers that make that true — they are used by *both* states, and are the
    // reason entering edit mode does not move anything.
    var cellPaddingH: CGFloat { 6 }
    var cellPaddingV: CGFloat { 3 }
    var cellCorner: CGFloat { 5 }
}

/// Which field a click, Tab, or Edit Transaction wants the cursor in.
/// How much of each transaction the register discloses. Modelled on GnuCash's
/// `SplitRegisterStyle` (split-register.h:186 — `REG_STYLE_LEDGER`,
/// `REG_STYLE_AUTO_LEDGER`, `REG_STYLE_JOURNAL`), but disclosing *all* of a
/// transaction's detail rather than only its splits.
///
/// GnuCash keeps a separate `use_double_line` flag that reveals one field
/// (Notes). We had copied that as a "Show Details" toggle, and it was a poor
/// bargain: a whole switch for a single field, orthogonal to a second control
/// that revealed the splits, so a transaction's detail arrived in two
/// unrelated halves. One disclosure now reveals the lot — notes, tags, and
/// every leg with its memo, action and share/foreign quantity.
public enum RegisterStyle: String, CaseIterable, Identifiable, Sendable {
    /// One line per transaction; only the row you disclose by hand opens.
    /// GnuCash's per-transaction expand flag
    /// (`gnc_split_register_expand_current_trans`).
    case basic
    /// The selected transaction discloses its detail automatically; every
    /// other row stays on one line. `REG_STYLE_AUTO_LEDGER`.
    case autoDetails
    /// Every transaction shows its full detail, always. `REG_STYLE_JOURNAL`.
    case journal

    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .basic: "Basic Ledger"
        case .autoDetails: "Auto Details"
        case .journal: "Transaction Journal"
        }
    }

    public var symbol: String {
        switch self {
        case .basic: "list.dash"
        case .autoDetails: "rectangle.expand.vertical"
        case .journal: "list.bullet.indent"
        }
    }

    /// Whether a row can be disclosed by hand. GnuCash's expand call is a
    /// no-op outside Basic (split-register.c:251) — the other two styles have
    /// already decided what is open.
    public var allowsManualExpand: Bool { self == .basic }
}

enum TransactionEditField: Hashable {
    case date, number, description, transfer, amount, notes, tags
    /// The transaction's own currency, which need not be any account's.
    ///
    /// GnuCash keeps one currency per transaction (`xaccTransGetCurrency`) and
    /// expresses every split's `value` in it, so a foreign purchase on a local
    /// card is a local-account transaction denominated abroad — not two
    /// currencies, and not a clearing account.
    case currency
    /// GnuCash's `RATE_CELL` (`split-register.h:211`): local units per one
    /// unit of the transaction currency. An accelerator, not a stored field —
    /// the rate lives in the splits as `value`/`quantity`.
    case rate
    case splitAccount(UUID), splitMemo(UUID), splitAction(UUID), splitAmount(UUID)
    /// GnuCash's RATE_CELL — the foreign quantity on an FX or security leg.
    case splitQuantity(UUID)
}

// MARK: - The cell

/// One cell of the register grid — a **real text field, always present**,
/// sharing one `FocusState` cursor with every other cell.
///
/// The single-cursor invariant is GnuCash's (`gnucash-item-edit.c`: one
/// `GtkEntry` for the whole sheet), but the enforcement is SwiftUI's native
/// one: a shared `@FocusState` enum decides which field holds focus, and only
/// the focused field draws a ring — every other field is indistinguishable
/// from drawn text. Conjuring the field on demand and then focusing it by
/// hand was the previous design; the dummy-data harness (RegisterLab) proved
/// it fought the platform twice over — clicks never reached conjured fields
/// inside a selected `List` row, and self-assigned focus raced. Real fields
/// plus one focus enum is the pattern Apple's own `focused(_:equals:)`
/// documentation teaches.
///
/// The live field is gated on `isEditable`: an unselected row renders drawn
/// text, so a click passes straight through to the row's own selection tap —
/// your spec's "selecting a field within an already selected transaction
/// makes it editable".
///
/// A cell keeps the same box in every state, so moving the cursor moves
/// nothing.
struct RegisterCell: View {
    let value: String
    var placeholder: LocalizedStringKey = ""
    var alignment: TextAlignment = .leading
    var monospaced = false
    var muted = false
    /// Whether this cell can take the cursor (its row is selected/edited).
    var isEditable = true
    /// This cell's identity in the shared cursor.
    var field: TransactionEditField?
    /// The shared cursor — one per register surface.
    var cursor: FocusState<TransactionEditField?>.Binding?
    /// Called when the cell takes focus, before any keystroke — the register
    /// uses it to promote the row to the edit draft.
    var onFocus: () -> Void = {}
    /// Called as the text changes, writing into the draft.
    var onEdit: (String) -> Void = { _ in }
    let metrics: RegisterMetrics

    @State private var draft: String

    init(value: String, placeholder: LocalizedStringKey = "",
         alignment: TextAlignment = .leading, monospaced: Bool = false,
         muted: Bool = false, isEditable: Bool = true,
         field: TransactionEditField? = nil,
         cursor: FocusState<TransactionEditField?>.Binding? = nil,
         metrics: RegisterMetrics,
         onFocus: @escaping () -> Void = {},
         onEdit: @escaping (String) -> Void = { _ in }) {
        self.value = value
        self.placeholder = placeholder
        self.alignment = alignment
        self.monospaced = monospaced
        self.muted = muted
        self.isEditable = isEditable
        self.field = field
        self.cursor = cursor
        self.metrics = metrics
        self.onFocus = onFocus
        self.onEdit = onEdit
        _draft = State(initialValue: value)
    }

    private var isFocused: Bool {
        field != nil && cursor?.wrappedValue == field
    }

    var body: some View {
        content
            .scaledFont(.body)
            .monospacedDigit(monospaced)
            .foregroundStyle(muted && !isFocused ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(.primary))
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.horizontal, metrics.cellPaddingH)
            .padding(.vertical, metrics.cellPaddingV)
            .overlay { focusRing }
    }

    @ViewBuilder
    private var content: some View {
        if isEditable, let field, let cursor {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .focused(cursor, equals: field)
                // Never hit-testable: under a NavigationSplitView detail a
                // direct click on a field in a lazy scroll container fails to
                // acquire focus (lab-verified), while programmatic FocusState
                // assignment always succeeds. So the row maps the tap to a
                // cell and assigns focus — GnuCash's own
                // gnucash_sheet_find_cell_by_pixel, one layer up.
                .allowsHitTesting(false)
                .onChange(of: isFocused) { _, now in
                    if now { draft = value; onFocus() }
                }
                .onChange(of: draft) { _, now in if isFocused { onEdit(now) } }
                .onChange(of: value) { _, now in if !isFocused { draft = now } }
                .accessibilityLabel(Text(placeholder))
        } else {
            cellText
        }
    }

    private var cellText: some View {
        Text(value.isEmpty ? " " : value)
    }

    private var frameAlignment: Alignment {
        alignment == .trailing ? .trailing : .leading
    }

    /// Nothing at rest; a ring and nothing else when this cell is the cursor.
    /// `.tint` as a ShapeStyle, per CLAUDE.md ▸ Theming — the banned accent
    /// API would resolve the asset catalog, not the app's live tint.
    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: metrics.cellCorner)
                .strokeBorder(.tint, lineWidth: 2)
        }
    }
}

private extension View {
    @ViewBuilder
    func monospacedDigit(_ on: Bool) -> some View {
        if on { self.monospacedDigit() } else { self }
    }
}

// MARK: - Tap → cell

/// What a tap on a register row means. The register applies it: moving the
/// cursor, toggling expansion, cycling reconcile, editing splits.
enum RegisterRowTap: Equatable {
    case selectOnly
    case cursor(TransactionEditField)
    case expandToggle
    case cycleReconcile
    case removeSplit(Int)
    case appendSplit
    case none
}

/// GnuCash's `gnucash_sheet_find_cell_by_pixel`, as a pure function.
///
/// Taps are delivered to the register at the row's outer edge — the one
/// position the AppKit bridge reliably feeds (a gesture attached *inside* the
/// row's own hierarchy under a `NavigationSplitView` detail never fires;
/// dummy-harness-verified) — so the row's geometry has to be arithmetic, not
/// hit-testing. Columns mirror the row's layout exactly; lines are weighted
/// bands (caption lines are shorter than body lines), scaled to the row's
/// rendered height, which keeps the mapping true under Dynamic Type.
enum RegisterTapMap {

    static func target(point: CGPoint, rowSize: CGSize,
                       metrics: RegisterMetrics,
                       draft: TransactionDraft?,
                       isExpanded: Bool, showsSecondLine: Bool,
                       showsAccountColumn: Bool, showsBalanceColumn: Bool,
                       focusAccountID: GncGUID?,
                       accounts: [AccountNode], currencyCode: String,
                       restSplitCount: Int) -> RegisterRowTap {
        let x = point.x - metrics.rowInset
        let width = rowSize.width - 2 * metrics.rowInset

        // The lines this row is showing, top to bottom, with height weights.
        enum Line { case main, notes, labels, split(Int), addSplit }
        var lines: [(Line, CGFloat)] = [(.main, 1.0)]
        if isExpanded || showsSecondLine { lines.append((.notes, 0.82)) }
        if isExpanded {
            lines.append((.labels, 0.82))
            let count = draft?.lines.count ?? restSplitCount
            for index in 0..<max(count, 0) { lines.append((.split(index), 1.0)) }
            if draft != nil { lines.append((.addSplit, 0.9)) }
        }
        let totalWeight = lines.reduce(0) { $0 + $1.1 }
        let unit = rowSize.height / max(totalWeight, 0.001)
        var top: CGFloat = 0
        var hit: Line = .main
        for (line, weight) in lines {
            let bottom = top + weight * unit
            if point.y < bottom { hit = line; break }
            top = bottom
            hit = line   // clamp to the last line
        }

        switch hit {
        case .main:
            return mainLine(x: x, width: width, metrics: metrics, draft: draft,
                            showsAccountColumn: showsAccountColumn,
                            showsBalanceColumn: showsBalanceColumn,
                            focusAccountID: focusAccountID)
        case .notes:
            guard draft != nil || showsSecondLine else { return .selectOnly }
            let tagsStart = width - 172
            return .cursor(x >= tagsStart ? .tags : .notes)
        case .labels:
            return .none
        case .split(let index):
            return splitLine(x: x, width: width, metrics: metrics, draft: draft,
                             index: index, showsAccountColumn: showsAccountColumn,
                             showsBalanceColumn: showsBalanceColumn,
                             accounts: accounts, currencyCode: currencyCode)
        case .addSplit:
            return draft != nil ? .appendSplit : .selectOnly
        }
    }

    private static func mainLine(x: CGFloat, width: CGFloat,
                                 metrics: RegisterMetrics,
                                 draft: TransactionDraft?,
                                 showsAccountColumn: Bool,
                                 showsBalanceColumn: Bool,
                                 focusAccountID: GncGUID?) -> RegisterRowTap {
        var edge: CGFloat = 0
        if metrics.showsDate {
            edge += metrics.date
            if x < edge { return .cursor(.date) }
        }
        edge += metrics.handle
        if x < edge { return .expandToggle }
        edge += descriptionWidth(width: width, metrics: metrics,
                                 showsAccountColumn: showsAccountColumn,
                                 showsBalanceColumn: showsBalanceColumn)
        if x < edge { return .cursor(.description) }
        if metrics.showsSide, showsAccountColumn {
            edge += metrics.account
            if x < edge { return .selectOnly }   // this account's own column
        }
        if metrics.showsSide {
            edge += metrics.transfer
            if x < edge { return .cursor(.transfer) }
        }
        edge += metrics.reconcile
        if x < edge { return .cycleReconcile }
        edge += metrics.amount
        if x < edge { return .cursor(.amount) }
        return .none   // balance column
    }

    private static func splitLine(x: CGFloat, width: CGFloat,
                                  metrics: RegisterMetrics,
                                  draft: TransactionDraft?, index: Int,
                                  showsAccountColumn: Bool,
                                  showsBalanceColumn: Bool,
                                  accounts: [AccountNode],
                                  currencyCode: String) -> RegisterRowTap {
        guard let draft, draft.lines.indices.contains(index) else { return .selectOnly }
        let line = draft.lines[index]
        var edge: CGFloat = 0
        if metrics.showsDate {
            edge += metrics.date
            if x < edge { return .cursor(.splitAction(line.id)) }
        }
        edge += metrics.handle
        if x < edge { return .none }
        edge += descriptionWidth(width: width, metrics: metrics,
                                 showsAccountColumn: showsAccountColumn,
                                 showsBalanceColumn: showsBalanceColumn)
        if x < edge { return .cursor(.splitMemo(line.id)) }
        if metrics.showsSide, showsAccountColumn {
            edge += metrics.account
            if x < edge { return .none }
        }
        if metrics.showsSide {
            edge += metrics.transfer
            if x < edge { return .cursor(.splitAccount(line.id)) }
        }
        edge += metrics.reconcile
        if x < edge { return draft.lines.count > 2 ? .removeSplit(index) : .none }
        edge += metrics.amount
        if x < edge { return .cursor(.splitAmount(line.id)) }
        if showsBalanceColumn, let id = line.accountID,
           let node = accounts.first(where: { $0.id == id }),
           node.currencyCode != currencyCode {
            return .cursor(.splitQuantity(line.id))
        }
        return .none
    }

    /// The description column's share — everything the fixed columns leave.
    static func descriptionWidth(width: CGFloat, metrics: RegisterMetrics,
                                 showsAccountColumn: Bool,
                                 showsBalanceColumn: Bool) -> CGFloat {
        var fixed: CGFloat = metrics.handle + metrics.reconcile + metrics.amount
        if metrics.showsDate { fixed += metrics.date }
        if metrics.showsSide, showsAccountColumn { fixed += metrics.account }
        if metrics.showsSide { fixed += metrics.transfer }
        if showsBalanceColumn { fixed += metrics.balance }
        return max(60, width - fixed)
    }
}

// MARK: - Tab capture

/// ⇥ / ⇧⇥ for the register's cursor. On macOS the Tab key belongs to AppKit's
/// key-view loop and is consumed before any SwiftUI `onKeyPress` on the
/// focused field can see it — which is why the per-cell handlers, correct as
/// they are on iOS hardware keyboards, did nothing on the Mac. An event-level
/// monitor takes the key while a draft is active and hands it to the
/// register's own traversal (GnuCash does the same thing one layer down:
/// `gnucash-sheet.c` intercepts `GDK_KEY_Tab` before GTK's focus chain).
struct TabCaptureModifier: ViewModifier {
    let active: Bool
    let onTab: (_ backwards: Bool) -> Void

    #if os(macOS)
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, now in
                if now, monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        guard event.keyCode == 48 else { return event }   // ⇥
                        onTab(event.modifierFlags.contains(.shift))
                        return nil                                        // consumed
                    }
                } else if !now, let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}

extension View {
    /// Routes ⇥ / ⇧⇥ to `onTab` while `active` — the register's cursor
    /// traversal. Inactive, the key belongs to the system again.
    func captureTabs(while active: Bool,
                     onTab: @escaping (_ backwards: Bool) -> Void) -> some View {
        modifier(TabCaptureModifier(active: active, onTab: onTab))
    }
}

// MARK: - The draft

/// A transaction being edited. Held by the register, not by a row, so the same
/// draft serves editing one cell in place and editing every field opened out —
/// they are the same edit, seen at two levels of detail.
///
/// `Equatable` is load-bearing, not cosmetic: rows receive `draft` through a
/// binding, and SwiftUI can only skip re-rendering a row when it can prove
/// the value unchanged. Without the conformance every register pass
/// re-rendered every visible row (`_draft changed`, ~650 times in six
/// seconds at idle) — the churn that made clicks laggy and intermittent.
struct TransactionDraft: Equatable {
    var transactionID: GncGUID
    var date: Date
    /// GnuCash's Num — a cheque number or an imported bank reference.
    var number: String
    var description: String
    var notes: String
    var tagsText: String
    var lines: [EditableSplit]
    /// An FX transaction's currency is its own fact — re-deriving it from the
    /// accounts would re-save the values in the wrong unit.
    var currencyOverride: Commodity?
    /// What is typed in the Currency cell. Kept beside the resolved commodity
    /// so a half-typed or unknown code stays on screen instead of vanishing —
    /// the cell can then be reported as wrong rather than silently ignored.
    var currencyText: String = ""
    /// What is typed in the Rate cell, while it is being typed. Empty means
    /// "show what the splits imply" (``impliedRate``), which is the truth once
    /// both figures exist.
    var rateText: String = ""
    /// Whether the row is opened out. Clicking a cell edits in place (`false`);
    /// Edit Transaction opens it out (`true`).
    var isExpanded: Bool

    @MainActor
    init?(model: AppModel, transactionID: GncGUID, expanded: Bool) {
        guard let edit = model.editData(forTransaction: transactionID) else { return nil }
        self.transactionID = transactionID
        date = edit.date
        number = edit.number
        description = edit.description
        notes = edit.notes
        tagsText = edit.tags.joined(separator: ", ")
        lines = edit.splits.map { EditableSplit($0) }
        let derived = model.transactionCurrency(for: edit.splits.compactMap(\.accountID))
        currencyOverride = edit.currency == derived ? nil : edit.currency
        currencyText = currencyOverride?.mnemonic ?? ""
        isExpanded = expanded
    }

    /// A draft assembled by a host that owns its own state — the modal editor,
    /// whose prefill/adopt/invoice flows write the same fields. Same shape, no
    /// book read, always opened out.
    init(transactionID: GncGUID, date: Date, number: String = "",
         description: String, notes: String,
         tagsText: String, lines: [EditableSplit], currencyOverride: Commodity?) {
        self.transactionID = transactionID
        self.date = date
        self.number = number
        self.description = description
        self.notes = notes
        self.tagsText = tagsText
        self.lines = lines
        self.currencyOverride = currencyOverride
        self.currencyText = currencyOverride?.mnemonic ?? ""
        self.isExpanded = true
    }

    var parsedTags: [String] {
        tagsText.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The residual over the legs that will actually be **posted**.
    ///
    /// Only lines carrying an account count, because only those are submitted:
    /// `commit` sends `lines.filter { $0.accountID != nil }`. Summing every
    /// line instead made the draft disagree with the save. `appendLine` opens
    /// the new leg pre-filled with the residual and no account yet, so the sum
    /// over all lines reached zero, `isBalanced` went true, the out-of-balance
    /// warning cleared and ⏎ was accepted — and then `updateTransaction`
    /// rejected the very same edit as unbalanced, because the accountless leg
    /// carrying the residual was never in the payload.
    var imbalance: Decimal {
        lines.reduce(Decimal(0)) { $0 + ($1.accountID == nil ? 0 : $1.amount) }
    }
    var validLineCount: Int { lines.filter { $0.accountID != nil }.count }
    var isBalanced: Bool {
        imbalance == 0 && validLineCount >= 2 && lines.allSatisfy(\.quantityIsValid)
            && currencyIsValid
    }

    // MARK: Currency (`FR-CUR-02`, `FR-REG-07`)

    /// Whether the typed currency code names a currency.
    ///
    /// Blank is valid and means "derive from the accounts" — the ordinary
    /// same-currency transaction, where a code would be noise.
    var currencyIsValid: Bool {
        let trimmed = currencyText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || currencyOverride != nil
    }

    /// The rate the two figures imply, local units per one foreign unit.
    ///
    /// Derived from the splits rather than stored, so it cannot go stale:
    /// `value` is in the transaction (foreign) currency and `quantity` in the
    /// account's own, exactly as GnuCash defines them (`Split.h:251-265`), so
    /// their ratio *is* the rate. `nil` when the transaction is single-currency
    /// or no leg has been given both figures yet.
    var impliedRate: Decimal? {
        guard currencyOverride != nil else { return nil }
        for line in lines where line.accountID != nil {
            let foreign = line.amount
            guard foreign != 0, let local = line.quantity, local != 0 else { continue }
            return local / foreign
        }
        return nil
    }

    /// Takes the transaction into (or out of) a foreign currency, moving the
    /// figures rather than reinterpreting them.
    ///
    /// Switching an AUD 600 transaction to MYR must not silently mean "600
    /// MYR" — the 600 is what left the account, so it becomes each leg's
    /// `quantity` and the `value` is cleared for the foreign figure. Clearing
    /// the currency puts them back. This is the same move `applyFx` makes in
    /// the editor sheet, so both routes produce one structure.
    mutating func setCurrency(_ currency: Commodity?, text: String) {
        currencyText = text
        let wasForeign = currencyOverride != nil
        let isForeign = currency != nil
        guard wasForeign != isForeign else { currencyOverride = currency; return }
        for index in lines.indices {
            if isForeign {
                // Local figures move to the quantity; value awaits the foreign.
                if lines[index].quantityText.isEmpty {
                    lines[index].quantityText = lines[index].amountText
                    lines[index].amountText = ""
                }
            } else if !lines[index].quantityText.isEmpty {
                lines[index].amountText = lines[index].quantityText
                lines[index].quantityText = ""
            }
        }
        currencyOverride = currency
    }

    /// Fills every foreign leg's value from its local amount at `rate` — the
    /// accelerator GnuCash spells `RATE_CELL` (`split-register.h:211`).
    ///
    /// The rate is local-per-foreign (1 MYR = 0.3383 AUD), so the foreign
    /// figure is `local / rate`. Legs already carrying a value are left alone:
    /// a rate typed after the amounts is a check, not an overwrite.
    mutating func applyRate(_ rate: Decimal, rounding foreign: Commodity?) {
        guard rate != 0 else { return }
        for index in lines.indices {
            guard let local = lines[index].quantity, local != 0,
                  lines[index].amountText.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            let value = local / rate
            let rounded = foreign?.round(value) ?? value
            lines[index].amountText = NSDecimalNumber(decimal: rounded).stringValue
        }
    }

    /// Writes an amount and, on a plain two-leg transaction, mirrors the
    /// negation onto the other leg — GnuCash's recalculation for a two-split
    /// transaction, which is what keeps "type the new amount, press ⏎" a
    /// complete edit instead of a silent imbalance. The mirror stays out of the
    /// way the moment the transaction is anything more: extra legs, an explicit
    /// currency, or a leg carrying its own quantity (FX / securities).
    mutating func setAmountText(_ text: String, at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines[index].amountText = text
        guard lines.count == 2, currencyOverride == nil else { return }
        let other = index == 0 ? 1 : 0
        guard lines[other].quantityText.isEmpty, lines[index].quantityText.isEmpty else { return }
        let value = lines[index].amount
        lines[other].amountText = value == 0 && lines[index].amountText.isEmpty
            ? "" : NSDecimalNumber(decimal: -value).stringValue
    }

    /// The leg for the register's own account — what the transaction line's
    /// Amount cell is a second view of.
    func focusIndex(account: GncGUID?) -> Int? {
        guard let account else { return lines.indices.first }
        return lines.firstIndex { $0.accountID == account } ?? lines.indices.first
    }

    /// The counterparty, for the Transfer cell: meaningful only when there is
    /// exactly one other leg. More than that and the cell says "— Split —" and
    /// the answer is on the lines below, where it belongs.
    func counterpartyIndex(account: GncGUID?) -> Int? {
        guard lines.count == 2, let focus = focusIndex(account: account) else { return nil }
        return lines.indices.first { $0 != focus }
    }

    /// The visible fields in visual order — what ⇥ walks. Derived from the
    /// same switches that decide what is drawn, so a folded column is never a
    /// tab stop (GnuCash's `gnc_table_move_tab` likewise skips cells that
    /// refuse the cursor). In-place editing walks the transaction line; an
    /// opened-out draft continues onto its split lines.
    /// `expandedOnScreen` is the *row's* state, not the draft's own flag: in
    /// Show All Splits a draft edits its split lines on screen while
    /// `isExpanded` stays false, and the tab order must follow what is drawn.
    func fieldOrder(metrics: RegisterMetrics,
                    expandedOnScreen: Bool,
                    showsSecondLine: Bool,
                    showsBalanceColumn: Bool,
                    focusAccountID: GncGUID?,
                    accounts: [AccountNode],
                    currencyCode: String) -> [TransactionEditField] {
        var fields: [TransactionEditField] = []
        if metrics.showsDate { fields.append(.date) }
        fields.append(.description)
        // The Transfer combo stays on the transaction line whenever there is
        // exactly one counterparty — GnuCash's MXFRM does too, opened out or
        // not.
        if metrics.showsSide, counterpartyIndex(account: focusAccountID) != nil {
            fields.append(.transfer)
        }
        fields.append(.amount)
        if expandedOnScreen || showsSecondLine {
            fields.append(.notes)
            fields.append(.tags)
        }
        if expandedOnScreen {
            for line in lines {
                if metrics.showsDate { fields.append(.splitAction(line.id)) }
                fields.append(.splitMemo(line.id))
                if metrics.showsSide { fields.append(.splitAccount(line.id)) }
                fields.append(.splitAmount(line.id))
                if showsBalanceColumn, let id = line.accountID,
                   let node = accounts.first(where: { $0.id == id }),
                   node.currencyCode != currencyCode {
                    fields.append(.splitQuantity(line.id))
                }
            }
        }
        return fields
    }

    /// The next tab stop. Wraps within the transaction — one deliberate
    /// divergence from GnuCash, whose ⇥ at the last cell commits the row and
    /// moves on: Return is this register's commit, and a key that both moves
    /// and saves would make the cheapest key on the keyboard a destructive one.
    func nextField(after current: TransactionEditField?, backwards: Bool,
                   in order: [TransactionEditField]) -> TransactionEditField? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return order.first
        }
        return backwards
            ? order[index == 0 ? order.count - 1 : index - 1]
            : order[(index + 1) % order.count]
    }
}
