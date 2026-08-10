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
//  AppKit, so everything a framework would have given it for free is built by
//  hand here:
//
//   * Accessibility is a real `NSAccessibilityTable` — a row proxy per
//     transaction, a cell proxy per column, selection reflected both ways,
//     and an "Unreconciled" `NSAccessibilityCustomRotor`. The tree is built
//     on the first AX query and dropped when the rows change, so a session
//     with no assistive client pays nothing.
//   * The mouse-only gestures have keys: ⌥⌘R cycles reconcile, ⌥⌘A adds a
//     split, ⌥⌘⌫ removes the one under the cursor. VoiceOver reaches the
//     same acts through each row's custom actions.
//   * Dynamic Type reaches the header strip and the suggestions popup, which
//     are separate views and had stayed at fixed 11/12pt.
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

    @AppStorage("registerViewStyle") private var style = RegisterStyle.basic
    /// Resolved against the sheet's own window, not here: `automatic` depends
    /// on the display the register is showing on, and a SwiftUI view has no
    /// window to ask.
    @AppStorage(AppearanceKey.registerRowHeight) private var rowHeight = RegisterRowHeight.automatic
    /// Which columns are switched off, as a bitmask. Shared with the header's
    /// own Control-click menu through `UserDefaults`, so either can drive it.
    @AppStorage(RegisterColumnVisibility.key) private var hiddenColumns = 0
    @State private var saveError: String?

    var body: some View {
        SheetHost(model: model, wholeBook: wholeBook,
                  rowsKey: rowsKey,
                  accountKey: accountKey,
                  style: wholeBook ? .journal : style,
                  fontScale: fontScale,
                  rowHeight: rowHeight,
                  hiddenColumns: hiddenColumns,
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
    let style: RegisterStyle
    let fontScale: CGFloat
    let rowHeight: RegisterRowHeight
    let hiddenColumns: Int
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
        view.headerView.onResize = { [weak view] column, width in
            view?.sheet.resizeColumn(column, to: width)
        }
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
                         style: style,
                         fontScale: fontScale, rowHeight: rowHeight,
                         hiddenColumns: hiddenColumns, dateFormat: dateFormat,
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
    /// GnuCash's Num field — a cheque number or the bank reference an import
    /// carried in. The model has always had it and the register has always
    /// been able to *sort* by it; nothing ever drew it.
    var number: String
    var description: String
    var notes: String
    /// Joined for display; the draft owns the editable text.
    var tags: String
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

/// The register's columns, in the order they are laid out.
///
/// **Num is not among them.** It is blank on the overwhelming majority of rows —
/// a cheque number or a bank reference, present when a transaction happens to
/// have one — so as a column it spent width on emptiness in every row to serve
/// a few. It now lives on its own line inside the disclosed detail, next to
/// Notes and Tags, where it is still fully editable.
///
/// `handle` (the edit pencil) sits immediately after `date`, so the row's two
/// affordances read left to right as disclosure-then-edit: the caret occupies a
/// gutter inside Date's own cell, and the pencil follows it.
private enum SheetColumn: Int, CaseIterable {
    case date, description, transfer, reconcile, amount, balance

    var title: String {
        switch self {
        case .date: String(localized: "Date")
        case .description: String(localized: "Description")
        case .transfer: String(localized: "Transfer")
        case .reconcile: String(localized: "R")
        case .amount: String(localized: "Amount")
        case .balance: String(localized: "Balance")
        }
    }

    var trailing: Bool { self == .amount || self == .balance }
    var sortable: Bool {
        self == .date || self == .description || self == .amount
    }

    /// Whether the column may be switched off.
    ///
    /// Date, Description and Amount are what makes this a register rather than
    /// a list, and the handle column carries the disclosure triangle and the
    /// edit pencil — hiding any of them would take away something the register
    /// has no other way to offer. The rest are the user's.
    ///
    /// Hiding a column hides **its editor too**: a field with no box cannot be
    /// clicked or tabbed to (see `focusOrder`). That is what hiding means, it
    /// is reversible from the same menu, and it is worth knowing for Balance in
    /// particular — on a leg row that column carries the foreign or share
    /// quantity (FR-REG-07), not a running balance.
    var canHide: Bool {
        switch self {
        case .transfer, .reconcile, .balance: true
        case .date, .description, .amount: false
        }
    }

    /// The heading a menu calls it by. `title` is empty for the handle column
    /// and a bare "R" for reconcile, neither of which reads as a menu item.
    var menuTitle: String {
        self == .reconcile ? String(localized: "Reconciled") : title
    }
}

/// Which columns are switched off, persisted as a bitmask.
///
/// A mask rather than a set because `@AppStorage` carries an `Int` natively:
/// the SwiftUI menus and this AppKit sheet then read and write the *same*
/// defaults key, and a change from either side reaches the other without a
/// second channel to keep in step.
public enum RegisterColumnVisibility {
    public static let key = "registerHiddenColumns2"

    fileprivate static func hidden(from mask: Int) -> Set<SheetColumn> {
        Set(SheetColumn.allCases.filter { $0.canHide && mask & (1 << $0.rawValue) != 0 })
    }

    fileprivate static func mask(of hidden: Set<SheetColumn>) -> Int {
        hidden.reduce(0) { $0 | (1 << $1.rawValue) }
    }

    /// The columns a menu may offer, in register order, as plain values — so
    /// the SwiftUI menus can build the same list without seeing the sheet's
    /// private column enum.
    public static var hideable: [(id: Int, title: String)] {
        SheetColumn.allCases.filter(\.canHide).map { ($0.rawValue, $0.menuTitle) }
    }

    public static func isHidden(_ id: Int, in mask: Int) -> Bool { mask & (1 << id) != 0 }
    public static func toggling(_ id: Int, in mask: Int) -> Int { mask ^ (1 << id) }
}

private enum SheetLine: Equatable {
    case heading
    case notes
    /// Tags were editable only in the modal editor — the register carried the
    /// field in its draft and in its tab order but mapped it to no cell at
    /// all, so the one place you keep transactions could not touch them.
    case tags
    case leg(Int)
    case addSplit
}

private enum SheetMetrics {
    static let headerHeight: CGFloat = 26
    static let textInset: CGFloat = 5
    /// A column may not be dragged narrower than this.
    static let minColumnWidth: CGFloat = 28
    /// How close to a ruler counts as grabbing it. Six points of target either
    /// side: three was a 6pt-wide sliver that had to be hit exactly, which is
    /// most of why the columns read as fixed rather than merely fiddly.
    static let resizeGrab: CGFloat = 6

    /// The disclosure triangle's gutter at the leading edge of the first
    /// column. HIG *Outline views*: "Expose data hierarchy in the first
    /// column only" — so the triangle lives inside Date, not in a column of
    /// its own and not on the trailing edge (a trailing chevron is the iOS
    /// *navigation* indicator, a different meaning).
    /// The base width, at a 24pt row and 100% Text Size; the view scales it
    /// (`SheetView.caretGutter`) so the gutter tracks the glyph it holds.
    static let caretGutter: CGFloat = 14
    /// The pencil sits beside the caret rather than in a column of its own, so
    /// the row reads disclose-then-edit before the date rather than putting the
    /// date between the two.
    static let editGutter: CGFloat = 20
    static let washRadius: CGFloat = 8
    static let washInset: CGFloat = 4

    struct Frames {
        var x: [CGFloat]
        var width: [CGFloat]

        /// - Parameters:
        ///   - natural: what each column needs for the content actually in it,
        ///     measured in the current font (`SheetView.measureNaturalWidths`).
        ///     These were seven literals, which is how a date came to
        ///     ellipsise: 80pt had to hold the disclosure gutter and two
        ///     insets — about 56pt of text — and none of it moved when the
        ///     Text Size or the date format did. Row *height* was measured
        ///     from the display; width never was.
        ///   - overrides: widths the user dragged, which win over both.
        init(totalWidth: CGFloat, natural: [SheetColumn: CGFloat] = [:],
             overrides: [SheetColumn: CGFloat] = [:],
             hidden: Set<SheetColumn> = []) {
            var fixed: [SheetColumn: CGFloat] = [
                .date: 80, .transfer: 180,
                .reconcile: 24, .amount: 100, .balance: 112,
            ]
            for (column, width) in natural where fixed[column] != nil {
                fixed[column] = max(SheetMetrics.minColumnWidth, width)
            }
            for (column, width) in overrides where fixed[column] != nil {
                fixed[column] = max(SheetMetrics.minColumnWidth, width)
            }
            // A hidden column is a zero-width one. Everything downstream then
            // falls out for free: `rect` returns an empty box so nothing draws,
            // `column(atX:)` can never land in it because no point satisfies
            // `x >= start && x < start`, and Description takes back the space.
            for column in hidden where fixed[column] != nil { fixed[column] = 0 }
            let flex = max(140, totalWidth - fixed.values.reduce(0, +))
            var xs: [CGFloat] = []
            var ws: [CGFloat] = []
            var cursor: CGFloat = 0
            for column in SheetColumn.allCases {
                let w = hidden.contains(column) ? 0 : (fixed[column] ?? flex)
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

        /// The column whose trailing ruler is under `x`, if any.
        ///
        /// Shared by the header and the body, because the body **draws** these
        /// rulers full height (`draw(_:)`, "Rulers between columns") and a line
        /// you can see running the whole way down is a line you expect to be
        /// able to grab. Only the 26pt header used to hit-test them.
        /// Description is excluded: it takes whatever is left, as in a Finder
        /// window, so its trailing edge is the window's, not a divider.
        func resizableColumn(nearX pointX: CGFloat, hidden: Set<SheetColumn>) -> SheetColumn? {
            for column in SheetColumn.allCases
            where column != .description && !hidden.contains(column) {
                let edge = x[column.rawValue] + width[column.rawValue]
                if abs(pointX - edge) <= SheetMetrics.resizeGrab { return column }
            }
            return nil
        }

        /// Every draggable ruler's x, for cursor rects.
        func resizableEdges(hidden: Set<SheetColumn>) -> [CGFloat] {
            SheetColumn.allCases
                .filter { $0 != .description && !hidden.contains($0) }
                .map { x[$0.rawValue] + width[$0.rawValue] }
        }
    }
}

/// Column widths the user dragged, kept across launches.
///
/// HIG *Lists and tables* (macOS) states it plainly — "Let people resize
/// columns" — and every app in this class obeys: Finder ("drag the line that's
/// between the column headings"), Quicken, and GnuCash, whose own manual says
/// the register's columns "can be resized by left-clicking and dragging the
/// dividers in the header".
@MainActor
private enum ColumnWidths {
    private static let key = "registerColumnWidths"

    static func load() -> [SheetColumn: CGFloat] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        else { return [:] }
        var out: [SheetColumn: CGFloat] = [:]
        for (name, width) in raw {
            if let index = Int(name), let column = SheetColumn(rawValue: index) {
                out[column] = CGFloat(width)
            }
        }
        return out
    }

    static func save(_ widths: [SheetColumn: CGFloat]) {
        let raw = Dictionary(uniqueKeysWithValues:
            widths.map { (String($0.key.rawValue), Double($0.value)) })
        UserDefaults.standard.set(raw, forKey: key)
    }
}

// MARK: - Symbols (drawn, not widgets)

@MainActor
private enum SheetSymbols {
    /// Cached per (name, size): the drawn glyphs have to follow Dynamic Type
    /// like the text does, and they were fixed-size statics — so at large text
    /// the caret and pencil stayed at their 11–12pt while every label around
    /// them grew.
    private static var cache: [String: NSImage?] = [:]

    /// Dropped when the appearance flips or the accent changes: a cached
    /// image has its colour baked in.
    static func invalidate() { cache.removeAll() }

    /// The attachment mark: accent, and bold at 12pt. It scored 26.3 ink mass
    /// in secondary grey at 10pt — the faintest thing in the row — against
    /// 61.7 here.
    static func paperclip(_ s: CGFloat) -> NSImage? {
        make("paperclip", NSColor(Color.appAccent), 12 * s, .bold)
    }
    // Interactive glyphs use `labelColor`, not the secondary/tertiary greys
    // they started in. Measured against the register's own alternating row
    // colours: tertiary lands at 1.88:1 in light and 2.26:1 in dark, which
    // fails WCAG 1.4.11's 3:1 for non-text controls, and secondary scrapes
    // 3.88:1 in light — technically a pass, and still too faint to find.
    // `labelColor` measures 13.96:1 / 10.89:1 on the same backgrounds.
    /// SF Symbols has **no filled pencil** — `pencil.fill`,
    /// `square.and.pencil.fill` and `pencil.tip.fill` do not exist, and the
    /// only filled pencil forms are circle discs. So the chunkiest non-disc
    /// pencil is this one at semibold: measured as alpha-weighted ink mass it
    /// scores 87.1, against the bare `pencil`'s 22.3 (which is why dropping
    /// the square made it fainter, not bolder) and the caret's 49.0.
    static func pencil(_ s: CGFloat) -> NSImage? {
        make("square.and.pencil", NSColor(Color.appAccent), 15 * s, .semibold)
    }

    /// Genuinely filled, and red: this one discards work, so it is the one
    /// place a stronger signal than the accent is right. `xmark.circle.fill`
    /// scores 151.8 ink mass against the outline ring's 61.2.
    static func cancel(_ s: CGFloat) -> NSImage? {
        make("xmark.circle.fill", .systemRed, 14 * s, knockout: .white)
    }

    static func addSplit(_ s: CGFloat) -> NSImage? {
        make("plus.circle", .labelColor, 11 * s)
    }
    /// The disclosure triangle. HIG *Disclosure controls*: it "points inward
    /// from the leading edge when its content is hidden and down when its
    /// content is visible" — hence a triangle, not a chevron. Sized to match
    /// the reconcile glyphs rather than the 9pt it began at.
    static func caret(open: Bool, _ s: CGFloat) -> NSImage? {
        make(open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill",
             NSColor(Color.appAccent), 11 * s)
    }
    static func removeSplit(_ s: CGFloat) -> NSImage? {
        make("minus.circle", .labelColor, 11 * s)
    }
    /// Same two-layer trap as `cancel`: with one palette colour this drew a
    /// plain orange triangle, mass identical to `triangle.fill`, no "!".
    static func warning(_ s: CGFloat) -> NSImage? {
        make("exclamationmark.triangle.fill", .systemOrange, 10 * s, knockout: .white)
    }
    static func sort(reversed: Bool, _ s: CGFloat) -> NSImage? {
        make(reversed ? "chevron.down" : "chevron.up", .secondaryLabelColor, 8 * s)
    }

    /// Weight is the lever for "solid": a thin outline anti-aliases to many
    /// pale pixels, a heavy stroke to fewer opaque ones, and the eye reads the
    /// second as darker even at equal area.
    /// `knockout` is the colour of the mark *inside* a filled badge, and it is
    /// not optional decoration: a `.fill` badge symbol has two layers, and a
    /// palette of ONE colour paints both — so `xmark.circle.fill` rendered as
    /// a plain red disc with no visible ✕. Measured, it scored exactly the
    /// same ink mass as `circle.fill` (151.8) with a red centre pixel. Passing
    /// two colours puts the mark back.
    private static func make(_ name: String, _ color: NSColor, _ size: CGFloat,
                             _ weight: NSFont.Weight = .regular,
                             knockout: NSColor? = nil) -> NSImage? {
        let key = "\(name)|\(Int(size.rounded()))|\(weight.rawValue)|\(knockout != nil)"
        if let hit = cache[key] { return hit }
        let palette = knockout.map { [$0, color] } ?? [color]
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: palette)))
        cache[key] = image
        return image
    }
}

/// The reconcile column's symbols — the drawn mirror of ``ReconcileBadge``.
@MainActor
private enum ReconcileSymbols {
    private static var cache: [String: NSImage?] = [:]

    /// Dropped when the appearance flips or the accent changes: a cached
    /// image has its colour baked in.
    static func invalidate() { cache.removeAll() }

    static func image(for glyph: String, scale: CGFloat) -> NSImage? {
        let key = "\(glyph)|\(Int((11 * scale).rounded()))"
        if let hit = cache[key] { return hit }
        // `knockout` is the mark inside a filled badge. Without it a palette of
        // one colour paints both layers, and "reconciled" drew as a solid
        // green dot with no tick in it — measured at the same ink mass as
        // `circle.fill`. Only the `.fill` glyph needs it; the outline ones are
        // a single layer.
        let (name, color, knockout): (String, NSColor, NSColor?) = switch glyph {
        // Reconciliation is a **progression**, so cleared and reconciled share
        // the app's accent and differ by weight — outline, then filled. They
        // used to be accent and system green: two unrelated colour languages
        // in one column, which read as arbitrary rather than as two points on
        // the same scale.
        //
        // Frozen and voided keep their own colours on purpose. They are not
        // further along the scale; they are outside it, and a colour that says
        // so is doing real work.
        case "c": ("checkmark.circle", NSColor(Color.appAccent), nil)
        case "y": ("checkmark.circle.fill", NSColor(Color.appAccent), .white)
        case "f": ("snowflake", .systemCyan, nil)
        case "v": ("xmark.circle", .systemRed, nil)
        default: ("circle.dotted", .secondaryLabelColor, nil)
        }
        let palette = knockout.map { [$0, color] } ?? [color]
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11 * scale, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: palette)))
        cache[key] = image
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
    private var style = RegisterStyle.basic
    /// GnuCash's `info->trans_expanded`: one flag, for the current transaction
    /// only, cleared whenever the selection moves.
    private var currentExpanded = false
    private var dateFormat: AppDateFormat?
    /// Content-derived widths for the fixed columns, remeasured when the rows,
    /// the font or the date form change.
    private var naturalWidths: [SheetColumn: CGFloat] = [:]
    /// A ruler drag in progress, started on the body rather than the header.
    private var columnDrag: (column: SheetColumn, startX: CGFloat, startWidth: CGFloat)?
    /// How fully this register is currently writing its dates.
    ///
    /// Screen width is the scarce resource here: a register has six columns
    /// competing for it and only Description can absorb the loss, so the date
    /// gives up the century before Description gives up readable payee names.
    /// A register is a dense table, so it starts at ``AppDateFormat/Form/table``
    /// — the same ceiling every SwiftUI ``AdaptiveDate`` starts at. Space picks
    /// downward from there, never above it.
    private var dateForm: AppDateFormat.Form = .table

    var onError: ((String) -> Void)?

    /// The date as this register is currently showing it — the single place
    /// that decides, so drawing, the accessibility summary and the in-place
    /// editor can never disagree about what a row says.
    func dateText(_ date: Date) -> String {
        guard let dateFormat else { return "" }
        return dateFormat.string(date, dateForm)
    }

    // Metrics. Two inputs — the app's Text Size and the row-height preference
    // — fold into one `scale` that every font, glyph and offset is a multiple
    // of, so the register grows as a piece.
    private var appFontScale: CGFloat = 1
    private var rowHeight = RegisterRowHeight.automatic
    /// The row height resolved against this view's display. `nil` means
    /// "measure again" — set by a preference change or a move to another screen.
    private var resolvedRowPoints: CGFloat?
    /// The disclosure gutter, scaled. It has to move with the glyph inside it:
    /// `drawSymbol` centres a symbol at its natural size and does not clip, so
    /// a fixed 14pt gutter spilled the triangle into the date text once the
    /// scale passed ~1.4 (measured: the 11pt triangle renders 16pt wide at
    /// scale 1.41, 19pt at 1.63). It is also the click target, which is the
    /// half that matters for a taller row.
    private var caretGutter: CGFloat = SheetMetrics.caretGutter
    /// The edit pencil's gutter, immediately after the caret's inside the Date
    /// cell. Wider than the caret's because the glyph is: a pencil at 15pt
    /// against a triangle at 11.
    private var editGutter: CGFloat = SheetMetrics.editGutter
    /// `rowHeight` resolved against this view's display, times Text Size,
    /// divided by the 24pt base. 1.0 is a 24pt row with 13pt text.
    private var fontScale: CGFloat = 0
    private var lineHeight: CGFloat = RegisterRowHeight.base
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
    private var columnWidths: [SheetColumn: CGFloat] = ColumnWidths.load()
    fileprivate private(set) var hiddenColumns: Set<SheetColumn> = []
    private var frames = SheetMetrics.Frames(totalWidth: 800,
                                             overrides: ColumnWidths.load())

    // The one editor (gnucash-item-edit)
    private let itemEdit = ItemEditField()
    private let suggestions = SuggestionsController()
    private lazy var unreconciledRotor = UnreconciledRotor(sheet: self)
    private var comboTyped = false
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?

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
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// A cached symbol carries its colour, so light/dark has to invalidate.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        SheetSymbols.invalidate()
        ReconcileSymbols.invalidate()
        needsDisplay = true
        header?.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // An automatic row height is a property of the *display*, so dragging
        // the window to another monitor has to re-measure it.
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let window {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window,
                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resolvedRowPoints = nil
                    self?.updateMetrics()
                }
            }
        }
        resolvedRowPoints = nil
        updateMetrics()

        guard scrollObserver == nil,
              let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suggestions.hide() }
        }
    }

    // MARK: Accessibility (NSAccessibilityTable — rows, cells, actions, rotor)

    /// The row proxies VoiceOver navigates. Built on the **first** accessibility
    /// query and dropped whenever the row set changes: a register holds tens of
    /// thousands of transactions, and a session with no assistive client must
    /// not pay to materialise a tree nothing is reading.
    private var axRowCache: [SheetAXRow]?

    fileprivate var axRows: [SheetAXRow] {
        if let axRowCache { return axRowCache }
        let built = rows.indices.map { SheetAXRow(sheet: self, index: $0) }
        axRowCache = built
        return built
    }

    /// Called wherever the row set or its geometry changes. Cheap when no
    /// assistive client has ever asked (the cache is still nil).
    private func invalidateAccessibilityTree() {
        guard axRowCache != nil else { return }
        axRowCache = nil
        NSAccessibility.post(element: self, notification: .rowCountChanged)
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityLabel() -> String? {
        wholeBook ? String(localized: "All Transactions")
                  : String(localized: "Transactions")
    }
    /// Rows, plus the one item editor whenever it is on screen: replacing the
    /// default children with row proxies alone would hide the live field from
    /// VoiceOver at exactly the moment someone is typing into it.
    override func accessibilityChildren() -> [Any]? {
        itemEdit.isHidden ? axRows : axRows + [itemEdit]
    }
    override func accessibilityRows() -> [Any]? { axRows }
    override func accessibilityVisibleRows() -> [Any]? {
        guard let clip = enclosingScrollView?.contentView else { return axRows }
        let visible = clip.bounds
        let first = firstBlock(atOrAfter: visible.minY)
        guard first < rows.count else { return [] }
        var last = first
        while last + 1 < rows.count, yOffsets[last + 1] < visible.maxY { last += 1 }
        return Array(axRows[first...last])
    }
    override func accessibilitySelectedRows() -> [Any]? {
        axRows.filter { axIsSelected($0.index) }
    }
    override func accessibilityRowCount() -> Int { rows.count }
    override func accessibilityColumnCount() -> Int { SheetColumn.allCases.count }

    /// The AppKit equivalent of the Table register's `.accessibilityRotor`:
    /// VO-⌘-arrow jumps between transactions that are not yet reconciled.
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        guard !wholeBook else { return [] }   // journal rows carry no reconcile
        let rotor = NSAccessibilityCustomRotor(
            label: String(localized: "Unreconciled"),
            itemSearchDelegate: unreconciledRotor)
        return [rotor]
    }

    // MARK: Accessibility — facts the row proxies read

    fileprivate var axRowCount: Int { rows.count }

    fileprivate func axIsSelected(_ index: Int) -> Bool {
        rows.indices.contains(index) && selection.contains(rows[index].txn)
    }

    /// The row as VoiceOver reads it — the same sentence the Table register
    /// speaks (`TransactionRowView.rowSummary`), so the two platforms agree.
    fileprivate func axRowSummary(_ index: Int) -> String {
        guard rows.indices.contains(index) else { return "" }
        let base = rows[index].base
        var parts = [dateText(base.date), base.description]
        if !base.transferName.isEmpty { parts.append(base.transferName) }
        if !base.isHeadingOnly {
            // `spoken`, not `string`: VoiceOver does not read a leading minus
            // at default punctuation settings, so the visual form makes an
            // $82.34 debit and an $82.34 credit sound identical.
            parts.append(AmountFormat.spoken(base.amount, code: currencyCode))
        }
        if base.hasDocument { parts.append(String(localized: "has attachment")) }
        if let balance = base.runningBalance {
            parts.append(String(localized:
                "balance \(AmountFormat.spoken(balance, code: currencyCode))"))
        }
        if !base.isHeadingOnly { parts.append(ReconcileBadge.word(base.reconcile)) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    fileprivate func axCellText(_ column: SheetColumn, at index: Int) -> String {
        guard rows.indices.contains(index) else { return "" }
        let base = rows[index].base
        switch column {
        case .date: return dateText(base.date)
        case .description: return base.description
        case .transfer: return base.isHeadingOnly ? "" : base.transferName
        case .reconcile:
            return base.isHeadingOnly ? "" : ReconcileBadge.word(base.reconcile)
        case .amount:
            return base.isHeadingOnly
                ? "" : AmountFormat.spoken(base.amount, code: currencyCode)
        case .balance:
            return base.runningBalance.map {
                AmountFormat.spoken($0, code: currencyCode)
            } ?? ""
        }
    }

    fileprivate func axScreenRect(ofBlock index: Int) -> NSRect {
        guard let window, rows.indices.contains(index) else { return .zero }
        return window.convertToScreen(convert(blockRect(index), to: nil))
    }

    fileprivate func axScreenRect(of column: SheetColumn, block index: Int) -> NSRect {
        guard let window, rows.indices.contains(index) else { return .zero }
        let rect = frames.rect(column, y: yOffsets[index], height: lineHeight)
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: Accessibility — actions the row proxies perform

    fileprivate func axSelect(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        requestSelection([rows[index].txn], anchor: index, lead: index)
        _ = scrollToVisible(blockRect(index))
        window?.makeFirstResponder(self)
    }

    fileprivate func axEdit(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        axSelect(index)
        // A dirty, unbalanced draft elsewhere refuses to be left; don't then
        // open an editor on a row the sheet declined to select.
        guard selectedTxn == rows[index].txn else { return }
        editExpanded()
    }

    /// The caret, for VoiceOver: only the selected row in Basic Ledger has one.
    fileprivate func axCanExpand(_ index: Int) -> Bool {
        rows.indices.contains(index) && style.allowsManualExpand
            && selectedTxn == rows[index].txn
    }

    fileprivate func axIsExpanded(_ index: Int) -> Bool {
        axCanExpand(index) && currentExpanded
    }

    fileprivate func axToggleExpanded(_ index: Int) {
        guard axCanExpand(index) else { return }
        toggleCurrentExpanded()
    }

    fileprivate func axCanReconcile(_ index: Int) -> Bool {
        rows.indices.contains(index) && rows[index].base.anchorSplit != nil
    }

    fileprivate func axCycleReconcile(_ index: Int) {
        guard rows.indices.contains(index),
              let split = rows[index].base.anchorSplit else { return }
        model.cycleReconcileState(splitID: split)
        damageBlock(ofTxn: rows[index].txn)
    }

    /// Reconcile states a rotor treats as still needing attention: GnuCash's
    /// `n` (and the empty state), never `c`/`y`/`f`/`v`.
    fileprivate func axIsUnreconciled(_ index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        let base = rows[index].base
        guard !base.isHeadingOnly else { return false }
        return !["c", "y", "f", "v"].contains(base.reconcile)
    }

    // MARK: Inputs from SwiftUI (updateNSView)

    private var lastAccent = ""
    private var rowsKey: Int = .min
    private var accountKey: Int = .min
    private var lastEditingRequest: GncGUID?

    /// Folds Text Size and the row-height preference into the one scale the
    /// whole sheet draws from, and rebuilds whatever measured itself against
    /// the old one.
    ///
    /// Idempotent on purpose — it returns the moment the number has not moved,
    /// which is what lets the screen-change notification call it blind.
    private func updateMetrics() {
        // Measured, then remembered. `apply` runs on every interaction, and
        // resolving the row costs ~10 µs of `CGDisplayScreenSize` and
        // `deviceDescription` lookup (measured, 100k iterations) — small, and
        // exactly the per-interaction work this register is built to avoid.
        let resolved = resolvedRowPoints ?? rowHeight.points(on: window?.screen)
        resolvedRowPoints = resolved
        let scale = appFontScale * (resolved / RegisterRowHeight.base)
        guard scale != fontScale else { return }
        fontScale = scale
        lineHeight = ceil(RegisterRowHeight.base * scale)
        caretGutter = ceil(SheetMetrics.caretGutter * scale)
        editGutter = ceil(SheetMetrics.editGutter * scale)
        bodyFont = NSFont.systemFont(ofSize: 13 * scale)
        monoFont = NSFont.monospacedDigitSystemFont(ofSize: 13 * scale, weight: .regular)
        smallFont = NSFont.systemFont(ofSize: 11 * scale)
        // The header strip and the suggestions popup are separate views; they
        // scale with the register or Dynamic Type stops at its edge.
        suggestions.fontScale = scale
        header?.fontScale = scale
        header?.superview?.needsLayout = true
        rebuildGeometry()
        needsDisplay = true
        positionEditor()
    }

    func apply(rowsKey: Int, accountKey: Int,
               style: RegisterStyle, fontScale: CGFloat,
               rowHeight: RegisterRowHeight, hiddenColumns: Int,
               dateFormat: AppDateFormat, editing: GncGUID?,
               pendingAvailable: Bool) {
        self.dateFormat = dateFormat

        let accent = UserDefaults.standard.string(forKey: AppearanceKey.accent) ?? ""
        if accent != lastAccent {
            lastAccent = accent
            SheetSymbols.invalidate()
            ReconcileSymbols.invalidate()
            needsDisplay = true
            header?.needsDisplay = true
        }

        appFontScale = fontScale
        if rowHeight != self.rowHeight {
            self.rowHeight = rowHeight
            resolvedRowPoints = nil
        }
        updateMetrics()

        let hidden = RegisterColumnVisibility.hidden(from: hiddenColumns)
        if hidden != self.hiddenColumns {
            self.hiddenColumns = hidden
            // A field in a column that just went away must not keep the
            // cursor — `setCursor(nil)` takes the editor down with it.
            if let cursor, hidden.contains(Self.column(of: cursor.field)) {
                setCursor(nil)
            }
            rebuildFrames()
            header?.hiddenColumns = hidden
            invalidateAccessibilityTree()
            needsDisplay = true
        }

        var settingsChanged = false
        if style != self.style {
            self.style = style
            // A hand-opened transaction has no meaning once the style decides
            // what is open (split-register.c:251).
            currentExpanded = false
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
                    // A request, not a state — clear it once honoured. The
                    // inspector binding that used to reset it went with the
                    // inspector, which made it a write-once latch: ⌘E, ⎋, ⌘E
                    // did nothing the second time, and a fresh SheetView
                    // (returning to the register from anywhere) started with
                    // `lastEditingRequest == nil` and so re-opened the same
                    // transaction over wherever the user actually was.
                    self.model.editingTransactionID = nil
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
        relayoutColumns()
        rebuildGeometry()
        invalidateAccessibilityTree()
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
                                        number: txn.number,
                                        description: txn.transactionDescription,
                                        notes: txn.notes,
                                        tags: txn.tags.joined(separator: ", "),
                                        reconcile: "",
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
                                    date: main.date, number: main.number,
                                    description: main.description,
                                    notes: main.notes,
                                    tags: model.transactionTags(ofTransaction: txn)
                                        .joined(separator: ", "),
                                    reconcile: main.reconcile,
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

    /// Whether this row is disclosed — the whole of the style difference, and
    /// now the only thing that governs detail. Journal discloses every row,
    /// Auto Details the selected one, Basic only what the caret opened.
    /// Mirrors GnuCash's passive/active cursor choice in
    /// `split-register-util.c:435-495`.
    private func isDisclosed(_ row: SheetRow, drafting: Bool) -> Bool {
        if wholeBook || style == .journal { return true }
        if drafting, draft?.isExpanded == true { return true }
        guard selectedTxn == row.txn else { return false }
        return style == .autoDetails || currentExpanded
    }

    /// The caret. Basic Ledger only: in the other two styles GnuCash's expand
    /// call returns immediately (split-register.c:251).
    private func toggleCurrentExpanded() {
        guard style.allowsManualExpand, let txn = selectedTxn else { return }
        currentExpanded.toggle()
        geometryChanged(fromBlock: indexByTxn[txn])
    }


    /// One disclosure, everything behind it: notes, tags, then every leg with
    /// its memo, action and share/foreign quantity.
    private func linePlan(_ row: SheetRow) -> [SheetLine] {
        let drafting = draft?.transactionID == row.txn
        var lines: [SheetLine] = [.heading]
        guard isDisclosed(row, drafting: drafting) else { return lines }
        // Unconditional, and that is the point. Emitting these only when they
        // held something made a block's height depend on whether it was being
        // edited — so clicking a row in Journal grew it by two lines with no
        // geometry rebuild, and it painted straight over the row beneath.
        // A disclosed row is the same height whether or not you are editing
        // it; that invariant is worth two quiet lines.
        lines.append(.notes)
        lines.append(.tags)
        let legCount = drafting ? (draft?.lines.count ?? 0) : row.legs.count
        for index in 0..<legCount { lines.append(.leg(index)) }
        if drafting, draft?.isExpanded == true { lines.append(.addSplit) }
        return lines
    }

    /// How tall a block is, in lines — **derived from the line plan**, never
    /// counted separately.
    ///
    /// This used to re-implement `linePlan`'s branches as arithmetic (`var
    /// count = 3  // heading + notes + tags`). The two had to agree and nothing
    /// enforced it: `lineCount` is the sole input to `rebuildGeometry`, so a
    /// divergence does not throw — the rows simply draw over one another, which
    /// is the exact class of bug the register rewrite was undertaken to fix.
    /// Adding the Num line proved the point, leaving the count one short.
    private func lineCount(_ row: SheetRow) -> Int {
        linePlan(row).count
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
        // The window resized, so the date form may have to change with it.
        relayoutColumns()
        rebuildFrames()
    }

    /// Size the fixed columns to their content, and pick the date form that
    /// the remaining width can afford.
    ///
    /// Screen width is the constraint the register is laid out against: seven
    /// columns compete for it and only Description can absorb a shortfall, so
    /// when the fixed columns would squeeze it below a readable floor the date
    /// gives up the century (`24/12/2026` → `24/12/26`) before payee names
    /// start disappearing. Measured, not assumed — the answer differs by date
    /// order, by Text Size, and by how wide the amounts in this particular
    /// account happen to run.
    private func relayoutColumns() {
        guard !rows.isEmpty, dateFormat != nil else { return }
        let floor = 220 * fontScale

        // Walk the ladder from the richest form this context allows down to the
        // tersest, stopping at the first that still leaves Description its
        // floor. Written as a walk rather than as the old full-or-compact
        // boolean so the rule is the *ladder*, not two hard-coded cases: adding
        // a rung, or raising `dateCeiling` for a wider surface, needs no change
        // here.
        let ladder = AppDateFormat.Form.allCases.drop { $0 != .table }
        var measured: [SheetColumn: CGFloat] = [:]
        for form in ladder {
            dateForm = form
            measured = measureNaturalWidths(rows)
            guard frame.width > 0 else { break }
            if frame.width - measured.values.reduce(0, +) >= floor { break }
        }
        naturalWidths = measured
    }

    /// A column divider was dragged, in the header or on the body's ruler.
    func resizeColumn(_ column: SheetColumn, to width: CGFloat) {
        columnWidths[column] = width
        ColumnWidths.save(columnWidths)
        rebuildFrames()
    }

    /// What each fixed column needs for the content actually in it.
    ///
    /// Scalars first, strings last: finding the longest number, the widest
    /// amount and the widest transfer name is cheap arithmetic over the rows,
    /// and only the handful of winners are ever laid out and measured. On a
    /// 46,000-row register that is one pass of comparisons and about eight
    /// `size(withAttributes:)` calls, rather than 46,000 of them.
    ///
    /// Every column is measured against its *own* font — Amount and Balance
    /// are monospaced-digit, the rest are not — because a column sized in the
    /// wrong face is a column that ellipsises at some Text Sizes and not
    /// others.
    private func measureNaturalWidths(_ rows: [SheetRow]) -> [SheetColumn: CGFloat] {
        guard !rows.isEmpty else { return [:] }
        let body = [NSAttributedString.Key.font: bodyFont]
        let mono = [NSAttributedString.Key.font: monoFont]

        var transferWidths: [CGFloat] = []
        var earliest = rows[0].base.date, latest = rows[0].base.date
        var biggestAmount = Decimal(0), biggestBalance = Decimal(0)
        var transferSeen: Set<String> = []
        for row in rows {
            let base = row.base
            // Account names repeat across thousands of rows; measure each
            // distinct one once.
            if !base.transferName.isEmpty, transferSeen.insert(base.transferName).inserted {
                transferWidths.append((base.transferName as NSString)
                    .size(withAttributes: body).width)
            }
            if base.date < earliest { earliest = base.date }
            if base.date > latest { latest = base.date }
            if abs(base.amount) > biggestAmount { biggestAmount = abs(base.amount) }
            if let balance = base.runningBalance, abs(balance) > biggestBalance {
                biggestBalance = abs(balance)
            }
        }

        func text(_ string: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
            ceil((string as NSString).size(withAttributes: attributes).width)
        }
        let pad = 2 * SheetMetrics.textInset
        // A negative amount is the widest an amount gets, and both ends of the
        // date range are measured because "9 Mar" is not "31 December".
        let amount = max(text(AmountFormat.string(-biggestAmount, code: currencyCode), mono),
                         text(AmountFormat.string(biggestAmount, code: currencyCode), mono))
        let balance = max(text(AmountFormat.string(-biggestBalance, code: currencyCode), mono),
                          text(AmountFormat.string(biggestBalance, code: currencyCode), mono))
        // Measured in the form currently chosen, and at both ends of the range,
        // because "9/3/2026" is not "24/12/2026".
        let date = max(text(dateText(earliest), body), text(dateText(latest), body))

        var natural: [SheetColumn: CGFloat] = [
            // The disclosure gutter lives inside Date (HIG *Outline views*:
            // hierarchy in the first column only), so it is added, not shared.
            .date: date + caretGutter + editGutter + pad,
            .amount: amount + pad,
            .balance: balance + pad,
            .transfer: transferWidth(transferWidths) + pad,
        ]
        // A column is never narrower than its own heading, or the header reads
        // as truncated while the rows look fine.
        let heading = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11 * fontScale,
                                                                     weight: .semibold)]
        for column in natural.keys {
            natural[column] = max(natural[column] ?? 0, text(column.title, heading) + pad + 14)
        }
        return natural
    }

    /// How wide Transfer needs to be — sized to the **90th percentile** of the
    /// account names in this register, not the widest.
    ///
    /// Sizing it to the widest was wrong, and measurably so: on the reference
    /// book the median account name is 9 characters and the 90th percentile is
    /// 18, but the longest of 560 is 37 — about 259pt. One account name was
    /// therefore setting the column width for 46,000 rows and pinning it at its
    /// cap, at Description's expense.
    ///
    /// The user's rule is to give Description as much room as possible and
    /// squeeze the rest to the minimum that does not truncate. Those two pull
    /// against each other only in the tail, so the tail is where the compromise
    /// belongs: nine names in ten fit whole, the tenth truncates, and any of
    /// them can be read in full by widening the column or opening the row.
    private func transferWidth(_ widths: [CGFloat]) -> CGFloat {
        guard !widths.isEmpty else { return 0 }
        let sorted = widths.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * 0.9))
        return min(sorted[index], 260 * fontScale)
    }

    private func rebuildFrames() {
        frames = SheetMetrics.Frames(totalWidth: frame.width, natural: naturalWidths,
                                     overrides: columnWidths, hidden: hiddenColumns)
        header?.frames = frames
        header?.window?.invalidateCursorRects(for: header!)
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
        for column in SheetColumn.allCases where column != .date {
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
        case .number: String(localized: "Num")
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

    /// `placeholder` is `@autoclosure`: it is a `String(localized:)` bundle
    /// lookup, and it is read only when the cell is both empty and drafting.
    /// Eager, every call site paid for one on every `draw(_:)` — roughly ten
    /// per transaction block, per frame, and at rest every one was discarded.
    private func drawEditableText(_ text: String, placeholder: @autoclosure () -> String,
                                  drafting: Bool, in cell: CGRect,
                                  muted: Bool = false, trailing: Bool = false,
                                  leadingInset: CGFloat = 0,
                                  middleTruncate: Bool = false) {
        if !text.isEmpty {
            drawText(text, in: cell, trailing: trailing, muted: muted,
                     leadingInset: leadingInset, middleTruncate: middleTruncate)
        } else if drafting {
            drawText(placeholder(), in: cell, trailing: trailing,
                     color: .placeholderTextColor, leadingInset: leadingInset)
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
            // Caret, pencil, date — in that reading order, both glyphs in
            // gutters at the leading edge of the Date cell. The pencil used to
            // be a column of its own *after* Date, which put the date text
            // between the two affordances.
            drawCaret(row, drafting: drafting, in: cell(.date))
            let editBox = CGRect(x: cell(.date).minX + caretGutter, y: cell(.date).minY,
                                 width: editGutter, height: cell(.date).height)
            drawHandle(row, drafting: drafting, in: editBox)
            if !skipForCursor(row, .date) {
                let date = drafting ? (draft?.date ?? row.base.date) : row.base.date
                drawText(dateText(date), in: cell(.date),
                         leadingInset: caretGutter + editGutter)
            }
            if !skipForCursor(row, .description) {
                var inset: CGFloat = 0
                if row.base.hasDocument {
                    let box = cell(.description)
                    drawSymbol(SheetSymbols.paperclip(fontScale),
                               centeredIn: CGRect(x: box.minX + 2, y: box.minY,
                                                  width: 16, height: box.height))
                    inset = 16
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
            // Guarded on emptiness exactly as the leg rows are. Without this
            // an unknown state fell through to the dotted "not reconciled"
            // circle on the heading while the leg beneath it drew nothing —
            // the same state, two glyphs, side by side in Transaction Journal.
            if !row.base.isHeadingOnly, !row.base.reconcile.isEmpty {
                drawSymbol(ReconcileSymbols.image(for: row.base.reconcile, scale: fontScale),
                           centeredIn: cell(.reconcile))
            }
            if !row.base.isHeadingOnly, !skipForCursor(row, .amount) {
                let amount = (drafting ? focusLine()?.amount : nil) ?? row.base.amount
                drawText(AmountFormat.string(amount, code: code), in: cell(.amount),
                         trailing: true, negative: amount < 0, mono: true)
            }
            drawHeadingBalance(row, drafting: drafting, in: cell(.balance), code: code)

        case .notes:
            // Num shares this line rather than taking one of its own: it is a
            // short token, and a line of its own for a field that is usually
            // empty is the same waste as the column it replaced. Leading cell
            // for Num, description cell for Notes — the arrangement leg rows
            // already use for Action beside Memo.
            if !skipForCursor(row, .number) {
                let num = drafting ? (draft?.number ?? "") : row.base.number
                drawEditableText(num, placeholder: placeholder(for: .number),
                                 drafting: drafting, in: cell(.date), muted: true)
            }
            if !skipForCursor(row, .notes) {
                let text = drafting ? (draft?.notes ?? "") : row.base.notes
                drawEditableText(text, placeholder: placeholder(for: .notes),
                                 drafting: drafting,
                                 in: cell(.description), muted: true)
            }

        case .tags:
            if !skipForCursor(row, .tags) {
                let text = drafting ? (draft?.tagsText ?? "") : row.base.tags
                drawEditableText(text, placeholder: placeholder(for: .tags),
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
                drawSymbol(ReconcileSymbols.image(for: reconcile, scale: fontScale),
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
            drawSymbol(SheetSymbols.addSplit(fontScale),
                       centeredIn: CGRect(x: box.minX + 2, y: box.minY,
                                          width: 14, height: box.height))
            drawText(String(localized: "Add Split"), in: box, muted: true,
                     leadingInset: 14)
        }
    }

    /// The disclosure triangle, in the leading gutter of the first column.
    ///
    /// Only Basic Ledger draws one: in Auto Details and Journal the style has
    /// already decided what is disclosed, so a triangle would promise a choice
    /// that does not exist.
    private func drawCaret(_ row: SheetRow, drafting: Bool, in dateCell: CGRect) {
        guard style.allowsManualExpand, selectedTxn == row.txn else { return }
        let open = currentExpanded || (drafting && draft?.isExpanded == true)
        let gutter = CGRect(x: dateCell.minX, y: dateCell.minY,
                            width: caretGutter, height: dateCell.height)
        drawSymbol(SheetSymbols.caret(open: open, fontScale), centeredIn: gutter)
    }

    /// Edit, in its own narrow column before the description — a per-row image
    /// button living *in the view*, which is where HIG *Buttons* (macOS) puts
    /// them: "Square buttons aren\u{2019}t intended for use in toolbars." While a
    /// row is opened out for editing it becomes the cancel glyph, because
    /// there the click abandons the edit.
    private func drawHandle(_ row: SheetRow, drafting: Bool, in rect: CGRect) {
        if drafting, draft?.isExpanded == true {
            drawSymbol(SheetSymbols.cancel(fontScale), centeredIn: rect)
        } else if selectedTxn == row.txn {
            drawSymbol(SheetSymbols.pencil(fontScale), centeredIn: rect)
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
            drawSymbol(SheetSymbols.warning(fontScale),
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
                         trailing: true, color: .placeholderTextColor)
            } else {
                drawText(line.quantityText, in: quantityRect, trailing: true, mono: true)
            }
        }
        if removable {
            drawSymbol(SheetSymbols.removeSplit(fontScale), centeredIn: removeHotspot(in: rect))
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

    private var armsOnSelection: Bool { wholeBook || style == .journal }

    /// Mirror the sheet's transaction selection into the model's split-based
    /// selection — the toolbar Edit button, attachments panel, and menu
    /// actions all read it. Deferred a beat: apply() runs inside a SwiftUI
    /// render pass, where model writes are illegal.
    /// The split a selected row stands for — the row's **own** leg, not
    /// `splits.first`.
    ///
    /// Everything reading `selectedSplitIDs` is leg-sensitive: Bulk Edit's
    /// Transfer rewrite takes "the other split" relative to this one, so
    /// handing it an arbitrary leg re-pointed the bank side of a grocery row
    /// and moved the money out of the wrong account; Reconcile marked a leg
    /// that is not on screen; ⌘J jumped back into the register it was already
    /// in. The right value is already on the row — `anchorSplit` is what
    /// reconcile cycling uses — and a heading row, which has none, falls back.
    private func rowSplitID(of txn: GncGUID) -> GncGUID? {
        indexByTxn[txn].flatMap { rows[$0].base.anchorSplit }
            ?? model.anySplitID(ofTransaction: txn)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let columnDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let width = max(SheetMetrics.minColumnWidth,
                        columnDrag.startWidth + (point.x - columnDrag.startX))
        resizeColumn(columnDrag.column, to: width)
    }

    override func mouseUp(with event: NSEvent) {
        guard columnDrag != nil else { return }
        columnDrag = nil
        window?.invalidateCursorRects(for: self)
    }

    private func mirrorSelection() {
        let ids = Set(selection.compactMap(rowSplitID(of:)))
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
        let previouslyOpen = selectedTxn
        let wasExpanded = currentExpanded
        selection = txns
        anchorBlock = anchor
        leadBlock = lead
        selectedTxn = txns.count == 1 ? txns.first : nil

        // GnuCash drops `trans_expanded` when the cursor leaves the
        // transaction; a hand-opened row shuts as you move off it.
        if selectedTxn != previouslyOpen { currentExpanded = false }

        // In Auto-Split — or when a hand-opened row just shut — the *open* row
        // has moved, so block heights changed. That is geometry, not paint:
        // repainting alone would leave every later block at a stale offset.
        if style == .autoDetails || wasExpanded || armsOnSelection {
            let touched = [previouslyOpen, selectedTxn]
                .compactMap { $0.flatMap { indexByTxn[$0] } }
            geometryChanged(fromBlock: touched.min())
        }
        damageBlocks(before.union(txns))
        mirrorSelection()
        if before != txns {
            NSAccessibility.post(element: self, notification: .selectedRowsChanged)
        }
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

    /// The body draws a ruler between every column, full height. A line you
    /// can see the whole way down is a line you expect to be able to grab, so
    /// the drag lives here as well as in the 26pt header — which was the only
    /// place that hit-tested it, making the columns look fixed.
    override func resetCursorRects() {
        super.resetCursorRects()
        for edge in frames.resizableEdges(hidden: hiddenColumns) {
            addCursorRect(CGRect(x: edge - SheetMetrics.resizeGrab, y: 0,
                                 width: SheetMetrics.resizeGrab * 2, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        suggestions.hide()
        let point = convert(event.locationInWindow, from: nil)
        // Before anything else: a ruler drag is not a click on a row.
        if let column = frames.resizableColumn(nearX: point.x, hidden: hiddenColumns) {
            columnDrag = (column, point.x, frames.width[column.rawValue])
            return
        }
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

        // The first column's leading gutter is the disclosure triangle.
        if column == .date, case .heading = line, style.allowsManualExpand,
           point.x < frames.x[SheetColumn.date.rawValue] + caretGutter {
            toggleCurrentExpanded()
            return
        }
        // Explicitly the *second* gutter, not merely "before the end of the
        // second". The caret's test above is conditional on
        // `style.allowsManualExpand`, so in Transaction Journal — where there
        // is nothing to expand — a tap on the caret would otherwise fall
        // through to here and start an edit.
        if column == .date, case .heading = line,
           point.x >= frames.x[SheetColumn.date.rawValue] + caretGutter,
           point.x < frames.x[SheetColumn.date.rawValue] + caretGutter + editGutter {
            if drafting, draft?.isExpanded == true {
                escapePressed()   // the cancel glyph abandons the edit
            } else {
                editExpanded()    // the pencil opens the row for editing
            }
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
        case (.date, .notes): .heading(.number)
        case (.description, .notes): .heading(.notes)
        case (.description, .tags): .heading(.tags)
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
        // Through `rowSplitID`, not `anySplitID`: the menu's Bulk Edit and
        // Auto-Categorise assign these straight to `model.selectedSplitIDs`,
        // so an arbitrary leg here would overwrite what `mirrorSelection`
        // just got right — the same wrong-account rewrite, by right-click.
        let splitIDs = Set(selection.compactMap(rowSplitID(of:)))
        return NSHostingMenu(rootView: TransactionActions(
            model: model, splitID: splitIDs.first, selectionSplitIDs: splitIDs))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: moveSelection(step: 1, extend: event.modifierFlags.contains(.shift))
        case 126: moveSelection(step: -1, extend: event.modifierFlags.contains(.shift))
        // → opens the selected row, ← shuts it: the disclosure keys an
        // outline row answers to. Bare arrows are unbound elsewhere in the
        // register (only the slide deck binds them).
        case 124 where style.allowsManualExpand && !currentExpanded:
            toggleCurrentExpanded()
        case 123 where style.allowsManualExpand && currentExpanded:
            toggleCurrentExpanded()
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
        let flags = event.modifierFlags
            .intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == .command, key == "e", selectedTxn != nil || draft != nil {
            editExpanded()
            return true
        }
        // Three gestures were mouse-only: the R column, the Add Split line and
        // the split remove hotspot are pixel targets no keyboard could reach.
        // GnuCash makes reconcile a tab stop that cycles the flag the moment
        // the cursor enters it (`gnc_recn_cell_enter`, recncell.c) — we keep
        // its cell but require an explicit key, because changing stored data
        // as a side effect of moving focus is a trap for anyone tabbing
        // through. ⌥ ⌘ keeps all three clear of the app's existing bindings.
        if flags == [.command, .option] {
            if key == "r" { return cycleReconcileUnderCursor() }
            if key == "a" { return appendSplitByKey() }
            if event.keyCode == 51 { return removeSplitUnderCursor() }   // ⌫
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌥⌘R — cycle the reconcile state of the leg under the cursor, else of
    /// the selected transaction. The mouse spelling is a click in the R column.
    private func cycleReconcileUnderCursor() -> Bool {
        if let cursor, let id = lineID(of: cursor.field), let d = draft,
           let line = d.lines.first(where: { $0.id == id }), let split = line.splitID {
            model.cycleReconcileState(splitID: split)
            damageBlock(ofTxn: d.transactionID)
            return true
        }
        guard let txn = selectedTxn, let index = indexByTxn[txn],
              axCanReconcile(index) else { return false }
        axCycleReconcile(index)
        return true
    }

    /// ⌥⌘A — the Add Split line's keyboard equivalent.
    private func appendSplitByKey() -> Bool {
        guard draft?.isExpanded == true else { return false }
        appendLine()
        return true
    }

    /// ⌥⌘⌫ — the remove hotspot's keyboard equivalent, on the leg holding the
    /// cursor. Two legs is the floor, exactly as the hotspot enforces.
    private func removeSplitUnderCursor() -> Bool {
        guard let cursor, let id = lineID(of: cursor.field), let d = draft,
              d.lines.count > 2, d.lines.contains(where: { $0.id == id })
        else { return false }
        removeLine(id)
        return true
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

    /// The column a field is edited in — on a leg row the register uses
    /// GnuCash's `CURSOR_SPLIT` mapping (`split-register-layout.c`): Action
    /// under Date, Memo under Description, the account under Transfer, and the
    /// foreign or share quantity under Balance.
    private static func column(of field: TransactionEditField) -> SheetColumn {
        switch field {
        case .date, .number, .splitAction: .date
        case .description, .notes, .tags, .splitMemo: .description
        case .transfer, .splitAccount: .transfer
        case .amount, .splitAmount: .amount
        case .splitQuantity: .balance
        }
    }

    private func cellRect(of focus: SheetFocus) -> CGRect? {
        guard let block = indexByTxn[focus.txn] else { return nil }
        let row = rows[block]
        let plan = linePlan(row)

        func lineIndex(_ wanted: SheetLine) -> Int? { plan.firstIndex(of: wanted) }
        func legIndex(_ id: UUID) -> Int? {
            draft?.lines.firstIndex { $0.id == id }
        }

        // Which *line* the field sits on. The column half is `column(of:)`,
        // shared with `focusOrder` so the two can never drift apart on which
        // box a field is edited in.
        let line: Int? = switch focus.field {
        case .date, .description, .transfer, .amount: lineIndex(.heading)
        case .number: lineIndex(.notes)
        case .notes: lineIndex(.notes)
        case .tags: lineIndex(.tags)
        case .splitAction(let id), .splitMemo(let id), .splitAccount(let id),
             .splitAmount(let id), .splitQuantity(let id):
            legIndex(id).flatMap { lineIndex(.leg($0)) }
        }
        guard let line else { return nil }
        let target = (line: line, column: Self.column(of: focus.field))
        var rect = frames.rect(target.column,
                               y: yOffsets[block] + CGFloat(target.line) * lineHeight,
                               height: lineHeight)
        // The date field starts after the disclosure gutter, so the editor
        // occupies the same box the drawn text does.
        if target.column == .date, case .date = focus.field {
            rect.origin.x += caretGutter
            rect.size.width -= caretGutter
        }
        return rect
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
        case .date: return dateText(d.date)
        case .number: return d.number
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
                if let date = dateFormat?.parseAny(text) { d.date = date }
            }
        case .number:
            withDraft { $0.number = text }
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
            tags: d.parsedTags, notes: d.notes, number: d.number)
    }

    func settleDirtyDraft() {
        if let d = draft, d != original {
            if d.isBalanced {
                // Not `try?`: the draft is cleared either way, so an error
                // swallowed here is an edit that vanishes without a word.
                // `isBalanced` is the draft's own opinion; the engine re-checks
                // and can still refuse (an account deleted in another window,
                // a residual the draft rounded differently).
                do { try commit(d) } catch { onError?(error.localizedDescription) }
            } else {
                onError?(String(localized: "Edit discarded — it didn’t balance."))
            }
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
            || style == .autoDetails || currentExpanded
        var order: [SheetFocus] = [
            SheetFocus(txn: txn, field: .date),
            SheetFocus(txn: txn, field: .number),
            SheetFocus(txn: txn, field: .description),
        ]
        // Visual order, and only visual order: Transfer and Amount are on the
        // heading line, so ⇥ must reach them before dropping to the notes and
        // tags lines underneath.
        if !wholeBook {
            if d.counterpartyIndex(account: model.selectedAccountID) != nil {
                order.append(SheetFocus(txn: txn, field: .transfer))
            }
            order.append(SheetFocus(txn: txn, field: .amount))
        }
        if legsVisible {
            order.append(SheetFocus(txn: txn, field: .notes))
            order.append(SheetFocus(txn: txn, field: .tags))
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
        // A hidden column is zero-width, so its fields have no box to edit in
        // and no point can click into them; ⇥ has to agree, or Tab would walk
        // the cursor somewhere invisible.
        guard !hiddenColumns.isEmpty else { return order }
        return order.filter { !hiddenColumns.contains(Self.column(of: $0.field)) }
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

// MARK: - Accessibility proxies (the sheet draws rows; AX needs objects)

/// One VoiceOver row per transaction block. Holds nothing but an index — every
/// label, value and frame is asked of the sheet at the moment AX wants it, so
/// a proxy can never go stale against the drawn register.
// These proxies are deliberately **not** `@MainActor` classes. They override
// AppKit's accessibility entry points, and `NSAccessibilityElement` — unlike
// `NSView` — carries no main-actor annotation, so an override cannot claim
// isolation its superclass does not have. Every hop is therefore explicit,
// the same shape the suggestions table's `NSTableViewDataSource` uses above,
// and each method binds plain locals first so a non-Sendable `self` is never
// sent into the closure. AX calls arrive on the main thread, which is what
// makes both the `assumeIsolated` hops and the `@unchecked Sendable` sound.

/// One VoiceOver row per transaction block. Holds nothing but an index — every
/// label, value and frame is asked of the sheet at the moment AX wants it, so
/// a proxy can never go stale against the drawn register.
///
/// The `NSAccessibilityElement` *class* conforms to `NSAccessibility`, not to
/// the same-named protocol (`NSAccessibilityElementProtocol` in Swift) that a
/// rotor's `ItemResult` demands, so that conformance is declared here. Both of
/// its requirements — `accessibilityFrame`, `accessibilityParent` — are met.
private final class SheetAXRow: NSAccessibilityElement, NSAccessibilityElementProtocol,
                                @unchecked Sendable {
    private weak var sheet: SheetView?
    let index: Int
    private var cellCache: [SheetAXCell]?

    @MainActor
    init(sheet: SheetView, index: Int) {
        self.sheet = sheet
        self.index = index
        super.init()
        setAccessibilityParent(sheet)
    }

    // No `accessibilityRoleDescription` override: AppKit's own description for
    // `.row` is already localised into every system language, which a string
    // of ours would only be in the eight the catalog carries.
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    /// Spelled out because the protocol wants a non-optional `String` and the
    /// inherited `NSAccessibility` version disagrees on optionality.
    override func accessibilityIdentifier() -> String { "register-row-\(index)" }
    override func accessibilityIndex() -> Int { index }
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityLabel() -> String? {
        let (sheet, index) = (self.sheet, self.index)
        return MainActor.assumeIsolated { sheet?.axRowSummary(index) }
    }

    override func accessibilityFrame() -> NSRect {
        let (sheet, index) = (self.sheet, self.index)
        return MainActor.assumeIsolated { sheet?.axScreenRect(ofBlock: index) ?? .zero }
    }

    override func isAccessibilitySelected() -> Bool {
        let (sheet, index) = (self.sheet, self.index)
        return MainActor.assumeIsolated { sheet?.axIsSelected(index) ?? false }
    }

    override func setAccessibilitySelected(_ selected: Bool) {
        guard selected else { return }
        let (sheet, index) = (self.sheet, self.index)
        MainActor.assumeIsolated { sheet?.axSelect(index) }
    }

    override func accessibilityChildren() -> [Any]? {
        if cellCache == nil {
            let (sheet, index) = (self.sheet, self.index)
            let built: [SheetAXCell]? = MainActor.assumeIsolated {
                guard let sheet else { return nil }
                return SheetColumn.allCases
                    .filter { !sheet.hiddenColumns.contains($0) }
                    .map { SheetAXCell(sheet: sheet, rowIndex: index, column: $0) }
            }
            // Parenting happens out here, where `self` is simply self.
            built?.forEach { $0.setAccessibilityParent(self) }
            cellCache = built
        }
        return cellCache
    }

    /// Everything the mouse can do to a row, offered to VoiceOver's actions
    /// menu — the gestures themselves (a click in the R column, the remove
    /// hotspot) are pixel targets an assistive client cannot reach.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction] {
        let (sheet, index) = (self.sheet, self.index)
        var actions = [
            NSAccessibilityCustomAction(name: String(localized: "Edit Transaction")) {
                MainActor.assumeIsolated { sheet?.axEdit(index) }
                return true
            },
        ]
        let canReconcile = MainActor.assumeIsolated {
            sheet?.axCanReconcile(index) ?? false
        }
        let canExpand = MainActor.assumeIsolated { sheet?.axCanExpand(index) ?? false }
        if canExpand {
            let open = MainActor.assumeIsolated { sheet?.axIsExpanded(index) ?? false }
            actions.append(NSAccessibilityCustomAction(
                name: open ? String(localized: "Hide Details")
                           : String(localized: "Show Details")) {
                MainActor.assumeIsolated { sheet?.axToggleExpanded(index) }
                return true
            })
        }
        if canReconcile {
            actions.append(NSAccessibilityCustomAction(
                name: String(localized: "Cycle Reconcile State")) {
                MainActor.assumeIsolated { sheet?.axCycleReconcile(index) }
                return true
            })
        }
        return actions
    }
}

/// One cell of a row. Reads its text from the sheet on demand, same as the row.
private final class SheetAXCell: NSAccessibilityElement, @unchecked Sendable {
    private weak var sheet: SheetView?
    private let rowIndex: Int
    private let column: SheetColumn

    @MainActor
    init(sheet: SheetView, rowIndex: Int, column: SheetColumn) {
        self.sheet = sheet
        self.rowIndex = rowIndex
        self.column = column
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { column.title }

    override func accessibilityValue() -> Any? {
        // Typed as String, not Any: only a Sendable value may cross the hop.
        let (sheet, rowIndex, column) = (self.sheet, self.rowIndex, self.column)
        let text: String? = MainActor.assumeIsolated {
            sheet?.axCellText(column, at: rowIndex)
        }
        return text
    }

    override func accessibilityFrame() -> NSRect {
        let (sheet, rowIndex, column) = (self.sheet, self.rowIndex, self.column)
        return MainActor.assumeIsolated {
            sheet?.axScreenRect(of: column, block: rowIndex) ?? .zero
        }
    }
}

/// A drawn column heading, as a button VoiceOver can read and press. Sorting
/// is also on the toolbar's Sort menu, so this is perception, not the only path.
private final class SheetAXColumnHeader: NSAccessibilityElement, @unchecked Sendable {
    private weak var header: SheetHeaderView?
    private let column: SheetColumn

    @MainActor
    init(header: SheetHeaderView, column: SheetColumn) {
        self.header = header
        self.column = column
        super.init()
        setAccessibilityParent(header)
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        column.sortable ? .button : .staticText
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { column.title }
    override func isAccessibilityEnabled() -> Bool { column.sortable }

    override func accessibilityValue() -> Any? {
        let (header, column) = (self.header, self.column)
        let text: String? = MainActor.assumeIsolated { header?.axSortDescription(column) }
        return text
    }

    override func accessibilityFrame() -> NSRect {
        let (header, column) = (self.header, self.column)
        return MainActor.assumeIsolated { header?.axScreenRect(of: column) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        guard column.sortable else { return false }
        let (header, column) = (self.header, self.column)
        MainActor.assumeIsolated { header?.axSort(column) }
        return true
    }

    // Resizing was a drag and nothing else — a column width the mouse could
    // change and the keyboard could not. Increment/decrement is how VoiceOver
    // and Full Keyboard Access drive a continuous value, so the same ruler is
    // now adjustable without a pointer.
    override func accessibilityPerformIncrement() -> Bool { nudge(+16) }
    override func accessibilityPerformDecrement() -> Bool { nudge(-16) }

    private func nudge(_ delta: CGFloat) -> Bool {
        guard column != .description else { return false }   // takes the remainder
        let (header, column) = (self.header, self.column)
        return MainActor.assumeIsolated {
            guard let header else { return false }
            let current = header.frames.width[column.rawValue]
            header.onResize?(column, max(SheetMetrics.minColumnWidth, current + delta))
            return true
        }
    }
}

/// AppKit's rotor equivalent of the Table register's `.accessibilityRotor`.
/// The conformance is `@MainActor`-isolated rather than `nonisolated`: the
/// result is an `ItemResult`, which is not `Sendable`, so it cannot be handed
/// back out of a `MainActor.assumeIsolated` block. AX calls arrive on the main
/// thread anyway.
@MainActor
private final class UnreconciledRotor:
    NSObject, @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
    private weak var sheet: SheetView?

    init(sheet: SheetView) {
        self.sheet = sheet
        super.init()
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor parameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let sheet else { return nil }
        let forward = parameters.searchDirection == .next
        let current = (parameters.currentItem?.targetElement as? SheetAXRow)?.index
        let start = current ?? (forward ? -1 : sheet.axRowCount)
        let candidates = forward
            ? Array(stride(from: start + 1, to: sheet.axRowCount, by: 1))
            : Array(stride(from: start - 1, through: 0, by: -1))
        guard let hit = candidates.first(where: { sheet.axIsUnreconciled($0) }),
              sheet.axRows.indices.contains(hit)
        else { return nil }
        return NSAccessibilityCustomRotor.ItemResult(targetElement: sheet.axRows[hit])
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
    /// Dynamic Type: the popup is its own window, so it has to be told.
    var fontScale: CGFloat = 1

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
        table.rowHeight = ceil(19 * fontScale)
        table.reloadData()
        if table.selectedRow < 0, !matches.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        let rowHeight = table.rowHeight + table.intercellSpacing.height
        let height = min(CGFloat(matches.count) * rowHeight + 4, ceil(240 * fontScale))
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
            text.font = NSFont.systemFont(ofSize: 12 * fontScale)
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
    /// Reports a finished drag: the column and its new width.
    var onResize: ((SheetColumn, CGFloat) -> Void)?
    private var dragging: (column: SheetColumn, startX: CGFloat, startWidth: CGFloat)?
    var fontScale: CGFloat = 1 {
        didSet { if fontScale != oldValue { needsDisplay = true } }
    }

    /// The strip grows with Dynamic Type, or large text clips against 26pt.
    var preferredHeight: CGFloat { ceil(SheetMetrics.headerHeight * fontScale) }

    override var isFlipped: Bool { true }

    var hiddenColumns: Set<SheetColumn> = [] {
        didSet {
            guard hiddenColumns != oldValue else { return }
            axHeaderCache = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    /// Control-click a heading to choose columns — the gesture Finder, Mail and
    /// Quicken all use for exactly this. HIG *Context menus* asks that the same
    /// items live in the main interface too, which they do: the register's
    /// View \u{25BE} menu and the View menu bar carry the same list.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for column in SheetColumn.allCases where column.canHide {
            let item = NSMenuItem(title: column.menuTitle,
                                  action: #selector(toggleColumn(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = column.rawValue
            item.state = hiddenColumns.contains(column) ? .off : .on
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = SheetColumn(rawValue: sender.tag), column.canHide else { return }
        var hidden = hiddenColumns
        if hidden.contains(column) { hidden.remove(column) } else { hidden.insert(column) }
        // Written straight to defaults: the SwiftUI menus read the same key
        // through `@AppStorage`, so the change reaches the sheet the same way
        // theirs does — one path in, not two.
        UserDefaults.standard.set(RegisterColumnVisibility.mask(of: hidden), forKey: RegisterColumnVisibility.key)
    }

    // MARK: Accessibility — the headings are drawn, so AX needs objects

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        String(localized: "Column headers")
    }
    override func accessibilityChildren() -> [Any]? {
        if let axHeaderCache { return axHeaderCache }
        let built = SheetColumn.allCases
            .filter { !$0.title.isEmpty && !hiddenColumns.contains($0) }
            .map { SheetAXColumnHeader(header: self, column: $0) }
        axHeaderCache = built
        return built
    }
    private var axHeaderCache: [SheetAXColumnHeader]?

    fileprivate func axScreenRect(of column: SheetColumn) -> NSRect {
        guard let window else { return .zero }
        let rect = frames.rect(column, y: 0, height: bounds.height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    fileprivate func axSort(_ column: SheetColumn) {
        guard column.sortable else { return }
        onSort?(column)
    }

    fileprivate func axSortDescription(_ column: SheetColumn) -> String? {
        guard let sortState, sortState.column == column else { return nil }
        return sortState.reversed ? String(localized: "sorted descending")
                                  : String(localized: "sorted ascending")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let font = NSFont.systemFont(ofSize: 11 * fontScale, weight: .medium)
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
                let indicator = SheetSymbols.sort(reversed: sortState.reversed,
                                                 fontScale)
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
        for column in SheetColumn.allCases where column != .date {
            CGRect(x: frames.x[column.rawValue] - 0.5, y: 0,
                   width: 1, height: bounds.height - 1).fill()
        }
    }

    /// The column whose trailing divider is under `x`, if any. Only fixed
    /// columns resize; Description takes whatever is left, as it does in a
    /// Finder window.
    override func resetCursorRects() {
        super.resetCursorRects()
        for edge in frames.resizableEdges(hidden: hiddenColumns) {
            addCursorRect(CGRect(x: edge - SheetMetrics.resizeGrab, y: 0,
                                 width: SheetMetrics.resizeGrab * 2,
                                 height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let column = frames.resizableColumn(nearX: point.x, hidden: hiddenColumns) {
            dragging = (column, point.x, frames.width[column.rawValue])
            return
        }
        guard let column = frames.column(atX: point.x), column.sortable else { return }
        onSort?(column)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let width = max(SheetMetrics.minColumnWidth,
                        dragging.startWidth + (point.x - dragging.startX))
        onResize?(dragging.column, width)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { return }
        self.dragging = nil
        window?.invalidateCursorRects(for: self)
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
        let headerHeight = headerView.preferredHeight
        headerView.frame = CGRect(x: 0, y: bounds.height - headerHeight,
                                  width: bounds.width, height: headerHeight)
        scrollView.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                  height: bounds.height - headerHeight)
        // The shell's entry/summary bars arrive as safe-area insets; keep the
        // last transaction scrollable above them.
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0,
                                                bottom: safeAreaInsets.bottom,
                                                right: 0)
        sheet.updateWidth(scrollView.contentSize.width)
    }
}

#endif
