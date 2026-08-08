//
//  RegisterSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The macOS account register (FR-REG-03) and whole-book journal (FR-REG-09)
//  as GnuCash's own sheet architecture, proven in the RegisterLab2 harness at
//  20k transactions (9 Aug 2026) after every framework-hosted design lagged:
//
//   * ONE custom NSView draws the whole register. `draw(_:)` paints only the
//     transaction blocks intersecting the dirty rect (zebra, wash, rulers,
//     text) — `gnucash_sheet_draw_cb` + `gnucash_sheet_compute_visible_range`.
//   * Selection and cursor are plain vars; changing them damages only the
//     affected block rects — `gnucash_sheet_redraw_block`.
//   * ONE NSTextField exists per sheet, positioned over the cursor cell —
//     `gnucash-item-edit.h`: "The editor whose status we reflect on the
//     sheet". The account combo is the same field plus a suggestions panel
//     (`combocell-gnome.c`: 30-match cap, resolve on leave/⏎, ⎋ reverts).
//   * A block's y-offset depends only on the blocks before it (flipped
//     coords), so expanding a transaction cannot move its own heading.
//
//  Editing is GnuCash's pending transaction (`split-register-control.cpp`,
//  `gnc_split_register_move_cursor`): leaving a dirty transaction commits if
//  balanced, bounces if not; ⏎ saves; ⎋ reverts; ⇥ walks visible fields.
//  Leg lines use the CURSOR_SPLIT mapping (`split-register-layout.c`):
//  Action under Date, Memo under Description, the Account under Transfer.
//
//  The interaction spec is the 7-point agreement recorded in
//  memory/register-redesign-brief.md; the visual agreements (quiet lavender
//  wash, no dark emphasized fill, focus ring only) hold throughout.
//
//  iOS keeps the SwiftUI Table register (RegisterTable.swift) — this sheet is
//  AppKit. KNOWN LIMITATION, tracked for follow-up: the sheet exposes itself
//  to accessibility as a single table element (no per-row AX rows/cells yet),
//  and the reconcile cell is mouse-only; the unreconciled rotor from the
//  Table port has no NSView equivalent yet.
//

#if os(macOS)

import SwiftUI
import AppKit
import FinvestLensEngine

// MARK: - The SwiftUI entry (drop-in where RegisterTableView stood)

struct RegisterSheet: View {
    @Bindable var model: AppModel
    /// FR-REG-09: All Transactions — the whole-book journal in this view.
    var wholeBook = false
    /// ⌘↑/⌘↓ from the shell; consumed here.
    var jump: Binding<RegisterEnd?> = .constant(nil)
    @Environment(\.appDateFormat) private var dateFormat
    @Environment(\.appFontScale) private var fontScale

    @AppStorage("registerDoubleLine") private var doubleLine = false
    @AppStorage("registerShowAllSplits") private var showAllSplits = false
    @State private var saveError: String?

    var body: some View {
        SheetHost(model: model, wholeBook: wholeBook,
                  rowsKey: rowsKey,
                  accountKey: accountKey,
                  showDetails: doubleLine,
                  showAllSplits: showAllSplits,
                  fontScale: fontScale,
                  dateFormat: dateFormat,
                  sort: model.registerSort,
                  sortReversed: model.registerSortReversed,
                  editing: model.editingTransactionID,
                  pendingAvailable: model.pendingRegisterSplitID != nil,
                  jump: jump,
                  onError: { message in saveError = message })
            .alert("Couldn’t save", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
    }

    /// Everything that shapes the base rows, folded to one comparison —
    /// reading these model properties here is what re-renders the wrapper
    /// (and so refreshes the sheet) when any of them change.
    private var rowsKey: Int {
        var hasher = Hasher()
        hasher.combine(model.bookRevision)
        hasher.combine(wholeBook)
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

    private var accountKey: Int {
        var hasher = Hasher()
        hasher.combine(model.selectedAccountID)
        hasher.combine(wholeBook)
        return hasher.finalize()
    }
}

// MARK: - Representable

private struct SheetHost: NSViewRepresentable {
    let model: AppModel
    let wholeBook: Bool
    let rowsKey: Int
    let accountKey: Int
    let showDetails: Bool
    let showAllSplits: Bool
    let fontScale: CGFloat
    let dateFormat: AppDateFormat
    let sort: RegisterSort
    let sortReversed: Bool
    let editing: GncGUID?
    let pendingAvailable: Bool
    let jump: Binding<RegisterEnd?>
    let onError: (String) -> Void

    func makeNSView(context: Context) -> SheetContainerView {
        let view = SheetContainerView(model: model, wholeBook: wholeBook)
        push(into: view)
        return view
    }

    func updateNSView(_ view: SheetContainerView, context: Context) {
        push(into: view)
    }

    static func dismantleNSView(_ view: SheetContainerView, coordinator: ()) {
        // Leaving the destination mid-edit: best-effort commit, GnuCash-style.
        view.sheet.settleDirtyDraft()
    }

    private func push(into view: SheetContainerView) {
        view.sheet.onError = onError
        view.headerView.sortState = sortIndicator
        view.headerView.onSort = { [weak model] column in
            guard let model else { return }
            let target: RegisterSort? = switch column {
            case .date: .date
            case .description: .description
            case .amount: .amount
            default: nil
            }
            guard let target else { return }
            if model.registerSort == target {
                // HIG Lists and tables: clicking a sorted heading re-sorts
                // in the opposite direction.
                model.registerSortReversed.toggle()
            } else {
                model.registerSort = target
                model.registerSortReversed = false
            }
        }
        view.sheet.apply(rowsKey: rowsKey, accountKey: accountKey,
                         showDetails: showDetails, showAllSplits: showAllSplits,
                         fontScale: fontScale, dateFormat: dateFormat,
                         editing: editing, pendingAvailable: pendingAvailable)
        if let target = jump.wrappedValue {
            view.sheet.scrollToEnd(target)
            let jump = jump
            DispatchQueue.main.async { jump.wrappedValue = nil }
        }
    }

    private var sortIndicator: (column: SheetColumn, reversed: Bool)? {
        switch sort {
        case .date: (.date, sortReversed)
        case .description: (.description, sortReversed)
        case .amount: (.amount, sortReversed)
        default: nil
        }
    }
}

// MARK: - Identity

private struct SheetFocus: Hashable {
    var txn: GncGUID
    var field: TransactionEditField
}

private enum SheetTap {
    case heading(TransactionEditField)
    case leg(Int, LegField)
    case addSplit

    enum LegField { case action, memo, account, amount, quantity }
}

// MARK: - Rows (book facts only; rebuilt per rowsKey)

private struct SheetRow {
    let txn: GncGUID
    let base: SheetMainBase
    let legs: [AutoSplitRow]
}

private struct SheetMainBase {
    var anchorSplit: GncGUID?
    var isHeadingOnly: Bool
    var date: Date
    var description: String
    var notes: String
    var reconcile: String
    var hasDocument: Bool
    var isSimple: Bool
    var transferName: String
    var amount: Decimal
    var runningBalance: Decimal?
}

/// `defaults write <bundle-id> FLRegisterTrace -bool true` logs sheet timings
/// to /tmp/fl-register-perf.log — no book contents, only counts and durations.
private enum SheetTrace {
    nonisolated(unsafe) static let enabled =
        UserDefaults.standard.bool(forKey: "FLRegisterTrace")

    static func note(_ text: @autoclosure () -> String) {
        guard enabled else { return }
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let line = "\(stamp) sheet \(text())\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/fl-register-perf.log") {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: "/tmp/fl-register-perf.log", atomically: false,
                            encoding: .utf8)
        }
    }
}

// MARK: - Geometry

private enum SheetColumn: Int, CaseIterable {
    case date, handle, description, transfer, reconcile, amount, balance

    var title: String {
        switch self {
        case .date: String(localized: "Date")
        case .handle: ""
        case .description: String(localized: "Description")
        case .transfer: String(localized: "Transfer")
        case .reconcile: String(localized: "R")
        case .amount: String(localized: "Amount")
        case .balance: String(localized: "Balance")
        }
    }

    var trailing: Bool { self == .amount || self == .balance }
    var sortable: Bool { self == .date || self == .description || self == .amount }
}

private enum SheetLine: Equatable {
    case heading
    case notes
    case leg(Int)
    case addSplit
}

private enum SheetMetrics {
    static let headerHeight: CGFloat = 26
    static let textInset: CGFloat = 5
    static let washRadius: CGFloat = 8
    static let washInset: CGFloat = 4

    struct Frames {
        var x: [CGFloat]
        var width: [CGFloat]

        init(totalWidth: CGFloat) {
            let fixed: [SheetColumn: CGFloat] = [
                .date: 80, .handle: 22, .transfer: 180,
                .reconcile: 24, .amount: 100, .balance: 112,
            ]
            let flex = max(140, totalWidth - fixed.values.reduce(0, +))
            var xs: [CGFloat] = []
            var ws: [CGFloat] = []
            var cursor: CGFloat = 0
            for column in SheetColumn.allCases {
                let w = fixed[column] ?? flex
                xs.append(cursor)
                ws.append(w)
                cursor += w
            }
            x = xs
            width = ws
        }

        func rect(_ column: SheetColumn, y: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: x[column.rawValue], y: y,
                   width: width[column.rawValue], height: height)
        }

        func column(atX pointX: CGFloat) -> SheetColumn? {
            for column in SheetColumn.allCases {
                let start = x[column.rawValue]
                if pointX >= start, pointX < start + width[column.rawValue] {
                    return column
                }
            }
            return nil
        }
    }
}

// MARK: - Symbols (drawn, not widgets)

@MainActor
private enum SheetSymbols {
    static let paperclip = make("paperclip", color: .secondaryLabelColor, size: 10)
    static let pencil = make("square.and.pencil", color: .secondaryLabelColor, size: 12)
    static let cancel = make("xmark.circle", color: .secondaryLabelColor, size: 12)
    static let addSplit = make("plus.circle", color: .secondaryLabelColor, size: 11)
    static let removeSplit = make("minus.circle", color: .secondaryLabelColor, size: 11)
    static let warning = make("exclamationmark.triangle.fill", color: .systemOrange, size: 10)
    static let sortUp = make("chevron.up", color: .secondaryLabelColor, size: 8)
    static let sortDown = make("chevron.down", color: .secondaryLabelColor, size: 8)

    private static func make(_ name: String, color: NSColor, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
    }
}

/// The reconcile column's symbols — the drawn mirror of ``ReconcileBadge``.
@MainActor
private enum ReconcileSymbols {
    private static var cache: [String: NSImage?] = [:]

    static func image(for glyph: String) -> NSImage? {
        if let hit = cache[glyph] { return hit }
        let (name, color): (String, NSColor) = switch glyph {
        case "c": ("checkmark.circle", NSColor(Color.appAccent))
        case "y": ("checkmark.circle.fill", .systemGreen)
        case "f": ("snowflake", .systemCyan)
        case "v": ("xmark.circle", .systemRed)
        default: ("circle.dotted", .secondaryLabelColor)
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
        cache[glyph] = image
        return image
    }
}

// MARK: - Row cache

@MainActor
private final class SheetRowCache {
    private var key: Int = .min
    private(set) var rows: [SheetRow] = []
    private(set) var indexByTxn: [GncGUID: Int] = [:]

    func refresh(for key: Int, build: () -> [SheetRow]) {
        guard key != self.key else { return }
        let start = ContinuousClock.now
        rows = build()
        self.key = key
        var index: [GncGUID: Int] = [:]
        index.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() { index[row.txn] = offset }
        indexByTxn = index
        SheetTrace.note("base rebuilt (\(rows.count) rows) in \(ContinuousClock.now - start)")
    }
}

// MARK: - The sheet view

@MainActor
private final class SheetView: NSView, NSTextFieldDelegate {
    let model: AppModel
    let wholeBook: Bool
    private let cache = SheetRowCache()
    private var rows: [SheetRow] { cache.rows }
    private var indexByTxn: [GncGUID: Int] { cache.indexByTxn }

    // Settings (pushed from SwiftUI)
    private var showDetails = false
    private var showAllSplits = false
    private var dateFormat: AppDateFormat?
    var onError: ((String) -> Void)?

    // Dynamic Type: the app font scale drives fonts and the line height.
    private var fontScale: CGFloat = 0
    private var lineHeight: CGFloat = 21
    private var bodyFont = NSFont.systemFont(ofSize: 13)
    private var monoFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private var smallFont = NSFont.systemFont(ofSize: 11)

    // Interaction state — plain vars, damage-driven (gnucash-sheet.c)
    private var selection: Set<GncGUID> = []
    private var selectedTxn: GncGUID?
    private var anchorBlock: Int?
    private var leadBlock: Int?
    private var draft: TransactionDraft?
    private var original: TransactionDraft?
    private var cursor: SheetFocus?

    // Geometry: yOffsets[i] = top of block i; count+1 entries (prefix sums).
    private var yOffsets: [CGFloat] = [0]
    private var frames = SheetMetrics.Frames(totalWidth: 800)

    // The one editor (gnucash-item-edit)
    private let itemEdit = ItemEditField()
    private let suggestions = SuggestionsController()
    private var comboTyped = false
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

    weak var header: SheetHeaderView?

    init(model: AppModel, wholeBook: Bool) {
        self.model = model
        self.wholeBook = wholeBook
        super.init(frame: .zero)
        itemEdit.isHidden = true
        itemEdit.delegate = self
        addSubview(itemEdit)
        suggestions.onPick = { [weak self] node in self?.comboPick(node) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard scrollObserver == nil,
              let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suggestions.hide() }
        }
    }

    // MARK: Accessibility (single-element for now — see the header note)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityLabel() -> String? {
        wholeBook ? String(localized: "All Transactions")
                  : String(localized: "Transactions")
    }

    // MARK: Inputs from SwiftUI (updateNSView)

    private var rowsKey: Int = .min
    private var accountKey: Int = .min
    private var lastEditingRequest: GncGUID?

    func apply(rowsKey: Int, accountKey: Int, showDetails: Bool,
               showAllSplits: Bool, fontScale: CGFloat,
               dateFormat: AppDateFormat, editing: GncGUID?,
               pendingAvailable: Bool) {
        self.dateFormat = dateFormat

        if fontScale != self.fontScale {
            self.fontScale = fontScale
            lineHeight = ceil(21 * fontScale)
            bodyFont = NSFont.systemFont(ofSize: 13 * fontScale)
            monoFont = NSFont.monospacedDigitSystemFont(ofSize: 13 * fontScale,
                                                        weight: .regular)
            smallFont = NSFont.systemFont(ofSize: 11 * fontScale)
            rebuildGeometry()
            needsDisplay = true
            positionEditor()
        }

        var settingsChanged = false
        if showDetails != self.showDetails {
            self.showDetails = showDetails
            settingsChanged = true
        }
        if showAllSplits != self.showAllSplits {
            self.showAllSplits = showAllSplits
            settleDirtyDraft()
            settingsChanged = true
        }

        if accountKey != self.accountKey {
            self.accountKey = accountKey
            settleDirtyDraft()
            clearDraft()
            selection = []
            selectedTxn = nil
            anchorBlock = nil
            leadBlock = nil
            mirrorSelection()
            reloadRows(key: rowsKey)
            scrollToBottom()
        } else if rowsKey != self.rowsKey {
            reloadRows(key: rowsKey)
        } else if settingsChanged {
            rebuildGeometry()
            needsDisplay = true
            positionEditor()
        }

        if editing != lastEditingRequest {
            lastEditingRequest = editing
            if let editing, indexByTxn[editing] != nil,
               draft?.transactionID != editing || draft?.isExpanded != true {
                Task { @MainActor in
                    self.requestSelection([editing],
                                          anchor: self.indexByTxn[editing],
                                          lead: self.indexByTxn[editing])
                    self.editExpanded()
                }
            }
        }

        if pendingAvailable, !wholeBook {
            // Consuming mutates the model — hop off the render pass first.
            Task { @MainActor in self.consumePendingJump() }
        }
    }

    private func consumePendingJump() {
        guard let split = model.consumePendingRegisterSelection(),
              let txn = model.transactionID(ofSplit: split),
              let block = indexByTxn[txn] else { return }
        requestSelection([txn], anchor: block, lead: block)
        _ = scrollToVisible(blockRect(block).insetBy(dx: 0, dy: -4 * lineHeight))
    }

    func scrollToEnd(_ end: RegisterEnd) {
        switch end {
        case .newest: scrollToBottom()
        case .oldest: _ = scrollToVisible(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func reloadRows(key: Int) {
        rowsKey = key
        cache.refresh(for: key) { buildBase() }
        selection = selection.filter { indexByTxn[$0] != nil }
        if let txn = selectedTxn, indexByTxn[txn] == nil { selectedTxn = nil }
        if selection.count == 1 { selectedTxn = selection.first }
        anchorBlock = anchorBlock.flatMap { $0 < rows.count ? $0 : nil }
        leadBlock = leadBlock.flatMap { $0 < rows.count ? $0 : nil }
        if let d = draft, indexByTxn[d.transactionID] == nil { clearDraft() }
        if let c = cursor, cellRect(of: c) == nil { setCursor(nil) }
        mirrorSelection()
        rebuildGeometry()
        needsDisplay = true
        positionEditor()
    }

    private func buildBase() -> [SheetRow] {
        var out: [SheetRow] = []
        if wholeBook {
            for txn in model.journalTransactions(forAccountID: nil) {
                out.append(SheetRow(
                    txn: txn.guid,
                    base: SheetMainBase(anchorSplit: nil, isHeadingOnly: true,
                                        date: txn.datePosted,
                                        description: txn.transactionDescription,
                                        notes: txn.notes, reconcile: "",
                                        hasDocument: txn.documentLink != nil,
                                        isSimple: false, transferName: "",
                                        amount: 0, runningBalance: nil),
                    legs: model.legRows(ofTransaction: txn.guid)))
            }
            return out
        }
        let mains = model.autoSplitRows(expanding: nil, expandAll: false)
        out.reserveCapacity(mains.count)
        for row in mains {
            guard let main = row.main,
                  let txn = model.transactionID(ofSplit: main.id) else { continue }
            out.append(SheetRow(
                txn: txn,
                base: SheetMainBase(anchorSplit: main.id, isHeadingOnly: false,
                                    date: main.date, description: main.description,
                                    notes: main.notes, reconcile: main.reconcile,
                                    hasDocument: main.hasDocument,
                                    isSimple: model.isSimpleTransfer(splitID: main.id),
                                    transferName: main.transfer,
                                    amount: main.amount,
                                    runningBalance: main.runningBalance),
                legs: model.legRows(ofTransaction: txn)))
        }
        return out
    }

    // MARK: Line plan

    private func linePlan(_ row: SheetRow) -> [SheetLine] {
        let drafting = draft?.transactionID == row.txn
        var lines: [SheetLine] = [.heading]
        if showDetails { lines.append(.notes) }
        let legCount = drafting ? (draft?.lines.count ?? 0) : row.legs.count
        let legsShown = wholeBook || showAllSplits
            || (drafting && draft?.isExpanded == true)
        if legsShown {
            for index in 0..<legCount { lines.append(.leg(index)) }
            if drafting, draft?.isExpanded == true { lines.append(.addSplit) }
        }
        return lines
    }

    private func lineCount(_ row: SheetRow) -> Int {
        let drafting = draft?.transactionID == row.txn
        var count = 1
        if showDetails { count += 1 }
        let legsShown = wholeBook || showAllSplits
            || (drafting && draft?.isExpanded == true)
        if legsShown {
            count += drafting ? (draft?.lines.count ?? 0) : row.legs.count
            if drafting, draft?.isExpanded == true { count += 1 }
        }
        return count
    }

    // MARK: Geometry

    private func rebuildGeometry() {
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(rows.count + 1)
        var y: CGFloat = 0
        for row in rows {
            offsets.append(y)
            y += CGFloat(lineCount(row)) * lineHeight
        }
        offsets.append(y)
        yOffsets = offsets
        let clipHeight = enclosingScrollView?.contentSize.height ?? 0
        setFrameSize(NSSize(width: frame.width, height: max(y, clipHeight)))
    }

    private func geometryChanged(fromBlock index: Int?) {
        let oldHeight = yOffsets.last ?? 0
        let top = index.map { yOffsets[min($0, max(0, yOffsets.count - 1))] } ?? 0
        rebuildGeometry()
        let newHeight = yOffsets.last ?? 0
        setNeedsDisplay(CGRect(x: 0, y: top, width: bounds.width,
                               height: max(oldHeight, newHeight) - top))
        positionEditor()
    }

    private func blockRect(_ index: Int) -> CGRect {
        guard index >= 0, index + 1 < yOffsets.count else { return .zero }
        return CGRect(x: 0, y: yOffsets[index], width: bounds.width,
                      height: yOffsets[index + 1] - yOffsets[index])
    }

    private func firstBlock(atOrAfter y: CGFloat) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if yOffsets[mid + 1] <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func blockIndex(atY y: CGFloat) -> Int? {
        guard !rows.isEmpty, y >= 0, y < (yOffsets.last ?? 0) else { return nil }
        let index = firstBlock(atOrAfter: y)
        return index < rows.count ? index : nil
    }

    func updateWidth(_ width: CGFloat) {
        guard abs(width - frame.width) > 0.5 else { return }
        setFrameSize(NSSize(width: width, height: frame.height))
        frames = SheetMetrics.Frames(totalWidth: width)
        header?.frames = frames
        needsDisplay = true
        positionEditor()
    }

    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let height = yOffsets.last ?? 0
        let clip = enclosingScrollView?.contentSize.height ?? 0
        _ = scrollToVisible(CGRect(x: 0, y: max(0, height - clip),
                                   width: 1, height: clip))
    }

    // MARK: Drawing (gnucash_sheet_draw_cb)

    override func draw(_ dirtyRect: NSRect) {
        let bases = NSColor.alternatingContentBackgroundColors
        let base0 = bases.first ?? .controlBackgroundColor
        let base1 = bases.count > 1 ? bases[1] : base0
        base0.setFill()
        dirtyRect.fill()
        guard !rows.isEmpty, dateFormat != nil else { return }

        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let wash = base0.blended(withFraction: dark ? 0.35 : 0.18,
                                 of: NSColor(Color.appAccent)) ?? base0

        let first = firstBlock(atOrAfter: dirtyRect.minY)

        // Pass 1 — zebra stripes, square and full width.
        var index = first
        while index < rows.count, yOffsets[index] < dirtyRect.maxY {
            (index % 2 == 0 ? base0 : base1).setFill()
            blockRect(index).fill()
            index += 1
        }

        // Rulers between columns (gnucash-sheet-private.c `draw_cell` strokes
        // each cell's side borders; gnucash-header.c boxes header cells).
        // The date|handle seam is skipped — the handle shares the date zone.
        NSColor.separatorColor.setFill()
        for column in SheetColumn.allCases where column != .date && column != .handle {
            CGRect(x: frames.x[column.rawValue] - 0.5, y: dirtyRect.minY,
                   width: 1, height: dirtyRect.height).fill()
        }

        // Pass 2 — selection wash (rounded, over the rulers) + cell content.
        index = first
        while index < rows.count, yOffsets[index] < dirtyRect.maxY {
            if selection.contains(rows[index].txn) { fillWash(index, wash: wash) }
            drawBlockContent(index)
            index += 1
        }

        if let cursor, let rect = cellRect(of: cursor) {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
                                    xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            NSColor(Color.appAccent).setStroke()
            ring.stroke()
        }
    }

    /// The selection wash: a rounded rect (the shape macOS gives list
    /// selection), squared off against an adjacent selected block so a
    /// contiguous range reads as one shape.
    private func fillWash(_ index: Int, wash: NSColor) {
        let rect = blockRect(index).insetBy(dx: SheetMetrics.washInset, dy: 0)
        let radius = SheetMetrics.washRadius
        wash.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if index > 0, selection.contains(rows[index - 1].txn) {
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: radius).fill()
        }
        if index + 1 < rows.count, selection.contains(rows[index + 1].txn) {
            CGRect(x: rect.minX, y: rect.maxY - radius,
                   width: rect.width, height: radius).fill()
        }
    }

    private func drawBlockContent(_ index: Int) {
        let row = rows[index]
        let drafting = draft?.transactionID == row.txn
        let plan = linePlan(row)
        var y = blockRect(index).minY
        for line in plan {
            drawLine(row, line: line, y: y, drafting: drafting)
            y += lineHeight
        }
    }

    private static let leftPara: NSParagraphStyle = {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        return para
    }()
    private static let rightPara: NSParagraphStyle = {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .right
        return para
    }()
    /// HIG Lists and tables: middle ellipsis preserves both ends — used for
    /// account paths.
    private static let middlePara: NSParagraphStyle = {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        return para
    }()

    private func drawText(_ text: String, in cell: CGRect, trailing: Bool = false,
                          muted: Bool = false, negative: Bool = false,
                          mono: Bool = false, font: NSFont? = nil,
                          color: NSColor? = nil, leadingInset: CGFloat = 0,
                          middleTruncate: Bool = false) {
        guard !text.isEmpty else { return }
        let font = font ?? (mono ? monoFont : bodyFont)
        let color = color ?? (negative ? .systemRed
                              : muted ? .secondaryLabelColor : .labelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: trailing ? Self.rightPara
                : middleTruncate ? Self.middlePara : Self.leftPara,
        ]
        let textHeight = ceil(font.ascender - font.descender)
        let textRect = CGRect(
            x: cell.minX + SheetMetrics.textInset + leadingInset,
            y: cell.minY + (cell.height - textHeight) / 2,
            width: cell.width - 2 * SheetMetrics.textInset - leadingInset,
            height: textHeight)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawSymbol(_ image: NSImage?, centeredIn rect: CGRect) {
        guard let image else { return }
        let size = image.size
        let target = CGRect(x: rect.midX - size.width / 2,
                            y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
    }

    private func placeholder(for field: TransactionEditField) -> String {
        switch field {
        case .date: String(localized: "Date")
        case .description: String(localized: "Description")
        case .notes: String(localized: "Notes")
        case .tags: String(localized: "Tags")
        case .amount, .splitAmount: String(localized: "Amount")
        case .splitAction: String(localized: "Action")
        case .splitMemo: String(localized: "Memo")
        case .transfer, .splitAccount: String(localized: "Account")
        case .splitQuantity: String(localized: "Quantity")
        }
    }

    private func drawEditableText(_ text: String, placeholder: String,
                                  drafting: Bool, in cell: CGRect,
                                  muted: Bool = false, trailing: Bool = false,
                                  leadingInset: CGFloat = 0,
                                  middleTruncate: Bool = false) {
        if !text.isEmpty {
            drawText(text, in: cell, trailing: trailing, muted: muted,
                     leadingInset: leadingInset, middleTruncate: middleTruncate)
        } else if drafting {
            drawText(placeholder, in: cell, trailing: trailing,
                     color: .tertiaryLabelColor, leadingInset: leadingInset)
        }
    }

    private func leg(_ row: SheetRow, _ index: Int,
                     drafting: Bool) -> (line: EditableSplit?, book: AutoSplitRow?) {
        if drafting, let d = draft, d.lines.indices.contains(index) {
            return (d.lines[index], nil)
        }
        return (nil, row.legs.indices.contains(index) ? row.legs[index] : nil)
    }

    private func skipForCursor(_ row: SheetRow, _ field: TransactionEditField?) -> Bool {
        guard let field else { return false }
        return cursor == SheetFocus(txn: row.txn, field: field)
    }

    private func drawLine(_ row: SheetRow, line: SheetLine, y: CGFloat, drafting: Bool) {
        let code = currencyCode

        func cell(_ column: SheetColumn) -> CGRect {
            frames.rect(column, y: y, height: lineHeight)
        }

        switch line {
        case .heading:
            if !skipForCursor(row, .date) {
                let date = drafting ? (draft?.date ?? row.base.date) : row.base.date
                drawText(dateFormat?.short(date) ?? "", in: cell(.date))
            }
            drawHandle(row, drafting: drafting, in: cell(.handle))
            if !skipForCursor(row, .description) {
                var inset: CGFloat = 0
                if row.base.hasDocument {
                    let box = cell(.description)
                    drawSymbol(SheetSymbols.paperclip,
                               centeredIn: CGRect(x: box.minX + 2, y: box.minY,
                                                  width: 14, height: box.height))
                    inset = 14
                }
                let text = drafting ? (draft?.description ?? "") : row.base.description
                drawEditableText(text, placeholder: placeholder(for: .description),
                                 drafting: drafting,
                                 in: cell(.description), leadingInset: inset)
            }
            if !row.base.isHeadingOnly, !skipForCursor(row, .transfer) {
                drawText(headingTransferName(row, drafting: drafting),
                         in: cell(.transfer), muted: true, middleTruncate: true)
            }
            if !row.base.isHeadingOnly {
                drawSymbol(ReconcileSymbols.image(for: row.base.reconcile),
                           centeredIn: cell(.reconcile))
            }
            if !row.base.isHeadingOnly, !skipForCursor(row, .amount) {
                let amount = (drafting ? focusLine()?.amount : nil) ?? row.base.amount
                drawText(AmountFormat.string(amount, code: code), in: cell(.amount),
                         trailing: true, negative: amount < 0, mono: true)
            }
            drawHeadingBalance(row, drafting: drafting, in: cell(.balance), code: code)

        case .notes:
            if !skipForCursor(row, .notes) {
                let text = drafting ? (draft?.notes ?? "") : row.base.notes
                drawEditableText(text, placeholder: placeholder(for: .notes),
                                 drafting: drafting,
                                 in: cell(.description), muted: true)
            }

        case .leg(let index):
            let leg = leg(row, index, drafting: drafting)
            if !skipForCursor(row, leg.line.map { .splitAction($0.id) }) {
                drawEditableText(leg.line?.action ?? leg.book?.legAction ?? "",
                                 placeholder: String(localized: "Action"),
                                 drafting: leg.line != nil,
                                 in: cell(.date), muted: true)
            }
            if !skipForCursor(row, leg.line.map { .splitMemo($0.id) }) {
                drawEditableText(leg.line?.memo ?? leg.book?.legMemo ?? "",
                                 placeholder: String(localized: "Memo"),
                                 drafting: leg.line != nil,
                                 in: cell(.description), muted: true)
            }
            if !skipForCursor(row, leg.line.map { .splitAccount($0.id) }) {
                let name = leg.line.map {
                    AccountSearch.name(of: $0.accountID, in: model.postableAccounts)
                } ?? leg.book?.legAccount ?? ""
                drawEditableText(name, placeholder: String(localized: "Account"),
                                 drafting: leg.line != nil,
                                 in: cell(.transfer), muted: true,
                                 middleTruncate: true)
            }
            let reconcile = leg.book?.legReconcile
                ?? leg.line?.splitID.flatMap { model.reconcileState(ofSplit: $0)?.rawValue }
                ?? ""
            if !reconcile.isEmpty {
                drawSymbol(ReconcileSymbols.image(for: reconcile),
                           centeredIn: cell(.reconcile))
            }
            if !skipForCursor(row, leg.line.map { .splitAmount($0.id) }) {
                let amount = leg.line?.amount ?? leg.book?.legAmount ?? 0
                drawText(AmountFormat.string(amount, code: leg.book?.legCurrencyCode ?? code),
                         in: cell(.amount), trailing: true, muted: leg.line == nil,
                         negative: amount < 0, mono: true)
            }
            drawLegBalance(row, line: leg.line, in: cell(.balance))

        case .addSplit:
            let box = cell(.description)
            drawSymbol(SheetSymbols.addSplit,
                       centeredIn: CGRect(x: box.minX + 2, y: box.minY,
                                          width: 14, height: box.height))
            drawText(String(localized: "Add Split"), in: box, muted: true,
                     leadingInset: 14)
        }
    }

    private func drawHandle(_ row: SheetRow, drafting: Bool, in rect: CGRect) {
        let expanded = drafting && draft?.isExpanded == true
        if expanded {
            drawSymbol(SheetSymbols.cancel, centeredIn: rect)
        } else if selectedTxn == row.txn {
            drawSymbol(SheetSymbols.pencil, centeredIn: rect)
        }
    }

    private func drawHeadingBalance(_ row: SheetRow, drafting: Bool,
                                    in rect: CGRect, code: String) {
        if drafting, let d = draft, d.imbalance != 0 {
            let text = AmountFormat.string(d.imbalance, code: code)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: smallFont, .foregroundColor: NSColor.systemOrange,
                .paragraphStyle: Self.rightPara,
            ]
            let textHeight = ceil(smallFont.ascender - smallFont.descender)
            let textRect = CGRect(x: rect.minX + 20,
                                  y: rect.minY + (rect.height - textHeight) / 2,
                                  width: rect.width - 20 - SheetMetrics.textInset,
                                  height: textHeight)
            (text as NSString).draw(in: textRect, withAttributes: attributes)
            let size = (text as NSString).size(withAttributes: attributes)
            drawSymbol(SheetSymbols.warning,
                       centeredIn: CGRect(x: textRect.maxX - size.width - 18,
                                          y: rect.minY, width: 14, height: rect.height))
        } else if let balance = row.base.runningBalance {
            drawText(AmountFormat.string(balance, code: code), in: rect,
                     trailing: true, mono: true)
        } else if !row.base.isHeadingOnly {
            drawText("—", in: rect, trailing: true, muted: true)
        }
    }

    private func drawLegBalance(_ row: SheetRow, line: EditableSplit?, in rect: CGRect) {
        guard let line else { return }
        let removable = (draft?.lines.count ?? 0) > 2
        if isForeign(line), !skipForCursor(row, .splitQuantity(line.id)) {
            let quantityRect = CGRect(x: rect.minX, y: rect.minY,
                                      width: rect.width - (removable ? 20 : 0),
                                      height: rect.height)
            if line.quantityText.isEmpty {
                drawText(String(localized: "Quantity"), in: quantityRect,
                         trailing: true, color: .tertiaryLabelColor)
            } else {
                drawText(line.quantityText, in: quantityRect, trailing: true, mono: true)
            }
        }
        if removable {
            drawSymbol(SheetSymbols.removeSplit, centeredIn: removeHotspot(in: rect))
        }
    }

    private func removeHotspot(in rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - 20, y: rect.minY, width: 16, height: rect.height)
    }

    private func headingTransferName(_ row: SheetRow, drafting: Bool) -> String {
        if drafting, let d = draft {
            guard let ci = d.counterpartyIndex(account: model.selectedAccountID)
            else { return String(localized: "— Split —") }
            return AccountSearch.name(of: d.lines[ci].accountID,
                                      in: model.postableAccounts)
        }
        return row.base.transferName
    }

    // MARK: Damage helpers (gnucash_sheet_redraw_block)

    private func damageBlock(ofTxn txn: GncGUID) {
        if let index = indexByTxn[txn] { setNeedsDisplay(blockRect(index)) }
    }

    private func damageBlocks(_ txns: Set<GncGUID>) {
        for txn in txns { damageBlock(ofTxn: txn) }
    }

    // MARK: Selection

    private var armsOnSelection: Bool { wholeBook || showAllSplits }

    /// Mirror the sheet's transaction selection into the model's split-based
    /// selection — the toolbar Edit button, attachments panel, and menu
    /// actions all read it. Deferred a beat: apply() runs inside a SwiftUI
    /// render pass, where model writes are illegal.
    private func mirrorSelection() {
        let ids = Set(selection.compactMap { model.anySplitID(ofTransaction: $0) })
        guard model.selectedSplitIDs != ids else { return }
        Task { @MainActor in
            self.model.selectedSplitIDs = ids
        }
    }

    private func requestSelection(_ txns: Set<GncGUID>, anchor: Int?, lead: Int?) {
        if let d = draft, !txns.contains(d.transactionID) {
            guard leaveDraft() else {
                let txn = d.transactionID
                NSSound.beep()
                applySelection([txn], anchor: indexByTxn[txn], lead: indexByTxn[txn])
                return
            }
        }
        applySelection(txns, anchor: anchor, lead: lead)
    }

    private func applySelection(_ txns: Set<GncGUID>, anchor: Int?, lead: Int?) {
        let before = selection
        selection = txns
        anchorBlock = anchor
        leadBlock = lead
        selectedTxn = txns.count == 1 ? txns.first : nil
        damageBlocks(before.union(txns))
        mirrorSelection()
        if armsOnSelection, draft == nil, let txn = selectedTxn {
            beginEdit(transaction: txn, expanded: false)
            damageBlock(ofTxn: txn)
        }
    }

    private func moveSelection(step: Int, extend: Bool) {
        guard !rows.isEmpty else { return }
        let current = leadBlock
            ?? selectedTxn.flatMap { indexByTxn[$0] }
            ?? (rows.count - 1)
        let next = max(0, min(rows.count - 1, current + step))
        if extend {
            let anchor = anchorBlock ?? current
            let range = min(anchor, next)...max(anchor, next)
            let txns = Set(range.map { rows[$0].txn })
            requestSelection(txns, anchor: anchor, lead: next)
        } else {
            requestSelection([rows[next].txn], anchor: next, lead: next)
        }
        _ = scrollToVisible(blockRect(next).insetBy(dx: 0, dy: -lineHeight))
    }

    // MARK: Mouse (find cell by pixel — gnucash-sheet.c button handler)

    override func mouseDown(with event: NSEvent) {
        suggestions.hide()
        let point = convert(event.locationInWindow, from: nil)
        guard let block = blockIndex(atY: point.y) else {
            if leaveDraft() { applySelection([], anchor: nil, lead: nil) }
            window?.makeFirstResponder(self)
            return
        }
        let row = rows[block]
        let modifiers = event.modifierFlags
            .intersection([.command, .shift, .option, .control])

        if modifiers.contains(.command) {
            var txns = selection
            if txns.contains(row.txn) { txns.remove(row.txn) } else { txns.insert(row.txn) }
            requestSelection(txns, anchor: block, lead: block)
            window?.makeFirstResponder(self)
            return
        }
        if modifiers.contains(.shift) {
            let anchor = anchorBlock ?? block
            let range = min(anchor, block)...max(anchor, block)
            requestSelection(Set(range.map { rows[$0].txn }), anchor: anchor, lead: block)
            window?.makeFirstResponder(self)
            return
        }
        guard modifiers.isEmpty else { return }

        if selectedTxn != row.txn {
            // First click's job is selection (spec 2/4) — never the cursor.
            requestSelection([row.txn], anchor: block, lead: block)
            window?.makeFirstResponder(self)
            return
        }

        guard let column = frames.column(atX: point.x) else { return }
        let plan = linePlan(row)
        let lineIndex = max(0, min(plan.count - 1,
                                   Int((point.y - yOffsets[block]) / lineHeight)))
        let line = plan[lineIndex]
        let drafting = draft?.transactionID == row.txn

        if column == .handle, case .heading = line {
            let expanded = drafting && draft?.isExpanded == true
            if expanded { escapePressed() } else { editExpanded() }
            return
        }
        if column == .reconcile {
            if case .heading = line, let split = row.base.anchorSplit {
                model.cycleReconcileState(splitID: split)
            } else if case .leg(let index) = line {
                let leg = leg(row, index, drafting: drafting)
                if let split = leg.book?.id ?? leg.line?.splitID {
                    model.cycleReconcileState(splitID: split)
                }
            }
            return
        }
        if case .leg(let index) = line, column == .balance, drafting,
           (draft?.lines.count ?? 0) > 2 {
            let cellRect = frames.rect(.balance,
                                       y: yOffsets[block] + CGFloat(lineIndex) * lineHeight,
                                       height: lineHeight)
            if removeHotspot(in: cellRect).contains(point),
               let d = draft, d.lines.indices.contains(index) {
                removeLine(d.lines[index].id)
                return
            }
        }

        let place: SheetTap? = switch (column, line) {
        case (.date, .heading): .heading(.date)
        case (.description, .heading): .heading(.description)
        case (.transfer, .heading): row.base.isHeadingOnly ? nil : .heading(.transfer)
        case (.amount, .heading): row.base.isHeadingOnly ? nil : .heading(.amount)
        case (.description, .notes): .heading(.notes)
        case (.date, .leg(let index)): .leg(index, .action)
        case (.description, .leg(let index)): .leg(index, .memo)
        case (.transfer, .leg(let index)): .leg(index, .account)
        case (.amount, .leg(let index)): .leg(index, .amount)
        case (.balance, .leg(let index)): .leg(index, .quantity)
        case (_, .addSplit): .addSplit
        default: nil
        }
        guard let place else { return }
        placeCursor(row, place: place)
    }

    /// Right-click: the shared transaction actions, over this row's selection
    /// (right-click on an unselected transaction selects it first, as native
    /// tables do).
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let block = blockIndex(atY: point.y) {
            let txn = rows[block].txn
            if !selection.contains(txn) {
                guard leaveDraft() else { return nil }
                applySelection([txn], anchor: block, lead: block)
            }
        }
        let splitIDs = Set(selection.compactMap { model.anySplitID(ofTransaction: $0) })
        return NSHostingMenu(rootView: TransactionActions(
            model: model, splitID: splitIDs.first, selectionSplitIDs: splitIDs))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: moveSelection(step: 1, extend: event.modifierFlags.contains(.shift))
        case 126: moveSelection(step: -1, extend: event.modifierFlags.contains(.shift))
        case 53: escapePressed()
        case 36:
            if let txn = selectedTxn, draft?.transactionID != txn {
                editExpanded()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers?.lowercased() == "e",
           selectedTxn != nil || draft != nil {
            editExpanded()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Cursor + the one editor (gnc_item_edit_configure/update)

    private func placeCursor(_ row: SheetRow, place: SheetTap) {
        if draft?.transactionID != row.txn {
            guard leaveDraft() else { return }
            beginEdit(transaction: row.txn, expanded: false)
        }
        guard let d = draft else { return }
        switch place {
        case .heading(let field):
            setCursor(SheetFocus(txn: row.txn, field: field))
        case .leg(let index, let legField):
            guard d.lines.indices.contains(index) else { return }
            let line = d.lines[index]
            switch legField {
            case .action: setCursor(SheetFocus(txn: row.txn, field: .splitAction(line.id)))
            case .memo: setCursor(SheetFocus(txn: row.txn, field: .splitMemo(line.id)))
            case .account: setCursor(SheetFocus(txn: row.txn, field: .splitAccount(line.id)))
            case .amount: setCursor(SheetFocus(txn: row.txn, field: .splitAmount(line.id)))
            case .quantity:
                guard isForeign(line) else { return }
                setCursor(SheetFocus(txn: row.txn, field: .splitQuantity(line.id)))
            }
        case .addSplit:
            appendLine()
        }
    }

    private func isAccountField(_ field: TransactionEditField) -> Bool {
        if case .transfer = field { return true }
        if case .splitAccount = field { return true }
        return false
    }

    private func setCursor(_ focus: SheetFocus?) {
        if let old = cursor, isAccountField(old.field), focus?.field != old.field {
            resolveCombo()
        }
        let oldRect = cursor.flatMap { cellRect(of: $0) }
        cursor = focus
        if let oldRect { setNeedsDisplay(oldRect.insetBy(dx: -2, dy: -2)) }
        guard let focus, let rect = cellRect(of: focus) else {
            itemEdit.isHidden = true
            suggestions.hide()
            window?.makeFirstResponder(self)
            return
        }
        setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
        configureEditor(for: focus, in: rect)
        _ = scrollToVisible(rect.insetBy(dx: 0, dy: -2 * lineHeight))
    }

    private func cellRect(of focus: SheetFocus) -> CGRect? {
        guard let block = indexByTxn[focus.txn] else { return nil }
        let row = rows[block]
        let plan = linePlan(row)

        func lineIndex(_ wanted: SheetLine) -> Int? { plan.firstIndex(of: wanted) }
        func legIndex(_ id: UUID) -> Int? {
            draft?.lines.firstIndex { $0.id == id }
        }

        let target: (line: Int, column: SheetColumn)? = switch focus.field {
        case .date: lineIndex(.heading).map { ($0, .date) }
        case .description: lineIndex(.heading).map { ($0, .description) }
        case .transfer: lineIndex(.heading).map { ($0, .transfer) }
        case .amount: lineIndex(.heading).map { ($0, .amount) }
        case .notes: lineIndex(.notes).map { ($0, .description) }
        case .tags: nil
        case .splitAction(let id):
            legIndex(id).flatMap { lineIndex(.leg($0)) }.map { ($0, .date) }
        case .splitMemo(let id):
            legIndex(id).flatMap { lineIndex(.leg($0)) }.map { ($0, .description) }
        case .splitAccount(let id):
            legIndex(id).flatMap { lineIndex(.leg($0)) }.map { ($0, .transfer) }
        case .splitAmount(let id):
            legIndex(id).flatMap { lineIndex(.leg($0)) }.map { ($0, .amount) }
        case .splitQuantity(let id):
            legIndex(id).flatMap { lineIndex(.leg($0)) }.map { ($0, .balance) }
        }
        guard let target else { return nil }
        return frames.rect(target.column,
                           y: yOffsets[block] + CGFloat(target.line) * lineHeight,
                           height: lineHeight)
    }

    private func configureEditor(for focus: SheetFocus, in rect: CGRect) {
        let trailing: Bool
        switch focus.field {
        case .amount, .splitAmount, .splitQuantity: trailing = true
        default: trailing = false
        }
        itemEdit.font = trailing ? monoFont : bodyFont
        itemEdit.alignment = trailing ? .right : .left

        let fieldHeight = ceil(itemEdit.font!.ascender - itemEdit.font!.descender) + 2
        itemEdit.frame = CGRect(
            x: rect.minX + SheetMetrics.textInset - 2,
            y: rect.minY + (rect.height - fieldHeight) / 2,
            width: rect.width - 2 * (SheetMetrics.textInset - 2),
            height: fieldHeight)

        comboTyped = false
        itemEdit.placeholderString = placeholder(for: focus.field)
        if isAccountField(focus.field) {
            itemEdit.stringValue = AccountSearch.name(of: comboAccountID(of: focus.field),
                                                      in: model.postableAccounts)
        } else {
            itemEdit.stringValue = editText(field: focus.field)
        }
        itemEdit.isHidden = false
        itemEdit.selectText(nil)
        if isAccountField(focus.field) {
            showSuggestions()
        } else {
            suggestions.hide()
        }
    }

    private func positionEditor() {
        guard let cursor else { return }
        guard let rect = cellRect(of: cursor) else {
            setCursor(nil)
            return
        }
        let fieldHeight = itemEdit.frame.height
        itemEdit.frame = CGRect(
            x: rect.minX + SheetMetrics.textInset - 2,
            y: rect.minY + (rect.height - fieldHeight) / 2,
            width: rect.width - 2 * (SheetMetrics.textInset - 2),
            height: fieldHeight)
    }

    // MARK: Editor text plumbing

    private func editText(field: TransactionEditField) -> String {
        guard let d = draft else { return "" }
        switch field {
        case .date: return dateFormat?.short(d.date) ?? ""
        case .description: return d.description
        case .notes: return d.notes
        case .tags: return d.tagsText
        case .amount:
            guard let index = d.focusIndex(account: model.selectedAccountID)
            else { return "" }
            return d.lines[index].amountText
        case .splitAction(let id): return draftLine(id: id)?.action ?? ""
        case .splitMemo(let id): return draftLine(id: id)?.memo ?? ""
        case .splitAmount(let id): return draftLine(id: id)?.amountText ?? ""
        case .splitQuantity(let id): return draftLine(id: id)?.quantityText ?? ""
        case .transfer, .splitAccount: return ""
        }
    }

    private func applyEdit(field: TransactionEditField, text: String) {
        switch field {
        case .date:
            withDraft { d in
                if let date = dateFormat?.parseShort(text) { d.date = date }
            }
        case .description:
            withDraft { $0.description = text }
        case .notes:
            withDraft { $0.notes = text }
        case .tags:
            withDraft { $0.tagsText = text }
        case .amount:
            withDraft { d in
                if let index = d.focusIndex(account: model.selectedAccountID) {
                    d.setAmountText(text, at: index)
                }
            }
        case .splitAction(let id):
            withLine(id) { $0.action = text }
        case .splitMemo(let id):
            withLine(id) { $0.memo = text }
        case .splitAmount(let id):
            withLineIndex(id) { d, index in d.setAmountText(text, at: index) }
        case .splitQuantity(let id):
            withLine(id) { $0.quantityText = text }
        case .transfer, .splitAccount:
            break
        }
        if let txn = draft?.transactionID { damageBlock(ofTxn: txn) }
    }

    // MARK: NSTextFieldDelegate — the item-edit's keys

    func controlTextDidChange(_ notification: Notification) {
        guard let cursor else { return }
        let text = itemEdit.stringValue
        if isAccountField(cursor.field) {
            comboTyped = true
            if let exact = exactMatch(text) {
                comboPick(exact)
            } else {
                showSuggestions()
            }
        } else {
            applyEdit(field: cursor.field, text: text)
        }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            moveCursor(backwards: false)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            moveCursor(backwards: true)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if suggestions.isVisible, let node = suggestions.highlighted {
                comboPick(node)
                suggestions.hide()
                return true
            }
            if let cursor, isAccountField(cursor.field) {
                guard resolveCombo() else { return true }
            }
            saveEdit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let cursor, isAccountField(cursor.field), comboTyped {
                itemEdit.stringValue = AccountSearch.name(
                    of: comboAccountID(of: cursor.field), in: model.postableAccounts)
                comboTyped = false
                suggestions.hide()
                return true
            }
            escapePressed()
            return true
        case #selector(NSResponder.moveDown(_:)):
            if suggestions.isVisible { suggestions.move(1); return true }
            return false
        case #selector(NSResponder.moveUp(_:)):
            if suggestions.isVisible { suggestions.move(-1); return true }
            return false
        default:
            return false
        }
    }

    // MARK: Combo

    private func comboAccountID(of field: TransactionEditField) -> GncGUID? {
        switch field {
        case .transfer: return counterpartyAccountID
        case .splitAccount(let id): return draftLine(id: id)?.accountID
        default: return nil
        }
    }

    private func exactMatch(_ text: String) -> AccountNode? {
        model.postableAccounts.first {
            $0.fullName.caseInsensitiveCompare(text) == .orderedSame
        }
    }

    private var comboMatches: [AccountNode] {
        let query = comboTyped ? itemEdit.stringValue : ""
        return Array(AccountSearch.matches(query, in: model.postableAccounts).prefix(30))
    }

    private func showSuggestions() {
        guard let window, !itemEdit.isHidden else { return }
        let fieldRectInWindow = convert(itemEdit.frame, to: nil)
        suggestions.show(matches: comboMatches, below: fieldRectInWindow, of: window)
    }

    private func comboPick(_ node: AccountNode) {
        guard let cursor else { return }
        switch cursor.field {
        case .transfer:
            withDraft { d in
                if let ci = d.counterpartyIndex(account: model.selectedAccountID) {
                    d.lines[ci].accountID = node.id
                }
            }
        case .splitAccount(let id):
            withLine(id) { $0.accountID = node.id }
        default:
            return
        }
        comboTyped = false
        itemEdit.stringValue = node.fullName
        suggestions.hide()
        damageBlock(ofTxn: cursor.txn)
    }

    /// Resolve on leave/⏎: an exact name, else the best match if typed, else
    /// keep the stored account. An emptied or matchless edit commits nothing —
    /// GnuCash's strict combo refuses rather than guesses
    /// (`gnc_combo_cell_leave` keeps a changed value only when it is in the
    /// list) — so the draft keeps the leg where it already posts.
    @discardableResult
    private func resolveCombo() -> Bool {
        guard let cursor, isAccountField(cursor.field) else { return true }
        if let exact = exactMatch(itemEdit.stringValue) {
            comboPick(exact)
            return true
        }
        if comboTyped,
           !itemEdit.stringValue.trimmingCharacters(in: .whitespaces).isEmpty,
           let best = comboMatches.first {
            comboPick(best)
            return true
        }
        return comboAccountID(of: cursor.field) != nil
    }

    // MARK: Draft plumbing (GnuCash pending transaction)

    private var currencyCode: String {
        model.postableAccounts.first { $0.id == model.selectedAccountID }?.currencyCode
            ?? model.reportCurrency.mnemonic
    }

    private func focusLine() -> EditableSplit? {
        guard let d = draft,
              let index = d.focusIndex(account: model.selectedAccountID)
        else { return nil }
        return d.lines[index]
    }

    private var counterpartyAccountID: GncGUID? {
        guard let d = draft,
              let ci = d.counterpartyIndex(account: model.selectedAccountID)
        else { return nil }
        return d.lines[ci].accountID
    }

    private func draftLine(id: UUID) -> EditableSplit? {
        draft?.lines.first { $0.id == id }
    }

    private func isForeign(_ line: EditableSplit) -> Bool {
        guard let id = line.accountID,
              let node = model.postableAccounts.first(where: { $0.id == id }),
              let d = draft
        else { return false }
        let code = d.currencyOverride?.mnemonic
            ?? model.transactionCurrency(for: d.lines.compactMap(\.accountID)).mnemonic
        return node.currencyCode != code
    }

    private func withDraft(_ apply: (inout TransactionDraft) -> Void) {
        guard var d = draft else { return }
        apply(&d)
        draft = d
    }

    private func withLineIndex(_ id: UUID,
                               _ apply: (inout TransactionDraft, Int) -> Void) {
        guard var d = draft,
              let index = d.lines.firstIndex(where: { $0.id == id }) else { return }
        apply(&d, index)
        draft = d
    }

    private func withLine(_ id: UUID, _ apply: (inout EditableSplit) -> Void) {
        withLineIndex(id) { d, index in apply(&d.lines[index]) }
    }

    private func beginEdit(transaction txn: GncGUID, expanded: Bool) {
        if draft?.transactionID == txn {
            if expanded, draft?.isExpanded != true {
                withDraft { $0.isExpanded = true }
                geometryChanged(fromBlock: indexByTxn[txn])
            }
            return
        }
        guard var d = TransactionDraft(model: model, transactionID: txn,
                                       expanded: expanded)
        else { return }
        d.isExpanded = expanded
        draft = d
        original = d
        if expanded { geometryChanged(fromBlock: indexByTxn[txn]) }
        else { damageBlock(ofTxn: txn) }
    }

    private func clearDraft() {
        let txn = draft?.transactionID
        let wasTall = draft.map {
            $0.isExpanded || $0.lines.count != bookLegCount(of: $0.transactionID)
        } ?? false
        draft = nil
        original = nil
        cursor = nil
        itemEdit.isHidden = true
        suggestions.hide()
        if let txn {
            if wasTall { geometryChanged(fromBlock: indexByTxn[txn]) }
            else { damageBlock(ofTxn: txn) }
        }
        window?.makeFirstResponder(self)
    }

    private func bookLegCount(of txn: GncGUID) -> Int {
        indexByTxn[txn].map { rows[$0].legs.count } ?? 0
    }

    private func leaveDraft() -> Bool {
        guard let d = draft else { return true }
        if d == original {
            clearDraft()
            return true
        }
        guard d.isBalanced else {
            onError?(blockedMessage(for: d))
            return false
        }
        do {
            try commit(d)
            clearDraft()
            return true
        } catch {
            onError?(error.localizedDescription)
            return false
        }
    }

    private func blockedMessage(for d: TransactionDraft) -> String {
        let what = if !d.lines.allSatisfy(\.quantityIsValid) {
            String(localized: "A quantity isn’t a number — clear it or fix it.")
        } else if d.validLineCount < 2 {
            String(localized: "A transaction needs at least two accounts.")
        } else {
            String(localized: "The splits don’t balance — off by \(AmountFormat.string(d.imbalance, code: currencyCode)).")
        }
        return what + " " + String(localized: "Press ⎋ to discard the edit.")
    }

    private func commit(_ d: TransactionDraft) throws {
        try model.updateTransaction(
            id: d.transactionID, date: d.date, description: d.description,
            currency: d.currencyOverride
                ?? model.transactionCurrency(for: d.lines.compactMap(\.accountID)),
            splits: d.lines.filter { $0.accountID != nil }.map(\.asInput),
            tags: d.parsedTags, notes: d.notes)
    }

    func settleDirtyDraft() {
        if let d = draft, d != original {
            if d.isBalanced { try? commit(d) }
            else { onError?(String(localized: "Edit discarded — it didn’t balance.")) }
        }
        clearDraft()
    }

    // MARK: Operations

    func editExpanded() {
        guard let txn = selectedTxn ?? draft?.transactionID else { return }
        if draft?.transactionID == txn {
            if draft?.isExpanded != true {
                withDraft { $0.isExpanded = true }
                geometryChanged(fromBlock: indexByTxn[txn])
            }
        } else {
            guard leaveDraft() else { return }
            beginEdit(transaction: txn, expanded: true)
        }
        setCursor(SheetFocus(txn: txn, field: .description))
        if let block = indexByTxn[txn] {
            let clip = enclosingScrollView?.contentSize.height ?? 400
            let rect = blockRect(block)
            _ = scrollToVisible(CGRect(x: 0, y: rect.minY, width: 1,
                                       height: min(rect.height + lineHeight, clip)))
        }
    }

    private func appendLine() {
        guard var d = draft else { return }
        var line = EditableSplit()
        let residual = -d.imbalance
        if residual != 0 {
            line.amountText = NSDecimalNumber(decimal: residual).stringValue
        }
        d.lines.append(line)
        draft = d
        geometryChanged(fromBlock: indexByTxn[d.transactionID])
        setCursor(SheetFocus(txn: d.transactionID, field: .splitMemo(line.id)))
    }

    private func removeLine(_ id: UUID) {
        if let cursor, lineID(of: cursor.field) == id {
            setCursor(nil)
        }
        withDraft { d in
            guard d.lines.count > 2,
                  let index = d.lines.firstIndex(where: { $0.id == id }) else { return }
            d.lines.remove(at: index)
        }
        if let txn = draft?.transactionID {
            geometryChanged(fromBlock: indexByTxn[txn])
        }
    }

    private func lineID(of field: TransactionEditField) -> UUID? {
        switch field {
        case .splitAccount(let id), .splitMemo(let id), .splitAction(let id),
             .splitAmount(let id), .splitQuantity(let id):
            id
        default:
            nil
        }
    }

    private func saveEdit() {
        guard let d = draft else { return }
        if d == original {
            clearDraft()
            rearm()
            return
        }
        guard d.isBalanced else {
            onError?(blockedMessage(for: d))
            return
        }
        do {
            try commit(d)
            clearDraft()
            rearm()
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func escapePressed() {
        if draft != nil {
            clearDraft()
            rearm()
        } else {
            applySelection([], anchor: nil, lead: nil)
        }
    }

    private func rearm() {
        guard armsOnSelection, let txn = selectedTxn else { return }
        beginEdit(transaction: txn, expanded: false)
    }

    // MARK: ⇥ traversal — visible fields only (spec point 4)

    private func focusOrder() -> [SheetFocus] {
        guard let d = draft else { return [] }
        let txn = d.transactionID
        let legsVisible = d.isExpanded || armsOnSelection
        var order: [SheetFocus] = [
            SheetFocus(txn: txn, field: .date),
            SheetFocus(txn: txn, field: .description),
        ]
        if showDetails { order.append(SheetFocus(txn: txn, field: .notes)) }
        if !wholeBook {
            if d.counterpartyIndex(account: model.selectedAccountID) != nil {
                order.append(SheetFocus(txn: txn, field: .transfer))
            }
            order.append(SheetFocus(txn: txn, field: .amount))
        }
        if legsVisible {
            for line in d.lines {
                order.append(SheetFocus(txn: txn, field: .splitAction(line.id)))
                order.append(SheetFocus(txn: txn, field: .splitMemo(line.id)))
                order.append(SheetFocus(txn: txn, field: .splitAccount(line.id)))
                order.append(SheetFocus(txn: txn, field: .splitAmount(line.id)))
                if isForeign(line) {
                    order.append(SheetFocus(txn: txn, field: .splitQuantity(line.id)))
                }
            }
        }
        return order
    }

    private func moveCursor(backwards: Bool) {
        let order = focusOrder()
        guard !order.isEmpty else { return }
        guard let current = cursor, let index = order.firstIndex(of: current) else {
            if let first = order.first { setCursor(first) }
            return
        }
        let next = backwards
            ? order[index == 0 ? order.count - 1 : index - 1]
            : order[(index + 1) % order.count]
        setCursor(next)
    }
}

// MARK: - The one text field

/// Chromeless single-line field: the sheet draws the focus ring and the
/// backgrounds; the field contributes only live text — the same box in both
/// states (HIG Text fields; the placeholder names the field).
private final class ItemEditField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 13)
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        if let cell = cell as? NSTextFieldCell {
            cell.isScrollable = true
            cell.wraps = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Suggestions (combocell-gnome.c's popup list)

@MainActor
private final class SuggestionsController: NSObject, NSTableViewDataSource,
                                           NSTableViewDelegate {
    private var panel: NSPanel?
    private var table = NSTableView()
    private var matches: [AccountNode] = []
    var onPick: ((AccountNode) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }
    var highlighted: AccountNode? {
        let row = table.selectedRow
        return matches.indices.contains(row) ? matches[row] : nil
    }

    func show(matches: [AccountNode], below fieldRectInWindow: CGRect,
              of window: NSWindow) {
        self.matches = matches
        guard !matches.isEmpty else {
            hide()
            return
        }
        let panel = ensurePanel()
        table.reloadData()
        if table.selectedRow < 0, !matches.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        let rowHeight = table.rowHeight + table.intercellSpacing.height
        let height = min(CGFloat(matches.count) * rowHeight + 4, 240)
        let screenRect = window.convertToScreen(fieldRectInWindow)
        panel.setFrame(CGRect(x: screenRect.minX,
                              y: screenRect.minY - height - 2,
                              width: max(screenRect.width, 260), height: height),
                       display: true)
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ step: Int) {
        guard !matches.isEmpty else { return }
        let next = max(0, min(matches.count - 1, table.selectedRow + step))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 260, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true

        let column = NSTableColumn(identifier: .init("account"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 19
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.style = .plain

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        panel.contentView = scroll
        self.panel = panel
        return panel
    }

    @objc private func rowClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard matches.indices.contains(row) else { return }
        onPick?(matches[row])
    }

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { matches.count }
    }

    nonisolated func tableView(_ tableView: NSTableView,
                               viewFor tableColumn: NSTableColumn?,
                               row: Int) -> NSView? {
        MainActor.assumeIsolated {
            guard matches.indices.contains(row) else { return nil }
            let text = NSTextField(labelWithString: matches[row].fullName)
            text.font = NSFont.systemFont(ofSize: 12)
            text.lineBreakMode = .byTruncatingMiddle
            return text
        }
    }
}

// MARK: - Header (gnucash-header.c: a separate strip, same column frames)

@MainActor
private final class SheetHeaderView: NSView {
    var frames = SheetMetrics.Frames(totalWidth: 800) {
        didSet { needsDisplay = true }
    }
    /// HIG Lists and tables: click a heading to sort; click again to reverse.
    var sortState: (column: SheetColumn, reversed: Bool)? {
        didSet {
            if sortState?.column != oldValue?.column
                || sortState?.reversed != oldValue?.reversed {
                needsDisplay = true
            }
        }
    }
    var onSort: ((SheetColumn) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for column in SheetColumn.allCases {
            let rect = frames.rect(column, y: 0, height: bounds.height)
            let para = NSMutableParagraphStyle()
            para.alignment = column.trailing ? .right : .left
            para.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ]
            let textHeight = ceil(font.ascender - font.descender)
            let title = column.title as NSString
            let textRect = CGRect(x: rect.minX + SheetMetrics.textInset,
                                  y: rect.minY + (rect.height - textHeight) / 2,
                                  width: rect.width - 2 * SheetMetrics.textInset - 10,
                                  height: textHeight)
            title.draw(in: textRect, withAttributes: attributes)
            if let sortState, sortState.column == column {
                let indicator = sortState.reversed ? SheetSymbols.sortDown
                                                   : SheetSymbols.sortUp
                let titleWidth = min(title.size(withAttributes: attributes).width,
                                     textRect.width)
                let x = column.trailing ? textRect.maxX - titleWidth - 12
                                        : textRect.minX + titleWidth + 2
                indicator?.draw(in: CGRect(x: x, y: (bounds.height - 8) / 2,
                                           width: 10, height: 8),
                                from: .zero, operation: .sourceOver, fraction: 1,
                                respectFlipped: true, hints: nil)
            }
        }
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for column in SheetColumn.allCases where column != .date && column != .handle {
            CGRect(x: frames.x[column.rawValue] - 0.5, y: 0,
                   width: 1, height: bounds.height - 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let column = frames.column(atX: point.x), column.sortable else { return }
        onSort?(column)
    }
}

// MARK: - Container: header strip + scroll view

@MainActor
private final class SheetContainerView: NSView {
    let headerView = SheetHeaderView()
    let scrollView = NSScrollView()
    let sheet: SheetView

    init(model: AppModel, wholeBook: Bool) {
        sheet = SheetView(model: model, wholeBook: wholeBook)
        super.init(frame: .zero)
        sheet.header = headerView
        scrollView.documentView = sheet
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(headerView)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let header = CGRect(x: 0, y: bounds.height - SheetMetrics.headerHeight,
                            width: bounds.width, height: SheetMetrics.headerHeight)
        headerView.frame = header
        scrollView.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                  height: bounds.height - SheetMetrics.headerHeight)
        // The shell's entry/summary bars arrive as safe-area insets; keep the
        // last transaction scrollable above them.
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0,
                                                bottom: safeAreaInsets.bottom,
                                                right: 0)
        sheet.updateWidth(scrollView.contentSize.width)
    }
}

#endif
