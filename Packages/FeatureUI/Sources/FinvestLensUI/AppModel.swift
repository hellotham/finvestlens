//
//  AppModel.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import FinvestLensEngine
import FinvestLensPersistence
import FinvestLensInterchange
import FinvestLensRules
import FinvestLensQuotes
import FinvestLensReports
import FinvestLensIntelligence
import FinvestLensCloud
import Network

/// A row in the chart-of-accounts tree.
public struct AccountNode: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var name: String
    public var fullName: String
    public var typeName: String
    public var balance: Decimal
    public var currencyCode: String
    public var isPlaceholder: Bool
    public var isHidden: Bool
    /// GnuCash colour string (`color` slot), e.g. "rgb(144,144,238)".
    public var color: String?
    public var children: [AccountNode]?
}

public extension AccountNode {
    /// Whether this node is one of the given engine types. `typeName` is the
    /// display-capitalized raw value ("Bank"), so comparing it to
    /// `AccountType.rawValue` ("bank") directly always fails — the trap that
    /// silently emptied the goal and funding pickers. Compare here, once.
    func isType(_ types: AccountType...) -> Bool { isType(types) }

    func isType(_ types: [AccountType]) -> Bool {
        types.contains { typeName.caseInsensitiveCompare($0.rawValue) == .orderedSame }
    }
}

/// A row in an account register (one split, with a running balance).
public struct RegisterRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var date: Date
    /// When the transaction was entered, as opposed to posted — GnuCash sorts
    /// by this ("Date of Entry") to see what was keyed in when.
    public var dateEntered: Date
    public var number: String
    public var description: String
    public var transfer: String
    public var reconcile: String
    /// The split's own memo, and the transaction's notes and this split's
    /// action — the three things GnuCash puts on a register's second line when
    /// Double Line is on. `memo` is also what the Memo sort orders by.
    public var memo: String
    public var notes: String
    public var action: String
    /// The account this row posted to. Empty unless the register is showing a
    /// subtree, where "which account" is the question a single-account register
    /// never had to answer.
    public var accountName: String = ""
    public var amount: Decimal
    /// The account's balance as of this posting, or `nil` when the register
    /// spans more than one commodity and a running total would mean nothing.
    public var runningBalance: Decimal?
    /// Whether the transaction carries a document link (`assoc_uri`) — drawn as
    /// a paperclip on the row, and what the attachments panel opens.
    public var hasDocument = false
    /// The transaction's own currency, when it is not this account's — the
    /// mark of a foreign-denominated transaction (`FR-CUR-02`).
    ///
    /// `nil` for the ordinary case, which is nearly every row: a register that
    /// announced "AUD" on every line of an AUD account would be saying nothing.
    /// The row's `amount` is always the account's own commodity (the split's
    /// `quantity`); this names the unit the transaction was *struck* in.
    public var foreignCurrencyCode: String?

    /// What double-line mode shows beneath the description: the transaction's
    /// notes, then this split's own memo, then its action. Any of the three can
    /// be empty, and on most rows all three are.
    public var secondLine: String {
        [notes, memo, action].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// How a register orders its rows for display (GnuCash View ▸ Sort By).
///
/// Display only. The running balance is always computed in ``standard`` order
/// and carried on the row, so re-sorting never changes what a row's balance
/// says — which is what GnuCash does: sort its register by amount and each row
/// keeps the balance it had in date order.
public enum RegisterSort: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard Order"
    case date = "Date"
    case dateEntered = "Date of Entry"
    case number = "Number"
    case amount = "Amount"
    case description = "Description"
    case memo = "Memo"
    public var id: String { rawValue }
}

/// Which rows a register shows (GnuCash View ▸ Filter By).
///
/// Filtering hides rows; it does not re-compute balances. A hidden split still
/// moved the account, so the rows either side of it keep the balances they have
/// in the unfiltered register.
public struct RegisterFilter: Equatable, Sendable {
    /// Reconcile states to show. Empty shows nothing — as in GnuCash, where
    /// "Clear All" leaves an empty register rather than meaning "no filter".
    public var statuses: Set<ReconcileState>
    /// Inclusive posting-date bounds; `nil` means unbounded.
    public var startDate: Date?
    public var endDate: Date?

    public static let showAll = RegisterFilter(
        statuses: Set(ReconcileState.allCases), startDate: nil, endDate: nil)

    /// True when this filter hides nothing — drives the "Filtered" hint.
    public var isShowingEverything: Bool { self == .showAll }

    public init(statuses: Set<ReconcileState>, startDate: Date? = nil, endDate: Date? = nil) {
        self.statuses = statuses
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// A tool panel presented over the root view. Routed through
/// ``AppModel/presentedPanel`` so both menu-bar commands and toolbar buttons
/// can open any panel.
public enum RootPanel: String, Identifiable, Sendable {
    // Short, focused tasks that remain modal sheets (HIG). App *areas* (reports,
    // rules, scheduled, budgets, goals, prices, business, time & mileage) are now
    // sidebar destinations — see ``SidebarSelection``.
    case newAccount, newSecurity, newTransaction, stockTransaction, currencyTransfer
    case saveSearch, onboarding
    case reconcile
    case autoCategorize
    case bulkEdit
    case matchAttachments
    case linkedDocuments
    case loanCalculator
    case closeBook
    case taxOptions
    case find
    case findAccount
    public var id: String { rawValue }

    /// Whether this opens as a **tab** rather than a modal sheet.
    ///
    /// The rule, agreed 16 Aug 2026: *a thing you work in is a tab; a question
    /// you must answer is a sheet.* The tabbed interface is meant to be
    /// consistent across modes, and a form you sit in for a few minutes —
    /// entering a transaction, reconciling, calculating a loan — is a document,
    /// not a question.
    ///
    /// The exceptions earn their modality. Find and Find Account are pickers
    /// that end the moment you choose; Save This Search asks one thing; Close
    /// Financial Year and the tax options hold the book until answered, and a
    /// tab you can wander away from leaves them half-answered — which is a
    /// data-integrity hazard, not a consistency win.
    public var opensAsTab: Bool {
        switch self {
        case .newAccount, .newSecurity, .newTransaction, .stockTransaction,
             .currencyTransfer, .reconcile, .autoCategorize, .bulkEdit,
             .matchAttachments, .linkedDocuments, .loanCalculator:
            true
        case .saveSearch, .onboarding, .closeBook, .taxOptions, .find, .findAccount:
            false
        }
    }

    /// What its tab calls it.
    public var title: String {
        switch self {
        case .newAccount: String(localized: "New Account")
        case .newSecurity: String(localized: "New Security")
        case .newTransaction: String(localized: "New Transaction")
        case .stockTransaction: String(localized: "Stock Transaction")
        case .currencyTransfer: String(localized: "Currency Transfer")
        case .saveSearch: String(localized: "Save Search")
        case .onboarding: String(localized: "Welcome")
        case .reconcile: String(localized: "Reconcile")
        case .autoCategorize: String(localized: "Auto-Categorise")
        case .bulkEdit: String(localized: "Bulk Edit")
        case .matchAttachments: String(localized: "Match Attachments")
        case .linkedDocuments: String(localized: "Linked Documents")
        case .loanCalculator: String(localized: "Loan Calculator")
        case .closeBook: String(localized: "Close Financial Year")
        case .taxOptions: String(localized: "Tax Options")
        case .find: String(localized: "Find")
        case .findAccount: String(localized: "Find Account")
        }
    }

    /// The mode whose tab strip hosts it, so opening one never moves the window
    /// to an unrelated area.
    public var hostMode: AppMode {
        switch self {
        case .newTransaction, .stockTransaction, .currencyTransfer, .reconcile,
             .autoCategorize, .bulkEdit, .matchAttachments, .linkedDocuments,
             .newAccount:
            .accounts
        case .newSecurity: .investments
        case .loanCalculator: .planning
        // The modal ones never become tabs, so their host is never consulted;
        // Accounts is the honest default rather than a trap.
        case .saveSearch, .onboarding, .closeBook, .taxOptions, .find, .findAccount:
            .accounts
        }
    }
}

/// What the sidebar has selected.
///
/// Two kinds of thing, and the distinction is the sidebar's whole shape since
/// P12: a **collection** (the parent row — Budgets, Rules, Favourites) and an
/// **instance within it** (that budget, that rule). Exactly two levels, which is
/// what HIG *Sidebars* asks for; accounts are the deliberate exception, since
/// GnuCash users expect the tree (navigation-design §4.2).
///
/// Areas that used to open as modal sheets are navigation destinations shown
/// inline in the detail pane (HIG: minimise modality).
public enum SidebarSelection: Hashable, Sendable {
    case dashboard
    case account(GncGUID)
    case reports
    /// The whole book in journal form — GnuCash's Tools ▸ General Ledger, a
    /// destination of its own rather than a register style (GnuCash's register
    /// has only Basic / Auto-Split / Journal).
    case generalLedger
    case budgets
    case scheduled
    case rules
    case goals
    case planner
    /// The three planners, each a destination of its own.
    ///
    /// They were a segmented `Picker` inside `PlanningView` — the only
    /// navigation in the app that lived in the content rather than in the
    /// sidebar and the tab strip. Three whole screens reachable from neither
    /// the sidebar, the tab strip, ⌘T nor the View menu, in a mode whose other
    /// four destinations were reachable from all four. Reports already lists a
    /// fixed catalogue as sidebar rows; this is the same shape.
    case plannerDebt
    case plannerLifetime
    case plannerTax
    case emergencyRecords
    /// The Investments hub (`FR-INV-08`) — holdings, price health, per-security
    /// detail. Replaced `case prices`, which named a database rather than a
    /// subject; session restore still accepts the old spelling.
    case investments
    /// One **portfolio** — a parent account that holds security accounts, so
    /// the holdings table can be scoped to a broker, a super fund or a
    /// self-managed pool rather than always showing every security in the book.
    ///
    /// Asked for on 16 Aug 2026: "tabs in the investment mode (All Holdings,
    /// and then each portfolio)". The tabs are the same mechanism every other
    /// mode uses — a sidebar row opened in a tab — so this is a selection, not
    /// a second kind of tab.
    case portfolio(GncGUID)
    /// An editor opened as a tab rather than a sheet (`RootPanel/opensAsTab`).
    case panel(RootPanel)
    case business
    case timeMileage

    // MARK: Instances (P12/N2)
    //
    // "What used to be a destination ('Budgets') becomes a heading over the
    // things themselves" — the parent row still selects the whole collection,
    // and the rows beneath select one of them.

    case budget(GncGUID)
    case goal(GncGUID)
    case scheduledTransaction(GncGUID)
    case ruleGroup(UUID)
    case emergencyRecord(UUID)
    case savedReport(UUID)
    /// One report from the standard catalogue, opened with its default
    /// configuration — the sidebar's "Standard" collection.
    case report(ReportKind)
    case invoice(GncGUID)
    case customer(GncGUID)
    case vendor(GncGUID)
    case job(GncGUID)
    case employee(GncGUID)
    /// A security, keyed by ``securityKey`` rather than by its ``Commodity``.
    /// The commodity value carries mutable fields — quote source, timezone,
    /// kvp — so two values of the *same* security compare unequal, and the
    /// selection would drop the moment a price fetch rewrote one of them.
    case security(String)
    /// One of Overview's views — a named selection of cards (`FR-NAV-07`).
    case overviewView(String)
    /// One card, shown full-window (`FR-NAV-08`), and the view it was picked
    /// from.
    ///
    /// The view is part of the identity because a card belongs to several: Net
    /// Worth is on Mix *and* on Accounts, and two sidebar rows carrying the same
    /// tag make `List` selection ambiguous. It is also the answer to "which
    /// board does closing this card return to?".
    case overviewCard(view: String, card: String)
    /// The book's own history. A collection, which is why it is a Records
    /// destination now rather than the modal sheet it used to be — everything
    /// else in the Tools menu is a command (navigation-design §4.2).
    case auditLog

    /// The identity Investments already dedupes securities by
    /// (`AppModel.securityCommodities`), reused so the sidebar and the hub agree
    /// on what counts as one security.
    public static func securityKey(_ commodity: Commodity) -> String {
        "\(commodity.namespace)|\(commodity.mnemonic)"
    }

    // MARK: Reading the focused instance
    //
    // A collection view asks "is one of mine selected?" and shows it. Each
    // accessor is one case test; written out rather than generated so that
    // adding a collection to the sidebar without teaching its view to focus is
    // a missing accessor rather than a silently ignored selection.

    public var budgetID: GncGUID? { if case .budget(let id) = self { id } else { nil } }
    public var goalID: GncGUID? { if case .goal(let id) = self { id } else { nil } }
    public var scheduledID: GncGUID? {
        if case .scheduledTransaction(let id) = self { id } else { nil }
    }
    public var ruleGroupID: UUID? { if case .ruleGroup(let id) = self { id } else { nil } }
    public var emergencyRecordID: UUID? {
        if case .emergencyRecord(let id) = self { id } else { nil }
    }
    public var savedReportID: UUID? { if case .savedReport(let id) = self { id } else { nil } }
    public var reportKind: ReportKind? { if case .report(let kind) = self { kind } else { nil } }
    public var invoiceID: GncGUID? { if case .invoice(let id) = self { id } else { nil } }
    /// Any business party — customer, vendor, job or employee. The hub lists
    /// them all on one page, so it wants the party rather than which kind.
    public var businessPartyID: GncGUID? {
        switch self {
        case .customer(let id), .vendor(let id), .job(let id), .employee(let id): id
        default: nil
        }
    }
}

/// The observable application/document model driving the UI.
///
/// The engine ``Book`` is the source of truth but is not itself observable, so
/// `AppModel` recomputes plain value snapshots (``accountTree``,
/// ``registerRows``) after each mutation — SwiftUI observes those. Document
/// operations delegate to ``FinvestLensPersistence``.
@MainActor
@Observable
public final class AppModel {

    public private(set) var document: FinvestLensDocument?

    /// The book currently being opened, or `nil`. The load runs off the main
    /// actor, so the window stays live and can say what it is doing rather than
    /// appearing to ignore the click — on the reference book the read alone is
    /// seconds long.
    public private(set) var openingURL: URL?

    /// How far through the open we are, or `nil` before the first report. Drives
    /// the bar in ``OpeningBookView``; see ``BookLoadProgress`` for the weights.
    public private(set) var loadProgress: BookLoadProgress?

    /// True while a book is being opened.
    public var isOpening: Bool { openingURL != nil }

    /// A book is on its way in — opened, created or imported, the one on
    /// screen closing for it first. Claimed before the first suspension and
    /// released on the way out.
    ///
    /// Closing is a suspension (``saveAndClose()`` writes off the main actor,
    /// seconds on a NAS) and the window stays live through it, so File ▸ New
    /// Book… and then Open Recent could both get past their checks and both
    /// land a document — the first one dropped unseen, with its working copy
    /// and whatever was typed into it meanwhile. One replacement at a time; a
    /// second is ignored, as a second click on Open always was.
    @ObservationIgnored var isReplacingBook = false

    /// The GnuCash file currently being imported, or `nil`. Parsing and the
    /// write-back both run off the main actor — on a large export (the
    /// Ashley Bears book: 46k transactions, 103k prices) each can run to
    /// several seconds, same as opening a book. Drives ``ImportingBookView``
    /// through the same ``loadProgress``.
    public private(set) var importingURL: URL?

    /// True while a GnuCash file is being imported.
    public var isImporting: Bool { importingURL != nil }

    /// Records a report from the loader, dropping any that would move the bar
    /// backwards.
    ///
    /// Reports are emitted off the main actor and hop here one `Task` each;
    /// nothing guarantees two hops arrive in the order they were sent, and a bar
    /// that goes backwards reads as a bug even when the load is fine. Monotonic
    /// is the only property that matters, and it is one comparison.
    func recordLoadProgress(_ progress: BookLoadProgress) {
        guard progress.fraction >= (loadProgress?.fraction ?? -1) else { return }
        loadProgress = progress
    }

    public private(set) var accountTree: [AccountNode] = [] {
        didSet {
            postableAccountsCache = nil
            typedAccountsCache.removeAll()
        }
    }

    /// Flattened, non-placeholder accounts usable as transfer endpoints —
    /// every picker in the app reads this list. Flattening the tree on each
    /// of the register's many body passes was measurable; the tree only
    /// changes when it is rebuilt, so the flattening follows it.
    @ObservationIgnored private var postableAccountsCache: [AccountNode]?

    /// The lists the assistants filter from ``postableAccounts`` — security,
    /// settlement, income and expense accounts — kept for the same reason and
    /// dropped at the same moment. The stock and currency sheets read them
    /// several times per body pass, and every keystroke there re-filtered the
    /// whole flat list (Performance Review P4).
    @ObservationIgnored var typedAccountsCache: [TypedAccounts: [AccountNode]] = [:]

    /// ``transactionsForLinking(query:limit:)``'s index, per transaction
    /// revision.
    @ObservationIgnored var linkingIndex: LinkingIndex?

    /// Which typed list, for ``typedAccountsCache``, and the engine types it
    /// holds.
    enum TypedAccounts: Hashable {
        case security, settlement, income, expense

        var types: [AccountType] {
            switch self {
            case .security: [.stock, .mutualFund]
            case .settlement: [.bank, .cash, .asset]
            case .income: [.income]
            case .expense: [.expense]
            }
        }
    }

    public var postableAccounts: [AccountNode] {
        if let cached = postableAccountsCache { return cached }
        func flatten(_ nodes: [AccountNode]) -> [AccountNode] {
            nodes.flatMap { [$0] + flatten($0.children ?? []) }
        }
        let flat = flatten(accountTree).filter { !$0.isPlaceholder }
        postableAccountsCache = flat
        return flat
    }
    public private(set) var registerRows: [RegisterRow] = []

    /// Bumped by ``refreshAll()`` whenever derived state is invalidated. The
    /// lazily-derived rows below read it, which is what registers them as
    /// observation dependencies — so a view showing them redraws after an edit
    /// even though the rows themselves are not stored observed properties.
    private var derivedRevision = 0

    /// Bumped by a `.preference`-scoped kvp edit (see ``KvpEditScope``); read
    /// by the getters of the settings it covers so their views redraw.
    public private(set) var preferencesRevision = 0

    /// Bumped whenever the document's dirty state may have changed — an edit,
    /// a save — so ``hasUnsavedChanges``' readers (the Save menu) re-evaluate
    /// without a full refresh after every save (Performance Review 2, R8).
    public private(set) var documentStateRevision = 0

    /// Bumped whenever ``registerRows`` (or the journal caches the whole-book
    /// register reads) are actually rebuilt — not on every ``derivedRevision``
    /// move. The register surfaces key their base rows on this rather than on
    /// ``bookRevision``, so a price-only edit, which changes valuations but
    /// not one register row, no longer costs them a rebuild (Performance
    /// Review 2, R8).
    public private(set) var registerRevision = 0

    /// Bumped by every `.book`-scoped refresh — whenever transactions, splits
    /// or accounts may have changed — and never by a price-only edit. The
    /// whole-book register keys its rows on it, and so do memos of facts that
    /// are about transactions alone (`legRows`, the linked-document list).
    public private(set) var transactionRevision = 0

    /// The book-state revision, for views that key async work off "did the
    /// book change" (P3's `.task(id:)` pattern). Observable: bumping it is
    /// what redraws report views after an edit.
    public var bookRevision: Int { derivedRevision }

    /// Price/rate rows for the price and rate editors, sorted newest first.
    ///
    /// Derived on demand rather than in ``refreshAll()``: sorting all 102,706
    /// prices of the reference book and building a row per price cost ~0.09s of
    /// every edit, for two panels that are usually closed. Building them here
    /// means an edit pays nothing and the panel pays once per change.
    public var priceRows: [PriceRow] {
        _ = derivedRevision
        buildPriceRowsIfNeeded()
        return priceRowCache ?? []
    }

    public var rateRows: [RateRow] {
        _ = derivedRevision
        buildPriceRowsIfNeeded()
        return rateRowCache ?? []
    }

    /// Caches for the two properties above. Not observed: they are a pure
    /// function of the book, and ``refreshAll()`` drops them alongside the
    /// observed state that does drive the redraw. Writing them from a getter
    /// must not notify observers, or reading a row inside a view's body would
    /// invalidate that body.
    @ObservationIgnored var securityCommoditiesCache: (revision: Int, value: [Commodity])?
    @ObservationIgnored private var priceRowCache: [PriceRow]?
    @ObservationIgnored private var rateRowCache: [RateRow]?

    /// ``availableProviders``' memo and the revision that drops it. A keyed
    /// provider is "available" when the Keychain holds a key for it, and the
    /// Keychain is a round trip to `securityd` — which the list used to make
    /// per keyed provider on every read, and a fetch run read it once per
    /// security (Performance Review 2, R9). Keys change only through
    /// ``setAPIKey(_:for:)`` in this process, which bumps the revision.
    @ObservationIgnored var availableProvidersCache: (revision: Int, value: [QuoteProviderKind])?
    public internal(set) var apiKeysRevision = 0

    /// ``legRows(ofTransaction:)``' memo, dropped when ``transactionRevision``
    /// moves: a leg's account `fullName` is a recursive string build per split,
    /// and every register surface asks for the same legs again and again.
    @ObservationIgnored var legRowsCache: [GncGUID: [AutoSplitRow]] = [:]
    @ObservationIgnored var legRowsRevision = -1

    /// Memoised results of the pure report functions (balance sheet, income
    /// statement, portfolio, net-worth series…), keyed by a per-call signature.
    /// The dashboard asks for several of these on every body pass, and its body
    /// re-runs on every hover — without this, each hover recomputed a full-book
    /// scan per panel. Dropped whenever the book changes (``derivedRevision``).
    @ObservationIgnored private var reportCache: [String: Any] = [:]
    @ObservationIgnored private var reportCacheRevision = -1

    /// Returns the cached value for `key`, or computes and caches it. `nil`
    /// results (no book) are not cached — they are cheap to recompute anyway.
    /// The cache is a pure function of the book, so writing it from a getter must
    /// not notify observers; ``derivedRevision`` is the redraw signal, not this.
    func cachedReport<T>(_ key: String, compute: () -> T?) -> T? {
        if reportCacheRevision != derivedRevision {
            reportCache.removeAll(keepingCapacity: true)
            reportCacheRevision = derivedRevision
        }
        if let hit = reportCache[key] as? T { return hit }
        let value = Perf.measureReport(key, compute)
        if let value { reportCache[key] = value }
        return value
    }

    /// The cached value for `key` if it is already there for the book as it
    /// stands — never computing it. A view that builds a report in a task
    /// draws a warm one in its first frame with this, instead of a
    /// placeholder for the frame it takes the task to land.
    func peekReport<T>(_ key: String) -> T? {
        guard reportCacheRevision == derivedRevision else { return nil }
        return reportCache[key] as? T
    }

    /// `request` from the memo, built here if it is cold.
    func report<Value>(_ request: ReportRequest<Value>) -> Value? {
        guard let book else { return nil }
        return cachedReport(request.key) {
            let start = ContinuousClock.now
            let value = request.build(book)
            reportBuildTimes[request.kind] = ReportBuildTime(took: ContinuousClock.now - start,
                                                             work: request.work)
            return value
        }
    }

    /// Builds `request` off the main actor, on a replica, when the memo does
    /// not hold it yet and building it is slow — so a report that takes
    /// seconds leaves the window drawing while it does (P3.3).
    ///
    /// Slow is measured, not assumed. Taking the replica is main-actor work
    /// too (45 ms on the reference book), so a report that builds faster than
    /// that is built where it is asked, and only one whose last build took
    /// longer than ``offMainThreshold`` — or that has not been built yet, so
    /// a first build on a large book never blocks — comes here. Every build
    /// records its time, so the choice follows the book as it grows, and how
    /// much it read, so a quick build over a quiet account does not vouch for
    /// the busiest one; closing the book forgets them all. What is
    /// built is kept under the revision the replica was taken at: an edit made
    /// meanwhile leaves it out, and the next ask builds again.
    func warm<Value>(_ request: ReportRequest<Value>) async {
        guard book != nil, (peekReport(request.key) as Value?) == nil else { return }
        if let last = reportBuildTimes[request.kind],
           last.isFast(for: request.work, under: Self.offMainThreshold) { return }
        // A revision that moves while it builds — an edit, a quote refresh
        // landing — leaves that build out of the memo, and the next ask
        // built it again on the main actor: the very wait this exists to
        // spare. So it builds again here, on a fresh replica, a few times.
        for _ in 0..<3 {
            guard !Task.isCancelled, let book, (peekReport(request.key) as Value?) == nil else { return }
            let revision = derivedRevision
            let replica = book.replica()
            let (value, took) = await Task.detached(priority: .userInitiated) {
                let start = ContinuousClock.now
                let value = request.build(replica.book)
                return (value, ContinuousClock.now - start)
            }.value
            guard self.book === book else { return }
            reportBuildTimes[request.kind] = ReportBuildTime(took: took, work: request.work)
            guard let value else { return }
            guard derivedRevision == revision else { continue }
            if reportCacheRevision != derivedRevision {
                reportCache.removeAll(keepingCapacity: true)
                reportCacheRevision = derivedRevision
            }
            reportCache[request.key] = value
            return
        }
    }

    /// A report that builds in less than this is built where it is asked:
    /// taking a replica to build it elsewhere costs the main actor more.
    static let offMainThreshold: Duration = .milliseconds(80)

    /// Fills both caches from **one** sort — the editor shows prices and rates
    /// together, and sorting 102,706 prices once per property would pay the
    /// dominant cost twice. The sorted array itself is not retained.
    private func buildPriceRowsIfNeeded() {
        guard priceRowCache == nil || rateRowCache == nil else { return }
        let sorted = book?.prices.sorted { $0.date > $1.date } ?? []
        priceRowCache = sorted
            .filter { $0.commodity.namespace != .currency }
            .map { PriceRow(id: $0.guid, symbol: $0.commodity.mnemonic,
                            currencyCode: $0.currency.mnemonic, date: $0.date, value: $0.value) }
        rateRowCache = sorted
            .filter { $0.commodity.namespace == .currency }
            .map { RateRow(id: $0.guid, from: $0.commodity.mnemonic,
                           to: $0.currency.mnemonic, date: $0.date, value: $0.value) }
    }

    /// Financial Review slide stories, keyed by (slide, revision, period) —
    /// the on-device model writes each once per book state.
    @ObservationIgnored var reviewStoryCache: [String: ReviewSlideStory] = [:]
    /// Slides the narrator was asked about and had nothing sound to say for,
    /// by the same key — so the deterministic headline stands until the book
    /// changes, instead of three more drafts being spent on every visit.
    @ObservationIgnored var reviewStoryDeclined: Set<String> = []

    @ObservationIgnored private var descriptionRecencyCache: [(text: String, folded: String)] = []
    @ObservationIgnored private var descriptionRecencyRevision = -1
    /// Each transaction's folded description, kept across revisions: an edit
    /// changes one description, so re-folding all 46k on the next keystroke
    /// was the avoidable half of a 139 ms hitch (Performance Review 2, R7).
    @ObservationIgnored private var descriptionFolds: [GncGUID: (text: String, folded: String)] = [:]
    @ObservationIgnored private var newestFirstCache: [Transaction] = []
    @ObservationIgnored private var newestFirstRevision = -1

    /// Every transaction, newest first: sorted once per
    /// ``transactionRevision`` for QuickFill and the link picker alike, which
    /// each sorted the book for themselves (17 October review).
    var transactionsNewestFirst: [Transaction] {
        if newestFirstRevision != transactionRevision {
            newestFirstCache = (book?.transactions ?? []).sorted { $0.datePosted > $1.datePosted }
            newestFirstRevision = transactionRevision
        }
        return newestFirstCache
    }

    /// `txn`'s description, lowercased — from the fold kept for QuickFill
    /// where the description is unchanged, so the link picker and QuickFill
    /// fold the same text the same way, once.
    func foldedDescription(of txn: Transaction) -> String {
        let description = txn.transactionDescription
        if let known = descriptionFolds[txn.guid], known.text == description { return known.folded }
        return description.lowercased()
    }

    /// Distinct transaction descriptions, most-recent first, each with its
    /// case-folded form. QuickFill used to sort all 46k transactions on every
    /// keystroke; now the sort happens once per change to the transactions
    /// and a keystroke is a prefix scan over ~thousands of short strings.
    ///
    /// Keyed on ``transactionRevision``: a description changes only with a
    /// transaction, and keying on the book revision made every quote refresh
    /// cost the next QuickFill keystroke a sort of every transaction
    /// (Performance Review 2, R7e).
    var recentDistinctDescriptions: [(text: String, folded: String)] {
        if descriptionRecencyRevision != transactionRevision {
            var seen = Set<String>()
            var entries: [(text: String, folded: String)] = []
            var folds: [GncGUID: (text: String, folded: String)] = [:]
            folds.reserveCapacity(descriptionFolds.count)
            for txn in transactionsNewestFirst {
                let description = txn.transactionDescription
                guard !description.isEmpty else { continue }
                let entry: (text: String, folded: String)
                if let known = descriptionFolds[txn.guid], known.text == description {
                    entry = known
                } else {
                    entry = (description, description.lowercased())
                }
                folds[txn.guid] = entry
                guard seen.insert(description).inserted else { continue }
                entries.append(entry)
            }
            descriptionFolds = folds
            descriptionRecencyCache = entries
            descriptionRecencyRevision = transactionRevision
        }
        return descriptionRecencyCache
    }

    @ObservationIgnored private var unreconciledRowsCache: [RegisterRow] = []
    @ObservationIgnored private var unreconciledRowsRevision = -1

    /// The register rows a VoiceOver rotor jumps between: the unreconciled ones.
    ///
    /// Memoised on ``derivedRevision`` for the same reason every other
    /// derivation here is. The rotor's `ForEach` is rebuilt on *every* body
    /// pass — every click, every keystroke, every selection change — and it was
    /// walking all 140,000 register rows and running a string switch on each,
    /// which is O(rows) work per interaction on a screen that shows thirty of
    /// them. This makes it O(rows) once per book change instead, which is what
    /// GnuCash does throughout: derive once into memory, invalidate on edit.
    var unreconciledRegisterRows: [RegisterRow] {
        if unreconciledRowsRevision != derivedRevision {
            // By the letter, not the word: the word is the reader's now, and
            // "Not reconciled" is English in one language only.
            unreconciledRowsCache = registerRows.filter { ReconcileBadge.isUnreconciled($0.reconcile) }
            unreconciledRowsRevision = derivedRevision
        }
        return unreconciledRowsCache
    }

    // MARK: Navigation — mode, and each mode's own selection

    /// The current mode (`FR-NAV-01`), each mode's open tabs, and which of them
    /// is showing.
    ///
    /// Stored rather than computed so `@Observable` instruments them: the public
    /// accessors below read them, which is what registers a view showing the
    /// sidebar, the tab strip or the mode control as a dependency.
    ///
    /// `tabsByMode` holds the tabs the user opened. The mode's **home** is not
    /// among them — it is always tab 0, and derived rather than stored, so it
    /// cannot be closed, reordered or lost to a stale desk state.
    private var currentMode: AppMode = .dashboard
    private var tabsByMode: [AppMode: [SidebarSelection]] = [:]
    private var activeTabByMode: [AppMode: Int] = [:]

    /// Tabs a mode **always** shows, derived from the book rather than opened
    /// by hand — like the home tab, and for the same reason.
    ///
    /// Asked for twice, in these words: "we talked about tabs in the investment
    /// mode (All Holdings, and then each portfolio) - I did not see this", and
    /// then again after the first attempt, which put the portfolios in the
    /// *sidebar* and left the user to open each one. The tabs were the ask.
    ///
    /// A portfolio is the account whose sub-accounts hold securities. On the
    /// reference book that is fifteen of them — brokers, super funds and the
    /// SMSF's two — so they come from the book, not from anyone's history of
    /// having clicked them.
    private func standingTabs(in mode: AppMode) -> [SidebarSelection] {
        switch mode {
        case .investments: portfolioAccounts.map { .portfolio($0.id) }
        default: []
        }
    }

    /// A mode's open tabs: home, then the ones it always has, then the ones the
    /// user opened (`FR-NAV-05`).
    public func tabs(in mode: AppMode) -> [SidebarSelection] {
        [mode.defaultSelection] + standingTabs(in: mode) + normalisedExtras(in: mode)
    }

    /// The mode's user-opened tabs, with everything the strip derives for
    /// itself removed — the home selection and the standing tabs.
    ///
    /// There is one list, and this is it. The strip used to filter derived
    /// entries out at display time while `tabsByMode` kept them, so a display
    /// index and a position in storage meant different things whenever a
    /// stored tab had since become a standing one — which desk state written
    /// against a book with different investment accounts does routinely. Three
    /// call sites subscripted storage with a display index, and a fourth
    /// clamped against a count that omitted the standing tabs entirely.
    /// Filtering here, and writing the filtered list back, means the two
    /// orders are the same order.
    private func normalisedExtras(in mode: AppMode) -> [SidebarSelection] {
        let standing = standingTabs(in: mode)
        return (tabsByMode[mode] ?? []).filter {
            $0 != mode.defaultSelection && !standing.contains($0)
        }
    }

    /// The first tab index the user may close. Home and the standing tabs are
    /// derived, so closing one would only make it come back.
    /// The compact shell's rule for opening a destination: the tab it opened
    /// last in this mode gives way to the new one. Home, a standing tab, or a
    /// tab that was already open is simply made active.
    private func openCompactTab(_ selection: SidebarSelection, in mode: AppMode) {
        var extras = normalisedExtras(in: mode)
        if let mine = compactTabByMode[mode], mine != selection {
            extras.removeAll { $0 == mine }
            compactTabByMode[mode] = nil
        }
        let base = firstClosableTabIndex(in: mode)
        if selection == mode.defaultSelection {
            activeTabByMode[mode] = 0
        } else if let standing = standingTabs(in: mode).firstIndex(of: selection) {
            activeTabByMode[mode] = 1 + standing
        } else if let existing = extras.firstIndex(of: selection) {
            activeTabByMode[mode] = base + existing
        } else {
            extras.append(selection)
            compactTabByMode[mode] = selection
            activeTabByMode[mode] = base + extras.count - 1
        }
        tabsByMode[mode] = extras
    }

    public func firstClosableTabIndex(in mode: AppMode) -> Int {
        1 + standingTabs(in: mode).count
    }

    /// Whether the tab at `index` in the current mode has a close button.
    public func isClosableTab(_ index: Int) -> Bool {
        index >= firstClosableTabIndex(in: currentMode)
    }

    /// The current mode's open tabs.
    public var openTabs: [SidebarSelection] { tabs(in: currentMode) }

    /// Which tab is showing. Clamped on read: a desk state restored against a
    /// book with fewer tabs must land somewhere real rather than out of bounds.
    public var activeTabIndex: Int {
        min(max(activeTabByMode[currentMode] ?? 0, 0), openTabs.count - 1)
    }

    private func storedSelection(in mode: AppMode) -> SidebarSelection {
        let all = tabs(in: mode)
        let index = min(max(activeTabByMode[mode] ?? 0, 0), all.count - 1)
        return all[index]
    }

    /// Shows the tab at `index` in the current mode.
    public func selectTab(_ index: Int) {
        guard openTabs.indices.contains(index), index != activeTabIndex else { return }
        let old = storedSelection(in: currentMode)
        activeTabByMode[currentMode] = index
        applyNavigationChange(from: old)
    }

    /// Closes a tab. The home tab (index 0) has no close button and this
    /// refuses it anyway — a mode with no tab at all has nothing to show.
    public func closeTab(_ index: Int) {
        // Home *and* the standing tabs are derived, so removing one only makes
        // it reappear on the next read — and the arithmetic below would take
        // the wrong element out of `tabsByMode`.
        let firstClosable = firstClosableTabIndex(in: currentMode)
        guard index >= firstClosable, openTabs.indices.contains(index) else { return }
        let old = storedSelection(in: currentMode)
        // The same list the strip is showing, so `index - firstClosable` lands
        // on the tab the user actually clicked the cross on.
        var extras = normalisedExtras(in: currentMode)
        extras.remove(at: index - firstClosable)
        tabsByMode[currentMode] = extras
        // Land on the tab that took its place, or the one before it — never on
        // the home tab merely because the arithmetic was easier.
        activeTabByMode[currentMode] = min(activeTabIndexAfterClosing(index),
                                           extras.count + firstClosable - 1)
        applyNavigationChange(from: old)
    }

    /// Where the selection goes when the tab at `closed` is removed. It needs
    /// no count: the caller has already shrunk the tab list but has not yet
    /// written the index, so this reads the pre-close value. (It took one, named
    /// `previousCount`, that it never read — and the caller passed the count
    /// *after* removal, so the name was wrong too.)
    private func activeTabIndexAfterClosing(_ closed: Int) -> Int {
        let active = activeTabByMode[currentMode] ?? 0
        if active == closed { return closed }   // the next tab slides into place
        return active > closed ? active - 1 : active
    }

    /// Opens `selection` in this mode, following GnuCash's rules
    /// (`gnc-main-window.cpp:3291`, `gnc-plugin-page-account-tree.cpp:987`):
    ///
    /// - **Never a duplicate.** Something already open is focused, not opened
    ///   again — GnuCash checks `gnc_main_window_page_exists` first.
    /// - **A single click replaces**, which is this app's existing behaviour and
    ///   worth keeping; a new tab is a deliberate act (`inNewTab`).
    /// - **Except from the home tab**, which is pinned: replacing it would lose
    ///   the one tab a mode cannot be without, so the first click from home
    ///   opens a tab beside it instead.
    private func openTab(_ selection: SidebarSelection, inNewTab: Bool, in mode: AppMode) {
        // A placeholder account has no register, so opening one would show an
        // empty one. GnuCash expands or collapses the row instead; here the
        // sidebar's disclosure already does that, so the tab simply does not
        // open and the selection stays where it was.
        if case .account(let id) = selection,
           book?.account(with: id)?.isPlaceholder == true,
           !(book?.account(with: id)?.children.isEmpty ?? true) {
            return
        }
        if compactNavigation {
            openCompactTab(selection, in: mode)
            return
        }
        if selection == mode.defaultSelection {
            activeTabByMode[mode] = 0
            return
        }
        // A standing tab is already open; select it rather than appending a
        // second copy into the stored list.
        if let standing = standingTabs(in: mode).firstIndex(of: selection) {
            activeTabByMode[mode] = 1 + standing
            return
        }
        let base = firstClosableTabIndex(in: mode)
        var extras = normalisedExtras(in: mode)
        if let existing = extras.firstIndex(of: selection) {
            activeTabByMode[mode] = existing + base
            return
        }
        // Clamped, not trusted. A stored index can outrun its list — restore
        // filters dead tabs out and the index does not follow — and this is the
        // one place that *subscripts* with it rather than reading through the
        // clamp, so an unvalidated read here is a crash rather than a wrong tab.
        let active = min(max(activeTabByMode[mode] ?? 0, 0), extras.count + base - 1)
        if inNewTab || active < base {
            extras.append(selection)
            activeTabByMode[mode] = extras.count + base - 1
        } else {
            extras[active - base] = selection
            activeTabByMode[mode] = active
        }
        tabsByMode[mode] = extras
    }

    /// The mode the window is in. Switching restores that mode's own selection,
    /// so leaving Accounts for Reports and coming back lands on the register you
    /// left rather than a default (`FR-NAV-03`).
    public var mode: AppMode {
        get { currentMode }
        set {
            guard newValue != currentMode else { return }
            let old = storedSelection(in: currentMode)
            currentMode = newValue
            applyNavigationChange(from: old)
        }
    }

    /// The current mode's destination — the source of truth for what the detail
    /// pane shows.
    ///
    /// Assigning moves there, switching mode when the destination belongs to
    /// another one, because every assignment from code is an explicit act: a
    /// menu command, a dashboard card, a search result. The rule that
    /// *selecting* must not switch mode (navigation-design §4.3) is a rule about
    /// gestures, and it is kept where gestures are — each mode's sidebar offers
    /// only its own destinations, so a click can never name a foreign one.
    public var sidebarSelection: SidebarSelection? {
        get { storedSelection(in: currentMode) }
        set { navigate(to: newValue ?? currentMode.defaultSelection) }
    }

    /// Moves to `selection`, switching mode if it lives in another one.
    ///
    /// `inNewTab` is the deliberate act: ⌘-click, double-click, the row's
    /// context menu, or the strip's + button.
    public func navigate(to selection: SidebarSelection, inNewTab: Bool = false) {
        let old = storedSelection(in: currentMode)
        let target = AppMode(hosting: selection)
        openTab(selection, inNewTab: inNewTab, in: target)
        currentMode = target
        applyNavigationChange(from: old)
    }

    /// Opens a new tab on the mode's home — View ▸ New Tab and the strip's +.
    ///
    /// It used to ask for a second tab on *what is showing*, which openTab
    /// refuses by design: the never-a-duplicate rule fires before the
    /// new-tab branch, so ⌘T and the + button did nothing in every state. A
    /// new tab has to name something not already open, and the mode's home is
    /// the one destination that is always meaningful.
    /// What ⌘T and the tab strip's `+` can open: this mode's destinations that
    /// are not already showing in a tab, in sidebar order.
    ///
    /// The home tab is excluded because it is derived rather than stored —
    /// `tabs(in:)` puts `mode.defaultSelection` at index 0 and `openTab`
    /// refuses to add a second copy — which is what made the old `openNewTab()`
    /// wrong: it appended exactly that selection, so ⌘T produced a duplicate
    /// home tab that `restoreNavigation` filtered out again on reopen.
    public var unopenedTabDestinations: [SidebarSelection] {
        let open = Set(openTabs)
        var seen = Set<SidebarSelection>()
        var out: [SidebarSelection] = []
        func consider(_ rows: [SidebarRow]) {
            for row in rows {
                if !open.contains(row.id), seen.insert(row.id).inserted { out.append(row.id) }
                if let children = row.children { consider(children) }
            }
        }
        if currentMode == .accounts {
            // Accounts builds its sidebar in the view (a tree, not a list), so
            // its destinations come from the account list the pickers use —
            // favourites first, because a book with 565 accounts has no useful
            // "first" one and the starred handful is exactly the shortlist
            // someone keeps for this. The sidebar remains the way to reach any
            // other; `unopenedTabLimit` is what says so on screen.
            for id in favouriteAccountIDs where !open.contains(.account(id)) {
                if seen.insert(.account(id)).inserted { out.append(.account(id)) }
            }
            for node in postableAccounts where !open.contains(.account(node.id)) {
                if seen.insert(.account(node.id)).inserted { out.append(.account(node.id)) }
            }
        } else {
            for group in ModeSidebarRows.groups(for: currentMode, model: self) {
                consider(group.rows)
            }
        }
        return out
    }

    /// How many the `+` menu shows before deferring to the sidebar. A menu is a
    /// shortcut, not a browser: 565 accounts in one would be worse than the
    /// list they are already in.
    public static let unopenedTabLimit = 12

    /// Opens the first destination this mode has left, for ⌘T. The strip's `+`
    /// offers the whole list instead — a menu can, a keystroke cannot.
    public func openNewTab() {
        guard let next = unopenedTabDestinations.first else { return }
        navigate(to: next, inNewTab: true)
    }

    /// The pruned, sorted account tree the sidebar draws, and the per-account
    /// facts its comparators read — both keyed on the book revision.
    @ObservationIgnored var sidebarTreeCache: [AccountNode] = []
    @ObservationIgnored var sidebarTreeKey = ""
    @ObservationIgnored var manualOrderIndex: [GncGUID: Int] = [:]
    @ObservationIgnored var codeIndex: [GncGUID: String] = [:]
    @ObservationIgnored var sortIndexRevision = -1

    /// The memo behind ``portfolioAccounts``, which the Investments tab strip
    /// reads several times per SwiftUI pass. `@ObservationIgnored` because it
    /// is a cache: `derivedRevision` is already the redraw signal.
    @ObservationIgnored var portfolioCache: [AccountNode] = []
    @ObservationIgnored var portfolioCacheRevision = -1
    /// Which side of the Show Closed Positions toggle the cache was built for.
    @ObservationIgnored var portfolioCacheShowedClosed = false

    /// Custom Overview views, decoded once per book rather than per read.
    /// Observed, not `@ObservationIgnored`: saving a view has to redraw the
    /// sidebar that lists it.
    var customViewsCache: [OverviewView] = []
    var customViewsKeyCached = ""

    /// Securities, and the key→commodity index the sidebar and tab strip look
    /// through. `securityCommodities` walks every account and builds a string
    /// per security on each call, and the tab strip asked three times per
    /// security tab per body pass.
    @ObservationIgnored var securityIndexCache: [String: Commodity] = [:]
    @ObservationIgnored var securityIndexRevision = -1

    /// Earliest posting per account, for the sidebar's "First Transaction"
    /// order. Memoised on ``bookRevision``: the sidebar asks per row on every
    /// body pass, and one pass over 46k transactions per pass is the shape of
    /// cost this codebase has paid for before.
    @ObservationIgnored var firstPostingCache: [GncGUID: Date] = [:]
    @ObservationIgnored var firstPostingRevision = -1

    /// Backs ``period``. `nil` means "the book's default" — so a book whose
    /// default period is changed in Settings takes effect immediately for
    /// anyone who has not moved the selector.
    var windowPeriod: ReportPeriod?

    /// Where every mode is, for session persistence — see `AppModel+Session`.
    var navigationSnapshot: (mode: AppMode,
                             tabs: [AppMode: [SidebarSelection]],
                             active: [AppMode: Int]) {
        (currentMode, tabsByMode, activeTabByMode)
    }

    /// Re-applies a whole desk state in one step — see `AppModel+Session`.
    ///
    /// One funnel rather than a mode assignment followed by a selection
    /// assignment: the two-step form refreshes the register against the
    /// half-restored state, and a restore that happens to land on the mode
    /// already showing would skip the refresh altogether.
    func restoreNavigation(mode restored: AppMode,
                           tabs: [AppMode: [SidebarSelection]],
                           active: [AppMode: Int]) {
        let old = storedSelection(in: currentMode)
        currentMode = restored
        // A stored home tab would be a duplicate of the derived one; dropping
        // it here means a desk state written by any future build cannot
        // produce a mode showing its home twice.
        tabsByMode = tabs.mapValues { list in
            list.filter { $0 != AppMode(hosting: $0).defaultSelection }
        }
        // Clamped against the list as restored, not as stored. Dropping a dead
        // tab shifts every index after it, so a desk state that lost one would
        // otherwise reopen on the tab *next to* the one it was left on — and an
        // index past the end poisons `openTab` until the next relaunch.
        //
        // Counted from the strip itself. Counting `tabsByMode` plus one for
        // home omitted the standing tabs, so in a mode that has any (only
        // Investments today) a perfectly valid index was clamped *down* and
        // the restore landed on the wrong tab. `self.tabs(in:)` because the
        // `tabs` parameter shadows the method here.
        activeTabByMode = active.reduce(into: [:]) { result, entry in
            result[entry.key] = min(max(entry.value, 0), self.tabs(in: entry.key).count - 1)
        }
        applyNavigationChange(from: old)
    }

    /// Forgets where every mode was — called when the book closes, so one
    /// book's desk does not open on top of the next one's.
    func resetNavigation() {
        let old = storedSelection(in: currentMode)
        currentMode = .dashboard
        tabsByMode = [:]
        activeTabByMode = [:]
        applyNavigationChange(from: old)
    }

    /// The tail every navigation shares: the register follows the selection, and
    /// where you are is remembered.
    private func applyNavigationChange(from old: SidebarSelection) {
        let oldAccount = Self.accountID(of: old)
        let newAccount = Self.accountID(of: sidebarSelection)
        if oldAccount != newAccount {
            // GnuCash's Save Sort Order / Save Filter, without the button:
            // leaving a register remembers how it was arranged, returning
            // restores it. Held outside the book, as GnuCash holds it in its
            // state file — sorting a register is not an edit, and must not
            // mark the document dirty or show up in an export.
            persistRegisterViewState(for: oldAccount)
            // Only an account destination needs its register built. Leaving
            // for Overview or Reports keeps the rows — nothing shows them
            // there — so coming back to the same account finds them, and the
            // view-state restore below is applied under one suspended refresh
            // rather than one rebuild per setter (Performance Review 2, R7).
            if newAccount != nil {
                isRestoringRegisterView = true
                restoreRegisterViewState(for: newAccount)
                isRestoringRegisterView = false
                refreshRegister()
            }
        }
        if case .generalLedger = sidebarSelection, old != sidebarSelection {
            // All Transactions is a register destination too: it opens in the
            // default arrangement — never under the last account's sort or
            // filter — and reads an empty `registerRows`, so the account's
            // rows must go, whichever way here was taken (through Overview
            // included).
            isRestoringRegisterView = true
            resetRegisterView()
            isRestoringRegisterView = false
            refreshRegister()
        }
        persistSessionSelection()
    }

    private static func accountID(of selection: SidebarSelection?) -> GncGUID? {
        if case .account(let id) = selection { return id }
        return nil
    }

    /// The selected account, if the sidebar is on an account. Setting it is
    /// navigation to that account; clearing it lands on the Accounts mode's own
    /// home (All Transactions) rather than jumping to Overview, which would be a
    /// mode switch nobody asked for.
    public var selectedAccountID: GncGUID? {
        get { Self.accountID(of: sidebarSelection) }
        set { navigate(to: newValue.map(SidebarSelection.account) ?? .generalLedger) }
    }

    /// What the sidebar's `+` asked for, or `nil`. The detail view that owns
    /// the editor consumes it and clears it — the same pattern as
    /// ``bankImportRequested``, because the sheet belongs to the view, not to
    /// the list that asked.
    public var sidebarCreateRequest: SidebarCreation?

    /// Navigates to where the new thing will appear, then asks for it.
    public func requestCreate(_ creation: SidebarCreation) {
        if let destination = creation.destination { navigate(to: destination) }
        // Accounts has a panel of its own already; everything else is a sheet
        // owned by the detail view.
        // Two that already own a panel. A security is **not** an account —
        // several accounts can hold the same security, in different portfolios
        // — so it gets its own sheet rather than being folded into the account
        // editor, which is how "add a security" came to mean "add an account"
        // and left no way to do the first without the second.
        if creation == .account {
            presentedPanel = .newAccount
        } else if creation == .security {
            presentedPanel = .newSecurity
        } else {
            sidebarCreateRequest = creation
        }
    }

    /// Bumped by New Transaction (⌘N) while a register is showing; the entry
    /// bar focuses its description field in response (RD4: entry without
    /// ceremony). When no register is on screen the full editor opens instead.
    public private(set) var entryBarFocusRequest = 0

    public func requestQuickEntry() {
        if selectedAccountID != nil, !registerIncludesSubaccounts {
            entryBarFocusRequest &+= 1
        } else {
            presentedPanel = .newTransaction
        }
    }

    /// Navigates the sidebar to `selection` (closing any open modal panel and
    /// leaving search) — how menu-bar and toolbar commands open an app area now
    /// that these are inline destinations rather than sheets.
    public func show(_ selection: SidebarSelection) {
        presentedPanel = nil
        searchQuery = ""
        sidebarSelection = selection
    }

    /// The security a `.security` selection names, or `nil` if the book no
    /// longer holds it. Resolved through the same composite key the sidebar and
    /// ``securityCommodities`` both use, so the three agree on identity.
    public func securityCommodity(forKey key: String) -> Commodity? {
        if securityIndexRevision != bookRevision {
            securityIndexCache = [:]
            for commodity in securityCommodities + watchlist {
                securityIndexCache[SidebarSelection.securityKey(commodity)] = commodity
            }
            securityIndexRevision = bookRevision
        }
        return securityIndexCache[key]
    }

    /// Switches mode without disturbing where that mode was — the toolbar
    /// control and the View menu's ⌘1…⌘7 (`FR-NAV-02`, `FR-NAV-03`).
    public func showMode(_ target: AppMode) {
        presentedPanel = nil
        searchQuery = ""
        mode = target
    }

    /// Display order of the register (`FR-REG-01`).
    public var registerSort: RegisterSort = .standard {
        didSet { if oldValue != registerSort, !isRestoringRegisterView { refreshRegister() } }
    }
    /// Reverses ``registerSort``.
    public var registerSortReversed = false {
        didSet { if oldValue != registerSortReversed, !isRestoringRegisterView { refreshRegister() } }
    }
    /// Which rows the register shows (`FR-REG-01`).
    public var registerFilter: RegisterFilter = .showAll {
        didSet { if oldValue != registerFilter, !isRestoringRegisterView { refreshRegister() } }
    }
    /// GnuCash's Open Subaccounts: show the selected account's whole subtree in
    /// one register, not just its own postings (`FR-ACC-03`).
    public var registerIncludesSubaccounts = false {
        didSet { if oldValue != registerIncludesSubaccounts, !isRestoringRegisterView { refreshRegister() } }
    }

    /// Suspends the view-state setters' own refreshes while a saved register
    /// arrangement is applied field by field; the caller refreshes once after.
    @ObservationIgnored var isRestoringRegisterView = false

    /// What the current `registerRows` were built from. A rebuild asked for
    /// the same inputs — returning to an account whose rows are still there,
    /// a view-state restore that changed nothing — is skipped.
    struct RegisterBuildKey: Equatable {
        let account: GncGUID
        let revision: Int
        let sort: RegisterSort
        let reversed: Bool
        let filter: RegisterFilter
        let subaccounts: Bool
        /// The summary's present/future split is taken at build time, so a
        /// build from yesterday is not the same build today.
        let day: Date
    }
    @ObservationIgnored private var lastRegisterBuildKey: RegisterBuildKey?
    /// The first register row of each transaction in `registerRows`.
    @ObservationIgnored var registerSplitByTransaction: [GncGUID: GncGUID] = [:]

    /// Resets the register's view options — called when the book closes, so a
    /// filter set on one book can't quietly hide rows in the next.
    func resetRegisterView() {
        registerSort = .standard
        registerSortReversed = false
        registerFilter = .showAll
        registerIncludesSubaccounts = false
    }

    // MARK: Per-account register view state

    /// What a register remembers about how it was shown. A value in
    /// `UserDefaults`, not the book: GnuCash keeps the same facts in its state
    /// file for the same reason — how you looked at an account is not part of
    /// what the account is.
    private struct RegisterViewState: Codable {
        var sort: String
        var reversed: Bool
        var statuses: [String]
        var startDate: Date?
        var endDate: Date?
        var subaccounts: Bool
    }

    static func registerViewKey(_ id: GncGUID) -> String {
        "registerView.\(id.hexString)"
    }

    private func persistRegisterViewState(for accountID: GncGUID?) {
        guard let accountID else { return }
        let key = Self.registerViewKey(accountID)
        // The default arrangement is not worth an entry — and removing one
        // means "forget it", so a reset register stays reset.
        let isDefault = registerSort == .standard && !registerSortReversed
            && registerFilter.isShowingEverything && !registerIncludesSubaccounts
        if isDefault {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        let state = RegisterViewState(
            sort: registerSort.rawValue,
            reversed: registerSortReversed,
            statuses: registerFilter.statuses.map(\.rawValue).sorted(),
            startDate: registerFilter.startDate,
            endDate: registerFilter.endDate,
            subaccounts: registerIncludesSubaccounts)
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: key)
    }

    private func restoreRegisterViewState(for accountID: GncGUID?) {
        guard let accountID,
              let data = UserDefaults.standard.data(forKey: Self.registerViewKey(accountID)),
              let state = try? JSONDecoder().decode(RegisterViewState.self, from: data)
        else {
            resetRegisterView()
            return
        }
        registerSort = RegisterSort(rawValue: state.sort) ?? .standard
        registerSortReversed = state.reversed
        registerFilter = RegisterFilter(
            statuses: Set(state.statuses.compactMap(ReconcileState.init(rawValue:))),
            startDate: state.startDate,
            endDate: state.endDate)
        registerIncludesSubaccounts = state.subaccounts
    }

    /// A register row to select and scroll to the next time a register shows —
    /// set by ``showInRegister(_:)`` when jumping to a transaction from a search
    /// result. One-shot: the register consumes it, because it names a specific
    /// split and must not re-apply to a later, unrelated register.
    public internal(set) var pendingRegisterSplitID: GncGUID?

    /// Takes the pending selection, if any, clearing it.
    func consumePendingRegisterSelection() -> GncGUID? {
        defer { pendingRegisterSplitID = nil }
        return pendingRegisterSplitID
    }

    /// GnuCash's Go to Date (`FR-REG-08`): select the first row posted on or
    /// after `date`, so the register lands where that day begins.
    ///
    /// On or *after*, not on: most dates in a year have no posting, and a jump
    /// that only worked when you named a day something happened would be a jump
    /// you could not use to look around. Answers against the rows as displayed,
    /// so a filtered-out row is not somewhere the register can land — it isn't
    /// there to land on.
    ///
    /// Returns whether it found one; nothing after the last posting is a
    /// question with no answer rather than a reason to jump to the end.
    @discardableResult
    public func goToDate(_ date: Date) -> Bool {
        let day = Calendar.current.startOfDay(for: date)
        // The rows carry the display order, which the sort may have reversed or
        // ordered by amount — "the first one on or after" means the earliest by
        // date, whatever order they happen to be shown in.
        guard let target = registerRows
            .filter({ Calendar.current.startOfDay(for: $0.date) >= day })
            .min(by: { $0.date < $1.date })
        else { return false }
        pendingRegisterSplitID = target.id
        return true
    }

    /// Free-text query; setting it recomputes ``searchResults`` after a short
    /// debounce — `.searchable` writes per keystroke, and the synchronous
    /// full-book scan made typing pay a whole-book walk per character on the
    /// main actor. Clearing is immediate. Programmatic callers (and tests) can
    /// call ``runSearch()`` directly for a synchronous result.
    public var searchQuery: String = "" {
        didSet { scheduleSearch() }
    }
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?

    /// What the search bar or Find matched: the transactions themselves, in
    /// book order. The results are shown as a register over them — GnuCash's
    /// search ledger (``searchLedgerTransactions()``) — and made into rows
    /// (``searchResults``) only when something asks for rows.
    @ObservationIgnored var searchMatches: [Transaction] = []
    /// Moves whenever ``searchMatches`` does. The search ledger and the result
    /// rows are kept per revision, and the views that show them read it.
    public private(set) var searchRevision = 0
    /// Rows made of the matches, for the revision they were made at.
    @ObservationIgnored var searchResultsCache: (search: Int, transactions: Int, rows: [TransactionSummary])?
    /// The search ledger, for the settings and revisions it was cut at.
    @ObservationIgnored var searchLedgerCache: (key: SearchLedgerKey, transactions: [Transaction])?
    /// The search ledger's summary bar, for the same key.
    @ObservationIgnored var searchSummaryMemo: (key: SearchLedgerKey, value: (count: Int, debits: Decimal))?
    /// All Transactions' summary bar, per transaction revision and filter.
    @ObservationIgnored var wholeBookSummaryMemo: (key: WholeBookSummaryKey, value: (count: Int, debits: Decimal))?
    struct WholeBookSummaryKey: Equatable {
        var revision: Int
        var filter: RegisterFilter
    }
    /// The folded text the search bar scans, for the book as it stands.
    @ObservationIgnored var searchTextIndex: (revision: Int, index: SearchTextIndex)?
    /// The last query's plain words and what they matched — so a query that
    /// only lengthens them looks among those, not the whole book again.
    @ObservationIgnored var lastWordSearch: (revision: Int, words: [String], positions: [Int])?

    /// Drops everything the search kept for the book that is going: its
    /// folded text, the last words' matches, the ledger and its summary, and
    /// the rows — and the whole-book summary. Close, Revert and Reload all
    /// replace the book; the next book's revisions start where these left
    /// off, so a cache keyed on them alone could answer for the wrong book,
    /// and each holds the old book's transactions alive meanwhile.
    func forgetSearchCaches() {
        searchTextIndex = nil
        lastWordSearch = nil
        searchLedgerCache = nil
        searchResultsCache = nil
        searchSummaryMemo = nil
        wholeBookSummaryMemo = nil
        #if os(macOS)
        RegisterSheet.forgetKeptRows()
        #endif
    }

    /// Replaces the matches — leaving the revision where it was when they are
    /// the same transactions, as after an edit that moved none in or out, so
    /// nothing redraws for a search that did not change.
    func setSearchMatches(_ matches: [Transaction]) {
        if matches.count == searchMatches.count,
           zip(matches, searchMatches).allSatisfy({ $0 === $1 }) { return }
        searchMatches = matches
        searchRevision &+= 1
    }

    /// What the search ledger was cut from: the matches and the book.
    struct SearchLedgerKey: Equatable {
        var search: Int
        var transactions: Int
    }

    private func scheduleSearch() {
        searchDebounceTask?.cancel()
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            runSearch()   // instant clear
            return
        }
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.runSearch()
        }
    }

    /// The active structured query (Find, ⌘F), or `nil` when the free-text bar
    /// is the search. The two are alternatives: running one clears the other.
    public internal(set) var findQuery: FindQuery?

    /// For each transaction in ``searchResults`` found by a structured Find, the
    /// split that actually matched. A free-text search leaves this empty.
    ///
    /// Worth keeping: it is the difference between guessing which register a
    /// result belongs in and knowing. The user asked for *that* split.
    @ObservationIgnored var findMatchedSplitID: [GncGUID: GncGUID] = [:]

    /// Every split the current find matched — the working set that GnuCash's
    /// "Type of search" modes (refine/add/delete) compose over. The rolled-up
    /// map above keeps one split per transaction for display; this keeps them
    /// all, or refining would test only the first hit of each transaction.
    @ObservationIgnored var findSplitIDs: Set<GncGUID> = []

    /// One step of the search that built the current results.
    struct FindStep {
        var query: FindQuery
        var mode: FindMode
    }

    /// The whole search as the user assembled it, replayed against the live
    /// book on every refresh — see ``recomputeFindResults()`` for why neither
    /// a frozen set nor the last query alone can be right.
    @ObservationIgnored var findPipeline: [FindStep] = []

    /// True while a query is present — including one that matched nothing, which
    /// is why this is not `!searchResults.isEmpty`: a search that found no rows
    /// still has to say so rather than drop the user back on the dashboard.
    public var isSearching: Bool {
        findQuery != nil || !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Things the query did that the user did not ask for, in their words.
    /// Populated by ``runSearch``; see ``SearchNotice``.
    public internal(set) var searchNotices: [SearchNotice] = []

    /// The active reconciliation session, or `nil` when not reconciling.
    public internal(set) var reconcileSession: ReconcileSessionState?

    // Book-KVP-backed collections, held as observed stored properties so views
    // update when they change (the underlying `book.kvp` is not observable).
    // Loaded from the book on open and persisted back on mutation.
    public internal(set) var ruleGroups: [RuleGroup] = []
    public internal(set) var scheduledTransactions: [ScheduledTransaction] = []
    public internal(set) var budgets: [Budget] = []
    public internal(set) var savedSearches: [SavedSearch] = []
    /// Saved structured Find queries (GnuCash has none; a query someone took
    /// six criteria to build is a query they will want back).
    public internal(set) var savedFindQueries: [SavedFindQuery] = []
    /// Saved report configurations — favourites (`FR-RPT-04`).
    public internal(set) var savedReports: [SavedReport] = []
    /// Book-scoped report preferences: FY start month, default period.
    public internal(set) var reportSettings = ReportSettings()

    /// Book-scoped company details for business documents (`FR-BUS`): the name,
    /// contact, and address that head printed invoices and statements.
    public internal(set) var companyInfo = CompanyInfo()

    /// Securities tracked but not held (watch list, `FR-PLAN-07`).
    public internal(set) var watchlist: [Commodity] = []

    /// Accounts pinned to the sidebar's Favourites section, in the order they
    /// were favourited. Book-KVP-backed, so favourites travel with the file
    /// (they are how the user works with *this* book, like watch lists — not
    /// desk state).
    public internal(set) var favouriteAccountIDs: [GncGUID] = []

    /// User-set price targets that raise alerts (`FR-PLAN-05`).
    public internal(set) var priceTargets: [PriceTarget] = []

    /// Savings goals ("piggy banks") earmarking parts of asset accounts
    /// (`FR-GOAL-01`).
    public internal(set) var savingsGoals: [SavingsGoal] = []
    /// P9 planning state (docs/planning-design.md), all book-KVP-backed.
    public internal(set) var debtPlanSettings = DebtPlanSettings()
    public internal(set) var lifetimePlan = StoredLifetimePlan()
    public internal(set) var taxSettings: TaxEstimate.Settings?
    public internal(set) var savingsChallenges: [SavingsChallenge] = []
    public internal(set) var emergencyRecords: [EmergencyRecord] = []

    /// Billable time and mileage awaiting or placed on invoices (`FR-PLAN-14`).
    public internal(set) var billableEntries: [BillableEntry] = []

    /// Per-security ticker overrides for quote lookups, keyed by
    /// `"namespace|mnemonic"` (e.g. maps `CBA` → `CBA.AX` for Yahoo).
    public internal(set) var quoteSymbols: [String: String] = [:]

    /// Per-security expected revaluation cadence for hand-valued securities,
    /// keyed by `"namespace|mnemonic"` (`FR-INV-30`). Without one, every
    /// hand-valued holding reads as permanently overdue.
    public internal(set) var valuationCadences: [String: String] = [:]

    /// Per-security provider choice, keyed by `"namespace|mnemonic"` and
    /// holding a ``QuoteProviderKind`` raw value (`FR-INV-22`).
    ///
    /// One provider for the whole book stopped being enough when bonds
    /// arrived: a corporate bond is priced by FIIG against its ISIN and by
    /// nobody else, while every share in the same book wants Yahoo. Sending
    /// one run to one provider would fail whichever half it was not for.
    public internal(set) var quoteProviders: [String: String] = [:]

    /// Securities that have stopped trading, keyed by `"namespace|mnemonic"`
    /// (`FR-INV-37`). Their last price is final, so they are not fetched and
    /// never appear on the worklist — see ``isDelisted(_:)``.
    public internal(set) var delistedSecurities: [String] = []

    /// Securities **nobody publishes a price for**, keyed by
    /// `"namespace|mnemonic"` (`FR-INV-40`).
    ///
    /// Deliberately not ``delistedSecurities``, though both stop the fetching.
    /// A retail superannuation or managed-fund unit is very much still
    /// trading and its unit price moves every week — there is simply no public
    /// feed for it, so it is valued from a statement by hand. Calling that
    /// "no longer trading" would be false, would freeze its last price as
    /// final, and would take it out of the valuation-confidence figures it
    /// belongs in.
    ///
    /// Recorded, never inferred, for the same reason delisting is: a fund that
    /// has not been priced for a month and one that never will be look
    /// identical from the price data.
    public internal(set) var unquotedSecurities: [String] = []

    /// Progress/result of the most recent quote fetch, for the UI.
    public internal(set) var quoteStatus: QuoteFetchStatus = .idle

    /// The app-wide toast (redesign 6.8): one overlay, every long operation
    /// routes its completion here. Transient — replaced by the next message,
    /// dismissed automatically.
    public struct StatusToast: Equatable, Sendable {
        public enum Kind: Sendable { case success, failure, info }
        public var kind: Kind
        public var message: String
    }
    public private(set) var toast: StatusToast?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    /// Shows `message` in the status overlay for a few seconds. Failures live
    /// a little longer — they carry the words worth reading.
    public func showToast(_ kind: StatusToast.Kind, _ message: LocalizedStringResource) {
        showToast(kind, verbatim: String(localized: message))
    }

    /// A toast whose words are already the reader's — a name, an error's own
    /// description. The other form takes what the app says itself, as a
    /// literal the compiler can emit a key for: taking a `String` there, every
    /// toast was English in every language and nothing could tell.
    public func showToast(_ kind: StatusToast.Kind, verbatim message: String) {
        toastDismissTask?.cancel()
        toast = StatusToast(kind: kind, message: message)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .failure ? 8 : 4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Fraction complete (0…1) of a running multi-security fetch, or `nil` when
    /// no determinate-progress fetch is in flight. Drives the Quotes progress bar.
    public internal(set) var quoteProgress: Double?

    /// Cost-basis method used by the capital-gains / lots reports.
    public var costBasisMethod: CostBasisMethod = .fifo
    /// How brokerage fees affect cost basis in the investment reports. Defaults
    /// to ignoring them (matching GnuCash's "ignore" mode to the cent on the
    /// reference book); switch to include-in-basis to match GnuCash's default.
    public var feeTreatment: FeeTreatment = .ignore

    /// Hypothetical events layered onto the cash-flow forecast (session-only).
    public internal(set) var whatIfEvents: [WhatIfEvent] = []

    /// The tool panel currently presented **as a sheet**. Views bind a sheet to
    /// this; menu commands and toolbar buttons set it, so every panel is
    /// reachable from the menu bar as well as the toolbar.
    ///
    /// Setting it to an **editor** opens a tab instead
    /// (`RootPanel/opensAsTab`) — every call site keeps the one spelling it
    /// always had, and the decision lives in one place rather than at each of
    /// the thirty-odd buttons and menu items that open one.
    /// Whether the compact shell is what is on screen. Two things follow.
    ///
    /// **One destination per mode.** The regular shell's strip holds as many
    /// tabs as are opened; a stack under a tab bar has no strip, so there a
    /// navigation *replaces* the one tab the compact shell opened in that mode
    /// (`openCompactTab`) instead of adding another — a phone session cannot
    /// pile up tabs nobody can see or close, and tabs an iPad had open before
    /// its window was narrowed are left as they were.
    ///
    /// **Panels are sheets.** A panel that is a tab in the regular shell — an
    /// editor one can wander away from and come back to — has no strip to
    /// come back through, so it presents modally; and one asked for from
    /// inside another (New Security… from New Account) goes on top of it
    /// (``nestedPanel``) rather than replacing it and what was typed.
    public var compactNavigation = false {
        didSet {
            guard !compactNavigation else { return }
            compactTabByMode = [:]
            nestedPanel = nil
        }
    }

    /// The tab the compact shell opened in each mode — one at most.
    private var compactTabByMode: [AppMode: SidebarSelection] = [:]

    /// A panel presented over ``presentedPanel`` in the compact shell.
    public var nestedPanel: RootPanel?

    /// What `mode` would show if it were brought forward.
    public func selection(in mode: AppMode) -> SidebarSelection {
        storedSelection(in: mode)
    }

    public var presentedPanel: RootPanel? {
        get { modalPanel }
        set {
            guard let panel = newValue else {
                modalPanel = nil
                nestedPanel = nil
                return
            }
            if panel.opensAsTab, !compactNavigation {
                modalPanel = nil
                navigate(to: .panel(panel), inNewTab: true)
            } else if compactNavigation, panel.opensAsTab, let open = modalPanel, open != panel {
                nestedPanel = panel
            } else {
                modalPanel = panel
            }
        }
    }

    /// The sheet-presented panel, which is what the `.sheet(item:)` binds to.
    /// Private storage so nothing can bypass the tab/sheet decision above.
    private var modalPanel: RootPanel?

    /// A report to open immediately when the Reports panel appears — set by a
    /// menu item that jumps straight to one report (e.g. the aging reports).
    var pendingReportKind: ReportKind?

    /// Set by Reports ▸ Financial Year Pack…; the gallery opens the pack
    /// sheet and clears it.
    public var financialYearPackRequested = false

    /// Set by Reports ▸ Financial Review…; the gallery opens the deck.
    public var financialReviewRequested = false

    /// Set by Reports ▸ Investment Review…; the gallery opens that deck.
    public var investmentReviewRequested = false
    /// Reports ▸ Financial Summary (the passport) — handled by ReportsHome.
    public var passportRequested = false

    /// Menu-bar jump straight to one report: lands on the Reports destination
    /// with the report already open (6.7).
    public func openReport(_ kind: ReportKind) {
        pendingReportKind = kind
        show(.reports)
    }

    /// Opens the Reports panel straight onto the receivable-aging report.
    public func openReceivableAging() {
        pendingReportKind = .receivableAging; show(.reports)
    }
    /// Opens the Reports panel straight onto the payable-aging report.
    public func openPayableAging() {
        pendingReportKind = .payableAging; show(.reports)
    }

    /// The register row the user has selected.
    ///
    /// Held here rather than in the register's own `@State` so that the menu
    /// bar can act on the same row the context menu does. Every per-transaction
    /// operation used to be context-menu-only: no menu items, no shortcuts, and
    /// nothing at all in the Journal and General Ledger styles, which offered
    /// Edit and nothing else.
    public var selectedSplitID: GncGUID? { selectedSplitIDs.first }

    /// Every selected register row (split GUIDs). ``selectedSplitID`` derives
    /// from this set — it was a stored copy every writer had to assign in
    /// lockstep, the exact stored-copy-that-can-drift pattern. This full set
    /// lets commands like Auto-Categorise act on a multi-row selection.
    /// Set by the View ▸ Filter Transactions… menu command; the register
    /// consumes it and opens its filter sheet. HIG *Toolbars* (macOS) requires
    /// every toolbar item to also be a menu-bar command, and the filter button
    /// had no menu equivalent.
    public var registerFilterRequested = false

    public var selectedSplitIDs: Set<GncGUID> = []

    /// The transactions the current register selection belongs to.
    public var selectedTransactionIDs: Set<GncGUID> {
        Set(selectedSplitIDs.compactMap { transactionID(ofSplit: $0) })
    }

    /// The transaction whose editor should be open, if any. Set by the register
    /// or by a menu command; the register presents the sheet.
    public var editingTransactionID: GncGUID?

    /// The transaction being turned into a schedule, if any. Same arrangement as
    /// ``editingTransactionID``: the command sets it, the register shows it.
    public var schedulingTransactionID: GncGUID?

    /// Whether the detail pane is showing Reports (docs/reports.md). Inline,
    /// like the dashboard — the detached window is the explicit alternative.
    /// Sidebar navigation clears it: selecting an account always answers
    /// "show me this account".
    /// Backwards-compatible shim over ``sidebarSelection``: the Reports area is
    /// now a sidebar destination rather than a flag.
    public var isShowingReports: Bool {
        get { sidebarSelection == .reports }
        set {
            if newValue { sidebarSelection = .reports }
            else if sidebarSelection == .reports { sidebarSelection = .dashboard }
        }
    }

    /// The transaction the selected row belongs to — what a menu command acts on.
    public var selectedTransactionID: GncGUID? {
        selectedSplitID.flatMap { transactionID(ofSplit: $0) }
    }

    /// Whether there is a register row to act on. Menu items are disabled rather
    /// than hidden, so the shortcuts are discoverable before you select a row.
    public var hasSelectedTransaction: Bool { selectedTransactionID != nil }

    /// Books opened recently (most recent first), for Open Recent / welcome.
    public internal(set) var recentBooks: [URL] = AppModel.loadRecents()

    /// Set by menu commands to trigger the bank-file importer in the root view.
    public var bankImportRequested = false
    /// Set by menu commands to trigger the GnuCash XML exporter in the root view.
    public var exportRequested = false
    /// File ▸ Export Ledger Journal… (`FR-XIO-10`).
    public var ledgerExportRequested = false
    /// Set by menu commands to trigger a CSV export (`FR-XIO-06`); the root view
    /// renders it and presents the save panel.
    public var csvExportRequest: CSVExportKind?
    /// Set by menu commands to trigger the Smart Import multi-PDF picker.
    public var smartImportRequested = false
    /// Set by the Transaction menu to attach a file to this transaction
    /// (`FR-REG-10`); the root view presents a file picker.
    public var attachDocumentRequestTxnID: GncGUID?
    /// Set by the Transaction menu to print a check for this transaction
    /// (`FR-REG-11`); the root view presents the check preview + PDF save.
    public var printCheckRequestTxnID: GncGUID?
    /// Set by the Help menu to present the in-app help / shortcut reference.
    public var showingHelp = false
    /// iPhone and iPad: the settings sheet. The Mac has a Settings window,
    /// which the system presents.
    public var showingSettings = false

    // MARK: Box (see AppModel+Box.swift)

    /// Where Box books are kept here, and each one's record. A property so a
    /// test can point it at a folder of its own; changing it reads that
    /// folder's records.
    @ObservationIgnored var boxLibrary = BoxLibrary.standard {
        didSet { reloadBoxLinks() }
    }
    /// What the records on disk said when last read, for views to show. Any
    /// decision that matters reads the record from disk again.
    public internal(set) var boxLinks: [String: BoxBookLink] = [:]
    /// Work going to or from Box now, by book: uploads, and Keep Both. The
    /// status chip shows it, and quitting waits for it.
    public internal(set) var boxWorkTasks: [String: Task<Void, Never>] = [:]
    /// Books whose conflict is being resolved: not opened meanwhile.
    public internal(set) var boxResolving: Set<String> = []
    /// A Box book whose changes wait on the person's decision (the alert).
    public var boxConflict: BoxConflict?
    /// File ▸ Open from Box… — the root view presents the browser.
    public var boxBrowserRequested = false
    /// Where opening a Box book has got to, for the opening screen.
    public internal(set) var boxOpenPhase: BoxOpenPhase?
    /// Why the Box client secret could not be kept in the Keychain, for
    /// Settings to say — until then it lasts only as long as the app runs.
    public internal(set) var boxSecretFailure: String?
    /// Bumped when the Box sign-in or the Box app's settings change, so
    /// views that show them look again (the Keychain is not observable).
    public internal(set) var boxSessionRevision = 0
    /// True while quitting waits for Box work to finish (the Mac).
    public internal(set) var isFinishingBoxWorkBeforeQuit = false
    @ObservationIgnored var boxRetryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var boxRetryAttempts: [String: Int] = [:]
    /// Books whose failed upload has been reported since the last one that
    /// worked — a retry that fails again says nothing new; ⌘S says it again.
    @ObservationIgnored var boxUploadFailuresReported: Set<String> = []
    /// Books an explicit save asked to hear about while an upload of them was
    /// already running — told when that one finishes, rather than not at all.
    @ObservationIgnored var boxAnnounceRequested: Set<String> = []
    /// Who is signed in to Box, asked once per sign-in (``boxAccount()``).
    @ObservationIgnored var boxAccountCache: BoxUser?
    /// Stopping the wait while a book from Box opens: set by Cancel on the
    /// opening screen, and the work it stops.
    @ObservationIgnored var boxOpenCancelled = false
    @ObservationIgnored var boxOpenCancel: (() -> Void)?
    @ObservationIgnored var boxPathMonitor: NWPathMonitor?
    @ObservationIgnored var boxQuitGate: BoxWaitGate?
    /// Above this size a book goes up in parts (Box's chunked upload API
    /// takes files from 20 MB; its direct upload, files up to 50 MB).
    @ObservationIgnored var boxChunkThreshold: Int64 = 20 * 1024 * 1024
    @ObservationIgnored var boxTransport: BoxTransport = URLSessionBoxTransport()
    @ObservationIgnored var boxTokenStore: BoxTokenStoring = KeychainBoxTokenStore() {
        didSet { boxSignedInCache = nil; boxAuthenticatorCache = nil; boxAccountCache = nil }
    }
    @ObservationIgnored var boxSecretStore: BoxClientSecretStoring = BoxClientSecretStore() {
        didSet { boxSecretCache = nil; boxAuthenticatorCache = nil }
    }
    @ObservationIgnored var boxDefaults: UserDefaults = .standard
    @ObservationIgnored var boxSecretCache: String?
    @ObservationIgnored var boxSignedInCache: Bool?
    @ObservationIgnored var boxAuthenticatorCache: (configuration: BoxAppConfiguration,
                                                    authenticator: BoxAuthenticator)?
    /// Callers waiting for a save in progress to finish — leaving the app on
    /// iOS waits for one before it saves again.
    @ObservationIgnored var saveWaiters: [CheckedContinuation<Void, Never>] = []

    /// A user-facing document error (open/new/import failed). When
    /// ``DocumentError/lockedURL`` is set the UI offers "Break Lock" recovery;
    /// when ``DocumentError/gnuCashImportURL`` is set it offers "Import…" —
    /// the user tried to *open* a GnuCash book, which only imports.
    public struct DocumentError: Identifiable, Sendable {
        public let id = UUID()
        public var message: String
        public var lockedURL: URL?
        public var gnuCashImportURL: URL?
        /// Set alongside `lockedURL` when it names a GnuCash-import
        /// *destination* rather than a book to open directly — recovery
        /// re-imports this source into it with the lock broken, instead of
        /// opening `lockedURL`.
        public var lockedImportSource: URL?
    }
    /// The most recent document-operation failure, surfaced as an alert.
    public var documentError: DocumentError?
    /// A user-facing confirmation (e.g. GnuCash import summary).
    public var infoMessage: String?
    /// Check & Repair findings awaiting the user's decision (sheet).
    public var pendingCleanup: CleanupProposal?

    /// API-key store (Keychain in production; injectable for tests/previews).
    let apiKeys: APIKeyStoring
    /// HTTP transport for quote providers (injectable for tests).
    let quoteHTTP: HTTPFetching
    /// Device authentication for the book lock (injectable for tests).
    let authenticator: Authenticating

    /// The sidecar for fetched company data (`FR-INV-35`). **Never the book** —
    /// prices stay the only fetched thing stored there, so the double-entry and
    /// round-trip invariants are untouched by the whole fundamentals feature.
    let fundamentalsCache: FundamentalsCache

    /// The Yahoo session token, shared across a run: `quoteSummary` needs a
    /// cookie-plus-crumb handshake, and doing it per security would be two
    /// pointless round trips per holding.
    @ObservationIgnored let yahooCrumbs = YahooCrumbStore()

    /// Per-security fetch state for the detail page's company sections.
    var fundamentalsStatus: [String: FundamentalsStatus] = [:]
    /// A bulk company-data run in progress, or `nil`. Drives the Investments
    /// progress strip the same way `quoteProgress` drives the price one.
    public var fundamentalsRun: FundamentalsRun?

    /// The **mode row's** current width, measured by `ModeBar` itself.
    ///
    /// It was `windowWidth`, measured on the whole split view, back when the
    /// modes were toolbar items spanning the window. They are not: `ModeBar` is
    /// a safe-area inset on the *detail* column, so the sidebar's 200–400pt was
    /// being counted as room the modes could use. Measured where it is drawn,
    /// and named after what it measures.
    public var modeRowWidth: CGFloat = 0

    /// Whether all seven modes can show their names on their own row.
    ///
    /// Measured over **every** mode now, not the toolbar-visible subset: the
    /// modes have a row to themselves, so all seven are always drawn and there
    /// is no customisation that could remove one. `ModeBar` no longer degrades
    /// to symbols at any width the window can take — 452pt of labels against an
    /// 860pt minimum — but the measurement stays, because a longer language or
    /// a larger accessibility text size can still outgrow the row, and this is
    /// what a future `ModeBar` would ask. Kept honest for that day: a retained
    /// measurement that measures the wrong thing is worse than none, because
    /// whoever picks it up will believe it.
    public var modeLabelsFit: Bool {
        ModeLabelFit.labelsFit(ModeBar.modes, in: modeRowWidth)
    }

    /// Bumped when the sidecar changes. The cache is a file, not an observed
    /// object, so without this a freshly fetched profile would sit on disk
    /// while the page kept drawing the absence of one.
    @ObservationIgnored var fundamentalsMemo: [String: (revision: UInt64, record: SecurityFundamentals?)] = [:]
    public internal(set) var fundamentalsRevision: UInt64 = 0

    /// The running periodic quote-refresh loop, if any.
    /// Journal transactions, sorted, keyed by focus account (`nil` = general
    /// ledger). Deriving this per body pass meant sorting and filtering the
    /// whole book on every redraw. Not observed: it is a pure function of the
    /// book, and ``refreshAll()`` clears it alongside the observed collections
    /// that do drive the redraw.
    @ObservationIgnored var journalTransactionCache: [GncGUID?: [Transaction]] = [:]

    /// Built journal rows, keyed the same way and dropped at the same time.
    @ObservationIgnored var journalRowCache: [GncGUID?: [JournalRow]] = [:]
    /// Where each general-ledger transaction's rows begin in
    /// `journalRowCache[nil]`, in the order of `journalTransactionCache[nil]`
    /// — made on the first patch, kept by the patches after (P7).
    @ObservationIgnored var ledgerBlockStarts: [Int]?
    /// How long each kind of report last took to build, and over how much of
    /// the book (``warm(_:)``). They describe one book: ``close()`` empties it.
    @ObservationIgnored var reportBuildTimes: [String: ReportBuildTime] = [:]
    /// The register settings the journal caches were built under.
    @ObservationIgnored var journalSettings: JournalSettings?

    @ObservationIgnored var quoteRefreshTask: Task<Void, Never>?

    /// Refreshes the lock heartbeat while a book is open, so a live holder's
    /// lock never looks stale to another instance (Architecture §6.1).
    @ObservationIgnored var heartbeatTask: Task<Void, Never>?

    /// Periodically saves unsaved changes back to the shared file
    /// (Architecture §3/§6.2 autosave; failures surface via ``documentError``).
    @ObservationIgnored var autosaveTask: Task<Void, Never>?

    /// `true` when the open book is locked behind authentication (`NFR-07`).
    public internal(set) var isLocked = false

    /// `true` when the shared file changed externally (another device via
    /// iCloud) since we opened it (`FR-PLT-02`).
    public internal(set) var externalChangePending = false

    /// `true` when a document is open.
    public var isOpen: Bool { document != nil }
    /// The open document's file URL (window title / titlebar proxy icon).
    public var documentURL: URL? { document?.fileURL }
    /// `true` when there are unsaved changes.
    public var hasUnsavedChanges: Bool {
        _ = documentStateRevision   // the document's flag is not observable; this is
        return document?.hasUnsavedChanges ?? false
    }

    /// True when the open book was opened read-only (`FR-DAT-06`) — editing and
    /// saving are refused; the shared file is never touched.
    public var isReadOnly: Bool { document?.isReadOnly ?? false }

    var book: Book? { document?.book }

    public init(apiKeys: APIKeyStoring? = nil, quoteHTTP: HTTPFetching? = nil,
                authenticator: Authenticating? = nil,
                fundamentalsCache: FundamentalsCache? = nil) {
        self.apiKeys = apiKeys ?? KeychainAPIKeyStore()
        self.quoteHTTP = quoteHTTP ?? URLSessionHTTPClient()
        self.authenticator = authenticator ?? BiometricAuthenticator()
        self.fundamentalsCache = fundamentalsCache ?? .standard()
    }

    // MARK: KVP-backed collections

    private enum KvpKey {
        static let rules = "finvestlens/ruleGroups"
        static let scheduled = BookKvpKeys.scheduledTransactions
        static let budgets = BookKvpKeys.budgets
        static let quoteSymbols = "finvestlens/quoteSymbols"
        static let quoteProviders = "finvestlens/quoteProviders"
        static let valuationCadences = "finvestlens/valuationCadences"
        static let savedSearches = "finvestlens/savedSearches"
        static let savedFindQueries = "finvestlens/savedFindQueries"
        static let savedReports = "finvestlens/savedReports"
        static let reportSettings = "finvestlens/reportSettings"
        static let watchlist = "finvestlens/watchlist"
        static let favouriteAccounts = "finvestlens/favouriteAccounts"
        static let priceTargets = "finvestlens/priceTargets"
        static let delisted = "finvestlens/delistedSecurities"
        static let unquoted = "finvestlens/unquotedSecurities"
        static let companyInfo = "finvestlens/companyInfo"
        static let savingsGoals = "finvestlens/savingsGoals"
        static let billableEntries = "finvestlens/billableEntries"
        static let debtPlan = "finvestlens/debtPlan"
        static let lifetimePlan = "finvestlens/lifetimePlan"
        static let taxSettings = "finvestlens/taxSettings"
        static let savingsChallenges = "finvestlens/savingsChallenges"
        static let emergencyRecords = "finvestlens/emergencyRecords"
    }

    /// Loads the KVP-backed collections from the current book.
    func reloadKvpCollections() {
        guard let book else {
            ruleGroups = []; scheduledTransactions = []; budgets = []; quoteSymbols = [:]
            quoteProviders = [:]; valuationCadences = [:]
            savingsGoals = []; billableEntries = []; favouriteAccountIDs = []
            debtPlanSettings = DebtPlanSettings(); lifetimePlan = StoredLifetimePlan()
            taxSettings = nil; savingsChallenges = []; emergencyRecords = []
            return
        }
        ruleGroups = Self.decodeSlot([RuleGroup].self, book.kvp[KvpKey.rules]) ?? []
        scheduledTransactions = Self.decodeSlot([ScheduledTransaction].self, book.kvp[KvpKey.scheduled]) ?? []
        budgets = Self.decodeSlot([Budget].self, book.kvp[KvpKey.budgets]) ?? []
        quoteSymbols = Self.decodeSlot([String: String].self, book.kvp[KvpKey.quoteSymbols]) ?? [:]
        quoteProviders = Self.decodeSlot([String: String].self, book.kvp[KvpKey.quoteProviders]) ?? [:]
        valuationCadences = Self.decodeSlot([String: String].self, book.kvp[KvpKey.valuationCadences]) ?? [:]
        savedSearches = Self.decodeSlot([SavedSearch].self, book.kvp[KvpKey.savedSearches]) ?? []
        savedFindQueries = Self.decodeSlot([SavedFindQuery].self, book.kvp[KvpKey.savedFindQueries]) ?? []
        savedReports = Self.decodeSlot([SavedReport].self, book.kvp[KvpKey.savedReports]) ?? []
        reportSettings = Self.decodeSlot(ReportSettings.self, book.kvp[KvpKey.reportSettings]) ?? ReportSettings()
        watchlist = Self.decodeSlot([Commodity].self, book.kvp[KvpKey.watchlist]) ?? []
        delistedSecurities = Self.decodeSlot([String].self, book.kvp[KvpKey.delisted]) ?? []
        unquotedSecurities = Self.decodeSlot([String].self, book.kvp[KvpKey.unquoted]) ?? []
        favouriteAccountIDs = Self.decodeSlot([GncGUID].self, book.kvp[KvpKey.favouriteAccounts]) ?? []
        priceTargets = Self.decodeSlot([PriceTarget].self, book.kvp[KvpKey.priceTargets]) ?? []
        companyInfo = Self.decodeSlot(CompanyInfo.self, book.kvp[KvpKey.companyInfo]) ?? CompanyInfo()
        savingsGoals = Self.decodeSlot([SavingsGoal].self, book.kvp[KvpKey.savingsGoals]) ?? []
        billableEntries = Self.decodeSlot([BillableEntry].self, book.kvp[KvpKey.billableEntries]) ?? []
        debtPlanSettings = Self.decodeSlot(DebtPlanSettings.self, book.kvp[KvpKey.debtPlan]) ?? DebtPlanSettings()
        lifetimePlan = Self.decodeSlot(StoredLifetimePlan.self, book.kvp[KvpKey.lifetimePlan]) ?? StoredLifetimePlan()
        taxSettings = Self.decodeSlot(TaxEstimate.Settings.self, book.kvp[KvpKey.taxSettings])
        savingsChallenges = Self.decodeSlot([SavingsChallenge].self, book.kvp[KvpKey.savingsChallenges]) ?? []
        emergencyRecords = Self.decodeSlot([EmergencyRecord].self, book.kvp[KvpKey.emergencyRecords]) ?? []
    }

    /// Writes the KVP-backed collections into the current book's slots.
    func persistKvpCollections() {
        guard let book else { return }
        book.kvp[KvpKey.rules] = Self.encodeSlot(ruleGroups)
        book.kvp[KvpKey.scheduled] = Self.encodeSlot(scheduledTransactions)
        book.kvp[KvpKey.budgets] = Self.encodeSlot(budgets)
        book.kvp[KvpKey.quoteSymbols] = Self.encodeMap(quoteSymbols)
        book.kvp[KvpKey.quoteProviders] = Self.encodeMap(quoteProviders)
        book.kvp[KvpKey.valuationCadences] = Self.encodeMap(valuationCadences)
        book.kvp[KvpKey.savedSearches] = Self.encodeSlot(savedSearches)
        book.kvp[KvpKey.savedFindQueries] = Self.encodeSlot(savedFindQueries)
        book.kvp[KvpKey.savedReports] = Self.encodeSlot(savedReports)
        // Defaults write nothing: a book that never changed a report setting
        // carries no slot, so the defaults can improve without stale copies.
        book.kvp[KvpKey.reportSettings] =
            reportSettings == ReportSettings() ? nil : Self.encodeSingle(reportSettings)
        book.kvp[KvpKey.watchlist] = Self.encodeSlot(watchlist)
        book.kvp[KvpKey.favouriteAccounts] = Self.encodeSlot(favouriteAccountIDs)
        book.kvp[KvpKey.priceTargets] = Self.encodeSlot(priceTargets)
        book.kvp[KvpKey.delisted] = delistedSecurities.isEmpty
            ? nil : Self.encodeSlot(delistedSecurities)
        book.kvp[KvpKey.unquoted] = unquotedSecurities.isEmpty
            ? nil : Self.encodeSlot(unquotedSecurities)
        book.kvp[KvpKey.companyInfo] =
            companyInfo == CompanyInfo() ? nil : Self.encodeSingle(companyInfo)
        book.kvp[KvpKey.savingsGoals] = Self.encodeSlot(savingsGoals)
        book.kvp[KvpKey.billableEntries] = Self.encodeSlot(billableEntries)
        book.kvp[KvpKey.debtPlan] =
            debtPlanSettings == DebtPlanSettings() ? nil : Self.encodeSingle(debtPlanSettings)
        book.kvp[KvpKey.lifetimePlan] =
            lifetimePlan == StoredLifetimePlan() ? nil : Self.encodeSingle(lifetimePlan)
        book.kvp[KvpKey.taxSettings] = taxSettings.map { Self.encodeSingle($0) } ?? nil
        book.kvp[KvpKey.savingsChallenges] = Self.encodeSlot(savingsChallenges)
        book.kvp[KvpKey.emergencyRecords] = Self.encodeSlot(emergencyRecords)
    }

    // MARK: Favourite accounts

    /// Whether an account is pinned to the sidebar's Favourites section.
    public func isFavouriteAccount(_ id: GncGUID) -> Bool {
        favouriteAccountIDs.contains(id)
    }

    /// Pins an account to (or unpins it from) the sidebar's Favourites, as one
    /// undoable change persisted with the book.
    public func toggleFavouriteAccount(_ id: GncGUID) {
        if let index = favouriteAccountIDs.firstIndex(of: id) {
            favouriteAccountIDs.remove(at: index)
            commitKvpCollections(named: "Remove Favourite")
        } else {
            favouriteAccountIDs.append(id)
            commitKvpCollections(named: "Add Favourite")
        }
    }

    /// The favourite accounts as sidebar nodes (name, balance, colour), in the
    /// order they were favourited. An id whose account no longer exists simply
    /// doesn't appear — the slot keeps it, so undoing the account's deletion
    /// restores the favourite too.
    public var favouriteAccountNodes: [AccountNode] {
        guard !favouriteAccountIDs.isEmpty else { return [] }
        let wanted = Set(favouriteAccountIDs)
        var found: [GncGUID: AccountNode] = [:]
        var stack = accountTree
        while let node = stack.popLast() {
            if wanted.contains(node.id) { found[node.id] = node }
            if found.count == wanted.count { break }
            if let children = node.children { stack.append(contentsOf: children) }
        }
        return favouriteAccountIDs.compactMap { found[$0] }
    }

    /// Persists the collections and refreshes derived UI state, as one undoable
    /// change. The collections live in the book's KVP slots rather than in any
    /// transaction, so undoing one means restoring the book.
    ///
    /// An edit's name — here and in every `editing…(named:)` below — is a
    /// `LocalizedStringResource`, not a `String`: it is what the Edit menu
    /// shows after "Undo" and what the audit trail records, and as a `String`
    /// each of some hundred and fifty of them was English in every language,
    /// where the catalog's gate could not see it. Written as a literal at the
    /// call, a name is a key the compiler emits.
    func commitKvpCollections(named: LocalizedStringResource = "Change") {
        editingBookKvp(named: named) {
            persistKvpCollections()
        }
    }

    /// Scoped undo for edits that touch only the **price database**. The
    /// whole-book variant snapshots via a full GnuCash-XML export — seconds on
    /// a large book — where copying the `prices` value array is milliseconds.
    public func editingPrices(named: LocalizedStringResource, _ body: () -> Void) {
        if isReadOnly { return }
        auditLog(named)
        // The book records what the body adds and removes; the undo is the
        // inverse of that log. Snapshotting `prices` instead cost a copy of
        // the whole database — 163k rows on the reference book — the moment
        // the body appended to it (Performance Review 2, R8).
        book?.beginRecordingPriceChanges()
        body()
        let changes = book?.endRecordingPriceChanges() ?? []
        // Price-scoped: the register, the journal caches and the search stay
        // (see ``RefreshScope``). Every body routed here mutates `book.prices`
        // alone — that is also what makes the undo below sufficient.
        refreshAfterChange(scope: .prices)
        guard isOpen, !changes.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            model.editingPrices(named: named) { model.book?.revertPriceChanges(changes) }
        }
        undoManager?.setActionName(String(localized: named))
    }

    /// Scoped undo for edits that touch only the **book's kvp frame**
    /// (settings, serialized collections). Same rationale as ``editingPrices``.
    /// What a kvp edit invalidates. `.book` is the default: the slots' own
    /// refresh (``RefreshScope/kvp``), which drops the report memos and keeps
    /// the tree, the register and the search. `.preference` is for a display
    /// setting the book happens
    /// to store — the sparkline window, Show Closed Positions — which changes
    /// no balance, row or report: it marks the document dirty and bumps
    /// ``preferencesRevision``, which the setting's readers observe, and
    /// nothing else (Performance Review 2, R6/R8).
    enum KvpEditScope { case book, preference }

    func editingBookKvp(named: LocalizedStringResource, scope: KvpEditScope = .book, _ body: () -> Void) {
        if isReadOnly { return }
        auditLog(named)
        let before = book?.kvp
        body()
        switch scope {
        case .book:
            refreshAfterChange(scope: .kvp)
        case .preference:
            document?.markDirty()
            documentStateRevision &+= 1
            preferencesRevision &+= 1
        }
        guard isOpen, let before else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            model.editingBookKvp(named: named, scope: scope) {
                model.book?.kvp = before
                // The published collections mirror kvp slots; without a reload
                // the next persist would re-write the undone values.
                model.reloadKvpCollections()
            }
        }
        undoManager?.setActionName(String(localized: named))
    }

    private static func decodeSlot<T: Decodable>(_ type: T.Type, _ value: KvpValue?) -> T? {
        guard case let .string(json)? = value, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// A single Codable value as a slot — the array variant treats empty as
    /// "no slot", which is wrong for a settings struct whose empty form still
    /// differs from another value's.
    private static func encodeSingle<T: Encodable>(_ value: T) -> KvpValue? {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return .string(json)
    }

    private static func encodeSlot<T: Encodable>(_ array: [T]) -> KvpValue? {
        guard !array.isEmpty,
              let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return .string(json)
    }

    private static func encodeMap(_ map: [String: String]) -> KvpValue? {
        guard !map.isEmpty,
              let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return .string(json)
    }

    // MARK: Document lifecycle

    public func newDocument(at url: URL, baseCurrency: Commodity = .aud) throws {
        document = try FinvestLensDocument.create(at: url, baseCurrency: baseCurrency)
        reloadKvpCollections()
        refreshAll()
        startQuoteAutoRefresh()
        startDocumentMaintenance()
        recordLastBook(url)
        resetUndoStack()
    }

    public func open(at url: URL, breakStaleLock: Bool = false) async throws {
        // Books picked via the iOS document picker (iCloud Drive, Box,
        // Dropbox, …) are security-scoped; access must span the whole session
        // because saves write back to the shared file.
        let accessURL = beginBookAccess(to: url)
        do {
            // Off the main actor: materialising the book is seconds of CPU on a
            // large file, and the window cannot repaint while it runs.
            document = try await FinvestLensDocument.load(at: accessURL,
                                                          breakStaleLock: breakStaleLock) { [weak self] progress in
                Task { @MainActor in self?.recordLoadProgress(progress) }
            }
        } catch {
            endBookAccess()
            throw error
        }
        // Open-what-you-can (NFR-05): the load never refuses a book over
        // unreadable stored values, but it must not stay silent about them.
        if let summary = document?.loadWarnings?.summary {
            showToast(.info, verbatim: summary)
        }
        // The read is done; everything below is main-actor work — balances, the
        // account tree, the dashboard — and the window cannot repaint while it
        // runs. Say so, and give the run loop one frame to actually paint it
        // before going busy: otherwise the last thing on screen for the whole of
        // that wait is a bar under "Reading prices", which is finished.
        // A frame is ~16ms against a multi-second open.
        recordLoadProgress(BookLoadProgress(stage: .finishing, completed: 0,
                                            total: 0, fraction: 1))
        try? await Task.sleep(for: .milliseconds(16))

        reloadKvpCollections()
        refreshAll()
        startQuoteAutoRefresh()
        lockIfNeeded()
        startDocumentMaintenance()
        recordLastBook(accessURL)
        observeExternalChanges()
        resetUndoStack()
    }

    /// Opens a book **read-only** (`FR-DAT-06`) — no lock is taken, so it is
    /// safe while another instance holds a live lock. Editing and saving are
    /// disabled for the session.
    public func openReadOnly(at url: URL) async {
        if isOpening || isReplacingBook { return }
        isReplacingBook = true
        defer { isReplacingBook = false }
        guard await saveAndClose() else { return }
        openingURL = url
        loadProgress = nil
        defer { openingURL = nil; loadProgress = nil }
        let accessURL = beginBookAccess(to: url)
        do {
            document = try await FinvestLensDocument.loadReadOnly(at: accessURL) { [weak self] progress in
                Task { @MainActor in self?.recordLoadProgress(progress) }
            }
        } catch {
            endBookAccess()
            if case FinvestLensDocument.DocumentError.notAFinvestLensBook(let kind) = error {
                documentError = Self.foreignBookError(kind, at: url)
            } else {
                documentError = DocumentError(message: error.localizedDescription)
            }
            return
        }
        recordLoadProgress(BookLoadProgress(stage: .finishing, completed: 0, total: 0, fraction: 1))
        try? await Task.sleep(for: .milliseconds(16))
        reloadKvpCollections()
        refreshAll()
        lockIfNeeded()
        recordLastBook(accessURL)
        observeExternalChanges()
        resetUndoStack()
    }

    // MARK: Security-scoped access (iOS document-provider locations)

    private var scopedBookURL: URL?
    static let recentBookmarksKey = "finvestlens.recentBookBookmarks"

    /// Starts security-scoped access to a book and keeps it for the session.
    /// Picker URLs carry their own scope; recents resolve through the stored
    /// bookmark (which can rewrite the path, so the caller must open the
    /// returned URL). On unsandboxed macOS both attempts are no-ops and the
    /// URL is returned unchanged.
    private func beginBookAccess(to url: URL) -> URL {
        endBookAccess()
        if url.startAccessingSecurityScopedResource() {
            scopedBookURL = url
            return url
        }
        if let resolved = Self.resolveBookmark(forPath: url.path) {
            if resolved.startAccessingSecurityScopedResource() {
                scopedBookURL = resolved
                return resolved
            }
            // A book in the app's own folder needs no scope, so the test
            // above is false for it — and the first version then opened the
            // stored path even when the bookmark had found the book somewhere
            // else (`relocated(paths:bookmarks:)`).
            if !FileManager.default.fileExists(atPath: url.path),
               FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }
        return url
    }

    private func endBookAccess() {
        scopedBookURL?.stopAccessingSecurityScopedResource()
        scopedBookURL = nil
    }

    private static func resolveBookmark(forPath path: String) -> URL? {
        guard let bookmarks = UserDefaults.standard
                .dictionary(forKey: recentBookmarksKey) as? [String: Data],
              let data = bookmarks[path] else { return nil }
        return ScopedBookmark.resolve(data)?.url
    }

    /// Defaults key for "reopen the last book on launch" (window/state
    /// restoration). Defaults to on when absent.
    public nonisolated static let reopenLastBookDefaultsKey = "finvestlens.reopenLastBook"

    /// Reopens the most recent book on launch when enabled and nothing is open
    /// yet (idempotent — `openBook` guards double-opens). Call once from the
    /// root view's `.task`.
    public func reopenLastBookIfEnabled() async {
        guard Self.reopensLastBook(UserDefaults.standard), !isOpen, !isOpening,
              let url = recentBooks.first else { return }
        await openBook(at: url)
    }

    /// Whether the last book reopens at launch: on unless turned off.
    ///
    /// Read with `bool(forKey:)`, which understands every way the setting
    /// arrives — the Settings toggle stores a Bool, a launch argument
    /// (`-finvestlens.reopenLastBook NO`) arrives as the string "NO". The
    /// first version cast the stored object to `Bool`, so the argument was
    /// not a Bool, fell to the default, and the book reopened anyway.
    nonisolated static func reopensLastBook(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: reopenLastBookDefaultsKey) == nil || defaults.bool(forKey: reopenLastBookDefaultsKey)
    }

    /// User-configurable autosave interval in seconds; 0 disables autosave
    /// (`FR-DAT-10`). Defaults to 5 minutes. App-wide (not per-book).
    public var autosaveIntervalSeconds: Int {
        get { (UserDefaults.standard.object(forKey: "finvestlens.autosaveIntervalSeconds") as? Int) ?? 300 }
        set { UserDefaults.standard.set(newValue, forKey: "finvestlens.autosaveIntervalSeconds") }
    }

    /// Keeps the advisory lock alive and autosaves while a book is open.
    /// Without the heartbeat, an idle book's lock ages past the staleness
    /// window and another instance could legitimately break it — two writers.
    private func startDocumentMaintenance() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { break }
                if let usurper = self?.document?.heartbeat() {
                    // Our stale lock was legitimately broken (e.g. this Mac
                    // slept past the staleness window). The session survives,
                    // guarded only by the save-time conflict check.
                    self?.showToast(.failure,
                        "\(usurper.user)@\(usurper.host) took over this book's lock while this Mac was asleep. Saving now requires the file to be unchanged.")
                }
            }
        }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                // Re-read each loop so a Settings change takes effect without a
                // reopen. 0 (or negative) disables autosave — the task idles and
                // ⌘S / save-on-close still protect data (FR-DAT-10).
                let interval = self?.autosaveIntervalSeconds ?? 300
                guard interval > 0 else {
                    try? await Task.sleep(for: .seconds(30)); continue
                }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.hasUnsavedChanges else { continue }
                await self.saveWithStatus(interactive: false)
            }
        }
    }

    private func stopDocumentMaintenance() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        autosaveTask?.cancel(); autosaveTask = nil
    }

    /// Watches the shared file for external changes (iCloud sync from another
    /// device) and raises ``externalChangePending`` (`FR-PLT-02`).
    private func observeExternalChanges() {
        document?.startObservingExternalChanges { [weak self] in
            Task { @MainActor in
                guard let self, let document = self.document else { return }
                if document.hasExternalChanges() { self.externalChangePending = true }
            }
        }
    }

    /// Reloads the book from the shared file, adopting external changes and
    /// discarding unsaved local edits.
    public func reloadFromDisk() {
        guard let document else { return }
        // Not over a save that is writing: the document would wait for it on
        // the main actor, seconds on a network volume (see ``revertWithStatus()``).
        if isSaving {
            Task { @MainActor in
                while isSaving { await waitForSaveToFinish() }
                reloadFromDisk()
            }
            return
        }
        try? document.reloadFromDisk()
        forgetSearchCaches()
        externalChangePending = false
        // The freshly adopted book invalidates every undo snapshot — replaying
        // one would silently rewrite the other device's data (an "Add
        // Transaction" entry would even delete a transaction that version
        // legitimately contains).
        resetUndoStack()
        reloadKvpCollections()
        refreshAll()
    }

    // MARK: Version conflicts (iCloud "edited in two places")

    /// `true` when the shared file has unresolved NSFileVersion conflicts.
    public var hasVersionConflicts: Bool {
        !(document?.unresolvedConflictVersions().isEmpty ?? true)
    }

    /// Keeps the local version: marks all conflict versions resolved and
    /// re-saves our copy over the shared file. Failures surface — the user
    /// must not believe their version won when it didn't.
    public func resolveConflictsKeepingMine() {
        guard let document else { return }
        do {
            try document.resolveConflictsKeepingCurrent()
            try document.save()
            externalChangePending = false
        } catch {
            documentError = DocumentError(
                message: String(localized: "Couldn’t keep your version: \(error.localizedDescription)"))
        }
        refreshAll()
    }

    /// Adopts the most recent conflicting version and reloads from it.
    public func resolveConflictsUsingOther() {
        guard let document else { return }
        if isSaving {
            Task { @MainActor in
                while isSaving { await waitForSaveToFinish() }
                resolveConflictsUsingOther()
            }
            return
        }
        let versions = document.unresolvedConflictVersions()
        if let newest = versions.max(by: {
            ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast)
        }) {
            try? document.adoptConflictVersion(newest)
        }
        reloadFromDisk()
    }

    /// Remembers the last-opened book so App Intents / Shortcuts can read it,
    /// and maintains the recents list (most recent first, capped at 5).
    func recordLastBook(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "finvestlens.lastBookPath")
        var paths = UserDefaults.standard.stringArray(forKey: "finvestlens.recentBookPaths") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        paths = Array(paths.prefix(5))
        UserDefaults.standard.set(paths, forKey: "finvestlens.recentBookPaths")
        recentBooks = paths.map { URL(fileURLWithPath: $0) }

        // Bookmark taken while scoped access is active, so Open Recent can
        // regain the grant on iOS after a relaunch. Pruned with the list.
        var bookmarks = UserDefaults.standard
            .dictionary(forKey: Self.recentBookmarksKey) as? [String: Data] ?? [:]
        if let bookmark = ScopedBookmark.make(url) {
            bookmarks[url.path] = bookmark
        }
        bookmarks = bookmarks.filter { paths.contains($0.key) }
        UserDefaults.standard.set(bookmarks, forKey: Self.recentBookmarksKey)
    }

    static func loadRecents() -> [URL] {
        // A provider-backed book (iCloud/Box/Dropbox on iOS) isn't visible to
        // fileExists without its grant, so a bookmark is the only evidence it
        // is still there. Requiring the bookmark to *resolve* — rather than
        // merely exist — is what separates those from a book that has since
        // been deleted: a bookmark for a deleted file no longer resolves, so
        // the entry drops out instead of haunting the list forever.
        let defaults = UserDefaults.standard
        let stored = relocated(paths: defaults.stringArray(forKey: "finvestlens.recentBookPaths") ?? [],
                               bookmarks: defaults.dictionary(forKey: recentBookmarksKey) as? [String: Data] ?? [:])
        if stored.moved {
            defaults.set(stored.paths, forKey: "finvestlens.recentBookPaths")
            defaults.set(stored.bookmarks, forKey: recentBookmarksKey)
        }
        return stored.paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) || resolves(stored.bookmarks[$0.path]) }
    }

    /// Recents whose path is dead but whose bookmark finds the book, moved to
    /// where it is now.
    ///
    /// A book in the app's own folder moves when the folder does — the app's
    /// container, which on 17 Oct 2026 an iPhone simulator moved when the app
    /// was reinstalled over itself. The bookmark kept beside each path follows
    /// the file; the path does not, and opening it failed with "no such file"
    /// and dropped the book from Recents, session restore with it. Resolved
    /// here, once, everything that reads Recents — the list, session restore,
    /// whether a book is a copy from Box — sees where the book is.
    nonisolated static func relocated(paths: [String], bookmarks: [String: Data],
                          resolve: (Data) -> URL? = { ScopedBookmark.resolve($0)?.url },
                          bookmark: (URL) -> Data? = { ScopedBookmark.make($0) })
        -> (paths: [String], bookmarks: [String: Data], moved: Bool) {
        var bookmarks = bookmarks
        var moved = false
        var result: [String] = []
        for path in paths {
            guard !FileManager.default.fileExists(atPath: path), let data = bookmarks[path],
                  let now = resolve(data), now.path != path,
                  FileManager.default.fileExists(atPath: now.path) else {
                result.append(path)
                continue
            }
            bookmarks[path] = nil
            bookmarks[now.path] = bookmark(now) ?? data
            moved = true
            if !result.contains(now.path) { result.append(now.path) }
        }
        return (result, bookmarks, moved)
    }

    /// `true` when `data` still resolves to a file. Resolution is the existence
    /// check here: a bookmark to a deleted file throws rather than resolving.
    private static func resolves(_ data: Data?) -> Bool {
        guard let data else { return false }
        return ScopedBookmark.resolve(data) != nil
    }

    /// Drops a book from the recents list and forgets its bookmark. Used when
    /// a recent turns out to be unopenable, so a dead entry doesn't persist.
    public func removeRecent(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "finvestlens.recentBookPaths") ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: "finvestlens.recentBookPaths")
        var bookmarks = UserDefaults.standard
            .dictionary(forKey: Self.recentBookmarksKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: url.path)
        UserDefaults.standard.set(bookmarks, forKey: Self.recentBookmarksKey)
        recentBooks = Self.loadRecents()
    }

    /// `true` when `error` means the book is locked by another instance —
    /// offer "Break Lock" recovery (safe when the other instance crashed).
    public static func isLockedError(_ error: Error) -> Bool {
        if case FileLock.LockError.alreadyLocked = error { return true }
        return false
    }

    /// `true` when `error` means the file itself is gone (as opposed to being
    /// unreadable, locked, or corrupt) — the entry is safe to forget.
    static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError):
            return true
        case (NSPOSIXErrorDomain, Int(ENOENT)):
            return true
        default:
            return false
        }
    }

    // MARK: Safe document operations (error-surfacing wrappers)

    /// Saves any open book, then opens `url`; failures land in
    /// ``documentError`` (with Break-Lock recovery for stale locks).
    public func openBook(at url: URL, breakStaleLock: Bool = false) async {
        // Re-opening the book that is already open is a no-op, not a reload.
        // Use Revert to reload.
        if isOpen, documentURL?.standardizedFileURL == url.standardizedFileURL { return }
        // The load runs off the main actor, so the window stays live while it
        // runs — which means a second click *can* arrive mid-load. Without this
        // guard it would open a second document over the first, orphaning the
        // first one's lock and working copy. The check and the set are both on
        // the main actor with no suspension between them, so two clicks cannot
        // both get past it.
        if isOpening || isReplacingBook { return }
        let boxFileID = boxLibrary.fileID(ofCopyAt: url)
        // A book whose Keep Both is under way is about to move; it opens when
        // that is done, from where it went.
        if let boxFileID, boxResolving.contains(boxFileID) {
            showToast(.info, "This book is still being put on Box. Try again in a moment.")
            return
        }
        openingURL = url
        isReplacingBook = true
        loadProgress = nil
        // Cleared on the way out as well as the way in: a late report can land
        // after the load returns (the hop is a `Task`), and the next open must
        // start from an empty bar rather than the last one's 100%.
        defer { openingURL = nil; loadProgress = nil; isReplacingBook = false }
        // A book from Box is brought up to date *before* the open book is
        // closed: when Box cannot be reached and there is no copy here, the
        // book the person was working in stays open.
        if let boxFileID, boxLibrary.record(boxFileID) != nil {
            guard await prepareBoxCopy(boxFileID) else { return }
        }
        guard await saveAndClose() else { return }
        do {
            try await open(at: url, breakStaleLock: breakStaleLock)
            publishWidgetData()
            restoreSessionSelection()
            restoreWindowPeriod()
            boxBookDidOpen()
        } catch {
            // A recent whose file has gone is dead weight: drop it now rather
            // than leave the user to hit the same error on every launch.
            if Self.isMissingFileError(error) { removeRecent(url) }
            if case FinvestLensDocument.DocumentError.notAFinvestLensBook(let kind) = error {
                documentError = Self.foreignBookError(kind, at: url)
            } else {
                documentError = DocumentError(
                    message: Self.isLockedError(error)
                        ? String(localized: "“\(url.lastPathComponent)” is locked by another FinvestLens instance. If that instance crashed, you can break the lock and open anyway.")
                        : error.localizedDescription,
                    lockedURL: Self.isLockedError(error) ? url : nil)
            }
        }
    }

    /// The message for opening a file that is not a `.finvestlens` book —
    /// GnuCash books get pointed (or handed straight) to the import flow
    /// instead of a raw SQLite error.
    static func foreignBookError(_ kind: FinvestLensDocument.ForeignFileKind,
                                 at url: URL) -> DocumentError {
        switch kind {
        case .gnuCashBook:
            return DocumentError(
                message: String(localized: "“\(url.lastPathComponent)” is a GnuCash book. FinvestLens keeps books in its own .finvestlens format — import it to create a native copy, and you can export back to GnuCash at any time."),
                gnuCashImportURL: url)
        case .gnuCashSQLite:
            return DocumentError(
                message: String(localized: "“\(url.lastPathComponent)” was saved with GnuCash’s SQLite backend, which FinvestLens can’t read. In GnuCash, choose File ▸ Save As… with the XML format, then use File ▸ Import GnuCash… here."))
        case .unrecognized:
            return DocumentError(
                message: String(localized: "“\(url.lastPathComponent)” isn’t a FinvestLens book."))
        }
    }

    /// Saves any open book, then creates a new one at `url`.
    public func newBook(at url: URL, baseCurrency: Commodity = .aud) async {
        if isOpening || isReplacingBook { return }
        isReplacingBook = true
        defer { isReplacingBook = false }
        guard await saveAndClose() else { return }
        do {
            try newDocument(at: url, baseCurrency: baseCurrency)
        } catch {
            documentError = DocumentError(message: error.localizedDescription)
        }
    }

    /// Imports a GnuCash XML file as a new native book, reporting the summary
    /// (or the failure) through ``infoMessage`` / ``documentError``. A locked
    /// `destination` (someone else's document at that path) offers "Break
    /// Lock and Import" the way opening a locked book does, rather than a
    /// raw lock error — pass `breakStaleLock: true` to retry through it.
    public func importGnuCashBook(from source: URL, saveAs destination: URL,
                                  breakStaleLock: Bool = false) async {
        // Refused before the close, not after it: a second import used to
        // close the book on screen and only then find the first still running.
        if isImporting || isOpening || isReplacingBook { return }
        isReplacingBook = true
        defer { isReplacingBook = false }
        guard await saveAndClose() else { return }
        importingURL = source
        loadProgress = nil
        defer { importingURL = nil; loadProgress = nil }
        do {
            let summary = try await importGnuCash(from: source, saveAs: destination,
                                                  breakStaleLock: breakStaleLock)
            recordLastBook(destination)
            let note = "Imported \(summary.accountCount) accounts and \(summary.transactionCount) transactions from “\(source.lastPathComponent)”."
            // Offer Check & Repair when the imported book has issues
            // (empty stubs, orphans, imbalances) — GnuCash files often do.
            if let proposal = cleanupProposal(importNote: note) {
                pendingCleanup = proposal
            } else {
                infoMessage = note
            }
        } catch {
            if Self.isLockedError(error) {
                documentError = DocumentError(
                    message: String(localized: "“\(destination.lastPathComponent)” is locked by another FinvestLens instance. If that instance crashed, you can break the lock and import anyway."),
                    lockedURL: destination, lockedImportSource: source)
            } else {
                documentError = DocumentError(message: String(localized: "Couldn’t import “\(source.lastPathComponent)”: \(error.localizedDescription)"))
            }
        }
    }

    /// Saves and closes the current book, if any — switching books never
    /// silently discards work. Returns `false` (leaving the book open and
    /// surfacing ``documentError``) if the save failed; callers must not
    /// proceed with whatever would have replaced the book.
    @discardableResult
    public func saveAndCloseIfOpen() -> Bool {
        guard isOpen else { return true }
        if hasUnsavedChanges {
            do {
                try save()
            } catch {
                documentError = DocumentError(
                    message: String(localized: "Couldn’t save “\(documentURL?.lastPathComponent ?? "")”: \(error.localizedDescription)"))
                return false
            }
        }
        // Closing a book from Box — and switching books, and quitting, which
        // close it — sends what Box has not got, autosaved work included: it
        // is often the last save before the book is picked up elsewhere.
        requestUploadOfOpenBoxBook(announce: false)
        close()
        return true
    }

    /// ``saveAndCloseIfOpen()`` without holding the main actor for the write
    /// (P10). Close Book, switching books and quitting all saved with
    /// ``save()`` — the whole rewrite on the main actor, so the window froze
    /// for seconds at each, and an autosave already writing made it wait on
    /// that one first. This waits for an autosave in flight instead of racing
    /// it, writes on a background thread, and saves again if an edit landed
    /// while the file was being written, so closing never drops one. Returns
    /// `false` (leaving the book open and surfacing ``documentError``) if the
    /// save failed; callers must not proceed with whatever would have
    /// replaced the book.
    @discardableResult
    public func saveAndClose() async -> Bool {
        // One close at a time: a second — Close Book then ⌘Q, or an open
        // while a close runs — waits for the first and takes its answer. Two
        // both wrote, and the first to finish closed the book, deleting the
        // working copy under the other's write.
        if let closing { return await closing.value }
        let task = Task { await saveAndCloseNow() }
        closing = task
        defer { closing = nil }
        return await task.value
    }

    /// The close in progress, which ``saveAndClose()`` callers share.
    @ObservationIgnored private var closing: Task<Bool, Never>?

    private func saveAndCloseNow() async -> Bool {
        var writes = 0
        while true {
            // Until none is in flight: one can start between a save's end
            // and this waking (an autosave, a save before suspension).
            while isSaving { await waitForSaveToFinish() }
            guard isOpen else { return true }
            guard hasUnsavedChanges else { break }
            do {
                // Still changing after three writes: one more that nothing
                // can interleave with, so the loop ends.
                if writes < 3 { try await writeInBackground() } else { try save() }
            } catch {
                documentError = DocumentError(
                    message: String(localized: "Couldn’t save “\(documentURL?.lastPathComponent ?? "")”: \(error.localizedDescription)"))
                return false
            }
            writes += 1
        }
        // Closing a book from Box — and switching books, and quitting, which
        // close it — sends what Box has not got, autosaved work included: it
        // is often the last save before the book is picked up elsewhere.
        requestUploadOfOpenBoxBook(announce: false)
        close()
        return true
    }

    /// Waits for a save in progress, if there is one, to finish.
    func waitForSaveToFinish() async {
        guard isSaving else { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    /// Imports a GnuCash file and saves it as a new native document.
    ///
    /// Parsing the XML and writing the result both run off the main actor
    /// (``DocumentLoader``, the same executor a book open uses) — a large
    /// GnuCash export takes seconds to parse and write, and the window
    /// cannot repaint while that runs on the main actor.
    @discardableResult
    public func importGnuCash(from source: URL, saveAs destination: URL,
                              breakStaleLock: Bool = false) async throws -> ImportSummary {
        let (doc, summary) = try await performGnuCashImport(
            source: source, destination: destination, breakStaleLock: breakStaleLock) { [weak self] progress in
                Task { @MainActor in self?.recordLoadProgress(progress) }
            }
        document = doc
        reloadKvpCollections()
        refreshAll()
        startQuoteAutoRefresh()
        startDocumentMaintenance()
        observeExternalChanges()
        resetUndoStack()
        return summary
    }

    /// Serialises the current book to GnuCash XML (`FR-EXP-01`), optionally
    /// gzip-compressed. Returns `nil` if no document is open.
    public func gnuCashExportData(compressed: Bool = false) -> Data? {
        guard let book else { return nil }
        return GnuCashXMLExporter.export(book, compressed: compressed)
    }

    /// The current book as a Ledger 3 journal (`FR-XIO-10`) — the same
    /// canonical text the `finlens print` command emits. `nil` if no
    /// document is open.
    public func ledgerExportText() -> String? {
        guard let book else { return nil }
        return LedgerExport.text(from: book)
    }

    /// ``gnuCashExportData(compressed:)`` built on a replica, off the main
    /// actor (R2e): the export walks the whole book, 1.6 s on the reference
    /// book, and File ▸ Export held the window for all of it before the save
    /// panel could appear. Only the copy is taken here — 44 ms.
    public func gnuCashExportDataOffMain(compressed: Bool = false) async -> Data? {
        await onReplica { GnuCashXMLExporter.export($0, compressed: compressed) }
    }

    /// ``ledgerExportText()`` built on a replica, off the main actor (R2e).
    public func ledgerExportTextOffMain() async -> String? {
        await onReplica { LedgerExport.text(from: $0) }
    }

    /// `work` run on a replica of the open book, off the main actor — or
    /// `nil` when no book is open, or when the book it was asked of was
    /// closed or replaced while it ran: an export of one book must not open
    /// its save panel over another, under the other's name.
    func onReplica<Value: Sendable>(_ work: @escaping @Sendable (Book) -> Value) async -> Value? {
        guard let book else { return nil }
        let replica = book.replica()
        let value = await Task.detached(priority: .userInitiated) { work(replica.book) }.value
        guard self.book === book else { return nil }
        return value
    }

    /// Imports a Ledger journal as a new native book, reporting the summary
    /// (or the failure) the way the GnuCash import does.
    public func importLedgerBook(from source: URL, saveAs destination: URL) async {
        if isImporting || isOpening || isReplacingBook { return }
        isReplacingBook = true
        defer { isReplacingBook = false }
        guard await saveAndClose() else { return }
        do {
            let summary = try importLedger(from: source, saveAs: destination)
            recordLastBook(destination)
            // Every fragment goes through `String(localized:)` and carries its
            // own count: these are `String`s, so a bare literal is neither
            // extracted nor looked up, and the old `+ (n == 1 ? "" : "s")`
            // suffix produced "3 Zeiles" in German however good the rest was.
            let name = source.lastPathComponent
            var note = String(localized: "Imported \(summary.accountsCreated) accounts and \(summary.transactions) transactions from “\(name)”.")
            var caveats: [String] = []
            if summary.assertionsChecked > 0 {
                caveats.append(summary.assertionsFailed > 0
                    ? String(localized: "\(summary.assertionsChecked) balance assertions checked (\(summary.assertionsFailed) failed)")
                    : String(localized: "\(summary.assertionsChecked) balance assertions checked"))
            }
            if summary.assignmentsResolved > 0 {
                caveats.append(String(localized: "\(summary.assignmentsResolved) balance assignments resolved"))
            }
            if summary.unbalancedVirtualsSkipped > 0 {
                caveats.append(String(localized: "\(summary.unbalancedVirtualsSkipped) unbalanced virtual postings skipped"))
            }
            let ignored = summary.periodicIgnored + summary.automatedIgnored
            if ignored > 0 {
                caveats.append(String(localized: "\(ignored) periodic/automated entries not applied"))
            }
            let errors = summary.diagnostics.filter { $0.severity == .error }
            if let first = errors.first {
                let detail = first.description
                caveats.append(String(localized: "\(errors.count) lines could not be read (first: \(detail))"))
            }
            if !caveats.isEmpty { note += " " + caveats.joined(separator: "; ") + "." }
            if let proposal = cleanupProposal(importNote: note) {
                pendingCleanup = proposal
            } else {
                infoMessage = note
            }
        } catch {
            documentError = DocumentError(
                message: String(localized: "Couldn’t import “\(source.lastPathComponent)”: \(error.localizedDescription)"))
        }
    }

    /// Parses a Ledger journal and saves it as a new native document.
    @discardableResult
    public func importLedger(from source: URL, saveAs destination: URL) throws -> LedgerImportSummary {
        let parsed = try LedgerParser.parse(fileAt: source)
        let result = LedgerImport.importBook(parsed: parsed)
        let doc = try FinvestLensDocument.create(at: destination,
                                                 baseCurrency: result.book.baseCurrency)
        try replaceBook(of: doc, with: result.book)
        document = doc
        reloadKvpCollections()
        refreshAll()
        startQuoteAutoRefresh()
        startDocumentMaintenance()
        observeExternalChanges()
        resetUndoStack()
        return result.summary
    }

    /// `FL_VERIFY_INDEXES=1`: a save with no edit landing during it must
    /// leave the working copy exactly what a full write would (P10b).
    private func verifySavedWorkingCopy(_ document: FinvestLensDocument) {
        guard Self.verifiesKeptIndexes, !document.hasUnsavedChanges else { return }
        precondition((try? document.workingCopyHoldsBook()) == true, "an incremental save left the working copy short of the book")
    }

    public func save() throws {
        try document?.save()
        if let document { verifySavedWorkingCopy(document) }
        // A save changes the file, not the book: nothing derived needs
        // rebuilding, only the dirty flag's readers need to look again.
        documentStateRevision &+= 1
        publishWidgetData()
    }

    /// True while a save is writing — the status overlay shows "Saving…".
    public private(set) var isSaving = false

    /// The status-routed save (P10, F20): paints the Saving… chip first, then
    /// writes, and reports the outcome through the overlay instead of a
    /// swallowed `try?`. `interactive` saves toast success; background
    /// (autosave) success stays quiet.
    public func saveWithStatus(interactive: Bool) async {
        guard hasUnsavedChanges || interactive else { return }
        // One save at a time. Autosave can fire while an earlier one is still
        // writing back, and two `replaceItem`s racing on the same destination
        // is not a race worth having.
        guard !isSaving, document != nil else { return }
        do {
            try await writeInBackground()
            if interactive { showToast(.success, "Saved.") }
            // ⌘S sends a book from Box up as a new version — after the
            // write-back, so the bytes sent are the ones on disk, and in a task
            // of its own, so a slow upload neither holds "Saving…" up nor
            // blocks the next save. Autosave keeps its work on this device
            // until an explicit save (the owner's decision, 17 Oct 2026).
            if interactive { requestUploadOfOpenBoxBook(announce: true) }
        } catch {
            if interactive {
                documentError = DocumentError(message: error.localizedDescription)
            } else if documentError == nil {
                // Surface once; don't stack alerts every autosave interval.
                documentError = DocumentError(
                    message: String(localized: "Autosave failed: \(error.localizedDescription)"))
            }
        }
    }

    /// The save itself, with the write off the main actor (P10). Phase 1 runs
    /// here, because it reads the book — but only into a value snapshot, a
    /// fraction of a second. Phase 2 — the SQLite rewrite of the working copy
    /// and the write-back to the shared file — reads nothing but that
    /// snapshot, so it goes to a background thread: that is where the seconds
    /// are (9.6 s for the whole save on the reference book, measured 9 Oct
    /// 2026), and doing the rewrite here froze the window for every save.
    /// Phase 3 records the result back here; an edit made meanwhile leaves the
    /// document dirty for the next save. Callers make sure no other save is
    /// writing (``isSaving``).
    private func writeInBackground() async throws {
        guard let document else { return }
        isSaving = true
        defer {
            isSaving = false
            let waiting = saveWaiters
            saveWaiters = []
            waiting.forEach { $0.resume() }
        }
        await Task.yield()   // commit the chip before the staging walk
        let staged = try document.stageSnapshot()
        let fingerprint: Data?
        do {
            fingerprint = try await Task.detached(priority: .userInitiated) {
                try FinvestLensDocument.commitStaged(staged)
            }.value
        } catch {
            document.saveFailed(staged)
            throw error
        }
        document.finishSave(fingerprint: fingerprint, staged: staged)
        verifySavedWorkingCopy(document)
        documentStateRevision &+= 1
        publishWidgetData()
    }

    /// Revert with the outcome reported (F20) — a failed revert is exactly
    /// when the user must know the file on disk was not what they thought.
    public func revertWithStatus() {
        // A save already writing finishes first, and what it wrote is part of
        // the saved book: it cannot be unwritten. Reverting under it waited on
        // the save's lock on the main actor — the window frozen for the rest
        // of the write — and then said "Reverted" over the very edits it had
        // been asked to discard. Now it waits off the main actor, and says so.
        if isSaving {
            Task { @MainActor in
                while isSaving { await waitForSaveToFinish() }
                do {
                    try revert()
                    showToast(.info, "Reverted to the saved book — including what the save that was running wrote.")
                } catch {
                    documentError = DocumentError(message: String(localized: "Couldn’t revert: \(error.localizedDescription)"))
                }
            }
            return
        }
        do {
            try revert()
            showToast(.success, "Reverted to the saved book.")
        } catch {
            documentError = DocumentError(message: String(localized: "Couldn’t revert: \(error.localizedDescription)"))
        }
    }

    public func revert() throws {
        try document?.revert()
        forgetSearchCaches()
        // Pre-revert undo entries would replay stale snapshots onto the
        // reloaded book (and autosave would then persist them) — every other
        // book-replacement path clears the stack too.
        resetUndoStack()
        reloadKvpCollections()
        refreshAll()
    }

    public func close() {
        // Remember how the last register was arranged before everything resets.
        persistRegisterViewState(for: selectedAccountID)
        stopQuoteAutoRefresh()
        stopDocumentMaintenance()
        document?.stopObservingExternalChanges()
        isLocked = false
        externalChangePending = false
        presentedPanel = nil
        // `isShowingReports = false` used to be here. Its setter now navigates,
        // and `document` is still live at this point — so closing the book from
        // the Reports gallery switched the mode to Overview and *persisted* it,
        // and the book reopened somewhere the user never was.
        // `resetNavigation()` below does the same job after `document` is nil,
        // where the write is correctly suppressed.
        searchQuery = ""
        clearFind()
        document?.discard()
        document = nil
        endBookAccess()
        publishWidgetData()   // book is now nil → clears the widget snapshot
        dropJournalCaches()
        priceRowCache = nil
        rateRowCache = nil
        // Measured on this book; the next one may be a hundred times larger.
        reportBuildTimes = [:]
        forgetSearchCaches()
        derivedRevision &+= 1
        accountTree = []
        registerRows = []
        registerSummary = nil
        resetNavigation()
        windowPeriod = nil
        resetRegisterView()
        ruleGroups = []
        scheduledTransactions = []
        budgets = []
        savedSearches = []
        savedFindQueries = []
        savedReports = []
        reportSettings = ReportSettings()
        watchlist = []
        delistedSecurities = []
        unquotedSecurities = []
        priceTargets = []
        quoteSymbols = [:]
        quoteProviders = [:]
        valuationCadences = [:]
        quoteStatus = .idle
        whatIfEvents = []
        resetUndoStack()
    }

    // MARK: Mutations

    @discardableResult
    public func addAccount(name: String, type: AccountType, commodity: Commodity? = nil,
                           parentID: GncGUID? = nil) -> GncGUID? {
        guard let book else { return nil }
        let parent = parentID.flatMap { book.account(with: $0) } ?? book.rootAccount
        let account = Account(name: name, type: type, commodity: commodity ?? parent.commodity)
        editing(accounts: [account.guid], named: "Add Account") {
            book.addAccount(account, under: parent)
        }
        return account.guid
    }

    /// What stands between an account and being deleted (`FR-ACC-04`).
    ///
    /// GnuCash asks this before deleting: an account with postings or children
    /// can still go, but its contents have to be given somewhere to live first.
    /// Refusing outright — which is what this used to do — leaves most of a real
    /// book undeletable, since almost every account has been posted to.
    public struct AccountDeletionPlan: Sendable, Equatable {
        public var splitCount: Int
        public var childCount: Int
        /// Descendants' postings, which move with their accounts rather than
        /// separately; counted so the dialog can say what it is about to move.
        public var descendantSplitCount: Int
        public var needsTransactionTarget: Bool { splitCount > 0 }
        public var needsChildTarget: Bool { childCount > 0 }
        public var isUnencumbered: Bool { splitCount == 0 && childCount == 0 }
    }

    public enum AccountDeletionError: Error, Equatable {
        case notFound
        /// The account has postings and no account was named to take them.
        case transactionsNeedTarget
        /// The account has children and no account was named to take them.
        case childrenNeedTarget
        case targetNotFound
        /// A target inside the subtree being deleted would be deleted with it.
        case targetIsSelfOrDescendant
        /// Quantities are denominated in the account's own commodity, so moving
        /// a split to an account of another commodity would silently reinterpret
        /// it — 100 shares becoming 100 dollars.
        case targetCommodityDiffers
    }

    /// An account's own name, for a dialog that has to name it.
    public func accountName(_ id: GncGUID) -> String? {
        book?.account(with: id)?.name
    }

    /// Why a deletion was refused, in words for the person who asked for it.
    public func describe(_ error: Error) -> String {
        switch error {
        case AccountDeletionError.transactionsNeedTarget:
            String(localized: "Choose an account to move the transactions to.")
        case AccountDeletionError.childrenNeedTarget:
            String(localized: "Choose an account to move the subaccounts to.")
        case AccountDeletionError.targetIsSelfOrDescendant:
            String(localized: "That account is inside the one being deleted, so it would go too.")
        case AccountDeletionError.targetCommodityDiffers:
            String(localized: "That account holds a different commodity, which would change what every moved amount means.")
        case AccountDeletionError.targetNotFound, AccountDeletionError.notFound:
            String(localized: "That account no longer exists.")
        default:
            (error as NSError).localizedDescription
        }
    }

    public func deletionPlan(for id: GncGUID) -> AccountDeletionPlan? {
        guard let book, let account = book.account(with: id) else { return nil }
        let descendants = account.descendants
        return AccountDeletionPlan(
            splitCount: book.splits(for: account).count,
            childCount: account.children.count,
            descendantSplitCount: descendants.reduce(0) { $0 + book.splits(for: $1).count }
        )
    }

    /// The accounts that could take `id`'s postings: same commodity, and not
    /// inside the subtree about to be removed.
    public func transactionTargets(forDeleting id: GncGUID) -> [AccountNode] {
        guard let book, let account = book.account(with: id) else { return [] }
        let excluded = Set(([account] + account.descendants).map(\.guid))
        return postableAccounts.filter {
            !excluded.contains($0.id)
                && book.account(with: $0.id)?.commodity == account.commodity
        }
    }

    /// The accounts that could adopt `id`'s children — anywhere outside the
    /// subtree. Commodity is not a constraint here: a parent does not hold its
    /// children's postings.
    public func childTargets(forDeleting id: GncGUID) -> [AccountNode] {
        guard let book, let account = book.account(with: id) else { return [] }
        let excluded = Set(([account] + account.descendants).map(\.guid))
        // Placeholders included, unlike the postings target: holding children is
        // exactly what a placeholder is for.
        func flatten(_ nodes: [AccountNode]) -> [AccountNode] {
            nodes.flatMap { [$0] + flatten($0.children ?? []) }
        }
        return flatten(accountTree).filter { !excluded.contains($0.id) }
    }

    /// Deletes an account, first moving its postings and children where asked
    /// (`FR-ACC-04`).
    ///
    /// Both moves are refused rather than guessed at: silently deleting someone's
    /// transactions because they did not name a target is not a thing to do by
    /// default, and neither is dropping them into an account whose commodity
    /// would reinterpret every quantity.
    public func deleteAccount(_ id: GncGUID,
                              movingTransactionsTo transactionTarget: GncGUID? = nil,
                              movingChildrenTo childTarget: GncGUID? = nil) throws {
        guard let book, let account = book.account(with: id) else {
            throw AccountDeletionError.notFound
        }
        let plan = deletionPlan(for: id) ?? AccountDeletionPlan(splitCount: 0, childCount: 0,
                                                               descendantSplitCount: 0)
        let subtree = Set(([account] + account.descendants).map(\.guid))

        var moveSplitsTo: Account?
        if plan.needsTransactionTarget {
            guard let targetID = transactionTarget else {
                throw AccountDeletionError.transactionsNeedTarget
            }
            guard let target = book.account(with: targetID) else {
                throw AccountDeletionError.targetNotFound
            }
            guard !subtree.contains(targetID) else {
                throw AccountDeletionError.targetIsSelfOrDescendant
            }
            guard target.commodity == account.commodity else {
                throw AccountDeletionError.targetCommodityDiffers
            }
            moveSplitsTo = target
        }

        var moveChildrenTo: Account?
        if plan.needsChildTarget {
            guard let targetID = childTarget else {
                throw AccountDeletionError.childrenNeedTarget
            }
            guard let target = book.account(with: targetID) else {
                throw AccountDeletionError.targetNotFound
            }
            guard !subtree.contains(targetID) else {
                throw AccountDeletionError.targetIsSelfOrDescendant
            }
            moveChildrenTo = target
        }

        // The account, the children it hands on (parents first), and every
        // transaction whose postings move — nothing else changes.
        let childIDs = account.children.map(\.guid)
        let touched = Array(Set(book.splits(for: account).compactMap { $0.transaction?.guid }))
        editing(accounts: [id] + childIDs, transactions: touched, named: "Delete Account") {
            if let moveSplitsTo {
                for split in book.splits(for: account) { split.account = moveSplitsTo }
            }
            if let moveChildrenTo {
                for child in account.children {
                    account.removeChild(child)
                    _ = moveChildrenTo.addChild(child)
                }
            }
            account.parent?.removeChild(account)
            if selectedAccountID == id { selectedAccountID = nil }
        }
    }

    /// Assigns sequential codes to the children of `parentID` (or the top level),
    /// ordered by existing code then name (`FR-COA`). Codes are zero-padded,
    /// e.g. prefix "" interval 10 → "010", "020", … `nil` parent renumbers the
    /// top-level accounts.
    public func renumberChildren(of parentID: GncGUID?, prefix: String = "", interval: Int = 10) {
        guard let book else { return }
        let parent = parentID.flatMap { book.account(with: $0) } ?? book.rootAccount
        let children = parent.children.sorted {
            ($0.code, $0.name) < ($1.code, $1.name)
        }
        guard !children.isEmpty else { return }
        let width = String((children.count) * max(interval, 1)).count
        editing(accounts: children.map(\.guid), named: "Renumber Accounts") {
            for (index, child) in children.enumerated() {
                let number = (index + 1) * max(interval, 1)
                child.code = prefix + String(format: "%0\(width)d", number)
            }
        }
    }

    /// Records a simple two-account transaction moving `amount` from `sourceID`
    /// into `destinationID` (positive `amount` credits the destination).
    @discardableResult
    public func addTransfer(from sourceID: GncGUID, to destinationID: GncGUID,
                            amount: Decimal, date: Date, description: String) -> GncGUID? {
        guard let book,
              let source = book.account(with: sourceID),
              let destination = book.account(with: destinationID)
        else { return nil }
        let txn = Transaction(currency: destination.commodity, datePosted: date, description: description)
        txn.addSplit(account: destination, value: amount)
        txn.addSplit(account: source, value: -amount)
        editing([txn.guid], named: "Add Transfer") {
            book.addTransaction(txn)
        }
        return txn.guid
    }

    // MARK: Snapshots

    /// What an edit invalidates (Performance Review 2, R8).
    ///
    /// `.book` drops everything derived. `.prices` is for an edit that touches
    /// only the price database — a quote refresh, a hand-entered price, an
    /// exchange rate. That changes valuations: the account tree's converted
    /// balances, every report memo, the price editor's rows. It changes no
    /// register row, journal row or search result — those are built from
    /// splits and transaction currencies, never from prices — and it cannot
    /// stale the book's split lookup indexes, so none of that is touched.
    ///
    /// `.kvp` is for an edit to the book's own slots and nothing else — a
    /// favourite, a rule, a budget, a saved search, a schedule's settings
    /// (R8i). No account, transaction, split or price changed, so the account
    /// tree, the register, the search, the journal caches and the lookup
    /// indexes all still stand: none of them reads a slot (the tree values in
    /// the book's base currency, which is the root account's, not a slot's).
    /// The report memos go — budgets, forecasts, planning and report settings
    /// all read slots — and with them anything else keyed on
    /// ``derivedRevision``, which rebuilds as it is next asked for.
    enum RefreshScope { case book, prices, kvp }

    /// What an edit says it changed, so what derives from the book follows it
    /// instead of starting again: the lookup indexes, the tree's balances
    /// (P5.4), the general ledger (P7). An edit that says nothing — `nil` —
    /// means anything, and everything is rebuilt.
    struct EditChanges {
        /// Each transaction the edit touched, as it was — a copy taken before,
        /// or the removed object — and as it is (`nil` once removed). Whole
        /// transactions an edit added have no `before`.
        var transactions: [(before: Transaction?, live: Transaction?)] = []
        /// Accounts changed too: names, types, places in the tree — which
        /// every journal row naming one shows.
        var accounts = false
    }

    nonisolated static let verifiesKeptIndexes =
        ProcessInfo.processInfo.environment["FL_VERIFY_INDEXES"] != nil

    func refreshAll(scope: RefreshScope = .book, changes: EditChanges? = nil) {
        if scope == .book {
            // Splits are added/removed on their transactions inside edit
            // closures, which the book cannot observe — so its lookup indexes
            // are dropped here, unless the edit told the book what it changed
            // (``reindex(_:)``, P5.4), which keeps them current.
            // A book just read from its file has nothing unsaved to forget —
            // an open, a revert, an import that has just been written — and
            // forgetting made the first save after every open rewrite every
            // transaction. An edit that cannot say what it changed always
            // marks the document dirty before it gets here.
            if changes == nil {
                if document?.hasUnsavedChanges == false { book?.dropLookupIndexes() } else { book?.invalidateLookupIndexes() }
            }
            followJournals(changes)
        }
        priceRowCache = nil
        rateRowCache = nil
        derivedRevision &+= 1
        if scope == .book { transactionRevision &+= 1 }
        guard scope != .kvp else { return }
        rebuildAccountTree()
        // `FL_VERIFY_INDEXES=1`: every edit that kept the indexes is checked
        // against a rebuild, and the tree's kept balances against a walk — so
        // a test run finds an edit that changed legs without saying so.
        if Self.verifiesKeptIndexes, scope == .book, changes != nil, let book {
            precondition(book.lookupIndexesMatchRebuild(), "an edit left the lookup indexes stale")
            precondition(treeNativesMatchWalk(), "an edit left the account tree's balances stale")
            precondition(generalLedgerMatchesRebuild(), "an edit left the general ledger stale")
        }
        guard scope == .book else { return }
        refreshRegister()
        // Whichever search is showing has to survive an edit: editing a result
        // from the results table must leave the other results on screen. The
        // find replays its whole pipeline — results are live, and refinements
        // stay in force; see `recomputeFindResults()`.
        Perf.measure("searchReplay") {
            if findQuery != nil { recomputeFindResults() } else { runSearch() }
        }
    }

    /// Marks the document dirty and rebuilds derived state. Records nothing on
    /// the undo stack, so it is *not* how a user's edit gets applied — those go
    /// through ``editing(_:named:)`` and the other scoped edits, which call
    /// this for you.
    func refreshAfterChange(scope: RefreshScope = .book, changes: EditChanges? = nil) {
        document?.markDirty()
        documentStateRevision &+= 1
        refreshAll(scope: scope, changes: changes)
        // A price cannot delete anything a tab shows; a slot can (a saved
        // report a tab holds).
        if scope != .prices { pruneDeadTabs() }
    }

    /// Closes any tab whose subject the book no longer has.
    ///
    /// Here rather than in each delete, because there are a dozen deletes and
    /// only one of them used to clean up — `deleteAccount` cleared the *active*
    /// selection and nothing else, so deleting an account open in another tab
    /// left a tab titled "Account" that showed an empty register until the next
    /// relaunch. Every edit passes through here; a tab is dead the moment its
    /// subject is, whichever command did it and whichever mode was showing.
    func pruneDeadTabs() {
        guard isOpen else { return }
        var changed = false
        // `Array(keys)` because the loop writes back into `tabsByMode`.
        for mode in Array(tabsByMode.keys) {
            let extras = normalisedExtras(in: mode)
            let live = extras.filter { exists($0) }
            guard live.count != extras.count else { continue }
            // Counted in *display* indices from end to end. `activeTabByMode`
            // indexes the strip (``tabs(in:)``), never `tabsByMode`, and the
            // old arithmetic — a position in storage plus one for home — was
            // right only in a mode whose strip begins with the home tab alone.
            // In Investments, where the standing portfolio tabs sit between,
            // deleting an account bounced the user onto a portfolio.
            let before = tabs(in: mode)
            let active = min(max(activeTabByMode[mode] ?? 0, 0), max(before.count - 1, 0))
            let current = before.indices.contains(active) ? before[active] : nil
            tabsByMode[mode] = live
            let after = tabs(in: mode)
            if let current, let landed = after.firstIndex(of: current) {
                // It survived: stay on it, wherever it moved to.
                activeTabByMode[mode] = landed
            } else {
                // It died: land on whatever took its place, or the last tab
                // that outlived it.
                let survivors = before.prefix(active).filter { after.contains($0) }.count
                activeTabByMode[mode] = min(survivors, max(after.count - 1, 0))
            }
            changed = true
        }
        guard changed else { return }
        refreshRegister()
        persistSessionSelection()
    }

    /// Whether the book still has what a selection names. Collection
    /// destinations always do — they are areas, not instances.
    /// Internal, not private, for the same reason the desk-state codec is: this
    /// is the filter that decides whether a restored tab survives, and a case
    /// missing from it drops that tab on every reopen without a word.
    func exists(_ selection: SidebarSelection) -> Bool {
        switch selection {
        case .account(let id): book?.account(with: id) != nil
        case .budget(let id): budgets.contains { $0.id == id }
        case .goal(let id): savingsGoals.contains { $0.id == id }
        case .scheduledTransaction(let id): scheduledTransactions.contains { $0.id == id }
        case .ruleGroup(let id): ruleGroups.contains { $0.id == id }
        case .emergencyRecord(let id): emergencyRecords.contains { $0.id == id }
        case .savedReport(let id): savedReports.contains { $0.id == id }
        case .security(let key): securityCommodity(forKey: key) != nil
        case .portfolio(let id): portfolioAccounts.contains { $0.id == id }
        // A panel tab is always live: it is a form, not a reference to
        // something in the book that could have been deleted.
        case .panel: true
        case .invoice(let id): businessInvoices.contains { $0.guid == id }
        case .customer(let id): businessCustomers.contains { $0.guid == id }
        case .vendor(let id): businessVendors.contains { $0.guid == id }
        case .job(let id): businessJobs.contains { $0.guid == id }
        case .employee(let id): businessEmployees.contains { $0.guid == id }
        case .overviewView(let id): overviewViews.contains { $0.id == id }
        case .dashboard, .generalLedger, .reports, .report, .investments,
             .business, .timeMileage, .planner, .budgets, .goals, .scheduled,
             .plannerDebt, .plannerLifetime, .plannerTax,
             .rules, .emergencyRecords, .auditLog, .overviewCard:
            true
        }
    }

    // MARK: Undo / redo (HIG: every edit must be undoable)
    //
    // Every edit captures what it is about to change *before* changing it, and
    // registers the inverse on the window's UndoManager. Undo re-enters the same
    // wrapper, so the state it replaces is captured in turn — that is what makes
    // redo work, and it means undo and redo are one code path.
    //
    // `editing` copies only the transactions named, which is what keeps the
    // register instant. Every other edit is scoped the same way — accounts,
    // prices, the book's slots, and the transactions an edit adds or removes
    // (`editingPostings`). There is no whole-book snapshot: the GnuCash XML
    // export that business and structural edits took before they ran cost
    // seconds on the reference book, and an import of it to undo them. None
    // holds a baseline between edits, so opening a book pays nothing.

    /// The focused window's undo manager, injected by the root view.
    @ObservationIgnored public weak var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = 25 }
    }

    /// A transaction as it stood before an edit. `state == nil` means it did not
    /// exist — which is what makes undo-of-add and redo-of-delete the same
    /// operation.
    struct TransactionSnapshot {
        let id: GncGUID
        let state: Transaction?
    }

    /// Applies `body` as one undoable edit of the transactions named by `ids`.
    ///
    /// `ids` must name every transaction `body` touches, including any it
    /// creates — generate the guid up front and pass it in. Anything `body`
    /// changes outside those transactions will not be undone.
    func editing(_ ids: [GncGUID], named: LocalizedStringResource, _ body: () -> Void) {
        if isReadOnly { return }   // read-only session: edits are refused (FR-DAT-06)
        auditLog(named, transactions: ids.count)
        let before = ids.map {
            TransactionSnapshot(id: $0, state: book?.transaction(with: $0)?.detachedCopy())
        }
        body()
        refreshAfterChange(changes: EditChanges(transactions: reindex(before)))
        guard isOpen else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            model.editing(ids, named: named) { model.restore(before) }
        }
        undoManager?.setActionName(String(localized: named))
    }

    /// An account's restorable state before an edit — its value fields plus
    /// where it sat in the tree — or `nil` when it did not exist, which makes
    /// undo-of-add and redo-of-delete the same operation, as
    /// ``TransactionSnapshot`` does for transactions. Transactions are not
    /// captured here; an edit that moves postings names them separately
    /// (``editing(accounts:transactions:prices:named:_:)``), so an account edit
    /// never needs a whole-book serialisation.
    struct AccountSnapshot {
        let id: GncGUID
        let state: AccountState?
    }

    struct AccountState {
        /// The live object itself, so an account the edit took out of the tree
        /// goes back with its identity — and its GUID — intact.
        let object: Account
        let name: String
        let type: AccountType
        let code: String
        let accountDescription: String
        let notes: String
        let commodity: Commodity
        let isPlaceholder: Bool
        let isHidden: Bool
        let kvp: KvpFrame           // carries colour and the tax slots
        let parentID: GncGUID?
        let indexInParent: Int
    }

    private func accountSnapshot(_ id: GncGUID) -> AccountSnapshot {
        guard let account = book?.account(with: id) else { return AccountSnapshot(id: id, state: nil) }
        let siblings = account.parent?.children ?? []
        return AccountSnapshot(id: id, state: AccountState(
            object: account, name: account.name, type: account.type, code: account.code,
            accountDescription: account.accountDescription, notes: account.notes,
            commodity: account.commodity, isPlaceholder: account.isPlaceholder,
            isHidden: account.isHidden, kvp: account.kvp,
            parentID: account.parent?.guid,
            indexInParent: siblings.firstIndex { $0 === account } ?? 0))
    }

    /// Applies `body` as one undoable edit of the accounts named by `ids`.
    ///
    /// `ids` must name every account `body` changes (for a cascade, the whole
    /// affected subtree). Only their value fields and tree placement are
    /// captured — transactions and other accounts are not — so an account edit
    /// pays for nothing it does not touch.
    func editingAccounts(_ ids: [GncGUID], named: LocalizedStringResource, _ body: () -> Void) {
        editing(accounts: ids, named: named, body)
    }

    /// Applies `body` as one undoable edit of named accounts and transactions,
    /// and optionally the price database — scoped where the whole-book
    /// snapshot it replaced was not (Performance Review 2, R2: that snapshot
    /// was 6.65 s on the reference book, paid by New Account and Change
    /// Colour alike).
    ///
    /// `accounts` must name every *existing* account `body` changes — for a
    /// deletion, the account and the children it re-parents, parents before
    /// children. Accounts `body` creates need not be named: the account set is
    /// compared before and after, and any newcomer is recorded as "did not
    /// exist", so undoing the edit removes it. `transactions` must name every
    /// transaction `body` touches, including ones it creates. `prices`
    /// snapshots the price database — a value array, free until mutated — for
    /// an edit that records a rate alongside.
    func editing(accounts accountIDs: [GncGUID], transactions transactionIDs: [GncGUID] = [],
                 prices snapshotsPrices: Bool = false, named: LocalizedStringResource, _ body: () -> Void) {
        if isReadOnly { return }   // read-only session: edits are refused (FR-DAT-06)
        auditLog(named, transactions: transactionIDs.isEmpty ? nil : transactionIDs.count)
        let idsBefore = Set(book?.accounts.map(\.guid) ?? [])
        // An account that brings a new security registers its commodity, which
        // removing the account does not undo — so the ones the body adds are
        // unregistered again (when nothing else uses them) on the way back.
        let commoditiesBefore = Set(book?.commodities ?? [])
        var accountsBefore = accountIDs.map { accountSnapshot($0) }
        let transactionsBefore = transactionIDs.map {
            TransactionSnapshot(id: $0, state: book?.transaction(with: $0)?.detachedCopy())
        }
        if snapshotsPrices { book?.beginRecordingPriceChanges() }
        body()
        let priceChanges = snapshotsPrices ? (book?.endRecordingPriceChanges() ?? []) : []
        let created = (book?.accounts.map(\.guid) ?? []).filter {
            !idsBefore.contains($0) && !accountIDs.contains($0)
        }
        accountsBefore += created.map { AccountSnapshot(id: $0, state: nil) }
        let allAccountIDs = accountIDs + created
        refreshAfterChange(changes: EditChanges(transactions: reindex(transactionsBefore),
                                                accounts: !allAccountIDs.isEmpty))
        guard isOpen else { return }
        let snapshots = accountsBefore
        undoManager?.registerUndo(withTarget: self) { model in
            model.editing(accounts: allAccountIDs, transactions: transactionIDs,
                          prices: snapshotsPrices, named: named) {
                // Accounts first: a restored transaction re-resolves its splits'
                // accounts by GUID, so an account the edit removed must be back
                // in the tree before the postings that pointed at it are.
                model.restoreAccounts(snapshots)
                model.restore(transactionsBefore)
                if !priceChanges.isEmpty { model.book?.revertPriceChanges(priceChanges) }
                for commodity in model.book?.commodities ?? [] where !commoditiesBefore.contains(commodity) {
                    _ = model.book?.unregisterCommodity(commodity)
                }
            }
        }
        undoManager?.setActionName(String(localized: named))
    }

    /// Puts snapshotted accounts back as they were, including their tree slot;
    /// re-inserts the ones the edit removed and removes the ones it created.
    private func restoreAccounts(_ snapshots: [AccountSnapshot]) {
        guard let book else { return }
        // Pass 1 — membership. An account the edit removed goes back under its
        // former parent *before* anything is placed relative to it; one the
        // edit created leaves the tree. Callers list parents before children,
        // so a removed subtree comes back top-down.
        for snapshot in snapshots {
            let live = book.account(with: snapshot.id)
            guard let state = snapshot.state else {
                if let live { live.parent?.removeChild(live) }
                continue
            }
            if live == nil {
                let parent = state.parentID.flatMap { book.account(with: $0) } ?? book.rootAccount
                parent.addChild(state.object, at: state.indexInParent)
                // `addChild` is the tree alone; `Book.addAccount` would also
                // have registered the commodity, and a redo of Add Account
                // (whose undo unregistered it) must do the same, or the saved
                // commodity table loses it and the loader guesses a fraction.
                book.registerCommodity(state.object.commodity)
            }
        }
        // Pass 2 — fields and placement, for everything that exists now.
        for snapshot in snapshots {
            guard let state = snapshot.state, let account = book.account(with: snapshot.id) else { continue }
            account.name = state.name
            account.type = state.type
            account.code = state.code
            account.accountDescription = state.accountDescription
            account.notes = state.notes
            account.commodity = state.commodity
            account.isPlaceholder = state.isPlaceholder
            account.isHidden = state.isHidden
            account.kvp = state.kvp
            // Re-parent only if it actually moved, restoring the former slot.
            let parent = state.parentID.flatMap { book.account(with: $0) } ?? book.rootAccount
            if account.parent !== parent
                || (account.parent?.children.firstIndex { $0 === account }) != state.indexInParent {
                parent.addChild(account, at: state.indexInParent)
            }
        }
    }

    /// Scoped undo for an edit of one commodity — a rename, an identifier, a
    /// newly added security. The inverse is replayed rather than a snapshot
    /// restored: the metadata lives on every account and price that uses the
    /// commodity, and `Book.updateCommodityMetadata` is the one way to write
    /// it everywhere. The book's kvp frame rides along for the watch-list
    /// mirror that a rename updates.
    func editingCommodity(_ commodity: Commodity, named: LocalizedStringResource, _ body: () -> Void) {
        if isReadOnly { return }
        auditLog(named)
        let stored = book?.commodities.first { $0 == commodity }
        let kvpBefore = book?.kvp
        body()
        refreshAfterChange()
        guard isOpen, let kvpBefore else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            model.editingCommodity(commodity, named: named) {
                guard let book = model.book else { return }
                if let stored {
                    book.registerCommodity(stored)
                    book.updateCommodityMetadata(stored, fullName: stored.fullName,
                                                 smallestFraction: stored.smallestFraction,
                                                 exchangeCode: stored.exchangeCode ?? "")
                } else {
                    book.unregisterCommodity(commodity)
                }
                book.kvp = kvpBefore
                model.reloadKvpCollections()
            }
        }
        undoManager?.setActionName(String(localized: named))
    }

    /// Runs `body` as one undo step. For a sheet whose Save makes several
    /// model calls, each undoable on its own, so one ⌘Z takes back the save.
    public func groupingUndo(named: LocalizedStringResource, _ body: () -> Void) {
        undoManager?.beginUndoGrouping()
        body()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(String(localized: named))
    }

    /// An edit that adds or removes whole transactions — invoices posted and
    /// paid, schedules posted — undone by taking them out and putting them
    /// back, without the whole-book snapshot these took before (P9c, P9d):
    /// a GnuCash export of the book before the edit, and an import of it on
    /// undo. The transactions are held, not copied — an invoice's posting and
    /// a lot's members point at the very objects, and a copy put back would
    /// leave them pointing at ones no longer in the book. That is sound only
    /// because none of these edits changes a transaction that was already
    /// there. With `business` the business tables are captured too
    /// (``BusinessTables``); with `kvp`, the book's slots, where the
    /// schedules keep their last-posted dates.
    func editingPostings(named: LocalizedStringResource, business: Bool = false, kvp: Bool = false,
                         _ body: () -> Void) {
        if isReadOnly { return }   // read-only session: edits are refused (FR-DAT-06)
        guard let book else { return }
        auditLog(named)
        let tables = business ? book.businessTables() : nil
        let slots = kvp ? book.kvp : nil
        let before = book.transactions
        let commoditiesBefore = Set(book.commodities)
        body()
        let after = book.transactions
        let beforeIDs = Set(before.map(ObjectIdentifier.init))
        let added = after.filter { !beforeIDs.contains(ObjectIdentifier($0)) }
        var removed: [Transaction] = []
        if before.count + added.count != after.count {
            let afterIDs = Set(after.map(ObjectIdentifier.init))
            removed = before.filter { !afterIDs.contains(ObjectIdentifier($0)) }
        }
        let commoditiesAfter = Set(book.commodities)
        let registered = commoditiesAfter.subtracting(commoditiesBefore)
        let dropped = commoditiesBefore.subtracting(commoditiesAfter)
        // Whole transactions only, which the book indexes as it adds and
        // removes them.
        refreshAfterChange(changes: EditChanges(
            transactions: added.map { (before: nil, live: $0) } + removed.map { (before: $0, live: nil) }))
        guard isOpen else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            // An undo belongs to the book it was made in.
            guard model.book === book else { return }
            model.editingPostings(named: named, business: business, kvp: kvp) {
                // By GUID, not by identity: a transaction deleted in the
                // register and brought back by its undo is a copy, and the
                // original is not in the book to take out — undoing a
                // payment then rewound the invoice and left the money.
                for transaction in added {
                    if let live = book.transaction(with: transaction.guid) { book.removeTransaction(live) }
                }
                for transaction in removed where book.transaction(with: transaction.guid) == nil {
                    book.restoreTransaction(transaction)
                }
                if let tables { book.restore(tables) }
                for commodity in dropped { book.registerCommodity(commodity) }
                for commodity in registered { book.unregisterCommodity(commodity) }
                if let slots {
                    book.kvp = slots
                    // The published collections mirror kvp slots; without a
                    // reload the next persist would re-write the undone values.
                    model.reloadKvpCollections()
                }
            }
        }
        undoManager?.setActionName(String(localized: named))
    }

    /// Tells the book which transactions an edit changed in place, and what
    /// their legs were before, so its lookup indexes stay current instead of
    /// being dropped and rebuilt for the whole book (P5.4). A transaction the
    /// edit added or removed, the book filed or unfiled itself.
    @discardableResult
    private func reindex(_ snapshots: [TransactionSnapshot]) -> [(before: Transaction?, live: Transaction?)] {
        guard let book else { return [] }
        // Re-filing is a pass over each touched account's legs per
        // transaction. Past a few dozen transactions — a reconcile, an
        // import, a bulk edit — one rebuild on the next lookup is cheaper;
        // what the save has to write is still recorded edit by edit. Each is
        // looked up first: a lookup after the drop would rebuild at once.
        let found = snapshots.map { ($0, book.transaction(with: $0.id)) }
        if snapshots.count > Self.refileLimit { book.dropLookupIndexes() }
        return found.map { snapshot, live in
            if let live { book.reindex(live, previous: snapshot.state?.splits ?? []) }
            return (snapshot.state, live)
        }
    }

    /// More transactions than this in one edit are not re-filed one by one;
    /// the lookup indexes are rebuilt instead (``reindex(_:)``).
    static let refileLimit = 64

    /// Puts snapshotted transactions back as they were.
    private func restore(_ snapshot: [TransactionSnapshot]) {
        guard let book else { return }
        for entry in snapshot {
            let live = book.transaction(with: entry.id)
            guard let state = entry.state else {
                if let live { book.removeTransaction(live) }
                continue
            }
            // Copy again so the snapshot itself stays pristine and can be
            // restored a second time, and re-resolve accounts against the book
            // that is live now — a whole-book undo swaps in a fresh object
            // graph, which leaves an older snapshot holding accounts the book
            // no longer knows.
            let restored = state.detachedCopy()
            for split in restored.splits {
                split.account = split.account.flatMap { book.account(with: $0.guid) }
            }
            guard let live else {
                book.addTransaction(restored)
                continue
            }
            // Refill in place rather than remove-and-re-add, so the transaction
            // keeps its identity and its position in the book.
            live.currency = restored.currency
            live.datePosted = restored.datePosted
            live.dateEntered = restored.dateEntered
            live.number = restored.number
            live.transactionDescription = restored.transactionDescription
            live.notes = restored.notes
            live.kvp = restored.kvp
            for split in Array(live.splits) { live.removeSplit(split) }
            for split in restored.splits { live.addSplit(split) }
        }
    }

    /// Clears the undo stack (call when a book is opened/created/closed).
    func resetUndoStack() {
        undoManager?.removeAllActions(withTarget: self)
    }

    private func rebuildAccountTree() {
        Perf.measure("rebuildAccountTree") { rebuildAccountTreeBody() }
    }

    private func rebuildAccountTreeBody() {
        guard let book else { accountTree = []; return }
        // Native balances for every account, kept from the last build and
        // recomputed only for the accounts whose legs changed since — each
        // from its own legs, as GnuCash recomputes an account marked
        // `balance_dirty` (P5.4). The whole book is walked only when the book
        // cannot say what changed. Then one conversion per account, rolled up
        // the tree.
        let natives: [ObjectIdentifier: Decimal]
        if treeNativesBook === book, let changed = book.takeChangedAccounts() {
            var kept = treeNatives
            for account in changed { kept[ObjectIdentifier(account)] = book.quantityTotal(of: account) }
            natives = kept
        } else {
            _ = book.takeChangedAccounts()      // what changed is in the walk
            natives = book.balancesByAccount()
        }
        treeNatives = natives
        treeNativesBook = book
        var converted: [ObjectIdentifier: Decimal] = [:]
        for account in book.accounts {
            let native = natives[ObjectIdentifier(account)] ?? 0
            if let value = convertedValue(native, of: account, in: reportCurrency, book: book) {
                converted[ObjectIdentifier(account)] = value
            }
        }
        accountTree = book.rootAccount.children.map {
            node(for: $0, book: book, natives: natives, converted: converted)
        }
    }

    /// Every account's native balance as the tree last built it, and the
    /// book that was for (see ``rebuildAccountTreeBody()``).
    @ObservationIgnored private var treeNatives: [ObjectIdentifier: Decimal] = [:]
    @ObservationIgnored private weak var treeNativesBook: Book?

    /// Whether the tree's kept balances are what a walk of the book gives —
    /// for tests of the accounts recomputed edit by edit.
    func treeNativesMatchWalk() -> Bool {
        guard let book, treeNativesBook === book else { return true }
        let walked = book.balancesByAccount()
        let keys = Set(walked.keys).union(treeNatives.keys)
        return keys.allSatisfy { (treeNatives[$0] ?? 0) == (walked[$0] ?? 0) }
    }

    /// `native` (an account's own balance, in its own commodity) valued in
    /// `currency` — the same rules as `Book.convertedBalance`, but without
    /// re-deriving the native balance.
    private func convertedValue(_ native: Decimal, of account: Account,
                                in currency: Commodity, book: Book) -> Decimal? {
        if account.commodity == currency { return native }
        if native == 0 { return 0 }
        if account.commodity.namespace == .currency {
            return book.convert(native, from: account.commodity, to: currency)
        }
        guard let unit = book.securityUnitValue(account.commodity, in: currency) else { return nil }
        return native * unit
    }

    private func node(for account: Account, book: Book,
                      natives: [ObjectIdentifier: Decimal],
                      converted: [ObjectIdentifier: Decimal]) -> AccountNode {
        let children = account.children.map {
            node(for: $0, book: book, natives: natives, converted: converted)
        }
        let amount: Decimal
        let code: String
        if children.isEmpty {
            // A leaf shows its own balance in its own commodity — shares for a
            // security, cash for a currency account (as GnuCash does).
            amount = account.commodity.round(natives[ObjectIdentifier(account)] ?? 0)
            code = account.commodity.mnemonic
        } else {
            // A parent shows the whole subtree valued in the base currency.
            // Each account is converted individually (securities at market,
            // foreign currencies at the FX rate) then summed — converting the
            // mixed-commodity quantity sum would be meaningless.
            let base = reportCurrency
            amount = subtreeValue(of: account, in: base, converted: converted)
            code = base.mnemonic
        }
        return AccountNode(
            id: account.guid,
            name: account.name,
            fullName: account.fullName,
            typeName: account.type.rawValue.capitalized,
            balance: amount,
            currencyCode: code,
            isPlaceholder: account.isPlaceholder,
            isHidden: account.isHidden,
            color: account.color,
            children: children.isEmpty ? nil : children
        )
    }

    /// The base-currency value of an account and all its descendants, summing
    /// each account's individually-converted balance (`FR-INV-06`).
    private func subtreeValue(of account: Account, in currency: Commodity,
                              converted: [ObjectIdentifier: Decimal]) -> Decimal {
        var total = Decimal(0)
        for descendant in [account] + account.descendants {
            if let value = converted[ObjectIdentifier(descendant)] { total += value }
        }
        return currency.round(total)
    }

    /// One-entry memo for the Basic/Auto-Split table's row array. The table asks
    /// for its rows on every body pass — every click and every field focus —
    /// and mapping thousands of RegisterRows into AutoSplitRows each time, then
    /// handing SwiftUI a brand-new array to diff, is what made the register
    /// feel sluggish. Returning the identical array instance lets the diff
    /// short-circuit. Dropped whenever the register rows are rebuilt.
    @ObservationIgnored private var autoSplitRowsCache: (key: GncGUID?, all: Bool, rows: [AutoSplitRow])?

    func cachedAutoSplitRows(expanding key: GncGUID?, all: Bool,
                             build: () -> [AutoSplitRow]) -> [AutoSplitRow] {
        if let cached = autoSplitRowsCache, cached.key == key, cached.all == all {
            return cached.rows
        }
        let rows = build()
        autoSplitRowsCache = (key, all, rows)
        return rows
    }

    private func refreshRegister() {
        Perf.measure("refreshRegister") { refreshRegisterBody() }
    }

    private func refreshRegisterBody() {
        // The journal styles honour the same sort/filter/subaccounts settings;
        // their caches note the settings they were built under and go when
        // asked under others (`journalCachesFollowSettings()`), and an edit
        // patches or drops them in `followJournals(_:)` — so selecting an
        // account no longer throws away a general ledger nothing changed.
        autoSplitRowsCache = nil
        // So is the rotor's, and it is keyed on `derivedRevision` — which does
        // not move when only the *register* changes. Selecting another account
        // (or a new sort, filter, or subaccount setting) replaces
        // `registerRows` wholesale while that revision stands still, so the
        // VoiceOver Unreconciled rotor went on offering the previous account's
        // rows, keyed on split GUIDs no longer in this register at all.
        unreconciledRowsRevision = -1
        guard let book, let id = selectedAccountID, let account = book.account(with: id) else {
            registerRows = []
            registerSplitByTransaction = [:]
            registerSummary = nil
            lastRegisterBuildKey = nil
            // No bump: the whole-book register keys its rows on
            // `transactionRevision`, so arriving at All Transactions with no
            // edit in between rebuilds nothing.
            return
        }
        let buildKey = RegisterBuildKey(account: id, revision: derivedRevision, sort: registerSort,
                                        reversed: registerSortReversed, filter: registerFilter,
                                        subaccounts: registerIncludesSubaccounts,
                                        day: Calendar.current.startOfDay(for: Date()))
        if buildKey == lastRegisterBuildKey, !registerRows.isEmpty { return }
        lastRegisterBuildKey = buildKey
        registerRevision &+= 1
        // GnuCash's Open Subaccounts shows the subtree's postings in one
        // register. The accounts, not just the one, decide which splits belong.
        let focus = registerIncludesSubaccounts ? [account] + account.descendants : [account]

        // Canonical order first, and the balance with it: a row's balance is the
        // account's balance as of that posting, so it must be accumulated over
        // *every* split in date order — before any filter hides rows and before
        // any sort moves them. GnuCash does the same: sort its register by
        // amount and each row still shows the balance it had in date order.
        // Through the per-account index, not every split in the book: the old
        // gather was 13 ms of O(book) for an O(account) question on every
        // click and edit (Performance Review 2, R7).
        let splits = focus
            .flatMap { book.splits(for: $0) }
            .sorted { a, b in
                // GnuCash's canonical order, so same-date rows and their running
                // balances match its register (date, num/action, entered, …).
                guard let ta = a.transaction, let tb = b.transaction else {
                    return b.transaction != nil
                }
                return Transaction.canonicalOrder(ta, action: a.action, tb, action: b.action) < 0
            }

        // A running balance adds quantities up, and a quantity means "so many of
        // the account's own commodity". Across a subtree holding more than one
        // of them that sum is not a number of anything — 10 BHP shares plus $10
        // is 20 of nothing. `Book.balance(includingDescendants:)` carries the
        // same caveat in its own doc. So the column is dropped for a mixed
        // subtree rather than filled with a figure that would be wrong.
        let balancesAreMeaningful = Set(focus.map(\.commodity)).count == 1

        // The status strip's four totals accumulate in this same pass. They
        // used to be a computed property calling `book.balance` three times —
        // three full-book scans on every SwiftUI body pass of the register.
        let now = Date()
        var future = Decimal(0), present = Decimal(0)
        var cleared = Decimal(0), reconciled = Decimal(0)

        var running = Decimal(0)
        let rows = splits.map { split in
            // A voided split still shows, with its amount, but must not move the
            // balance — `Book.balance` excludes it, so counting it here made the
            // register's last running balance disagree with the figure the
            // sidebar and every report show for the same account.
            if split.reconcileState != .voided {
                running += split.quantity
                future += split.quantity
                if (split.transaction?.datePosted ?? .distantPast) <= now {
                    present += split.quantity
                }
                // Mirrors `Book.matches`: cleared counts everything not
                // unreconciled; reconciled counts reconciled and frozen.
                if split.reconcileState != .notReconciled { cleared += split.quantity }
                if split.reconcileState == .reconciled || split.reconcileState == .frozen {
                    reconciled += split.quantity
                }
            }
            return RegisterRow(
                id: split.guid,
                date: split.transaction?.datePosted ?? Date(timeIntervalSince1970: 0),
                dateEntered: split.transaction?.dateEntered ?? Date(timeIntervalSince1970: 0),
                number: split.transaction?.number ?? "",
                description: split.transaction?.transactionDescription ?? "",
                transfer: transferDescription(for: split, in: account),
                reconcile: split.reconcileState.rawValue,
                memo: split.memo,
                notes: split.transaction?.notes ?? "",
                action: split.action,
                // In a subtree register a row belongs to whichever account it
                // posted to, which is the one thing the single-account register
                // never had to say.
                accountName: registerIncludesSubaccounts ? (split.account?.name ?? "") : "",
                amount: split.quantity,
                runningBalance: balancesAreMeaningful ? running : nil,
                hasDocument: split.transaction?.documentLink != nil,
                // Read from the two objects already in hand, so a register of
                // 46k rows pays nothing for a fact that is nil on almost all
                // of them.
                foreignCurrencyCode: split.transaction.map { txn in
                    txn.currency == split.account?.commodity ? nil : txn.currency.mnemonic
                } ?? nil
            )
        }
        registerRows = ordered(filtered(rows))
        // First row per transaction, for `registerSplitID(ofTransaction:)` —
        // a dictionary built once per rebuild where the iPad's selection path
        // scanned the rows per selected row, quadratic on select-all
        // (Performance Review 2, R10).
        registerSplitByTransaction = Dictionary(
            registerRows.compactMap { row in transactionID(ofSplit: row.id).map { ($0, row.id) } },
            uniquingKeysWith: { first, _ in first })

        // Same gate as the running balance: a mixed-commodity sum means
        // nothing, so the strip is withheld rather than wrong. The filter is
        // deliberately *not* applied — hidden rows still moved the money.
        if balancesAreMeaningful {
            let commodity = account.commodity
            registerSummary = RegisterSummary(
                present: commodity.round(present),
                future: commodity.round(future),
                cleared: commodity.round(cleared),
                reconciled: commodity.round(reconciled),
                currencyCode: commodity.mnemonic,
                isSecurity: commodity.namespace != .currency)
        } else {
            registerSummary = nil
        }
    }

    /// Whether the current register can show a running balance. False for a
    /// subtree spanning more than one commodity, where the sum means nothing.
    public var registerHasBalances: Bool {
        registerRows.first?.runningBalance != nil || registerRows.isEmpty
    }

    /// Whether the selected account has anything under it — Open Subaccounts is
    /// meaningless for a leaf.
    public var selectedAccountHasChildren: Bool {
        guard let book, let id = selectedAccountID else { return false }
        return !(book.account(with: id)?.children.isEmpty ?? true)
    }

    /// GnuCash's register status strip. `nil` when nothing is selected, or when
    /// a subtree register spans more than one commodity (the totals would be a
    /// sum of unlike units — the same reason the running balance is withheld).
    public struct RegisterSummary: Sendable {
        /// Balance as of today — future-dated postings excluded.
        public var present: Decimal
        /// Balance including future-dated postings.
        public var future: Decimal
        /// Balance of cleared and reconciled splits.
        public var cleared: Decimal
        /// Balance of reconciled splits only.
        public var reconciled: Decimal
        public var currencyCode: String
        /// A holding measured in shares, not currency — labels adapt.
        public var isSecurity: Bool
        /// Present and future differ, so a future row exists worth showing.
        public var hasFuture: Bool { present != future }
    }

    /// Snapshotted by ``refreshRegister()`` in the same pass that builds the
    /// rows. As a computed property this cost three full-book `balance` scans
    /// per SwiftUI body pass; as a snapshot it costs nothing to read.
    public private(set) var registerSummary: RegisterSummary?

    /// Hides rows the filter excludes. Balances are already fixed, so a hidden
    /// split still counts toward the rows around it — as it must: the money
    /// moved whether or not you are looking at it.
    private func filtered(_ rows: [RegisterRow]) -> [RegisterRow] {
        let filter = registerFilter
        guard !filter.isShowingEverything else { return rows }
        let calendar = Calendar.current
        let start = filter.startDate.map { calendar.startOfDay(for: $0) }
        let end = filter.endDate.map { calendar.startOfDay(for: $0) }
        return rows.filter { row in
            guard let state = ReconcileState(rawValue: row.reconcile),
                  filter.statuses.contains(state) else { return false }
            // Whole-day bounds, inclusive at both ends — a range of "the 3rd to
            // the 3rd" has to include the 3rd.
            let day = calendar.startOfDay(for: row.date)
            if let start, day < start { return false }
            if let end, day > end { return false }
            return true
        }
    }

    /// Re-orders rows for display only.
    private func ordered(_ rows: [RegisterRow]) -> [RegisterRow] {
        let sorted: [RegisterRow]
        switch registerSort {
        case .standard:
            sorted = rows   // already in canonical order
        case .date:
            sorted = rows.sorted { $0.date < $1.date }
        case .dateEntered:
            sorted = rows.sorted { $0.dateEntered < $1.dateEntered }
        case .number:
            sorted = rows.sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
        case .amount:
            sorted = rows.sorted { $0.amount < $1.amount }
        case .description:
            sorted = rows.sorted {
                $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending
            }
        case .memo:
            sorted = rows.sorted {
                $0.memo.localizedCaseInsensitiveCompare($1.memo) == .orderedAscending
            }
        }
        return registerSortReversed ? sorted.reversed() : sorted
    }

    private func transferDescription(for split: Split, in account: Account) -> String {
        guard let others = split.transaction?.splits.filter({ $0 !== split }) else { return "" }
        let names = others.compactMap { $0.account?.name }
        if names.count == 1 { return names[0] }
        if names.count > 1 { return String(localized: "— Split —") }
        return ""
    }

    // MARK: Helpers

    private func replaceBook(of doc: FinvestLensDocument, with book: Book) throws {
        // Swap the imported book in wholesale. A piecemeal copy of only
        // commodities/accounts/transactions silently dropped the price
        // database, book-level KVP slots, and the imported book GUID —
        // losing 100k+ prices from a real GnuCash import.
        doc.replaceBook(book)
        try doc.save()
    }
}

/// Parses a GnuCash file and writes it into a fresh document, off the main
/// actor — the counterpart to ``FinvestLensDocument/load(at:breakStaleLock:progress:)``
/// for import. `Book` is deliberately not `Sendable` (Architecture ADR), so the
/// whole pipeline runs in one isolation domain and the result crosses back to
/// the caller as a `sending` value, same as opening a book.
///
/// `progress` sees the whole import as one bar: parsing the XML is the first
/// half, writing the parsed book into the fresh document the second. Neither
/// half is measured against the other (Interchange's parse and Persistence's
/// write are different kinds of work), so the split is an even 50/50 rather
/// than a claimed measurement.
@DocumentLoader
private func performGnuCashImport(
    source: URL, destination: URL, breakStaleLock: Bool = false,
    progress: @escaping @Sendable (BookLoadProgress) -> Void
) throws -> sending (document: FinvestLensDocument, summary: ImportSummary) {
    let result = try GnuCashXMLImporter.importBook(from: source) { parsed in
        progress(BookLoadProgress(stage: mapImportStage(parsed.stage),
                                  completed: parsed.completed, total: parsed.total,
                                  fraction: parsed.fraction * 0.5, operation: .parsing))
    }
    let doc = try FinvestLensDocument.create(at: destination,
                                             baseCurrency: result.book.commodities.first ?? .aud,
                                             breakStaleLock: breakStaleLock)
    doc.replaceBook(result.book)
    try doc.save { written in
        progress(BookLoadProgress(stage: written.stage, completed: written.completed,
                                  total: written.total,
                                  fraction: 0.5 + written.fraction * 0.5, operation: written.operation))
    }
    return (doc, result.summary)
}

/// `GnuCashImportProgress` (Interchange) has no notion of `BookLoadProgress`'s
/// `.finishing` stage — it only ever reports the three it counts elements for.
private func mapImportStage(_ stage: GnuCashImportStage) -> BookLoadProgress.Stage {
    switch stage {
    case .accounts: .accounts
    case .transactions: .transactions
    case .prices: .prices
    }
}
