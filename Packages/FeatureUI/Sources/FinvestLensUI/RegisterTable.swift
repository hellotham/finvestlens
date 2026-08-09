//
//  RegisterTable.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The account register (FR-REG-03: **one register**) and the whole-book
//  journal (FR-REG-09: All Transactions, `wholeBook: true`) as a single
//  SwiftUI `Table` of flat rows — the architecture proven in the RegisterLab2
//  dummy-data harness on 8 Aug 2026 after the in-place row designs failed.
//
//  The interaction spec (memory/register-redesign-brief.md, transcript-agreed):
//
//   1. Opens with nothing selected.
//   2. Selecting a transaction highlights it (an even lavender row wash — the
//      app accent at 18% — painted at the NSTableView row level, never the
//      dark emphasized fill) and does not expand or edit anything.
//   3. Multi-/shift-selection is native Table behaviour.
//   4. Clicking a field inside the already-selected transaction edits that
//      field in place with zero layout shift; ⇥/⇧⇥ walk the visible fields
//      only; ⏎ saves, ⎋ cancels.
//   5. The selected transaction carries a control in a 22pt handle column
//      between Date and Description: a disclosure triangle in Basic Ledger,
//      where the row's detail is the user's to open, and the pencil that
//      opens the full edit (≡ right-click Edit Transaction… ≡ ⌘E) in the
//      styles that have already decided. Either becomes an ✕ while the edit
//      is expanded.
//   6. Edit Transaction expands the transaction into leg rows — every field,
//      including the foreign quantity on FX/security legs (FR-REG-07), plus
//      Add Split and per-leg remove.
//   7. **One disclosure reveals the lot** — the notes line, the tags line,
//      then every leg (`legRows(ofTransaction:)`, the focus account's own
//      included). ``RegisterStyle`` decides which rows are disclosed:
//      Journal every row, Auto Details the selected one, Basic only the row
//      the handle opened. This is the same line plan the macOS sheet draws
//      (RegisterSheet's `linePlan`/`isDisclosed`), so the two platforms
//      disclose the same set. Editing swaps live cells in under unchanged row
//      identities, so nothing moves.
//
//  Row identity rule: **headings are transactions, legs are splits** — the
//  anchor's own leg row can never collide with its heading (a duplicate Table
//  identity scrambles the diff; found the hard way in the harness).
//
//  Performance follows GnuCash's register (`split-register-load.c`): the row
//  *structure* is loaded once per data change into a revision-keyed cache —
//  never per interaction — and cells format lazily, so only the visible
//  handful pay for date/amount formatting. The per-pass compose applies
//  selection/draft state to the cached base with no book lookups and no
//  formatting. Editing is GnuCash's pending-transaction model
//  (`split-register-control.cpp`, `gnc_split_register_move_cursor`): leaving
//  a modified transaction commits it if balanced and bounces the cursor back
//  if not. Leg rows use the CURSOR_SPLIT column mapping
//  (`split-register-layout.c`): Action under Date, Memo under Description,
//  the Account under Transfer.
//

import SwiftUI
import FinvestLensEngine
#if os(macOS)
import AppKit
#endif

// MARK: - Identity

/// A register row's identity. Headings are transactions, legs are splits.
enum RegisterRowID: Hashable {
    case txn(GncGUID)
    /// A disclosed transaction's notes and tags lines. Rows of their own, the
    /// way the macOS sheet's line plan has them — the transaction's identity
    /// is enough to tell them apart from its heading.
    case notes(GncGUID)
    case tags(GncGUID)
    case split(GncGUID)
    /// A leg the user just added in this edit (draft line id).
    case draftLine(UUID)
    /// The trailing "Add Split" row of an expanded edit.
    case addSplit
}

/// One cell's identity in the shared focus cursor: which row, which field.
struct RegisterFocus: Hashable {
    var row: RegisterRowID
    var field: TransactionEditField
}

// MARK: - Base rows (loaded once per data change, GnuCash-style)

/// The register's raw structure: everything derivable from the book alone —
/// no selection, no draft, no formatted strings. Rebuilt only when the
/// revision-keyed fingerprint changes.
private struct RegisterBaseRow {
    enum Kind {
        case main(RegisterMainBase)
        case bookLeg(AutoSplitRow)
    }
    let id: RegisterRowID
    let txn: GncGUID
    let kind: Kind
}

private struct RegisterMainBase {
    var id: GncGUID
    var isHeadingOnly: Bool
    var date: Date
    var description: String
    var notes: String
    /// The transaction's tags, comma-joined — the second line a disclosure
    /// reveals, and what ``TransactionDraft/tagsText`` edits.
    var tags: String
    var reconcile: String
    var hasDocument: Bool
    /// Two legs, both in the transaction currency — the transfer combo case.
    var isSimple: Bool
    var transferName: String
    var amount: Decimal
    var runningBalance: Decimal?
}

/// Body-owned memo: identical keys return the cached array with zero work.
/// A reference type on purpose — refreshing it during a body pass must not
/// write SwiftUI state.
///
/// Two layers. The composed layer matters as much as the base one: returning
/// the *same array instance* for an unchanged (selection, draft) state lets
/// the Table skip its whole diff, so a focus move or an unrelated model
/// change costs nothing — GnuCash's "redraw only what changed".
@MainActor
private final class RegisterRowCache {
    private var baseKey: Int = .min
    private var base: [RegisterBaseRow] = []
    private var composedKey: Int = .min
    private var composed: [RegisterTableRow] = []

    /// `defaults write <bundle-id> FLRegisterTrace -bool true` logs base and
    /// compose timings from real usage to /tmp/fl-register-perf.log.
    let traceEnabled = UserDefaults.standard.bool(forKey: "FLRegisterTrace")

    func base(for key: Int, build: () -> [RegisterBaseRow]) -> [RegisterBaseRow] {
        if key != baseKey {
            base = timed("base") { build() }
            baseKey = key
        }
        return base
    }

    func composed(for key: Int, build: () -> [RegisterTableRow]) -> [RegisterTableRow] {
        if key != composedKey {
            composed = timed("compose") { build() }
            composedKey = key
        }
        return composed
    }

    private func timed<T>(_ label: String, _ work: () -> T) -> T {
        guard traceEnabled else { return work() }
        let start = ContinuousClock.now
        let result = work()
        let elapsed = ContinuousClock.now - start
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(label) \(elapsed)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/fl-register-perf.log") {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: "/tmp/fl-register-perf.log", atomically: false,
                            encoding: .utf8)
        }
        return result
    }
}

// MARK: - Render rows (per-pass compose: base + selection/draft state)

enum RegisterHandleState: Equatable {
    case hidden
    /// The pencil: opens the transaction right out (Add Split, per-leg
    /// remove). Shown where the style, not the user, decides disclosure.
    case edit
    /// The disclosure triangle — Basic Ledger only, where the row's detail is
    /// the user's to open.
    case disclose(open: Bool)
    case cancel
}

/// Which of a disclosed transaction's two text lines a row is.
enum RegisterDetailField: Hashable {
    case notes, tags

    /// The label the cell carries — HIG *Text fields*: a placeholder is not a
    /// label, so this is also the cell's accessibility label.
    var placeholder: LocalizedStringKey {
        switch self {
        case .notes: "Notes"
        case .tags: "Tags"
        }
    }

    var editField: TransactionEditField {
        switch self {
        case .notes: .notes
        case .tags: .tags
        }
    }
}

/// What a disclosed transaction's notes or tags line draws.
struct RegisterDetailRowData: Equatable {
    var field: RegisterDetailField
    var text: String
}

/// What a heading row's cells draw. Raw values — cells format on render, so
/// only visible cells pay.
struct RegisterMainRowData: Equatable {
    var id: GncGUID
    var isHeadingOnly: Bool
    var reconcile: String
    var hasDocument: Bool
    var drafting: Bool
    var handle: RegisterHandleState
    var date: Date
    var description: String
    var transferIsCombo: Bool
    var transferAccountID: GncGUID?
    var transferName: String?
    var transferStatic: String
    var amount: Decimal
    /// The raw text editing starts from while drafting (the focus line's
    /// amount text); the book amount otherwise.
    var amountEditText: String?
    var imbalance: Decimal
    var runningBalance: Decimal?
}

struct RegisterTableRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case main(RegisterMainRowData)
        case detail(RegisterDetailRowData)
        case bookLeg(AutoSplitRow)
        case draftLeg(line: EditableSplit, reconcile: String,
                      canRemove: Bool, quantityEditable: Bool)
        case addSplit
    }
    let id: RegisterRowID
    var selected: Bool
    var editable: Bool
    let kind: Kind

    // Sort handles for the sortable headers. Never applied to reorder rows —
    // the model sorts; see `tableSortOrder`.
    var sortDate: Date {
        if case .main(let data) = kind { return data.date }
        return .distantFuture
    }
    var sortDescription: String {
        if case .main(let data) = kind { return data.description }
        return ""
    }
    var sortAmount: Decimal {
        if case .main(let data) = kind { return data.amount }
        return 0
    }
}

// MARK: - The register table

struct RegisterTableView: View {
    @Bindable var model: AppModel
    /// FR-REG-09: All Transactions — the whole-book journal in this same view.
    var wholeBook = false
    /// ⌘↑/⌘↓ from the shell; consumed here.
    var jump: Binding<RegisterEnd?> = .constant(nil)
    @Environment(\.appDateFormat) private var dateFormat
    @Environment(\.appFontScale) private var appFontScale
    /// How tall a transaction row stands, and — because everything in the row
    /// is a multiple of it — how big its text and glyphs are.
    @AppStorage(AppearanceKey.registerRowHeight)
    private var rowHeightPreference = RegisterRowHeight.automatic

    /// The shared register style — all three of them. A `Table` can honour
    /// Auto Details as cheaply as Journal, because disclosure here is rows
    /// appearing in the composed array, not block geometry to reconcile.
    @AppStorage("registerViewStyle") private var registerStyle = RegisterStyle.basic
    /// Basic Ledger's hand-opened row: GnuCash's per-transaction
    /// `trans_expanded` (split-register.c) — one flag for the current
    /// transaction, dropped the moment the selection leaves it. The other two
    /// styles have already decided what is open, so the flag is theirs to
    /// ignore (`RegisterStyle.allowsManualExpand`).
    @State private var currentExpanded = false

    @State private var selection: Set<RegisterRowID> = []
    @FocusState private var cursor: RegisterFocus?
    /// The one transaction being edited, and the pristine copy that decides
    /// whether leaving it needs a commit at all.
    @State private var draft: TransactionDraft?
    @State private var original: TransactionDraft?
    /// The drafted transaction's heading row — where its heading cells live.
    @State private var anchorRow: RegisterRowID?
    /// Where the cursor last sat inside the draft — the bounce-back target.
    @State private var lastDraftCursor: RegisterFocus?
    @State private var saveError: String?
    @State private var cache = RegisterRowCache()
    /// Bumped on every draft mutation — the composed cache's draft dimension.
    @State private var editGeneration = 0
    /// A row to bring into view on the next pass (set after expansion, so the
    /// edited transaction never slides out of the viewport).
    @State private var scrollTarget: RegisterRowID?

    /// The style actually in force. All Transactions is a journal whatever the
    /// preference says — the same substitution the macOS sheet makes.
    private var style: RegisterStyle { wholeBook ? .journal : registerStyle }

    /// The row height at 100% Text Size.
    ///
    /// `automatic` is display-derived on macOS; iOS and iPadOS publish no
    /// physical screen size at all, and there Dynamic Type already carries the
    /// accessibility contract — `scaledFont` multiplies every register font by
    /// it — so `automatic` resolves to the 24pt base and the person's own text
    /// setting moves it from there.
    private var rowPoints: CGFloat {
        #if os(macOS)
        rowHeightPreference.points(on: NSScreen.main)
        #else
        rowHeightPreference.points(pointsPerInch: nil, screenHeight: nil)
        #endif
    }

    /// Published into the table's subtree so `scaledFont` grows the row's text
    /// and symbols with the row itself — a taller row is a bigger row, not the
    /// same small text with more air around it.
    private var rowFontScale: CGFloat {
        appFontScale * (rowPoints / RegisterRowHeight.base)
    }

    /// Journal only: every transaction is disclosed, so the base rows carry
    /// every leg. The other two styles disclose at most the selected
    /// transaction, whose legs come from its draft.
    private var disclosesEveryRow: Bool { style == .journal }

    /// Styles that disclose on selection arm the selected transaction with an
    /// invisible clean draft, so its cells edit in place with zero shift
    /// (spec 7). Basic arms when the handle opens the row instead.
    private var armsOnSelection: Bool { style != .basic }

    /// Whether a transaction shows its detail — notes, tags and legs. The
    /// whole of the style difference, and the mirror of the macOS sheet's
    /// `isDisclosed` (GnuCash's passive/active cursor choice,
    /// split-register-util.c:435-495).
    private func isDisclosed(txn: GncGUID, drafting: Bool,
                             selected: GncGUID?) -> Bool {
        if style == .journal { return true }
        if drafting, draft?.isExpanded == true { return true }
        guard selected == txn else { return false }
        return style == .autoDetails || currentExpanded
    }

    var body: some View {
        let rows = buildRows()
        table(rows, code: currencyCode)
            .captureTabs(while: draft != nil) { moveCursor(backwards: $0) }
            .onSubmit(of: .text) { saveEdit() }
            #if os(macOS)
            .onExitCommand { escapePressed() }
            #endif
            .onChange(of: selection) { before, now in
                selectionChanged(from: before, to: now)
            }
            .onChange(of: cursor) { _, now in cursorChanged(now) }
            .onChange(of: registerStyle) { settleAndReset(keepSelection: true) }
            .onChange(of: model.editingTransactionID) { _, id in
                guard let id, draft?.transactionID != id || draft?.isExpanded != true
                else { return }
                selection = [.txn(id)]
                open(id)
            }
            .alert("Couldn’t save", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onDisappear {
                // Leaving the destination mid-edit: best-effort commit,
                // GnuCash-style; an unbalanced edit is dropped.
                if let d = draft, d != original, d.isBalanced { try? commit(d) }
            }
    }

    // MARK: Table

    private func table(_ rows: [RegisterTableRow], code: String) -> some View {
        ScrollViewReader { proxy in
            Table(rows, selection: $selection, sortOrder: tableSortOrder) {
                // The row's height floor rides on the first column: a `Table`
                // row is as tall as its tallest cell, so one `minHeight` sets
                // the lot without touching the other six.
                TableColumn("Date", value: \.sortDate) {
                    dateCell($0).frame(minHeight: rowPoints * appFontScale)
                }
                .width(96)
                // The edit-handle column: 22pt between Date and Description,
                // always laid out, so the pencil appearing moves nothing.
                TableColumn("") { handleCell($0) }
                    .width(22)
                TableColumn("Description", value: \.sortDescription) { descriptionCell($0) }
                TableColumn("Transfer") { transferCell($0) }
                    .width(200)
                TableColumn("R") { reconcileCell($0) }
                    .width(26)
                TableColumn("Amount", value: \.sortAmount) { amountCell($0, code: code) }
                    .width(110)
                    .alignment(.numeric)
                TableColumn("Balance") { balanceCell($0, code: code) }
                    .width(120)
                    .alignment(.numeric)
            }
            .environment(\.appFontScale, rowFontScale)
            .scrollEdgeEffectStyle(.hard, for: .top)
            #if os(macOS)
            // Selection *interaction* stays native; drawing is ours: the
            // probe paints zebra and the even lavender selection wash at the
            // NSTableRowView level, from SwiftUI's own selection (AppKit's
            // index set goes stale once its drawing is disabled).
            .background(RegisterTableStyleProbe(
                selectedIndices: IndexSet(rows.enumerated().compactMap {
                    selection.contains($0.element.id) ? $0.offset : nil
                }),
                tick: paintTick(rows)))
            #endif
            .contextMenu(forSelectionType: RegisterRowID.self) { ids in
                let splitIDs = Set(ids.compactMap(splitID(of:)))
                TransactionActions(model: model, splitID: splitIDs.first,
                                   selectionSplitIDs: splitIDs)
            }
            .accessibilityRotor("Unreconciled") {
                ForEach(model.unreconciledRegisterRows) { row in
                    if let txn = model.transactionID(ofSplit: row.id) {
                        AccessibilityRotorEntry(row.description, id: RegisterRowID.txn(txn))
                    }
                }
            }
            .onAppear { showPendingOrNewest(proxy, rows: rows) }
            .onChange(of: model.selectedAccountID) {
                settleAndReset()
                Task { @MainActor in showPendingOrNewest(proxy, rows: buildRows()) }
            }
            .onChange(of: model.pendingRegisterSplitID) {
                showPendingOrNewest(proxy, rows: rows)
            }
            .onChange(of: jump.wrappedValue) { _, target in
                guard let target else { return }
                scroll(proxy, to: target, rows: rows)
                jump.wrappedValue = nil
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                // Minimal scroll (no anchor): just enough to keep the row on
                // screen after leg rows push heights around.
                proxy.scrollTo(target)
                scrollTarget = nil
            }
        }
    }

    private func paintTick(_ rows: [RegisterTableRow]) -> Int {
        var tick = selection.hashValue
        tick = tick &* 31 &+ rows.count
        tick = tick &* 31 &+ (draft != nil ? 1 : 0)
        return tick
    }

    /// Click-to-sort, kept honest with the Sort menu: both read and write
    /// ``AppModel/registerSort``. The comparator itself is never applied —
    /// the model sorts, and the binding is just the header's handle on it.
    private var tableSortOrder: Binding<[KeyPathComparator<RegisterTableRow>]> {
        Binding(
            get: {
                switch model.registerSort {
                case .date: [KeyPathComparator(\RegisterTableRow.sortDate,
                                               order: model.registerSortReversed ? .reverse : .forward)]
                case .description: [KeyPathComparator(\RegisterTableRow.sortDescription,
                                                      order: model.registerSortReversed ? .reverse : .forward)]
                case .amount: [KeyPathComparator(\RegisterTableRow.sortAmount,
                                                 order: model.registerSortReversed ? .reverse : .forward)]
                default: []
                }
            },
            set: { comparators in
                guard let first = comparators.first else {
                    model.registerSort = .standard
                    model.registerSortReversed = false
                    return
                }
                if first.keyPath == \RegisterTableRow.sortDate { model.registerSort = .date }
                else if first.keyPath == \RegisterTableRow.sortDescription { model.registerSort = .description }
                else if first.keyPath == \RegisterTableRow.sortAmount { model.registerSort = .amount }
                model.registerSortReversed = first.order == .reverse
            })
    }

    /// Lands on the row a jump asked for, or the newest when nothing did.
    private func showPendingOrNewest(_ proxy: ScrollViewProxy, rows: [RegisterTableRow]) {
        guard !wholeBook, let target = model.consumePendingRegisterSelection(),
              let txn = model.transactionID(ofSplit: target),
              rows.contains(where: { $0.id == .txn(txn) }) else {
            if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            return
        }
        selection = [.txn(txn)]
        proxy.scrollTo(RegisterRowID.txn(txn), anchor: .center)
    }

    private func scroll(_ proxy: ScrollViewProxy, to end: RegisterEnd,
                        rows: [RegisterTableRow]) {
        let target = end == .newest ? rows.last?.id : rows.first?.id
        guard let target else { return }
        proxy.scrollTo(target, anchor: end == .newest ? .bottom : .top)
    }

    // MARK: Cells (formatting happens here — visible cells only)

    @ViewBuilder
    private func dateCell(_ row: RegisterTableRow) -> some View {
        switch row.kind {
        case .main(let data):
            GridCell(restValue: dateFormat.short(data.date), placeholder: "Date",
                     isEditable: row.editable,
                     focus: RegisterFocus(row: row.id, field: .date), cursor: $cursor,
                     onEdit: { text in
                         withDraft { if let date = dateFormat.parseShort(text) { $0.date = date } }
                     },
                     onEscape: { escapePressed() })
        case .bookLeg(let leg):
            restText(leg.legAction, muted: true)
        case .draftLeg(let line, _, _, _):
            GridCell(restValue: line.action, placeholder: "Action", muted: true,
                     isEditable: row.editable,
                     focus: RegisterFocus(row: row.id, field: .splitAction(line.id)),
                     cursor: $cursor,
                     onEdit: { text in withLine(line.id) { $0.action = text } },
                     onEscape: { escapePressed() })
        case .detail, .addSplit:
            restText("")
        }
    }

    @ViewBuilder
    private func handleCell(_ row: RegisterTableRow) -> some View {
        if case .main(let data) = row.kind, data.handle != .hidden {
            Button {
                switch data.handle {
                case .cancel: escapePressed()
                case .disclose: toggleDisclosure()
                case .edit, .hidden: editExpanded()
                }
            } label: {
                Image(systemName: handleSymbol(data.handle))
                    .imageScale(.medium)
                    .fontWeight(.semibold)
                    // The app's accent, matching the macOS sheet's caret and
                    // pencil. `.secondary` measured 3.88:1 on the register's
                    // own alternating rows — a technical WCAG 1.4.11 pass
                    // that read as invisible; every selectable accent now
                    // measures at least 3.2:1 on the same backgrounds.
                    .foregroundStyle(data.handle == .cancel
                                     ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help(handleHelp(data.handle))
            .accessibilityLabel(handleLabel(data.handle))
        } else {
            restText("")
        }
    }

    /// HIG *Disclosure controls*: the triangle "points inward from the leading
    /// edge when its content is hidden and down when its content is visible" —
    /// the pair the macOS sheet draws (`SheetSymbols.caretClosed/caretOpen`).
    private func handleSymbol(_ state: RegisterHandleState) -> String {
        switch state {
        case .hidden: ""
        // Filled, matching the macOS sheet: the outline pencil measured 32%
        // ink against the solid caret's 42% and read as faint beside it.
        // SF Symbols has no filled pencil (`pencil.fill` and
        // `square.and.pencil.fill` do not exist), so the chunkiest non-disc
        // pencil is this one at semibold — 87.1 alpha-weighted ink mass
        // against the bare `pencil`'s 22.3.
        case .edit: "square.and.pencil"
        case .disclose(let open): open ? "arrowtriangle.down.fill"
                                       : "arrowtriangle.right.fill"
        case .cancel: "xmark.circle.fill"
        }
    }

    private func handleHelp(_ state: RegisterHandleState) -> LocalizedStringKey {
        switch state {
        case .hidden: ""
        case .edit: "Edit Transaction (⌘E)"
        case .disclose(let open): open ? "Hide Details" : "Show Details"
        case .cancel: "Cancel Edit (⎋)"
        }
    }

    private func handleLabel(_ state: RegisterHandleState) -> LocalizedStringKey {
        switch state {
        case .hidden: ""
        case .edit: "Edit Transaction"
        case .disclose(let open): open ? "Hide Details" : "Show Details"
        case .cancel: "Cancel Edit"
        }
    }

    @ViewBuilder
    private func descriptionCell(_ row: RegisterTableRow) -> some View {
        switch row.kind {
        case .main(let data):
            HStack(spacing: 4) {
                if data.hasDocument {
                    Image(systemName: "paperclip")
                        .imageScale(.medium)
                        .fontWeight(.bold)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Has attachment")
                }
                GridCell(restValue: data.description,
                         placeholder: "Description",
                         isEditable: row.editable,
                         focus: RegisterFocus(row: row.id, field: .description),
                         cursor: $cursor,
                         onEdit: { text in withDraft { $0.description = text } },
                         onEscape: { escapePressed() })
            }
        case .detail(let detail):
            // Notes and tags sit under the description, GnuCash's own column
            // for them (split-register-layout.c, and the macOS sheet's
            // `cellIndex` mapping both lines to the description column).
            GridCell(restValue: detail.text,
                     placeholder: detail.field.placeholder, muted: true,
                     isEditable: row.editable,
                     focus: RegisterFocus(row: row.id, field: detail.field.editField),
                     cursor: $cursor,
                     onEdit: { text in
                         withDraft { draft in
                             switch detail.field {
                             case .notes: draft.notes = text
                             case .tags: draft.tagsText = text
                             }
                         }
                     },
                     onEscape: { escapePressed() })
        case .bookLeg(let leg):
            restText(leg.legMemo, muted: true)
        case .draftLeg(let line, _, _, _):
            GridCell(restValue: line.memo, placeholder: "Memo", muted: true,
                     isEditable: row.editable,
                     focus: RegisterFocus(row: row.id, field: .splitMemo(line.id)),
                     cursor: $cursor,
                     onEdit: { text in withLine(line.id) { $0.memo = text } },
                     onEscape: { escapePressed() })
        case .addSplit:
            Label("Add Split", systemImage: "plus.circle")
                .scaledFont(.body)
                .foregroundStyle(.secondary)
                .accessibilityHint("Adds a split line to the edited transaction")
        }
    }

    @ViewBuilder
    private func transferCell(_ row: RegisterTableRow) -> some View {
        switch row.kind {
        case .main(let data):
            if data.transferIsCombo {
                ComboCell(accountID: data.transferAccountID,
                          displayName: data.transferAccountID == nil ? data.transferName : nil,
                          placeholder: "Transfer",
                          nodes: model.postableAccounts,
                          isEditable: row.editable,
                          focus: RegisterFocus(row: row.id, field: .transfer),
                          cursor: $cursor,
                          onPick: { id in
                              withDraft { d in
                                  if let ci = d.counterpartyIndex(account: model.selectedAccountID) {
                                      d.lines[ci].accountID = id
                                  }
                              }
                          },
                          onReturn: { saveEdit() },
                          onEscape: { escapePressed() })
            } else {
                restText(data.transferStatic, muted: true)
            }
        case .bookLeg(let leg):
            restText(leg.legAccount, muted: true)
        case .draftLeg(let line, _, _, _):
            ComboCell(accountID: line.accountID,
                      nodes: model.postableAccounts,
                      isEditable: row.editable,
                      focus: RegisterFocus(row: row.id, field: .splitAccount(line.id)),
                      cursor: $cursor,
                      onPick: { id in withLine(line.id) { $0.accountID = id } },
                      onReturn: { saveEdit() },
                      onEscape: { escapePressed() })
        case .detail, .addSplit:
            restText("")
        }
    }

    @ViewBuilder
    private func reconcileCell(_ row: RegisterTableRow) -> some View {
        switch row.kind {
        case .main(let data) where !data.isHeadingOnly:
            ReconcileBadge(glyph: data.reconcile) {
                model.cycleReconcileState(splitID: data.id)
            }
        case .bookLeg(let leg):
            ReconcileBadge(glyph: leg.legReconcile) {
                model.cycleReconcileState(splitID: leg.id)
            }
        case .draftLeg(let line, let reconcile, _, _):
            if let splitID = line.splitID {
                ReconcileBadge(glyph: reconcile) {
                    model.cycleReconcileState(splitID: splitID)
                }
            } else {
                restText("")
            }
        default:
            restText("")
        }
    }

    @ViewBuilder
    private func amountCell(_ row: RegisterTableRow, code: String) -> some View {
        switch row.kind {
        case .main(let data) where data.isHeadingOnly:
            restText("")
        case .main(let data):
            GridCell(restValue: AmountFormat.string(data.amount, code: code),
                     editValue: data.amountEditText
                        ?? NSDecimalNumber(decimal: data.amount).stringValue,
                     placeholder: "Amount",
                     alignment: .trailing, monospaced: true,
                     negative: data.amount < 0,
                     isEditable: row.editable,
                     focus: RegisterFocus(row: row.id, field: .amount), cursor: $cursor,
                     onEdit: { text in
                         withDraft { d in
                             if let index = d.focusIndex(account: model.selectedAccountID) {
                                 d.setAmountText(text, at: index)
                             }
                         }
                     },
                     onEscape: { escapePressed() })
        case .bookLeg(let leg):
            restText(AmountFormat.string(leg.legAmount, code: leg.legCurrencyCode),
                     muted: true, trailing: true, monospaced: true,
                     negative: leg.legAmount < 0)
        case .draftLeg(let line, _, _, _):
            GridCell(restValue: AmountFormat.string(line.amount, code: draftCurrencyCode),
                     editValue: line.amountText,
                     placeholder: "Amount",
                     alignment: .trailing, monospaced: true,
                     negative: line.amount < 0,
                     isEditable: row.editable,
                     focus: RegisterFocus(row: row.id, field: .splitAmount(line.id)),
                     cursor: $cursor,
                     onEdit: { text in
                         withLineIndex(line.id) { d, index in d.setAmountText(text, at: index) }
                     },
                     onEscape: { escapePressed() })
        case .detail, .addSplit:
            restText("")
        }
    }

    @ViewBuilder
    private func balanceCell(_ row: RegisterTableRow, code: String) -> some View {
        switch row.kind {
        case .main(let data) where data.drafting && data.imbalance != 0:
            // The out-of-balance warning takes the Balance cell — a cell that
            // is already there, so no line appears.
            Label(AmountFormat.string(data.imbalance, code: draftCurrencyCode),
                  systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("Out of balance — the splits do not sum to zero")
        case .main(let data):
            if let balance = data.runningBalance {
                restText(AmountFormat.string(balance, code: code),
                         trailing: true, monospaced: true)
            } else {
                restText(data.isHeadingOnly ? "" : "—", muted: true, trailing: true)
            }
        case .draftLeg(let line, _, let canRemove, let quantityEditable):
            // GnuCash's RATE_CELL position: the foreign quantity edits in the
            // Balance column of an FX/security leg (FR-REG-07); remove sits
            // beside it. Both are blank otherwise, so nothing appears or moves.
            HStack(spacing: 2) {
                if quantityEditable {
                    GridCell(restValue: line.quantityText, placeholder: "Quantity",
                             alignment: .trailing, monospaced: true,
                             isEditable: row.editable,
                             focus: RegisterFocus(row: row.id, field: .splitQuantity(line.id)),
                             cursor: $cursor,
                             onEdit: { text in withLine(line.id) { $0.quantityText = text } },
                             onEscape: { escapePressed() })
                } else {
                    restText("")
                }
                if canRemove {
                    Button {
                        removeLine(line.id)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this split")
                    .accessibilityLabel("Remove Split")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        default:
            restText("")
        }
    }

    /// Rest text at the exact box a GridCell occupies, so columns never shift.
    private func restText(_ value: String, muted: Bool = false,
                          trailing: Bool = false, monospaced: Bool = false,
                          negative: Bool = false) -> some View {
        Text(value.isEmpty ? " " : value)
            .scaledFont(.body)
            .conditionallyMonospacedDigit(monospaced)
            .foregroundStyle(negative ? AnyShapeStyle(.red)
                             : muted ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(.primary))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .padding(.horizontal, 4)
    }

    // MARK: Base rows (once per data change)

    /// Everything that shapes the base structure, folded to one comparison.
    /// `bookRevision` covers edits; the row-count/end fingerprints cover
    /// account, sort, and filter changes.
    private var cacheKey: Int {
        var hasher = Hasher()
        hasher.combine(model.bookRevision)
        hasher.combine(wholeBook)
        hasher.combine(disclosesEveryRow)
        if wholeBook {
            hasher.combine(model.journalTransactions(forAccountID: nil).count)
        } else {
            hasher.combine(model.selectedAccountID)
            hasher.combine(model.registerSort)
            hasher.combine(model.registerSortReversed)
            hasher.combine(model.registerIncludesSubaccounts)
            let rows = model.registerRows
            hasher.combine(rows.count)
            hasher.combine(rows.first?.id)
            hasher.combine(rows.last?.id)
        }
        return hasher.finalize()
    }

    private func buildBase() -> [RegisterBaseRow] {
        wholeBook ? wholeBookBase() : accountBase()
    }

    private func accountBase() -> [RegisterBaseRow] {
        var out: [RegisterBaseRow] = []
        let mains = model.autoSplitRows(expanding: nil, expandAll: false)
        out.reserveCapacity(disclosesEveryRow ? mains.count * 3 : mains.count)
        for row in mains {
            guard let main = row.main,
                  let txn = model.transactionID(ofSplit: main.id) else { continue }
            out.append(RegisterBaseRow(
                id: .txn(txn), txn: txn,
                kind: .main(RegisterMainBase(
                    id: main.id, isHeadingOnly: false,
                    date: main.date, description: main.description,
                    notes: main.notes,
                    tags: model.transactionTags(ofTransaction: txn)
                        .joined(separator: ", "),
                    reconcile: main.reconcile,
                    hasDocument: main.hasDocument,
                    isSimple: model.isSimpleTransfer(splitID: main.id),
                    transferName: main.transfer,
                    amount: main.amount,
                    runningBalance: main.runningBalance))))
            if disclosesEveryRow {
                for leg in model.legRows(ofTransaction: txn) {
                    out.append(RegisterBaseRow(id: .split(leg.id), txn: txn,
                                               kind: .bookLeg(leg)))
                }
            }
        }
        return out
    }

    private func wholeBookBase() -> [RegisterBaseRow] {
        var out: [RegisterBaseRow] = []
        for txn in model.journalTransactions(forAccountID: nil) {
            out.append(RegisterBaseRow(
                id: .txn(txn.guid), txn: txn.guid,
                kind: .main(RegisterMainBase(
                    id: txn.guid, isHeadingOnly: true,
                    date: txn.datePosted, description: txn.transactionDescription,
                    notes: txn.notes,
                    tags: txn.tags.joined(separator: ", "),
                    reconcile: "",
                    hasDocument: txn.documentLink != nil,
                    isSimple: false, transferName: "",
                    amount: 0, runningBalance: nil))))
            for leg in model.legRows(ofTransaction: txn.guid) {
                out.append(RegisterBaseRow(id: .split(leg.id), txn: txn.guid,
                                           kind: .bookLeg(leg)))
            }
        }
        return out
    }

    // MARK: Per-pass compose (no book lookups, no formatting)

    private func buildRows() -> [RegisterTableRow] {
        let baseKey = cacheKey
        var hasher = Hasher()
        hasher.combine(baseKey)
        hasher.combine(selection)
        hasher.combine(editGeneration)
        // Disclosure is composed, not based: Auto Details and a hand-opened
        // Basic row change which rows exist without changing the base.
        hasher.combine(style)
        hasher.combine(currentExpanded)
        return cache.composed(for: hasher.finalize()) {
            composeRows(base: cache.base(for: baseKey) { buildBase() })
        }
    }

    private func composeRows(base: [RegisterBaseRow]) -> [RegisterTableRow] {
        let selectedTxn = singleSelectedTransaction
        let draftTxn = draft?.transactionID
        var out: [RegisterTableRow] = []
        out.reserveCapacity(base.count + (draft?.lines.count ?? 0) + 3)
        for row in base {
            let drafting = draftTxn == row.txn
            let disclosed = isDisclosed(txn: row.txn, drafting: drafting,
                                        selected: selectedTxn)
            switch row.kind {
            case .main(let mainBase):
                let editable = selectedTxn == row.txn
                out.append(RegisterTableRow(
                    id: row.id,
                    selected: selection.contains(row.id),
                    editable: editable,
                    kind: .main(renderData(mainBase, drafting: drafting,
                                           editable: editable,
                                           disclosed: disclosed))))
                guard disclosed else { continue }
                // One disclosure, everything behind it: notes, tags, then
                // every leg — the macOS sheet's `linePlan`, row for row.
                // Unconditional: a disclosed row must be the same height
                // whether or not it is being edited, or selecting one shifts
                // everything below it.
                out.append(detailRow(.notes, txn: row.txn, editable: editable,
                                     text: drafting ? (draft?.notes ?? "")
                                                    : mainBase.notes))
                out.append(detailRow(.tags, txn: row.txn, editable: editable,
                                     text: drafting ? (draft?.tagsText ?? "")
                                                    : mainBase.tags))
                // Outside Journal the base carries no legs: the disclosed
                // transaction is the armed one, and its draft supplies them.
                if drafting { out.append(contentsOf: draftLegRows()) }
            case .bookLeg(let leg):
                // Book legs only reach the base where every row discloses;
                // the drafted transaction's are replaced by its draft rows
                // (same split identities — no shift).
                guard disclosed, !drafting else { continue }
                out.append(RegisterTableRow(
                    id: row.id,
                    selected: selection.contains(row.id),
                    editable: false,
                    kind: .bookLeg(leg)))
            }
        }
        return out
    }

    private func detailRow(_ field: RegisterDetailField, txn: GncGUID,
                           editable: Bool, text: String) -> RegisterTableRow {
        let id: RegisterRowID = field == .notes ? .notes(txn) : .tags(txn)
        return RegisterTableRow(
            id: id, selected: selection.contains(id), editable: editable,
            kind: .detail(RegisterDetailRowData(field: field, text: text)))
    }

    /// The handle column at rest. Basic Ledger is the only style where a row's
    /// disclosure is the user's to choose (``RegisterStyle/allowsManualExpand``
    /// — GnuCash's expand call is a no-op elsewhere, split-register.c:251), so
    /// it is the only one that offers a triangle; the others keep the pencil
    /// that opens the transaction right out.
    private func restingHandle(editable: Bool, disclosed: Bool) -> RegisterHandleState {
        guard editable else { return .hidden }
        return style.allowsManualExpand ? .disclose(open: disclosed) : .edit
    }

    private func renderData(_ base: RegisterMainBase, drafting: Bool,
                            editable: Bool, disclosed: Bool) -> RegisterMainRowData {
        var data = RegisterMainRowData(
            id: base.id, isHeadingOnly: base.isHeadingOnly,
            reconcile: base.reconcile, hasDocument: base.hasDocument,
            drafting: drafting,
            handle: restingHandle(editable: editable, disclosed: disclosed),
            date: base.date,
            description: base.description,
            transferIsCombo: base.isSimple,
            transferAccountID: nil,
            transferName: base.transferName,
            transferStatic: base.transferName,
            amount: base.amount,
            amountEditText: nil,
            imbalance: 0,
            runningBalance: base.runningBalance)
        if drafting, let d = draft {
            data.date = d.date
            data.description = d.description
            data.imbalance = d.imbalance
            // An expanded edit always shows its ✕ — cancelling must not
            // depend on where the selection happens to sit.
            if d.isExpanded { data.handle = .cancel }
            if !data.isHeadingOnly {
                if let ci = d.counterpartyIndex(account: model.selectedAccountID) {
                    data.transferIsCombo = true
                    data.transferAccountID = d.lines[ci].accountID
                    data.transferName = nil
                } else {
                    data.transferIsCombo = false
                }
                if let fi = d.focusIndex(account: model.selectedAccountID) {
                    let line = d.lines[fi]
                    data.amount = line.amount
                    data.amountEditText = line.amountText
                }
            }
        }
        return data
    }

    /// The drafted transaction's leg rows. A line from a real split keeps
    /// that split's row identity, so journal-reading edits swap content under
    /// the same rows — no shift (spec 7).
    private func draftLegRows() -> [RegisterTableRow] {
        guard let draft else { return [] }
        var out: [RegisterTableRow] = []
        for line in draft.lines {
            let id = line.splitID.map(RegisterRowID.split) ?? .draftLine(line.id)
            let reconcile = line.splitID
                .flatMap { model.reconcileState(ofSplit: $0)?.rawValue } ?? ""
            out.append(RegisterTableRow(id: id,
                                        selected: selection.contains(id),
                                        editable: true,
                                        kind: .draftLeg(line: line, reconcile: reconcile,
                                                        canRemove: draft.lines.count > 2,
                                                        quantityEditable: isForeign(line))))
        }
        if draft.isExpanded {
            out.append(RegisterTableRow(id: .addSplit, selected: false, editable: true,
                                        kind: .addSplit))
        }
        return out
    }

    // MARK: State helpers

    private var currencyCode: String {
        model.postableAccounts.first { $0.id == model.selectedAccountID }?.currencyCode
            ?? model.reportCurrency.mnemonic
    }

    /// The drafted transaction's own currency — leg values are in it.
    private var draftCurrencyCode: String {
        guard let d = draft else { return currencyCode }
        if let override = d.currencyOverride { return override.mnemonic }
        return model.transactionCurrency(for: d.lines.compactMap(\.accountID)).mnemonic
    }

    /// FR-REG-07: a leg posting to an account in another commodity carries its
    /// own quantity — that's the cell the Balance column exposes.
    private func isForeign(_ line: EditableSplit) -> Bool {
        guard let id = line.accountID,
              let node = model.postableAccounts.first(where: { $0.id == id })
        else { return false }
        return node.currencyCode != draftCurrencyCode
    }

    private func transaction(of rowID: RegisterRowID) -> GncGUID? {
        switch rowID {
        case .txn(let guid), .notes(let guid), .tags(let guid): guid
        case .split(let guid): model.transactionID(ofSplit: guid)
        case .draftLine, .addSplit: draft?.transactionID
        }
    }

    /// The split a row stands for — what the shared transaction actions and
    /// `selectedSplitIDs` consumers expect.
    private func splitID(of rowID: RegisterRowID) -> GncGUID? {
        switch rowID {
        case .split(let guid): guid
        case .txn(let guid), .notes(let guid), .tags(let guid):
            model.anySplitID(ofTransaction: guid)
        case .draftLine, .addSplit: nil
        }
    }

    /// The transaction a selection is about — when it is about exactly one.
    private func singleTransaction(in ids: Set<RegisterRowID>) -> GncGUID? {
        guard !ids.isEmpty else { return nil }
        let txns = Set(ids.compactMap(transaction(of:)))
        return txns.count == 1 ? txns.first : nil
    }

    private var singleSelectedTransaction: GncGUID? {
        singleTransaction(in: selection)
    }

    private func withDraft(_ apply: (inout TransactionDraft) -> Void) {
        guard var d = draft else { return }
        apply(&d)
        draft = d
        editGeneration &+= 1
    }

    private func withLineIndex(_ id: UUID,
                               _ apply: (inout TransactionDraft, Int) -> Void) {
        guard var d = draft,
              let index = d.lines.firstIndex(where: { $0.id == id }) else { return }
        apply(&d, index)
        draft = d
        editGeneration &+= 1
    }

    private func withLine(_ id: UUID, _ apply: (inout EditableSplit) -> Void) {
        withLineIndex(id) { d, index in apply(&d.lines[index]) }
    }

    /// The draft line a cursor field belongs to, if it is a leg field.
    private func lineID(of field: TransactionEditField?) -> UUID? {
        switch field {
        case .splitAccount(let id), .splitMemo(let id), .splitAction(let id),
             .splitAmount(let id), .splitQuantity(let id):
            id
        default:
            nil
        }
    }

    // MARK: Draft control (GnuCash's pending transaction)

    private func beginEdit(transaction txn: GncGUID, expanded: Bool) {
        if draft?.transactionID == txn {
            if expanded { withDraft { $0.isExpanded = true } }
            return
        }
        guard var d = TransactionDraft(model: model, transactionID: txn, expanded: expanded)
        else { return }
        d.isExpanded = expanded
        draft = d
        original = d
        anchorRow = .txn(txn)
        editGeneration &+= 1
    }

    private func clearDraft() {
        draft = nil
        original = nil
        anchorRow = nil
        lastDraftCursor = nil
        editGeneration &+= 1
    }

    /// Leaving the drafted transaction, GnuCash's way: a clean draft goes
    /// freely; a dirty balanced one commits; a dirty unbalanced one bounces
    /// the cursor back (`gnc_split_register_move_cursor`: "Trans was
    /// unbalanced" → the new location is put back where it was).
    private func leaveDraft() -> Bool {
        guard let d = draft else { return true }
        if d == original {
            clearDraft()
            return true
        }
        guard d.isBalanced else {
            saveError = blockedMessage(for: d)
            bounceBack()
            return false
        }
        do {
            try commit(d)
            clearDraft()
            return true
        } catch {
            saveError = error.localizedDescription
            bounceBack()
            return false
        }
    }

    private func blockedMessage(for d: TransactionDraft) -> String {
        if !d.lines.allSatisfy(\.quantityIsValid) {
            String(localized: "A quantity isn’t a number — clear it or fix it.")
        } else if d.validLineCount < 2 {
            String(localized: "A transaction needs at least two accounts.")
        } else {
            String(localized: "The splits don’t balance — off by \(AmountFormat.string(d.imbalance, code: draftCurrencyCode)).")
        }
    }

    private func commit(_ d: TransactionDraft) throws {
        // `number` goes back untouched: this table has no Num column, so
        // `TransactionEditField.number` is never focusable here and the draft
        // still carries whatever the book held. Writing it keeps the commit
        // whole should a column ever be added.
        try model.updateTransaction(
            id: d.transactionID, date: d.date, description: d.description,
            currency: d.currencyOverride
                ?? model.transactionCurrency(for: d.lines.compactMap(\.accountID)),
            splits: d.lines.filter { $0.accountID != nil }.map(\.asInput),
            tags: d.parsedTags, notes: d.notes, number: d.number)
    }

    private func bounceBack() {
        if let anchorRow {
            let target: Set<RegisterRowID> = [anchorRow]
            if selection != target { selection = target }
        }
        if let back = lastDraftCursor {
            Task { @MainActor in cursor = back }
        }
    }

    // MARK: Selection / focus handlers

    private func selectionChanged(from before: Set<RegisterRowID>,
                                  to now: Set<RegisterRowID>) {
        if now.contains(.addSplit) {
            appendLine()
            return
        }
        // GnuCash drops `trans_expanded` when the cursor leaves the
        // transaction: a hand-opened row shuts as you move off it.
        if singleTransaction(in: now) != singleTransaction(in: before) {
            currentExpanded = false
        }
        model.selectedSplitIDs = Set(now.compactMap(splitID(of:)))
        // Leaving the drafted transaction commits or bounces.
        let txns = Set(now.compactMap(transaction(of:)))
        if let d = draft, !txns.contains(d.transactionID) {
            guard leaveDraft() else { return }
        }
        // Journal readings: the selected transaction's cells come alive under
        // unchanged row identities — a clean draft is invisible (spec 7).
        // The plain register drafts nothing on selection (spec 2).
        if armsOnSelection, draft == nil, let txn = singleSelectedTransaction {
            beginEdit(transaction: txn, expanded: false)
        }
    }

    private func cursorChanged(_ now: RegisterFocus?) {
        guard let now else { return }
        guard let txn = transaction(of: now.row) else { return }
        if draft?.transactionID == txn {
            lastDraftCursor = now
        } else {
            // A field can only take focus inside the selected transaction
            // (hit-gating), so this is the first edit of that transaction:
            // settle any other draft, then open one in place.
            guard leaveDraft() else { return }
            beginEdit(transaction: txn, expanded: false)
            lastDraftCursor = now
        }
    }

    /// Account switches and style changes change the row population wholesale:
    /// settle any dirty edit, then re-arm under the new rules.
    private func settleAndReset(keepSelection: Bool = false) {
        if let d = draft, d != original {
            if d.isBalanced { try? commit(d) }
            else { saveError = String(localized: "Edit discarded — it didn’t balance.") }
        }
        clearDraft()
        cursor = nil
        // A hand-opened row has no meaning once the style decides what is open
        // (split-register.c:251), nor once the rows themselves are replaced.
        currentExpanded = false
        if keepSelection {
            rearm()
        } else {
            selection = []
        }
    }

    // MARK: Editing operations

    private func editExpanded() {
        if let txn = singleSelectedTransaction ?? draft?.transactionID {
            open(txn)
        }
    }

    /// The disclosure triangle. Basic Ledger only: in the other two styles
    /// GnuCash's expand call returns immediately (split-register.c:251), so
    /// the control is never offered there.
    ///
    /// Opening arms the row with a clean draft — the same invisible draft the
    /// journal readings use — so the notes, tags and legs it reveals are live
    /// cells rather than a read-only echo. Folding settles that draft first:
    /// an unbalanced edit refuses, exactly as it refuses to be left.
    private func toggleDisclosure() {
        guard style.allowsManualExpand,
              let txn = singleSelectedTransaction else { return }
        if currentExpanded {
            guard leaveDraft() else { return }
            cursor = nil
            currentExpanded = false
        } else {
            currentExpanded = true
            if draft == nil { beginEdit(transaction: txn, expanded: false) }
            // The rows below shift down; keep the opened one on screen.
            scrollTarget = .txn(txn)
        }
    }

    private func open(_ txn: GncGUID) {
        if draft?.transactionID == txn {
            withDraft { $0.isExpanded = true }
        } else {
            guard leaveDraft() else { return }
            beginEdit(transaction: txn, expanded: true)
        }
        if let anchorRow {
            focusLater(RegisterFocus(row: anchorRow, field: .description))
            // Row insertion can shift NSTableView's estimated-height scroll;
            // bring the edited transaction back if it slid away.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                scrollTarget = anchorRow
            }
        }
    }

    private func appendLine() {
        guard var d = draft else {
            selection = anchorRow.map { [$0] } ?? []
            return
        }
        var line = EditableSplit()
        // GnuCash's blank-split convenience: a new leg opens carrying the
        // residual, so a two-line fix is one keystroke from balancing.
        let residual = -d.imbalance
        if residual != 0 {
            line.amountText = NSDecimalNumber(decimal: residual).stringValue
        }
        d.lines.append(line)
        draft = d
        selection = anchorRow.map { [$0] } ?? []
        // Entry starts at the memo (the leg's own text), then ⇥ walks on to
        // account and amount.
        focusLater(RegisterFocus(row: .draftLine(line.id), field: .splitMemo(line.id)))
    }

    /// Programmatic focus, with one delayed retry: an assignment issued in the
    /// same beat as a row-content rebuild can be dropped (harness-logged).
    private func focusLater(_ target: RegisterFocus) {
        Task { @MainActor in
            cursor = target
            try? await Task.sleep(for: .milliseconds(90))
            if cursor != target { cursor = target }
        }
    }

    private func removeLine(_ id: UUID) {
        if lineID(of: cursor?.field) == id {
            cursor = nil
        }
        withDraft { d in
            guard d.lines.count > 2,
                  let index = d.lines.firstIndex(where: { $0.id == id }) else { return }
            d.lines.remove(at: index)
        }
    }

    /// ⏎ — save and fold back to the plain line (spec 4/6). The journal
    /// readings re-arm the selection so the next click still edits in place.
    private func saveEdit() {
        guard let d = draft else { return }
        if d == original {
            clearDraft()
            cursor = nil
            rearm()
            return
        }
        guard d.isBalanced else {
            saveError = blockedMessage(for: d)
            return
        }
        do {
            let anchor = anchorRow
            try commit(d)
            clearDraft()
            cursor = nil
            if let anchor { selection = [anchor] }
            rearm()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// ⎋ — cancel: revert a dirty edit and fold back; a second ⎋ deselects.
    private func escapePressed() {
        if draft != nil {
            let anchor = anchorRow
            clearDraft()
            cursor = nil
            if let anchor, selection != [anchor] { selection = [anchor] }
            rearm()
        } else {
            selection = []
        }
    }

    /// A disclosed row keeps a clean draft behind it, so its cells stay live
    /// after a save or a cancel — whether the style disclosed it or the
    /// handle did.
    private func rearm() {
        guard armsOnSelection || currentExpanded,
              let txn = singleSelectedTransaction else { return }
        beginEdit(transaction: txn, expanded: false)
    }

    // MARK: ⇥ traversal — visible fields only (spec point 4)

    private func focusOrder() -> [RegisterFocus] {
        guard let d = draft, let anchorRow else { return [] }
        let txn = d.transactionID
        // Reading order, so ⇥ and VoiceOver walk the rows the way they are
        // drawn: the heading line, then the disclosed lines beneath it.
        var order: [RegisterFocus] = [
            RegisterFocus(row: anchorRow, field: .date),
            RegisterFocus(row: anchorRow, field: .description),
        ]
        // `.number` (GnuCash's Num) has no column in this table, so it is not
        // a stop — a Tab landing on a cell that is never drawn is a trap.
        if !wholeBook {
            if d.counterpartyIndex(account: model.selectedAccountID) != nil {
                order.append(RegisterFocus(row: anchorRow, field: .transfer))
            }
            order.append(RegisterFocus(row: anchorRow, field: .amount))
        }
        guard isDisclosed(txn: txn, drafting: true,
                          selected: singleSelectedTransaction) else { return order }
        order.append(RegisterFocus(row: .notes(txn), field: .notes))
        order.append(RegisterFocus(row: .tags(txn), field: .tags))
        for line in d.lines {
            let row = line.splitID.map(RegisterRowID.split) ?? .draftLine(line.id)
            order.append(RegisterFocus(row: row, field: .splitAction(line.id)))
            order.append(RegisterFocus(row: row, field: .splitMemo(line.id)))
            order.append(RegisterFocus(row: row, field: .splitAccount(line.id)))
            order.append(RegisterFocus(row: row, field: .splitAmount(line.id)))
            if isForeign(line) {
                order.append(RegisterFocus(row: row, field: .splitQuantity(line.id)))
            }
        }
        return order
    }

    private func moveCursor(backwards: Bool) {
        let order = focusOrder()
        guard !order.isEmpty else { return }
        guard let cur = cursor, let index = order.firstIndex(of: cur) else {
            cursor = order.first
            return
        }
        cursor = backwards
            ? order[index == 0 ? order.count - 1 : index - 1]
            : order[(index + 1) % order.count]
    }
}

// MARK: - Row painting (selection wash + zebra, even, at the row level)

#if os(macOS)
/// Owns the NSTableView's row drawing: switches off the emphasized selection
/// fill (spec: never a dark selection), then paints every available row
/// view's `backgroundColor` itself — zebra from the system's alternating
/// colors, selection as one flat lavender wash (base blended 18% toward the
/// accent) per row. Native selection *interaction* is untouched.
private struct RegisterTableStyleProbe: NSViewRepresentable {
    /// SwiftUI's selection as row indices — the paint source of truth.
    var selectedIndices: IndexSet
    var tick: Int

    @MainActor
    final class Coordinator {
        weak var table: NSTableView?
        var selected = IndexSet()
        nonisolated(unsafe) var boundsObserver: NSObjectProtocol?
        private let accent = NSColor(Color.appAccent)

        func attach(near view: NSView) {
            if table == nil || table?.window == nil {
                var node: NSView? = view
                var depth = 0
                while let current = node, depth < 12, table?.window == nil {
                    if let found = Self.findTable(in: current) {
                        adopt(found)
                        break
                    }
                    node = current.superview
                    depth += 1
                }
            }
            paint()
        }

        private func adopt(_ t: NSTableView) {
            guard table !== t else { return }
            table = t
            t.selectionHighlightStyle = .none
            if let clip = t.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip,
                    queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.paint() }
                }
            }
        }

        func paint() {
            guard let table else { return }
            let bases = NSColor.alternatingContentBackgroundColors
            let selectionBase = bases.first ?? NSColor.controlBackgroundColor
            let wash = selectionBase.blended(withFraction: 0.18, of: accent)
                ?? selectionBase
            table.enumerateAvailableRowViews { rowView, row in
                rowView.backgroundColor = selected.contains(row)
                    ? wash
                    : bases.isEmpty ? NSColor.controlBackgroundColor
                                    : bases[row % bases.count]
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        private static func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews {
                if let found = findTable(in: sub) { return found }
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.selected = selectedIndices
        DispatchQueue.main.async { context.coordinator.attach(near: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.selected = selectedIndices
        DispatchQueue.main.async { context.coordinator.attach(near: view) }
    }
}
#endif

// MARK: - The cell

/// One register cell: a real TextField, always present so editing never
/// changes the layout — but **hit-transparent unless its transaction is the
/// selection**, so a click on an unselected row is a plain row selection and
/// a click inside the selected one edits (spec point 4). `restValue` is the
/// display text; `editValue` (when given) is the raw text editing starts from
/// — the amount cell rests on "$12.30" and edits "12.3". The cell occupies
/// the same box in every state; focus adds a `.tint` ring and nothing else,
/// and the placeholder appears only while focused (a placeholder drawn on
/// every empty rest cell reads as content).
struct GridCell: View {
    let restValue: String
    var editValue: String?
    var placeholder: LocalizedStringKey = ""
    var alignment: TextAlignment = .leading
    var monospaced = false
    var muted = false
    var negative = false
    var isEditable = true
    let focus: RegisterFocus
    var cursor: FocusState<RegisterFocus?>.Binding
    var onEdit: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}

    @State private var text: String

    init(restValue: String, editValue: String? = nil,
         placeholder: LocalizedStringKey = "",
         alignment: TextAlignment = .leading, monospaced: Bool = false,
         muted: Bool = false, negative: Bool = false, isEditable: Bool = true,
         focus: RegisterFocus, cursor: FocusState<RegisterFocus?>.Binding,
         onEdit: @escaping (String) -> Void = { _ in },
         onEscape: @escaping () -> Void = {}) {
        self.restValue = restValue
        self.editValue = editValue
        self.placeholder = placeholder
        self.alignment = alignment
        self.monospaced = monospaced
        self.muted = muted
        self.negative = negative
        self.isEditable = isEditable
        self.focus = focus
        self.cursor = cursor
        self.onEdit = onEdit
        self.onEscape = onEscape
        _text = State(initialValue: restValue)
    }

    private var isFocused: Bool { cursor.wrappedValue == focus }

    var body: some View {
        TextField(isFocused ? placeholder : "", text: $text)
            .textFieldStyle(.plain)
            .focusEffectDisabled()   // the ring below is the focus visual
            .scaledFont(.body)
            .conditionallyMonospacedDigit(monospaced)
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .foregroundStyle(negative && !isFocused ? AnyShapeStyle(.red)
                             : muted && !isFocused ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(.primary))
            .focused(cursor, equals: focus)
            .allowsHitTesting(isEditable)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.tint, lineWidth: 2)
                }
            }
            .accessibilityLabel(Text(placeholder))
            .onChange(of: restValue) { _, now in
                if !isFocused { text = now }
            }
            .onChange(of: isFocused) { _, now in
                // Focus-gain reseeds from the raw editing text; focus-loss
                // snaps back to the canonical display.
                if now { text = editValue ?? restValue } else { text = restValue }
            }
            .onChange(of: text) { _, now in
                if isFocused { onEdit(now) }
            }
            .onKeyPress(keys: [.escape]) { _ in
                onEscape()
                return .handled
            }
    }
}

// MARK: - The account combo cell

/// GnuCash's ComboCell over a real, clickable field — the semantics of
/// `combocell-gnome.c` (30-match cap, ⎋ reverts an edited cell, resolve on
/// leave, ⏎ resolves then saves), with the same selection hit-gate as
/// ``GridCell``. macOS gets the native suggestions dropdown; iOS keeps typed
/// completion (HIG: combo boxes are not an iOS control).
struct ComboCell: View {
    let accountID: GncGUID?
    /// Rest text when the account isn't resolvable yet (an undrafted row's
    /// counterparty name).
    var displayName: String?
    var placeholder: LocalizedStringKey = "Account"
    let nodes: [AccountNode]
    var isEditable = true
    let focus: RegisterFocus
    var cursor: FocusState<RegisterFocus?>.Binding
    let onPick: (GncGUID) -> Void
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}

    @State private var query: String
    @State private var hasTyped = false

    init(accountID: GncGUID?, displayName: String? = nil,
         placeholder: LocalizedStringKey = "Account", nodes: [AccountNode],
         isEditable: Bool = true,
         focus: RegisterFocus, cursor: FocusState<RegisterFocus?>.Binding,
         onPick: @escaping (GncGUID) -> Void,
         onReturn: @escaping () -> Void = {},
         onEscape: @escaping () -> Void = {}) {
        self.accountID = accountID
        self.displayName = displayName
        self.placeholder = placeholder
        self.nodes = nodes
        self.isEditable = isEditable
        self.focus = focus
        self.cursor = cursor
        self.onPick = onPick
        self.onReturn = onReturn
        self.onEscape = onEscape
        _query = State(initialValue: displayName
            ?? AccountSearch.name(of: accountID, in: nodes))
    }

    private var isFocused: Bool { cursor.wrappedValue == focus }
    private var currentName: String {
        if let displayName, accountID == nil { return displayName }
        return AccountSearch.name(of: accountID, in: nodes)
    }
    /// The GnuCash cap: past thirty rows a combo popup stops being a shortlist.
    private var matches: [AccountNode] {
        Array(AccountSearch.matches(hasTyped ? query : "", in: nodes).prefix(30))
    }

    var body: some View {
        field
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .scaledFont(.body)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(isFocused || currentName.isEmpty
                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .focused(cursor, equals: focus)
            .allowsHitTesting(isEditable)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.tint, lineWidth: 2)
                }
            }
            .accessibilityLabel(Text(placeholder))
            .onChange(of: currentName) { _, now in
                if !isFocused { query = now }
            }
            .onChange(of: isFocused) { was, now in
                if now {
                    query = currentName
                    hasTyped = false
                } else if was {
                    resolve()
                    query = currentName
                }
            }
            .onChange(of: query) { old, now in
                guard old != now, isFocused else { return }
                hasTyped = true
                if let exact = exactMatch(now) { commit(exact) }
            }
            .submitScope()
            .onSubmit { if resolve() { onReturn() } }
            .onKeyPress(keys: [.escape]) { _ in
                if hasTyped {
                    query = currentName        // changed ⎋ reverts the cell
                    hasTyped = false
                } else {
                    onEscape()                 // unchanged ⎋ cancels the row
                }
                return .handled
            }
    }

    @ViewBuilder
    private var field: some View {
        #if os(macOS)
        // Attached unconditionally — a structural swap on focus change would
        // give the field a new identity mid-click. The list is empty at rest.
        TextField(isFocused ? placeholder : "", text: $query)
            .textInputSuggestions {
                ForEach(isFocused ? matches : []) { node in
                    Text(node.fullName)
                        .textInputCompletion(node.fullName)
                }
            }
        #else
        TextField(isFocused ? placeholder : "", text: $query)
        #endif
    }

    private func exactMatch(_ text: String) -> AccountNode? {
        nodes.first { $0.fullName.caseInsensitiveCompare(text) == .orderedSame }
    }

    @discardableResult
    private func resolve() -> Bool {
        if let exact = exactMatch(query) { commit(exact); return true }
        if hasTyped, let best = matches.first { commit(best); return true }
        return accountID != nil
    }

    private func commit(_ node: AccountNode) {
        if node.id != accountID { onPick(node.id) }
        query = node.fullName
        hasTyped = false
    }
}

// MARK: - Helpers

private extension View {
    @ViewBuilder
    func conditionallyMonospacedDigit(_ on: Bool) -> some View {
        if on { self.monospacedDigit() } else { self }
    }
}
