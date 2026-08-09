//
//  Views.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import TipKit
import UniformTypeIdentifiers
import FinvestLensEngine
import FinvestLensIntelligence
import FinvestLensPersistence
#if os(macOS)
import AppKit

/// Direct NSOpenPanel wrapper for macOS. SwiftUI's `.fileImporter` does not
/// reliably present in this app's window setup (menu-triggered bindings are
/// dropped), so macOS uses the same AppKit-panel pattern as DocumentDialogs;
/// iOS keeps `.fileImporter`.
@MainActor
enum MacFilePanel {
    static func open(types: [UTType], title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openMultiple(types: [UTType], title: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
#endif

extension View {
    /// A checkbox toggle style on macOS; the platform default (a switch) on iOS,
    /// where `.checkbox` is unavailable.
    @ViewBuilder func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}

/// A GnuCash XML file for `.fileExporter` (export only).
struct GnuCashFileDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "gnucash") ?? .xml
    static var readableContentTypes: [UTType] { [contentType, .xml] }

    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A Ledger 3 journal for `.fileExporter` (`FR-XIO-10`, export only).
struct LedgerFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// The three whole-book export chains (GnuCash XML, Ledger journal, CSV),
/// lifted out of the root view's body: each is a request flag → document →
/// `fileExporter` pair, and inline they pushed the body past the
/// type-checker's budget.
private struct FileExportModifiers: ViewModifier {
    @Bindable var model: AppModel
    @Binding var exportDocument: GnuCashFileDocument?
    @Binding var showingExport: Bool
    @Binding var ledgerDocument: LedgerFileDocument?
    @Binding var showingLedgerExport: Bool
    @Binding var ledgerFilename: String
    @Binding var csvDocument: CSVFileDocument?
    @Binding var showingCSVExport: Bool
    @Binding var csvFilename: String

    private var bookName: String {
        model.documentURL?.deletingPathExtension().lastPathComponent ?? "FinvestLens"
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: model.exportRequested) {
                guard model.exportRequested else { return }
                model.exportRequested = false
                guard let data = model.gnuCashExportData() else { return }
                exportDocument = GnuCashFileDocument(data: data)
                showingExport = true
            }
            .fileExporter(isPresented: $showingExport, document: exportDocument,
                          contentType: GnuCashFileDocument.contentType,
                          defaultFilename: "Book") { _ in
                exportDocument = nil
            }
            .onChange(of: model.ledgerExportRequested) {
                guard model.ledgerExportRequested else { return }
                model.ledgerExportRequested = false
                guard let text = model.ledgerExportText() else { return }
                ledgerFilename = bookName + ".ledger"
                ledgerDocument = LedgerFileDocument(text: text)
                showingLedgerExport = true
            }
            .fileExporter(isPresented: $showingLedgerExport, document: ledgerDocument,
                          contentType: .plainText,
                          defaultFilename: ledgerFilename) { _ in
                ledgerDocument = nil
            }
            .onChange(of: model.csvExportRequest) {
                guard let kind = model.csvExportRequest else { return }
                model.csvExportRequest = nil
                csvFilename = kind.filename(book: bookName)
                csvDocument = CSVFileDocument(text: model.csvExport(kind))
                showingCSVExport = true
            }
            .fileExporter(isPresented: $showingCSVExport, document: csvDocument,
                          contentType: .commaSeparatedText,
                          defaultFilename: csvFilename) { _ in
                csvDocument = nil
            }
    }
}

/// A UTF-8 CSV file for `.fileExporter` (`FR-XIO-06`, export only).
struct CSVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Embedded destinations

extension EnvironmentValues {
    /// True when a view that was designed as a modal sheet is instead shown
    /// inline as a sidebar destination — it should then hide its Done/Cancel
    /// dismissal chrome and drop its sheet-sizing frame.
    @Entry public var isEmbeddedDestination: Bool = false
}

// MARK: - Formatting

enum AmountFormat {
    static func string(_ value: Decimal, code: String) -> String {
        value.formatted(.currency(code: code))
    }

    /// "[redacted]" / "$120k" — deck callouts breathe better compact. One
    /// implementation (both review decks carried byte-identical private
    /// copies, each with a `.first`-character symbol hack that printed
    /// "C[redacted]" for CHF and "A[redacted]" for a foreign-locale AUD).
    static func compact(_ value: Decimal, code: String) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        // The full localized symbol: everything before the first digit of a
        // formatted zero ("A$0.00" → "A$", "CHF 0.00" → "CHF ").
        let zero = string(0, code: code)
        let symbol = String(zero.prefix { !$0.isNumber })
        let magnitude = abs(double)
        let sign = double < 0 ? "−" : ""
        switch magnitude {
        case 1_000_000...:
            return "\(sign)\(symbol)\(String(format: "%.2f", magnitude / 1_000_000))m"
        case 10_000...:
            return "\(sign)\(symbol)\(String(format: "%.0f", magnitude / 1_000))k"
        default:
            return "\(sign)\(string(abs(value), code: code))"
        }
    }

    /// A VoiceOver-friendly reading of a signed money value: the magnitude in
    /// words plus "debit"/"credit", so a dense numeric cell isn't read as a
    /// bare stream of digits with an ambiguous minus sign.
    static func spoken(_ value: Decimal, code: String) -> String {
        let money = abs(value).formatted(.currency(code: code))
        if value == 0 { return money }
        return "\(money), \(value < 0 ? "debit" : "credit")"
    }
}

/// Applies keyboard focus a beat after a sheet finishes presenting, so very
/// fast input (or automation) can't precede the field gaining focus.
@MainActor
func focusSoon(_ apply: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(120))
        apply()
    }
}

// MARK: - Lock screen

/// Gates a locked book behind device authentication (`NFR-07`).
public struct LockView: View {
    @Bindable var model: AppModel
    @State private var failed = false
    @Environment(\.appFontScale) private var appFontScale
    private var iconSize: CGFloat { 48 * appFontScale }

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: iconSize)).foregroundStyle(.tint)
            Text("This book is locked").scaledFont(.title2, weight: .bold)
            Text("Authenticate to view your accounts.").foregroundStyle(.secondary)
            Button {
                Task { failed = !(await model.unlock()) }
            } label: {
                Label("Unlock", systemImage: "touchid").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            if failed {
                Text("Authentication failed. Try again.").scaledFont(.caption).foregroundStyle(.red)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.unlock() }   // prompt immediately on appear
    }
}

/// The bar + caption shared by ``OpeningBookView`` and ``ImportingBookView`` —
/// both watch a ``BookLoadProgress`` fill in from off the main actor, and
/// differ only in title and the indeterminate-phase caption; the stage label
/// ("Reading transactions"/"Writing prices"/…) is already in the progress.
///
/// The bar is determinate once the operation has sized the book, and
/// indeterminate until then: the first report cannot arrive before the row
/// counts are known, and a bar sitting at zero says "stuck" where a spinner
/// says "working".
private struct BookProgressView: View {
    let title: String
    let indeterminateDetail: String
    let progress: BookLoadProgress?

    /// "Reading transactions… 12,000 of 46,553" — the count is what makes the
    /// wait legible: it says the book is big, not that the app is hung.
    private var detail: String {
        guard let progress else { return indeterminateDetail }
        guard progress.total > 0 else { return progress.label + "…" }
        return "\(progress.label)… \(progress.completed.formatted(.number)) of \(progress.total.formatted(.number))"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let progress {
                ProgressView(value: progress.fraction, total: 1)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
                    // No implicit animation. SwiftUI would ease the fill toward
                    // each new value over ~0.25s, and the main actor goes busy
                    // the instant the read ends — so the last ease never
                    // finishes and the bar strands part-way (measured: it sat at
                    // 93% under "102,706 of 102,706"). Painting the reported
                    // number is both honest and what actually shows up.
                    .animation(nil, value: progress.fraction)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: 320)
            }
            Text(title)
                .scaledFont(.title3, weight: .semibold)
            Text(detail)
                .foregroundStyle(.secondary)
                .scaledFont(.callout)
                .monospacedDigit()
                .animation(nil, value: detail)   // the digits update, not slide
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown while a book is being read. The read runs off the main actor, so this
/// view actually animates — the point of it is that a large book no longer looks
/// like a click that did nothing.
public struct OpeningBookView: View {
    let url: URL
    let progress: BookLoadProgress?

    public init(url: URL, progress: BookLoadProgress? = nil) {
        self.url = url
        self.progress = progress
    }

    private var bookName: String { url.deletingPathExtension().lastPathComponent }

    public var body: some View {
        BookProgressView(title: "Opening \(bookName)…",
                         indeterminateDetail: "Reading accounts, transactions and prices.",
                         progress: progress)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Opening \(bookName)")
            .accessibilityValue(progress.map { "\(Int($0.fraction * 100)) percent" } ?? "")
    }
}

/// Shown while a GnuCash file is being imported: parsing the XML and writing
/// the parsed book into a fresh document are each sized and instrumented —
/// see ``GnuCashImportProgress``/``ParseReporter`` and
/// ``SQLiteDocumentStore/write(_:progress:)`` — and shown end to end as one
/// bar (parsing is the first half, writing the second).
public struct ImportingBookView: View {
    let url: URL
    let progress: BookLoadProgress?

    public init(url: URL, progress: BookLoadProgress? = nil) {
        self.url = url
        self.progress = progress
    }

    private var bookName: String { url.lastPathComponent }

    public var body: some View {
        BookProgressView(title: "Importing \(bookName)…",
                         indeterminateDetail: "Parsing the GnuCash file.",
                         progress: progress)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Importing \(bookName)")
            .accessibilityValue(progress.map { "\(Int($0.fraction * 100)) percent" } ?? "")
    }
}

// MARK: - Root

/// The main document view: accounts sidebar + register (or search results).
/// Tool panels are routed through ``AppModel/presentedPanel`` so the menu bar
/// and toolbar share one entry point per panel.
public struct FinvestLensRootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingExport = false
    @State private var exportDocument: GnuCashFileDocument?
    @State private var ledgerDocument: LedgerFileDocument?
    @State private var showingLedgerExport = false
    @State private var ledgerFilename = "Book.ledger"
    @State private var showingCSVExport = false
    @State private var csvDocument: CSVFileDocument?
    @State private var csvFilename = "Export"
    @State private var importPayload: ImportPayload?
    @State private var offeredOnboarding = false
    @State private var smartPayload: SmartImportPayload?
    @State private var statementProgress: (done: Int, total: Int)?
    @State private var statementError: String?

    public init(model: AppModel) {
        self.model = model
    }

    /// The detail pane: search results, or the selected sidebar destination.
    /// Areas that used to be modal sheets are shown inline here (HIG).
    @ViewBuilder
    private var detailPane: some View {
        if model.isSearching {
            SearchResultsView(model: model)
        } else {
            destinationView
                // Areas that were modal sheets suppress their Done/sheet chrome
                // via this flag when shown inline.
                .environment(\.isEmbeddedDestination, true)
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.sidebarSelection ?? .dashboard {
        case .dashboard: DashboardView(model: model)
        case .account: RegisterView(model: model)
        case .reports: ReportsHome(model: model)
        case .generalLedger: GeneralLedgerView(model: model)
        case .budgets: BudgetView(model: model)
        case .scheduled: ScheduledView(model: model)
        case .rules: RulesView(model: model)
        case .goals: GoalsView(model: model)
        case .prices: PricesView(model: model)
        case .business: BusinessHub(model: model)
        case .timeMileage: TimeMileageView(model: model)
        case .planner: PlanningView(model: model)
        case .emergencyRecords: EmergencyRecordsView(model: model)
        }
    }

    public var body: some View {
        NavigationSplitView {
            AccountsSidebar(model: model)
                .navigationTitle("Accounts")
        } detail: {
            // Editing an existing transaction happens in the register row
            // itself (see `RegisterView`), not in a pane beside it: the row
            // opens out into its splits and its cells become fields. A pane
            // here was a second sidebar competing with the attachments panel,
            // and as a split-view column it widened the *window* to make room —
            // off the side of the display, where the editor could not be seen.
            detailPane
        }
        .overlay(alignment: .bottom) { StatusOverlay(model: model) }
        .searchable(text: $model.searchQuery, prompt: "Search transactions")
        .searchSuggestions {
            let trimmed = model.searchQuery.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                ForEach(model.savedSearches) { search in
                    Label(search.name, systemImage: "bookmark")
                        .searchCompletion(search.query)
                        .contextMenu {
                            Button("Delete Saved Search", role: .destructive) {
                                model.deleteSavedSearch(search.id)
                            }
                        }
                }
            } else {
                Button {
                    model.presentedPanel = .saveSearch
                } label: {
                    Label("Save This Search…", systemImage: "bookmark.badge.plus")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if model.externalChangePending {
                ExternalChangeBanner(model: model)
            }
        }
        .toolbar {
            // Primary create actions (the rest live in the menu bar). Areas
            // (Dashboard, Reports, Budgets, …) are now in the sidebar, so they
            // no longer need toolbar buttons. Pinned leading (redesign 6.1):
            // `[+ New ▾] [⬇ Import ▾] … [Search]` — never behind ».
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    Button("New Transaction…", systemImage: "plus.circle") {
                        model.presentedPanel = .newTransaction
                    }
                    .disabled(model.postableAccounts.count < 2)
                    Button("New Account…", systemImage: "plus.rectangle.on.folder") {
                        model.presentedPanel = .newAccount
                    }
                    // Stock Transaction and Currency Transfer are guided
                    // *transaction editors*, not top-level app actions: they
                    // are reached from the transaction area (the Transaction
                    // menu and the register's context menu) and from the Book
                    // menu, which is where HIG *Toolbars* (macOS) requires
                    // every command to exist anyway.
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("Create a transaction or account")
            }
        }
        .sheet(item: $model.presentedPanel) { panel in
            switch panel {
            case .newAccount: NewAccountSheet(model: model)
            case .newTransaction: TransactionEditorSheet(model: model)
            case .stockTransaction: StockTransactionSheet(model: model)
            case .currencyTransfer: CurrencyTransferSheet(model: model)
            case .saveSearch: SaveSearchSheet(model: model)
            case .onboarding: OnboardingSheet(model: model)
            case .reconcile:
                if let id = model.selectedAccountID {
                    ReconcileView(model: model, accountID: id)
                }
            case .autoCategorize: AutoCategorizeSheet(model: model)
            case .bulkEdit: BulkEditSheet(model: model)
            case .matchAttachments: MatchAttachmentsSheet(model: model)
            case .linkedDocuments: LinkedDocumentsView(model: model)
            case .loanCalculator: LoanCalculatorView(model: model)
            case .closeBook: CloseBookView(model: model)
            case .taxOptions: TaxOptionsView(model: model)
            case .auditLog: AuditLogSheet(model: model)
            case .find: FindSheet(model: model)
            case .findAccount: FindAccountSheet(model: model)
            }
        }
        #if os(macOS)
        // macOS: AppKit panels — .fileImporter does not present reliably here.
        .onChange(of: model.bankImportRequested) {
            guard model.bankImportRequested else { return }
            model.bankImportRequested = false
            // Deferred out of the view-update transaction: running a modal
            // panel inside it is silently dropped when triggered from a menu.
            Task { @MainActor in
                if let url = MacFilePanel.open(types: [.commaSeparatedText, .text, .pdf, .data],
                                               title: "Choose a bank file (CSV, QIF, OFX, MT940, CAMT or PDF)") {
                    loadBankFile(url)
                }
            }
        }
        .onChange(of: model.smartImportRequested) {
            guard model.smartImportRequested else { return }
            model.smartImportRequested = false
            Task { @MainActor in
                let urls = MacFilePanel.openMultiple(
                    types: [.pdf],
                    title: "Choose statements, dividend statements, or invoices (PDF)")
                let files = urls.compactMap { url -> (String, Data)? in
                    guard let data = readScoped(url) else { return nil }
                    return (url.lastPathComponent, data)
                }
                if !files.isEmpty {
                    smartPayload = SmartImportPayload(files: files)
                }
            }
        }
        #else
        .fileImporter(isPresented: $model.bankImportRequested,
                      allowedContentTypes: [.commaSeparatedText, .text, .pdf, .data]) { result in
            if case .success(let url) = result { loadBankFile(url) }
        }
        // Anchored to a background view: two fileImporters on the same view
        // clobber each other's presentation.
        .background {
            Color.clear
                .fileImporter(isPresented: $model.smartImportRequested,
                              allowedContentTypes: [.pdf],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result {
                        let files = urls.compactMap { url -> (String, Data)? in
                            guard let data = readScoped(url) else { return nil }
                            return (url.lastPathComponent, data)
                        }
                        if !files.isEmpty {
                            smartPayload = SmartImportPayload(files: files)
                        }
                    }
                }
        }
        #endif
        .sheet(item: $importPayload) { payload in
            ImportView(model: model, payload: payload)
        }
        .sheet(item: $smartPayload) { payload in
            SmartImportSheet(model: model, payload: payload)
        }
        .overlay {
            if let statementProgress {
                StatementProgressCard(done: statementProgress.done, total: statementProgress.total)
            }
        }
        .alert("Couldn’t read the statement", isPresented: Binding(
            get: { statementError != nil },
            set: { if !$0 { statementError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statementError ?? "")
        }
        .onAppear(perform: offerOnboardingIfEmpty)
        .modifier(FileExportModifiers(
            model: model,
            exportDocument: $exportDocument, showingExport: $showingExport,
            ledgerDocument: $ledgerDocument, showingLedgerExport: $showingLedgerExport,
            ledgerFilename: $ledgerFilename,
            csvDocument: $csvDocument, showingCSVExport: $showingCSVExport,
            csvFilename: $csvFilename))
        .sheet(isPresented: $model.showingHelp) { HelpView() }
        .sheet(item: $model.printCheckRequestTxnID) { txnID in
            CheckPrintSheet(model: model, txnID: txnID)
        }
        .fileImporter(isPresented: Binding(
            get: { model.attachDocumentRequestTxnID != nil },
            set: { if !$0 { model.attachDocumentRequestTxnID = nil } }
        ), allowedContentTypes: [.item]) { result in
            guard let txnID = model.attachDocumentRequestTxnID else { return }
            model.attachDocumentRequestTxnID = nil
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                statementError = "Couldn't read “\(url.lastPathComponent)”."; return
            }
            do {
                _ = try model.attachDocument(named: url.lastPathComponent, data: data, to: txnID)
            } catch {
                statementError = "Couldn't attach the file: \(error.localizedDescription). Set a document folder in Settings ▸ Documents."
            }
        }
    }

    private func loadBankFile(_ url: URL) {
        guard let data = readScoped(url),
              let format = BankFileFormat.detect(data, extension: url.pathExtension)
        else { return }
        if format == .pdf {
            extractStatement(data)
        } else {
            importPayload = ImportPayload(data: data, format: format)
        }
    }

    private func readScoped(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }

    /// Reads a PDF statement with the on-device model (`FR-AI-01`), showing
    /// page progress, then hands the rows to the normal import review sheet.
    private func extractStatement(_ data: Data) {
        statementProgress = (0, 1)
        Task {
            do {
                let staged = try await model.extractStatementPDF(data) { done, total in
                    Task { @MainActor in statementProgress = (done, total) }
                }
                statementProgress = nil
                if staged.isEmpty {
                    statementError = "No transactions were found in this PDF."
                } else {
                    importPayload = ImportPayload(data: data, format: .pdf, prestaged: staged)
                }
            } catch {
                statementProgress = nil
                statementError = error.localizedDescription
            }
        }
    }

    /// Offers onboarding once per open document when it has no accounts yet.
    private func offerOnboardingIfEmpty() {
        guard !offeredOnboarding else { return }
        offeredOnboarding = true
        if model.isOpen && model.accountTree.isEmpty {
            model.presentedPanel = .onboarding
        }
    }
}

/// Progress card shown while Apple Intelligence reads a PDF statement.
private struct StatementProgressCard: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(1, total)))
                .frame(width: 200)
            Text("Reading statement… page \(min(done + 1, total)) of \(total)")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
        .accessibilityLabel("Reading statement with Apple Intelligence")
    }
}

/// Banner shown when the shared file changed on another device. Offers a plain
/// reload, and — when the change produced NSFileVersion conflicts — explicit
/// "keep mine" / "use other" resolution (`FR-PLT-02`).
struct ExternalChangeBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        let conflicted = model.hasVersionConflicts
        HStack(spacing: 12) {
            Image(systemName: conflicted
                  ? "exclamationmark.triangle.fill"
                  : "arrow.triangle.2.circlepath.icloud")
            Text(conflicted
                 ? "This book was edited in two places at once."
                 : "This book changed on another device.")
            Spacer()
            if conflicted {
                Button("Keep My Version") { model.resolveConflictsKeepingMine() }
                Button("Use Other Version") { model.resolveConflictsUsingOther() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Reload") { model.reloadFromDisk() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { model.externalChangePending = false }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.25))
    }
}

/// Offers a starter chart of accounts for a new, empty book (`FR-COA-03`,
/// `FR-PLAN-09`).
struct OnboardingSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var iconSize: CGFloat { 44 * appFontScale }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: iconSize)).foregroundStyle(.tint)
                Text("Welcome to your new book").scaledFont(.title2, weight: .bold)
                Text("Start with a ready-made personal chart of accounts — cheque, savings, credit card, income and common expense categories — or begin from scratch.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.createStarterAccounts()
                    dismiss()
                } label: {
                    Label("Create Starter Accounts", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Start Empty") { dismiss() }
            }
            .padding(32)
            .frame(minWidth: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } }
            }
        }
    }
}

// MARK: - Accounts sidebar

/// Which modal a sidebar account row is presenting.
enum AccountSheet: Identifiable {
    case edit(GncGUID)
    case reconcile(GncGUID)
    case delete(GncGUID)
    case cascade(GncGUID)

    var id: String {
        switch self {
        case .edit(let guid): return "edit-\(guid.hexString)"
        case .reconcile(let guid): return "rec-\(guid.hexString)"
        case .delete(let guid): return "del-\(guid.hexString)"
        case .cascade(let guid): return "casc-\(guid.hexString)"
        }
    }
}

/// GnuCash's Cascade Account Properties: copy this account's colour,
/// placeholder and hidden flags down its subtree (`FR-ACC-02`).
struct CascadeAccountSheet: View {
    @Bindable var model: AppModel
    var accountID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var options = AppModel.CascadeOptions()

    private var name: String { model.accountName(accountID) ?? "this account" }
    private var count: Int { model.descendantCount(of: accountID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Copy the properties you tick from “\(name)” onto "
                         + "\(DeleteAccountSheet.count(count, "account")) beneath it.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Colour", isOn: $options.color)
                    Toggle("Group", isOn: $options.isPlaceholder)
                    Toggle("Hidden", isOn: $options.isHidden)
                }
            }
            .navigationTitle("Cascade Properties")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.cascadeProperties(from: accountID, options)
                        dismiss()
                    }
                    // Nothing ticked would be a no-op dressed as an action.
                    .disabled(options.isEmpty || count == 0)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 260)
    }
}

/// GnuCash's Delete Account dialog: an account with postings or children can be
/// deleted, but has to say where they go first (`FR-ACC-04`).
struct DeleteAccountSheet: View {
    @Bindable var model: AppModel
    var accountID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var transactionTarget: GncGUID?
    @State private var childTarget: GncGUID?
    @State private var failure: String?

    private var plan: AppModel.AccountDeletionPlan? { model.deletionPlan(for: accountID) }
    private var name: String { model.accountName(accountID) ?? "this account" }

    /// "1 split" / "2,312 splits", grouped for reading.
    ///
    /// Spelled out rather than `^[\(n) split](inflect: true)`: automatic
    /// grammatical agreement resolves only for a localized string resource, and
    /// interpolating it into a `Text` renders the markup itself — this dialog
    /// said "^[2312 split](inflect: true) posted to “ANZ Access”".
    static func count(_ n: Int, _ noun: String) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: n),
                                                        number: .decimal)
        return "\(formatted) \(noun)\(n == 1 ? "" : "s")"
    }

    private var isReady: Bool {
        guard let plan else { return false }
        if plan.needsTransactionTarget && transactionTarget == nil { return false }
        if plan.needsChildTarget && childTarget == nil { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                if let plan {
                    if plan.isUnencumbered {
                        Text("“\(name)” is empty and can be deleted.")
                    }
                    if plan.needsTransactionTarget {
                        Section("Transactions") {
                            Text("\(Self.count(plan.splitCount, "split")) posted to “\(name)” "
                                 + "must move to another account.")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Move to", selection: $transactionTarget) {
                                Text("Choose an account…").tag(GncGUID?.none)
                                ForEach(model.transactionTargets(forDeleting: accountID)) { node in
                                    Text(node.fullName).tag(GncGUID?.some(node.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    if plan.needsChildTarget {
                        Section("Subaccounts") {
                            Text(plan.descendantSplitCount > 0
                                 ? "\(Self.count(plan.childCount, "subaccount")) — carrying "
                                   + "\(Self.count(plan.descendantSplitCount, "split")) — must "
                                   + "move to another parent."
                                 : "\(Self.count(plan.childCount, "subaccount")) must move to "
                                   + "another parent.")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Reparent to", selection: $childTarget) {
                                Text("Choose an account…").tag(GncGUID?.none)
                                ForEach(model.childTargets(forDeleting: accountID)) { node in
                                    Text(node.fullName).tag(GncGUID?.some(node.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    if let failure {
                        Text(failure).scaledFont(.caption).foregroundStyle(.red)
                    }
                } else {
                    Text("This account no longer exists.")
                }
            }
            .navigationTitle("Delete “\(name)”")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) { commit() }
                        .disabled(!isReady)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 300)
    }

    private func commit() {
        do {
            try model.deleteAccount(accountID, movingTransactionsTo: transactionTarget,
                                    movingChildrenTo: childTarget)
            dismiss()
        } catch {
            failure = model.describe(error)
        }
    }
}

struct AccountsSidebar: View {
    @Bindable var model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var sheet: AccountSheet?
    @State private var filter = ""
    /// GnuCash's "show hidden accounts". `isHidden` has been settable, stored
    /// and round-tripped all along, and the tree showed every account anyway —
    /// so marking one hidden greyed its name and changed nothing else.
    @AppStorage("showHiddenAccounts") private var showHidden = false
    @Environment(\.appFontScale) private var appFontScale

    private var trimmedFilter: String { filter.trimmingCharacters(in: .whitespaces) }

    private var visibleTree: [AccountNode] {
        showHidden ? model.accountTree : Self.pruningHidden(model.accountTree)
    }

    /// Drops hidden accounts and everything under them. Hiding a parent hides
    /// the subtree, as in GnuCash — a visible child of a hidden parent would
    /// have nowhere to hang.
    static func pruningHidden(_ nodes: [AccountNode]) -> [AccountNode] {
        nodes.compactMap { node in
            guard !node.isHidden else { return nil }
            guard let children = node.children else { return node }
            var copy = node
            copy.children = pruningHidden(children)
            return copy
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter accounts", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle(isOn: $showHidden) {
                    Image(systemName: showHidden ? "eye" : "eye.slash")
                        .accessibilityLabel("Show hidden accounts")
                }
                .toggleStyle(.button)
                .help("Show hidden accounts")
            }
            .padding(8)
            Divider()
            list
        }
        .navigationSplitViewColumnWidth(min: 200 * appFontScale,
                                        ideal: 240 * appFontScale,
                                        max: 400 * appFontScale)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let id): EditAccountSheet(model: model, accountID: id)
            case .reconcile(let id): ReconcileView(model: model, accountID: id)
            case .delete(let id): DeleteAccountSheet(model: model, accountID: id)
            case .cascade(let id): CascadeAccountSheet(model: model, accountID: id)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        List(selection: $model.sidebarSelection) {
            // App areas that used to be modal sheets are now destinations shown
            // inline in the detail pane (HIG: minimise modality).
            if trimmedFilter.isEmpty {
                Section {
                    Label("Dashboard", systemImage: "square.grid.2x2").tag(SidebarSelection.dashboard)
                    Label("Reports", systemImage: "chart.pie").tag(SidebarSelection.reports)
                    Label("All Transactions", systemImage: "text.book.closed").tag(SidebarSelection.generalLedger)
                }
                Section("Planning") {
                    Label("Planner", systemImage: "chart.xyaxis.line").tag(SidebarSelection.planner)
                    Label("Budgets", systemImage: "chart.bar.doc.horizontal").tag(SidebarSelection.budgets)
                    Label("Scheduled", systemImage: "calendar.badge.clock").tag(SidebarSelection.scheduled)
                    Label("Savings Goals", systemImage: "target").tag(SidebarSelection.goals)
                }
                Section("Records") {
                    Label("Business", systemImage: "building.2").tag(SidebarSelection.business)
                    Label("Prices & Securities", systemImage: "tag").tag(SidebarSelection.prices)
                    Label("Time & Mileage", systemImage: "clock.badge.checkmark").tag(SidebarSelection.timeMileage)
                    Label("Rules", systemImage: "wand.and.stars").tag(SidebarSelection.rules)
                    Label("Emergency Records", systemImage: "cross.case").tag(SidebarSelection.emergencyRecords)
                }
                // Pinned accounts, flat, in the order they were favourited —
                // the shortcut past three disclosure triangles for the handful
                // of registers someone lives in. Same row (and context menu)
                // as the tree, so selecting one is selecting the account.
                let favourites = model.favouriteAccountNodes
                if !favourites.isEmpty {
                    Section("Favourites") {
                        ForEach(favourites) { node in
                            row(node, label: node.name)
                        }
                    }
                }
            }
            accountsSection
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        Section("Accounts") {
            if trimmedFilter.isEmpty {
                OutlineGroup(visibleTree, children: \.children) { node in
                    row(node, label: node.name)
                }
            } else {
                // Filtering flattens to matches and shows full names — the same
                // shape as Find's account picker, and the reason typing "cdia"
                // beats opening three disclosure triangles on 559 accounts.
                let matches = AccountMatchPicker.matching(visibleTree, filter: trimmedFilter,
                                                          includingPlaceholders: true)
                if matches.isEmpty {
                    Text("No accounts match “\(trimmedFilter)”.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matches) { node in
                        row(node, label: node.fullName)
                    }
                }
            }
        }
    }

    private func row(_ node: AccountNode, label: String) -> some View {
        HStack {
            // GnuCash account colour, shown Finder-tag style.
            if let dot = node.color.flatMap(GnuCashColor.color(from:)) {
                Circle()
                    .fill(dot)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            Text(label)
                .scaledFont(.body)
                .foregroundStyle(node.isHidden ? .secondary : .primary)
            Spacer()
            Text(AmountFormat.string(node.balance, code: node.currencyCode))
                .scaledFont(.body)
                .monospacedDigit()
                .foregroundStyle(node.balance < 0 ? .red : .secondary)
        }
        .tag(SidebarSelection.account(node.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(AmountFormat.string(node.balance, code: node.currencyCode))
        .contextMenu {
            Button(model.isFavouriteAccount(node.id) ? "Remove from Favourites" : "Add to Favourites",
                   systemImage: model.isFavouriteAccount(node.id) ? "star.slash" : "star") {
                model.toggleFavouriteAccount(node.id)
            }
            Divider()
            Button("Edit…") { sheet = .edit(node.id) }
            Button("Reconcile…") {
                #if os(macOS)
                openWindow(id: "reconcile", value: node.id)
                #else
                sheet = .reconcile(node.id)
                #endif
            }
            // Only where there is a subtree to cascade onto.
            if !(node.children ?? []).isEmpty {
                Button("Cascade Properties…") { sheet = .cascade(node.id) }
            }
            // Always offered. It used to appear only for an account with
            // nothing in it, which on a real book is almost none of them — so
            // the answer to "why can't I delete this?" was a button that wasn't
            // there.
            Button("Delete…", role: .destructive) { sheet = .delete(node.id) }
        }
    }
}

// MARK: - Register

/// Which end of a register to scroll to (`FR-REG-08`).
enum RegisterEnd {
    case oldest, newest
}

/// Column widths as clamped proportions of the register's measured width, so
/// the grid rescales continuously as the window resizes: every column grows
/// with available space up to a cap, never shrinks below what its content
/// needs, and Description (the one unconstrained column) takes the rest.
/// Shared by the Basic and journal tables so the styles line up.
enum RegisterColumns {
    private static func metrics(_ width: CGFloat, _ scale: CGFloat) -> RegisterMetrics {
        RegisterMetrics(width: width, scale: scale)
    }

    static func showsSide(_ width: CGFloat, _ scale: CGFloat) -> Bool {
        metrics(width, scale).showsSide
    }
    static func showsBalance(_ width: CGFloat, _ scale: CGFloat) -> Bool {
        metrics(width, scale).showsBalance
    }
    static func showsDate(_ width: CGFloat, _ scale: CGFloat) -> Bool {
        metrics(width, scale).showsDate
    }

    static func date(_ width: CGFloat, _ scale: CGFloat) -> CGFloat {
        metrics(width, scale).date
    }
    static func account(_ width: CGFloat, _ scale: CGFloat) -> CGFloat {
        metrics(width, scale).account
    }
    static func transfer(_ width: CGFloat, _ scale: CGFloat) -> CGFloat {
        metrics(width, scale).transfer
    }
    static func amount(_ width: CGFloat, _ scale: CGFloat) -> CGFloat {
        metrics(width, scale).amount
    }
    static func balance(_ width: CGFloat, _ scale: CGFloat) -> CGFloat {
        metrics(width, scale).balance
    }
}

/// A text field for in-place register editing: holds a draft, commits on
/// Return. Escape (or clicking away without submitting) abandons the draft —
/// nothing reaches the book until the commit.
struct InlineTextCell: View {
    let value: String
    var placeholder = ""
    var trailing = false
    var onFocus: () -> Void = {}
    let commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(value: String, placeholder: String = "", trailing: Bool = false,
         onFocus: @escaping () -> Void = {}, commit: @escaping (String) -> Void) {
        self.value = value
        self.placeholder = placeholder
        self.trailing = trailing
        self.onFocus = onFocus
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .scaledFont(.body)
            .multilineTextAlignment(trailing ? .trailing : .leading)
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, isFocused in
                // Click-in reports up (the row becomes the selection);
                // click-away or Tab-away commits what changed.
                if isFocused { onFocus() } else if draft != value { commit(draft) }
            }
            .onChange(of: value) { _, newValue in draft = newValue }
    }
}

/// An account chooser that reads as text until clicked. A Menu, not a Picker:
/// menu content is built lazily on open, so every visible row can afford one.


/// The reconcile state as a glanceable symbol, shared by the Basic register and
/// the journal styles so the column reads identically everywhere. Activating it
/// cycles the state (n → c → y), as the letter button always did.
struct ReconcileBadge: View {
    let glyph: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbol(glyph))
                .foregroundStyle(Self.color(glyph))
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reconciliation status")
        .accessibilityValue(Self.word(glyph))
        .accessibilityHint("Activate to change")
    }

    static func symbol(_ glyph: String) -> String {
        switch glyph {
        case "c": "checkmark.circle"
        case "y": "checkmark.circle.fill"
        case "f": "snowflake"
        case "v": "xmark.circle"
        default: "circle.dotted"
        }
    }

    static func color(_ glyph: String) -> Color {
        switch glyph {
        case "c": .appAccent   // the banned shorthand hid here; appAccent follows the app's tint
        case "y": .green
        case "f": .cyan
        case "v": .red
        default: .secondary
        }
    }

    static func word(_ glyph: String) -> String {
        switch glyph {
        case "c": "Cleared"
        case "y": "Reconciled"
        case "f": "Frozen"
        case "v": "Voided"
        default: "Not reconciled"
        }
    }
}

struct RegisterView: View {
    @Bindable var model: AppModel
    @State private var filterShown = false
    @State private var goToDateShown = false
    /// GnuCash's View ▸ Double Line, renamed Show Details. A preference
    /// rather than per-register state, so it survives moving between accounts.
    /// How much of each transaction is opened out — GnuCash's three register
    /// styles (``RegisterStyle``). This was a single "Show All Splits" flag,
    /// which could say Basic or Journal but had no way to say Auto-Split.
    @AppStorage("registerViewStyle") private var registerStyle = RegisterStyle.basic
    /// Row height is a Settings preference, but it is also a thing you judge
    /// *while looking at the register* — so it is on the register's own View
    /// menu too, and mirrored into the menu bar (HIG *Toolbars*, macOS).
    @AppStorage(AppearanceKey.registerRowHeight)
    private var rowHeightPreference = RegisterRowHeight.automatic
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    /// Whether the attachments sidebar is shown (persisted like Double Line).
    @AppStorage("registerAttachmentsShown") private var attachmentsShown = false
    /// Set by the ⌘↑/⌘↓ shortcuts; the table consumes and clears it.
    @State private var jump: RegisterEnd?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                content
                    // The entry bar belongs to every single-account style, not just
                    // Basic — same reason as the summary bar.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let accountID = model.selectedAccountID,
                           !model.registerIncludesSubaccounts {
                            VStack(spacing: 0) {
                                Divider()
                                RegisterEntryBar(model: model, accountID: accountID)
                            }
                        }
                    }
                // The panel stays put while a row is edited in place. The old
                // condition hid it whenever `editingTransactionID` was set —
                // right for the removed trailing *inspector*, which fought the
                // panel for width, but the in-row editor takes no width at
                // all, so hiding the panel on click-to-edit just made the
                // whole register reflow: a layout shift delivered by the very
                // feature whose contract is that nothing moves.
                if attachmentsShown {
                    Divider()
                    AttachmentsPanel(model: model)
                }
            }
            if let summary = model.registerSummary {
                Divider()
                summaryBar(summary)
            }
        }
        .navigationTitle(selectedName)
        .background { jumpShortcuts }
        .onChange(of: model.registerFilterRequested) { _, now in
            if now {
                filterShown = true
                model.registerFilterRequested = false
            }
        }
        .sheet(isPresented: $filterShown) {
            RegisterFilterSheet(model: model)
        }
        .sheet(isPresented: $goToDateShown) {
            GoToDateSheet(model: model)
        }
        .toolbar { registerToolbar }
    }

    /// The register's toolbar. Register controls live with the window's, so
    /// the register itself is all rows — no strip eating a line of every
    /// account.
    ///
    /// Two groups, in the shape Mail uses: the controls that decide *what you
    /// are looking at* together on the leading side, then a separator, then
    /// the things you can *do*.
    ///
    /// HIG *Toolbars* — "Minimize the number of groups… in general, aim for a
    /// maximum of three" — and it is why Edit has left: a per-row command does
    /// not belong in the window frame (HIG *Buttons*, macOS: "Square buttons
    /// aren\u{2019}t intended for use in toolbars"). Editing is the row\u{2019}s pencil,
    /// a click in any cell, \u{2318}E, and the Transaction menu.
    @ToolbarContentBuilder
    private var registerToolbar: some ToolbarContent {
        ToolbarItemGroup {
            viewMenu
            filterButton
        }
        // HIG *Toolbars*: separation between sections is fixed space, not a
        // drawn rule — "Add separation by inserting fixed space between the
        // buttons." On macOS 26 the system renders that as the divider you
        // see between Mail's groups.
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            actionsMenu
        }
    }

    /// Everything you can *do* to this register, in one pull-down — the
    /// "actions" half of the toolbar. HIG *Pull-down buttons* sanctions this
    /// shape (its own examples are an Add menu and a Sort menu) and warns only
    /// against burying a view\u{2019}s primary actions; entering a transaction is
    /// the primary action here and it stays on the entry bar and \u{2318}N.
    private var actionsMenu: some View {
        Menu {
            Button("Reconcile Account…", systemImage: "checkmark.seal") {
                #if os(macOS)
                if let id = model.selectedAccountID { openWindow(id: "reconcile", value: id) }
                #else
                model.presentedPanel = .reconcile
                #endif
            }
            .disabled(model.selectedAccountID == nil)
            Button("Bulk Edit…", systemImage: "square.and.pencil") {
                model.presentedPanel = .bulkEdit
            }
            .disabled(model.selectedTransactionIDs.count < 2)
            Divider()
            Button("Import Bank File…", systemImage: "square.and.arrow.down.on.square") {
                model.bankImportRequested = true
            }
            Button("Smart Import PDFs…", systemImage: "doc.viewfinder") {
                model.smartImportRequested = true
            }
            .disabled(!model.isIntelligenceAvailable)
            .help(model.intelligenceUnavailableReason
                  ?? "Import bank statements, dividend statements, and invoices — each PDF is identified and handled automatically")
            Button("Auto-Categorise…", systemImage: "sparkles") {
                model.presentedPanel = .autoCategorize
            }
            .help("Assign categories to uncategorised transactions")
            Button("Match Attachments…", systemImage: "paperclip.badge.ellipsis") {
                model.presentedPanel = .matchAttachments
            }
            .disabled(!model.isIntelligenceAvailable)
            .help(model.intelligenceUnavailableReason
                  ?? "Pick receipts and statements — each is matched to its transaction, linked, and categorised")
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .help("Reconcile, import, categorise")
    }

    /// The register style, plus what to show alongside it: details
    /// (notes/memo), the subtree, the attachments panel.
    private var viewMenu: some View {
        let selectedHasDocument = model.selectedTransactionIDs.count == 1
            && model.selectedTransactionIDs.first.map(model.hasLinkedDocument) == true
        return Menu {
            Picker(selection: $registerStyle) {
                ForEach(RegisterStyle.allCases) { style in
                    Label(style.title, systemImage: style.symbol).tag(style)
                }
            } label: {
                Label("Style", systemImage: "rectangle.split.1x2")
            }
            .pickerStyle(.inline)
            Divider()
            Menu {
                Picker("Row Height", selection: $rowHeightPreference) {
                    ForEach(RegisterRowHeight.allCases) { height in
                        Text(height.title).tag(height)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Row Height", systemImage: "arrow.up.and.down.text.horizontal")
            }
            .help("How tall each transaction stands — Automatic measures the display")
            Menu {
                Picker("Sort By", selection: $model.registerSort) {
                    ForEach(RegisterSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Reverse Order", isOn: $model.registerSortReversed)
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            Divider()
            Toggle(isOn: $model.registerIncludesSubaccounts) {
                Label("Include Subaccounts", systemImage: "arrow.triangle.branch")
            }
            .disabled(!model.selectedAccountHasChildren)
            .help("Include this account’s subaccounts in the register")
            Toggle(isOn: $attachmentsShown) {
                Label("Attachments",
                      systemImage: selectedHasDocument ? "paperclip.badge.ellipsis" : "paperclip")
            }
            .help("Show the selected transaction’s attachment")
        } label: {
            Label("View", systemImage: "slider.horizontal.3")
        }
        .help("Choose what the register shows")
    }

    private var filterButton: some View {
        Button {
            filterShown = true
        } label: {
            Label(model.registerFilter.isShowingEverything ? "Filter" : "Filtered",
                  systemImage: model.registerFilter.isShowingEverything
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
        }
        .fixedSize()
        .help("Show only some transactions")
    }

    /// Keyboard-only buttons: a register spanning years of history is otherwise
    /// thousands of scroll-wheel ticks end to end. In the journal styles these
    /// move within the loaded page — "oldest" means the oldest entry on screen,
    /// which "Show Earlier" extends.
    private var jumpShortcuts: some View {
        Group {
            Button("Go to Oldest Transaction") { jump = .oldest }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Go to Newest Transaction") { jump = .newest }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Go to Date…") { goToDateShown = true }
                .keyboardShortcut("g", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedAccountID == nil {
            ContentUnavailableView("Select an account", systemImage: "list.bullet.rectangle",
                                   description: Text("Choose an account to see its transactions."))
        } else if model.registerRows.isEmpty {
            // The empty state points at the entry bar below it — the fastest
            // way out of "no postings yet" is to add one (RD4).
            ContentUnavailableView {
                Label("No transactions", systemImage: "tray")
            } description: {
                Text("This account has no postings yet.")
            } actions: {
                Button("Add a Transaction (⌘N)") { model.requestQuickEntry() }
            }
        } else {
            // The register itself — selection, in-place editing, expansion,
            // and scrolling all live there. macOS draws it as a GnuCash-style
            // sheet (RegisterSheet.swift); iOS keeps the SwiftUI Table
            // (RegisterTable.swift).
            #if os(macOS)
            RegisterSheet(model: model, jump: $jump)
            #else
            RegisterTableView(model: model, jump: $jump)
            #endif
        }
    }


    private var selectedName: String {
        model.postableAccounts.first { $0.id == model.selectedAccountID }?.name
            ?? model.accountTree.first { $0.id == model.selectedAccountID }?.name
            ?? "Register"
    }

    /// GnuCash's register status strip: the balance under each reconcile lens.
    /// Values come from the engine's existing `BalanceFilter`, so they agree
    /// with the sidebar and the reports to the cent.
    private func summaryBar(_ s: AppModel.RegisterSummary) -> some View {
        func cell(_ label: LocalizedStringKey, _ value: Decimal) -> some View {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Text(AmountFormat.string(value, code: s.currencyCode))
                    .monospacedDigit()
            }
            .scaledFont(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) \(AmountFormat.string(value, code: s.currencyCode))")
        }
        return HStack(spacing: 16) {
            cell("Present:", s.present)
            if s.hasFuture { cell("Future:", s.future) }
            cell("Cleared:", s.cleared)
            cell("Reconciled:", s.reconciled)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
    }

    private var currencyCode: String {
        model.postableAccounts.first { $0.id == model.selectedAccountID }?.currencyCode
            ?? model.reportCurrency.mnemonic
    }
}

/// Journal / general-ledger register: each transaction with all its legs.
///
/// Journal / general-ledger register: each transaction's heading followed by
/// its legs, oldest first, opening on the newest.
///
/// A `Table` rather than a `List` of sections. Uniform rows are what make the
/// whole book affordable: AppKit positions row N without laying out the rows
/// before it, so jumping to either end is instant across 46k transactions and
/// no windowing is needed. The nested-section version had to be paged, and
/// scrolling it to the far end never settled.
/// The whole book in journal form — a sidebar destination, mirroring GnuCash's
/// Tools ▸ General Ledger (a separate tool there too, not a register style).
struct GeneralLedgerView: View {
    @Bindable var model: AppModel
    @State private var jump: RegisterEnd?

    var body: some View {
        // The same register as the accounts, over the whole book (FR-REG-09)
        // — one editing dialect everywhere.
        #if os(macOS)
        RegisterSheet(model: model, wholeBook: true, jump: $jump)
            .navigationTitle("All Transactions")
        #else
        RegisterTableView(model: model, wholeBook: true, jump: $jump)
            .navigationTitle("All Transactions")
        #endif
    }
}

/// Everything you can do to the selected transaction.
///
/// One definition, used by the Basic register's context menu, the Journal's,
/// the General Ledger's, and the Transaction menu in the menu bar. They were
/// three different lists before — Basic had seven operations, Journal had Edit,
/// and the menu bar had none — and the only way to keep them the same is for
/// there to be one of them.
public struct TransactionActions: View {
    @Bindable var model: AppModel
    /// The split the row stands for. `nil` when nothing is selected, which is
    /// what disables the menu-bar copy.
    var splitID: GncGUID?
    /// Every selected row (split GUIDs) — what multi-selection actions like
    /// Auto-Categorise act on. Empty falls back to `splitID` alone.
    var selectionSplitIDs: Set<GncGUID> = []
    @State private var pasteError: String?

    public init(model: AppModel, splitID: GncGUID?, selectionSplitIDs: Set<GncGUID> = []) {
        self.model = model
        self.splitID = splitID
        self.selectionSplitIDs = selectionSplitIDs
    }

    private var txnID: GncGUID? { splitID.flatMap { model.transactionID(ofSplit: $0) } }

    /// Each item carries its own condition rather than the whole menu being
    /// disabled together: `disabled` is inherited and cannot be undone by a
    /// child, and Paste is the one item here that does not want a selected row —
    /// it wants something on the clipboard.
    private var needsRow: Bool { txnID == nil }

    public var body: some View {
        Group {
            Button("Edit Transaction…") {
                // Unanimated on purpose — HIG Motion: "In apps, generally avoid
                // adding motion to UI interactions that occur frequently."
                model.editingTransactionID = txnID
            }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(needsRow)
            Button("Go to Other Account") {
                if let splitID { model.jumpToOtherAccount(ofSplit: splitID) }
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(needsRow)
            Button("Auto-Categorise…", systemImage: "sparkles") {
                // Scope the sheet to exactly the rows this menu was opened on —
                // the full selection, or just this row when invoked on one.
                let ids = selectionSplitIDs.isEmpty
                    ? (splitID.map { Set([$0]) } ?? [])
                    : selectionSplitIDs
                model.selectedSplitIDs = ids
                model.presentedPanel = .autoCategorize
            }
            .disabled(needsRow)
            Button("Bulk Edit…", systemImage: "square.and.pencil") {
                model.selectedSplitIDs = selectionSplitIDs
                model.presentedPanel = .bulkEdit
            }
            // A uniform change needs a set to change; one row edits in place or
            // in the inspector.
            .disabled(selectionSplitIDs.count < 2)
            Button("Attach File…", systemImage: "paperclip") {
                if let txnID { model.attachDocumentRequestTxnID = txnID }
            }
            .disabled(needsRow)
            Button("Print Check…", systemImage: "printer") {
                if let txnID { model.printCheckRequestTxnID = txnID }
            }
            .disabled(needsRow)
            if let txnID, model.hasLinkedDocument(txnID) {
                Button("Open Linked Document", systemImage: "paperclip.badge.ellipsis") {
                    model.openLinkedDocument(for: txnID)
                }
            }
            Divider()
            reconcileStateMenu
            Divider()
            // Shifted, because ⌘C/⌘X/⌘V belong to whatever text has focus, and
            // taking them would make copying a description impossible.
            Button("Cut Transaction") {
                if let txnID { model.cutTransaction(txnID) }
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(needsRow)
            Button("Copy Transaction") {
                if let txnID { model.copyTransaction(txnID) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(needsRow)
            Button("Paste Transaction") {
                do { _ = try model.pasteTransaction() }
                catch let error as AppModel.PasteError { pasteError = model.describe(error) }
                catch { pasteError = error.localizedDescription }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!model.canPasteTransaction)
            Divider()
            Button("Duplicate Transaction") {
                if let txnID { model.duplicateTransaction(txnID) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(needsRow)
            Button("Add Reversing Transaction") {
                if let txnID { _ = model.addReversingTransaction(txnID) }
            }
            .disabled(needsRow)
            Button("Schedule…") { model.schedulingTransactionID = txnID }
                .disabled(needsRow)
            if let txnID, model.isVoided(txnID) {
                Button("Unvoid Transaction") { model.unvoidTransaction(txnID) }
            } else {
                Button("Void Transaction") {
                    if let txnID { model.voidTransaction(txnID) }
                }
                .disabled(needsRow)
            }
            Divider()
            Button("Delete Transaction", role: .destructive) {
                if let txnID { model.deleteTransaction(txnID) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(needsRow)
        }
        .alert("Paste Transaction", isPresented: Binding(
            get: { pasteError != nil },
            set: { if !$0 { pasteError = nil } })) {
            Button("OK", role: .cancel) { pasteError = nil }
        } message: {
            Text(pasteError ?? "")
        }
    }

    /// Every reconcile state, not just the three the R column cycles through.
    ///
    /// `setReconcileState` has handled all five since it was written, and had no
    /// caller outside its tests — so frozen (`f`) could be imported, stored,
    /// exported and shown, but never set. Clicking the R column still cycles
    /// n → c → y, which is the common path; this is where the other two live.
    /// Voided is absent on purpose: it is not a flag but an operation, and it
    /// has its own Void/Unvoid item that rewrites the whole transaction.
    @ViewBuilder
    private var reconcileStateMenu: some View {
        let current = splitID.flatMap { model.reconcileState(ofSplit: $0) }
        Menu("Reconcile State") {
            Picker("Reconcile State", selection: Binding(
                get: { current ?? .notReconciled },
                set: { state in
                    if let splitID { model.setReconcileState(splitID: splitID, to: state) }
                }
            )) {
                ForEach(ReconcileState.settableInRegister, id: \.self) { state in
                    Text(state.label).tag(state)
                }
            }
            .pickerStyle(.inline)
        }
        .disabled(splitID == nil || current == .voided)
    }
}

/// GnuCash's blank transaction row, as an entry bar at the foot of the register
/// (`FR-REG-05`).
///
/// Date, description, transfer account, amount, Return — and the row appears
/// above with focus back in the description, because the point of entering at
/// the register is entering the *next* one too. QuickFill fills the transfer
/// and amount from the last transaction with the same description, which is
/// most of most people's entries.
struct RegisterEntryBar: View {
    @Bindable var model: AppModel
    let accountID: GncGUID

    @State private var date = Date()
    @State private var descriptionText = ""
    @State private var transferID: GncGUID?
    @State private var amountText = ""
    @FocusState private var descriptionFocused: Bool
    @Environment(\.appFontScale) private var appFontScale

    private var amount: Decimal? { EditableSplit.strictDecimal(
        amountText.trimmingCharacters(in: .whitespaces)) }
    private var canCommit: Bool {
        transferID != nil && (amount ?? 0) != 0
            && !descriptionText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()

            // QuickFill as ghost text: the best recent match completes the
            // typed prefix in-place; Tab accepts it (and fills the transfer
            // account and amount from that transaction). Offered, not applied
            // — autofilling on a prefix match would race the typing.
            ZStack(alignment: .leading) {
                if let ghost = ghostSuggestion {
                    HStack(spacing: 0) {
                        Text(descriptionText).foregroundStyle(.clear)
                        Text(ghost.dropFirst(descriptionText.count))
                            .foregroundStyle(.tertiary)
                    }
                    .lineLimit(1)
                    .allowsHitTesting(false)
                }
                TextField("Add a transaction (⌘N)", text: $descriptionText)
                    .textFieldStyle(.plain)
                    .focused($descriptionFocused)
                    .onKeyPress(.tab) {
                        guard let ghost = ghostSuggestion else { return .ignored }
                        applySuggestion(ghost)
                        return .handled
                    }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .frame(minWidth: 160)

            Picker("", selection: $transferID) {
                Text("Transfer from…").tag(GncGUID?.none)
                ForEach(model.postableAccounts.filter { $0.id != accountID }) { node in
                    Text(node.fullName).tag(GncGUID?.some(node.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            TextField("Amount", text: $amountText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100 * appFontScale)
                .onSubmit(commit)

            Button("Enter", action: commit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)
                .help("Add this transaction (⌘↩)")
        }
        .scaledFont(.body)
        .padding(8)
        .background(.bar)
        .onChange(of: model.entryBarFocusRequest) {
            descriptionFocused = true
        }
    }

    /// The recent description that completes what's typed so far, if any —
    /// rendered as ghost text after the caret.
    private var ghostSuggestion: String? {
        guard descriptionFocused,
              !descriptionText.trimmingCharacters(in: .whitespaces).isEmpty,
              let match = model.descriptionSuggestions(prefix: descriptionText, limit: 1).first,
              match.count > descriptionText.count
        else { return nil }
        return match
    }

    private func applySuggestion(_ suggestion: String) {
        descriptionText = suggestion
        if let fill = model.quickFill(forDescription: suggestion, into: accountID) {
            transferID = fill.transferID
            amountText = NSDecimalNumber(decimal: fill.amount).stringValue
        }
    }

    private func commit() {
        guard canCommit, let transferID, let amount else { return }
        guard model.quickEnter(into: accountID, transferFrom: transferID,
                               amount: amount, date: date,
                               description: descriptionText) != nil else { return }
        // Keep the date and the transfer: runs of entries share both. Clear
        // what identifies the transaction, and put focus back where the next
        // one starts.
        descriptionText = ""
        amountText = ""
        descriptionFocused = true
    }
}

/// GnuCash's Find Account (⌘I): type a few letters, land on the account
/// (`FR-FIND-02`).
///
/// The sidebar filter covers browsing; this is for the keyboard. ⌘I, type,
/// Return — no mouse, no disclosure triangles, and it works however deep the
/// account is buried. The filter is the same `matching` Find's picker and the
/// sidebar use, so all three agree about what a search string means.
struct FindAccountSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""
    @State private var selection: GncGUID?
    @FocusState private var filterFocused: Bool

    private var matches: [AccountNode] {
        AccountMatchPicker.matching(model.accountTree,
                                    filter: filter.trimmingCharacters(in: .whitespaces),
                                    includingPlaceholders: true)
    }

    /// Return acts on what you can see: the chosen row, or the only match —
    /// "cdia" narrowing to one account should not also demand an arrow key.
    private var target: GncGUID? { Self.target(selection: selection, matches: matches) }

    static func target(selection: GncGUID?, matches: [AccountNode]) -> GncGUID? {
        selection ?? (matches.count == 1 ? matches.first?.id : nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Account name", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .onSubmit(show)
                    .padding(8)
                Divider()
                List(selection: $selection) {
                    ForEach(matches) { node in
                        HStack {
                            Text(node.fullName)
                            Spacer()
                            Text(AmountFormat.string(node.balance, code: node.currencyCode))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .tag(node.id)
                    }
                }
                .contextMenu(forSelectionType: GncGUID.self) { _ in } primaryAction: { ids in
                    selection = ids.first
                    show()
                }
                if matches.isEmpty {
                    Text("No accounts match “\(filter)”.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .navigationTitle("Find Account")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") { show() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(target == nil)
                }
            }
            .onAppear { focusSoon { filterFocused = true } }
            .onChange(of: filter) { selection = nil }
        }
        .frame(minWidth: 440, minHeight: 360)
    }

    private func show() {
        guard let target else { return }
        model.selectedAccountID = target
        dismiss()
    }
}

/// GnuCash's Transaction ▸ Schedule…: turn a transaction you have already
/// entered into a recurring one (`FR-SCH-01`).
struct ScheduleTransactionSheet: View {
    @Bindable var model: AppModel
    var transactionID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var name = ""
    @State private var period: RecurrencePeriod = .monthly
    @State private var interval = 1
    @State private var advanceCreateDays = 0
    @State private var advanceRemindDays = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Repeat") {
                    Picker("Every", selection: $period) {
                        ForEach(RecurrencePeriod.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Stepper("Every \(interval) \(unitName)", value: $interval, in: 1...52)
                }
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section("Create ahead") {
                    Stepper("Create \(advanceCreateDays) days early",
                            value: $advanceCreateDays, in: 0...90)
                    Stepper("Remind \(advanceRemindDays) days early",
                            value: $advanceRemindDays, in: 0...90)
                }
                Section {
                    // The thing worth saying: this schedules the *next* one. The
                    // transaction in front of you already exists and is not
                    // about to be posted again.
                    Text("""
                         The first occurrence will be the next one after this \
                         transaction’s date. This transaction is left alone.
                         """)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule Transaction")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        model.scheduleTransaction(transactionID, period: period,
                                                  interval: interval, name: name,
                                                  advanceCreateDays: advanceCreateDays,
                                                  advanceRemindDays: advanceRemindDays)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private var unitName: String {
        let singular = period.unitNoun
        return interval == 1 ? singular : singular + "s"
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let edit = model.editData(forTransaction: transactionID) {
            name = edit.description
        }
    }
}

/// GnuCash's Go to Date (⌘G): jump the register to where a day begins.
struct GoToDateSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var missed = false

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                if missed {
                    Text("No transaction on or after that date.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Go to Date")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        // Say so rather than dismissing onto an unchanged
                        // register, which would read as the jump being ignored.
                        if model.goToDate(date) { dismiss() } else { missed = true }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .onChange(of: date) { missed = false }
        }
        .frame(minWidth: 340, minHeight: 180)
    }
}

/// GnuCash's View ▸ Filter By: which rows the register shows, by date and by
/// reconcile status. Edits a draft and applies on Done, so half-set criteria
/// don't churn the register underneath the user.
struct RegisterFilterSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var limitDates = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var statuses: Set<ReconcileState> = Set(ReconcileState.allCases)
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Toggle("Limit to a date range", isOn: $limitDates)
                    if limitDates {
                        DatePicker("From", selection: $start, displayedComponents: .date)
                        DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                    }
                }
                Section("Status") {
                    ForEach(ReconcileState.allCases, id: \.self) { state in
                        Toggle(Self.name(state), isOn: binding(for: state))
                    }
                    HStack {
                        Button("Select All") { statuses = Set(ReconcileState.allCases) }
                        Spacer()
                        Button("Clear All") { statuses = [] }
                    }
                }
                if statuses.isEmpty {
                    Text("No statuses selected — the register will be empty.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Filter Transactions")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply() }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Show All") {
                        model.registerFilter = .showAll
                        dismiss()
                    }
                    .disabled(model.registerFilter.isShowingEverything)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    private func binding(for state: ReconcileState) -> Binding<Bool> {
        Binding(
            get: { statuses.contains(state) },
            set: { isOn in
                if isOn { statuses.insert(state) } else { statuses.remove(state) }
            }
        )
    }

    private static func name(_ state: ReconcileState) -> String {
        switch state {
        case .notReconciled: "Unreconciled"
        case .cleared: "Cleared"
        case .reconciled: "Reconciled"
        case .frozen: "Frozen"
        case .voided: "Voided"
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let filter = model.registerFilter
        statuses = filter.statuses
        if let from = filter.startDate, let to = filter.endDate {
            limitDates = true
            start = from
            end = to
        } else {
            // Default the range to the span actually on screen, so turning the
            // toggle on doesn't blank the register.
            start = model.registerRows.first?.date ?? Date()
            end = model.registerRows.last?.date ?? Date()
        }
    }

    private func apply() {
        model.registerFilter = RegisterFilter(
            statuses: statuses,
            startDate: limitDates ? start : nil,
            endDate: limitDates ? end : nil)
        dismiss()
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    @State private var selection: Set<GncGUID> = []
    @State private var editingTransactionID: GncGUID?

    var body: some View {
        Table(model.searchResults, selection: $selection) {
            TableColumn("Date") { row in
                Text(dateFormat.short(row.date))
                    .scaledFont(.body)
            }
            TableColumn("Description") { row in
                Text(row.description).scaledFont(.body)
            }
            TableColumn("Accounts") { row in
                Text(row.accounts).scaledFont(.body)
            }
            TableColumn("Amount") { row in
                Text(AmountFormat.string(row.amount, code: row.currencyCode))
                    .scaledFont(.body)
                    .monospacedDigit()
            }
        }
        // A result is a transaction, so it can be worked on like one. Editing
        // in place is what makes "find, then fix each one" possible without
        // leaving the results — the nearest thing we have to GnuCash, whose
        // Find opens its results as a register. With several rows selected the
        // menu acts on all of them, as one edit and one Undo: "find last
        // month's cheques, mark them cleared" is one act, not forty.
        .contextMenu(forSelectionType: GncGUID.self) { ids in
            let list = Array(ids)
            if let id = list.first, list.count == 1 {
                Button("Edit…") { editingTransactionID = id }
                Button("Show in Register") { model.showInRegister(id) }
                Divider()
            }
            // Reconcile state applies to the *matched* split of each result —
            // the leg the search was about — so it is only offered where a
            // structured find remembered one.
            if model.findQuery != nil, !list.isEmpty {
                Menu(list.count == 1 ? "Set Reconcile State"
                     : "Set Reconcile State (\(list.count))") {
                    ForEach(ReconcileState.settableInRegister, id: \.self) { state in
                        Button(state.label) {
                            model.setReconcileStateOfMatches(in: list, to: state)
                        }
                    }
                }
            }
            if !list.isEmpty {
                Button(list.count == 1 ? "Void Transaction"
                       : "Void \(list.count) Transactions") {
                    model.voidTransactions(list)
                }
                Divider()
                Button(list.count == 1 ? "Delete Transaction"
                       : "Delete \(list.count) Transactions", role: .destructive) {
                    model.deleteTransactions(list)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, ids.count == 1 { editingTransactionID = id }
        }
        .sheet(item: $editingTransactionID) { id in
            TransactionEditorSheet(model: model, editingID: id)
        }
        .overlay {
            if model.searchResults.isEmpty { noResults }
        }
        .safeAreaInset(edge: .top) {
            if !model.searchNotices.isEmpty { noticeBanner }
        }
        .toolbar {
            if model.findQuery != nil {
                ToolbarItemGroup {
                    Button("Edit Find…", systemImage: "slider.horizontal.3") {
                        model.presentedPanel = .find
                    }
                    .help("Change the search criteria (⌘F)")
                    Button("Clear", systemImage: "xmark.circle") { model.clearFind() }
                        .help("Stop showing find results")
                }
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        model.findQuery == nil
            ? "Results for “\(model.searchQuery)”"
            : "Find Results (\(model.searchResults.count))"
    }

    /// Finding nothing is a result. Saying nothing is not: without this the
    /// detail pane fell back to the dashboard and the search vanished.
    private var noResults: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            if model.findQuery == nil {
                Text("No transactions match “\(model.searchQuery)”.")
            } else {
                Text("No splits match these criteria.")
            }
        } actions: {
            if model.findQuery != nil {
                Button("Edit Criteria…") { model.presentedPanel = .find }
            }
        }
    }

    private var noticeBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.searchNotices) { notice in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.message).scaledFont(.callout)
                        Text(notice.recovery)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }
}

// MARK: - New account

/// A small catalog of common ISO currencies for the account editor.
enum CurrencyCatalog {
    static let common: [Commodity] = [
        .currency("AUD", name: "Australian Dollar"),
        .currency("USD", name: "US Dollar"),
        .currency("EUR", name: "Euro"),
        .currency("GBP", name: "Pound Sterling"),
        .currency("NZD", name: "New Zealand Dollar"),
        .currency("CAD", name: "Canadian Dollar"),
        .currency("JPY", fractionDigits: 0, name: "Japanese Yen"),
        .currency("CHF", name: "Swiss Franc"),
        .currency("CNY", name: "Chinese Yuan"),
        .currency("HKD", name: "Hong Kong Dollar"),
        .currency("SGD", name: "Singapore Dollar"),
        .currency("INR", name: "Indian Rupee"),
    ]
}

/// Names and saves the current search query.
struct SaveSearchSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Query", value: model.searchQuery)
                TextField("Name", text: $name).focused($focused)
            }
            .navigationTitle("Save Search")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveCurrentSearch(name: name); dismiss() }
                }
            }
            .onAppear { focusSoon { focused = true } }
        }
        .frame(minWidth: 360, minHeight: 160)
    }
}

struct NewAccountSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .bank
    @State private var parentID: GncGUID?
    @State private var currencyCode = ""
    @State private var exchange = ""
    @State private var ticker = ""
    @State private var securityName = ""
    @FocusState private var nameFocused: Bool

    private let selectableTypes: [AccountType] = [
        .bank, .cash, .asset, .credit, .liability, .equity, .income, .expense, .stock, .mutualFund,
    ]

    private var isSecurity: Bool { type.isSecurityType }

    /// Book currencies plus the common catalog, de-duplicated by code.
    private var availableCurrencies: [Commodity] {
        var seen = Set<String>()
        var result: [Commodity] = []
        for commodity in model.currencyCommodities + CurrencyCatalog.common
        where seen.insert(commodity.mnemonic).inserted {
            result.append(commodity)
        }
        return result
    }

    private var canAdd: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isSecurity ? !ticker.trimmingCharacters(in: .whitespaces).isEmpty : true
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                Picker("Type", selection: $type) {
                    ForEach(selectableTypes, id: \.self) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                Picker("Parent", selection: $parentID) {
                    Text("Top level").tag(GncGUID?.none)
                    ForEach(model.accountTree) { node in
                        Text(node.name).tag(GncGUID?.some(node.id))
                    }
                }

                if isSecurity {
                    Section("Security") {
                        TextField("Exchange (e.g. ASX)", text: $exchange)
                        TextField("Ticker (e.g. CBA)", text: $ticker)
                        TextField("Full name (optional)", text: $securityName)
                    }
                } else {
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(availableCurrencies, id: \.mnemonic) { c in
                            Text("\(c.mnemonic) — \(c.fullName)").tag(c.mnemonic)
                        }
                    }
                }
            }
            .navigationTitle("New Account")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!canAdd)
                }
            }
            .onAppear {
                if currencyCode.isEmpty { currencyCode = model.reportCurrency.mnemonic }
                focusSoon { nameFocused = true }
            }
        }
    }

    private func makeCommodity() -> Commodity {
        if isSecurity {
            let code = ticker.trimmingCharacters(in: .whitespaces).uppercased()
            let ex = exchange.trimmingCharacters(in: .whitespaces).uppercased()
            let full = securityName.trimmingCharacters(in: .whitespaces)
            return Commodity(namespace: .security(ex.isEmpty ? "OTHER" : ex),
                             mnemonic: code,
                             fullName: full.isEmpty ? code : full,
                             smallestFraction: 10_000)
        }
        return availableCurrencies.first { $0.mnemonic == currencyCode } ?? .currency(currencyCode)
    }

    private func add() {
        model.addAccount(name: name, type: type, commodity: makeCommodity(), parentID: parentID)
        dismiss()
    }
}

// MARK: - Transaction editor (multi-split)

/// One editable row of the transaction editor.
///
/// Internal rather than private so the round-trip below can be tested: this
/// type is the only thing standing between a transaction and its rewrite on
/// save, and the fields it forgets are the fields the save destroys.
struct EditableSplit: Identifiable, Equatable {
    let id = UUID()

    /// The split this row came from, or `nil` for a leg the user just added.
    /// Carried so the save can re-attach to that split instead of replacing it,
    /// which is what keeps its reconcile state, identity and slots alive.
    var splitID: GncGUID?
    var accountID: GncGUID?
    var amountText: String = ""

    /// The split's amount in its **own** commodity — a share count for a
    /// security, the foreign amount for an FX leg — when it differs from the
    /// value. Empty means "same as the value", which is right for a plain cash
    /// posting and lets editing the amount carry the quantity with it.
    ///
    /// Editable text now (GnuCash's Edit Exchange Rate); it was carried blind,
    /// so the one number you could not fix on an FX or security leg was the
    /// foreign amount. GnuCash's dialog edits the *rate*, but the book stores
    /// value and quantity — editing the quantity with the implied rate shown is
    /// the same act without a derived field that can drift from what is stored.
    var quantityText: String = ""

    var quantity: Decimal? {
        let trimmed = quantityText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Self.strictDecimal(trimmed)
    }

    /// Empty is fine (the quantity follows the value); text that does not parse
    /// is not. The test for this found the hazard was worse than assumed:
    /// `Decimal(string:)` parses a numeric *prefix*, so "1o" is not rejected —
    /// it is **1**, and a typo would have quietly set a share count to 1.
    var quantityIsValid: Bool {
        quantityText.trimmingCharacters(in: .whitespaces).isEmpty || quantity != nil
    }

    /// A decimal only if the *whole* string is one — or a whole arithmetic
    /// expression that evaluates to one (GnuCash lets you type `5*3` or
    /// `10.50+2` into an amount cell; ``AmountExpression`` validates the whole
    /// string and returns the number for a plain figure).
    static func strictDecimal(_ text: String) -> Decimal? {
        AmountExpression.evaluate(text)
    }

    /// Per-split memo and GnuCash's per-split Action. Both are editable below;
    /// both were previously carried blind, and `action` was not carried at all.
    var memo: String = ""
    var action: String = ""

    /// Strict for the same reason as the quantity: `Decimal(string:)` parses a
    /// prefix, so "4o0" would be 4 — here it is 0, and the imbalance readout
    /// says so instead of the sheet saving a number nobody typed.
    var amount: Decimal { Self.strictDecimal(amountText.trimmingCharacters(in: .whitespaces)) ?? 0 }

    init(accountID: GncGUID? = nil, amountText: String = "") {
        self.accountID = accountID
        self.amountText = amountText
    }

    init(_ input: SplitInput) {
        self.splitID = input.splitID
        self.accountID = input.accountID
        self.amountText = NSDecimalNumber(decimal: input.value).stringValue
        self.quantityText = input.quantity.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        self.memo = input.memo
        self.action = input.action
    }

    /// The row as the engine takes it. Everything the editor knows about a
    /// split has to come back out here, including the parts it never showed.
    var asInput: SplitInput {
        SplitInput(splitID: splitID, accountID: accountID, value: amount,
                   quantity: quantity, memo: memo, action: action)
    }
}

/// Creates or edits a transaction with N balancing splits, with QuickFill.
struct TransactionEditorSheet: View {
    @Bindable var model: AppModel
    var editingID: GncGUID?
    /// A source document to record: shown in Quick Look beside the editor,
    /// prefills a new transaction, and is attached to whatever the editor
    /// commits (a new transaction, or one adopted via "Link to Existing…").
    var documentPrefill: DocumentPrefill?
    @Environment(\.dismiss) private var dismiss

    struct DocumentPrefill {
        var url: URL
        var description: String?
        var date: Date?
        var amount: Decimal?
        /// A foreign currency the document names (e.g. "MYR"), when detected.
        var currencyCode: String?
    }

    @State private var loaded = false
    @State private var date = Date()
    @State private var description = ""
    @State private var notes = ""
    @State private var tagsText = ""
    @State private var lines: [EditableSplit] = [EditableSplit(), EditableSplit()]
    @State private var commitError: String?
    @State private var invoicePickerShown = false
    @State private var analyzingInvoice = false
    @State private var linkPickerShown = false
    @State private var linkingToID: GncGUID?
    @State private var categorising = false
    // Foreign-amount converter (FR-CUR-01): foreign amount + currency; the rate
    // auto-fills from the price DB or a live fetch, and editing the local
    // amount back-solves the implied rate.
    @State private var fxShown = false
    @State private var fxAmountText = ""
    @State private var fxCode = "USD"
    @State private var fxRateText = ""
    @State private var fxLocalText = ""
    @State private var fxFetching = false
    @State private var fxError: String?
    /// A transaction currency differing from the accounts' (an FX purchase):
    /// split `value`s are in this currency, `quantity` moves each account in
    /// its own. Set by the converter's Apply, or by loading such a transaction.
    @State private var fxCurrencyOverride: Commodity?
    @Environment(\.appFontScale) private var appFontScale
    @Environment(\.appDateFormat) private var dateFormat
    private var amountWidth: CGFloat { 100 * appFontScale }

    // The hosted register row's plumbing: its cursor, its measured width, and
    // a stable identity for the synthetic row it hangs on.
    @FocusState private var cursor: TransactionEditField?
    @State private var rowWidth: CGFloat = 640
    @State private var rowSize: CGSize = CGSize(width: 640, height: 200)
    @State private var hostRowID = GncGUID.random()

    /// Everything on screen comes from the draft binding while editing, so the
    /// row itself only has to exist and keep a stable identity.
    private var hostRow: AutoSplitRow {
        AutoSplitRow(legID: hostRowID, account: "", memo: "", action: "",
                     reconcile: "", amount: 0, currencyCode: "")
    }

    private var rowMetrics: RegisterMetrics {
        RegisterMetrics(width: rowWidth, scale: appFontScale)
    }

    /// The sheet's state, seen as the register's draft. The getter assembles
    /// it from the fields the aux flows (prefill, invoice analysis, adopt, FX
    /// converter) already write; the setter routes the row's edits back into
    /// them. One source of truth, viewed two ways.
    private var rowDraft: Binding<TransactionDraft?> {
        Binding(
            get: {
                TransactionDraft(transactionID: editingID ?? hostRowID,
                                 date: date, description: description,
                                 notes: notes, tagsText: tagsText, lines: lines,
                                 currencyOverride: fxCurrencyOverride)
            },
            set: { new in
                guard let new else { return }
                date = new.date
                description = new.description
                notes = new.notes
                tagsText = new.tagsText
                lines = new.lines
            })
    }

    private var parsedTags: [String] {
        tagsText.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What is being typed after the last comma — the tag in progress, which is
    /// what suggestions should narrow on.
    private var tagFragment: String {
        String(tagsText.split(separator: ",", omittingEmptySubsequences: false).last ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Completes the tag in progress rather than appending after it, so picking
    /// "groceries" while "groc" is typed does not leave "groc, groceries".
    private func appendTag(_ tag: String) {
        var parts = tagsText.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty || !tagFragment.isEmpty { _ = parts.popLast() }
        parts.removeAll { $0.isEmpty }
        parts.append(tag)
        tagsText = parts.joined(separator: ", ")
    }

    private var imbalance: Decimal { lines.reduce(Decimal(0)) { $0 + $1.amount } }
    /// Currency of the transaction being built: an FX override (the foreign
    /// currency of a converted purchase), else the first cash account's.
    private var displayCurrency: Commodity {
        fxCurrencyOverride ?? model.transactionCurrency(for: lines.compactMap(\.accountID))
    }
    private var validLineCount: Int { lines.filter { $0.accountID != nil }.count }
    private var isBalanced: Bool {
        imbalance == 0 && validLineCount >= 2 && lines.allSatisfy(\.quantityIsValid)
    }
    private var isEditing: Bool { editingID != nil }

    /// The document to show beside the editor: the prefill's, or the edited
    /// transaction's own linked file.
    private var documentURL: URL? {
        if let documentPrefill { return documentPrefill.url }
        if let editingID { return model.linkedDocumentURL(for: editingID) }
        return nil
    }

    /// Never in the inspector: the preview wants 320pt of its own beside a form
    /// that already wants 340, which is wider than the inspector column can be —
    /// the window would have to grow to show it. The register's attachments
    /// panel is where an existing attachment is previewed; this pane is for the
    /// sheet, where a document being recorded has to be readable as it is keyed.
    private var showsDocumentPane: Bool {
        #if os(macOS)
        guard let documentURL else { return false }
        return FileManager.default.fileExists(atPath: documentURL.path)
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                editorForm
                    // Wide enough that the hosted row keeps its Transfer/
                    // Account column (the fold threshold is 640·scale) — a
                    // sheet that folded the account cells away would have no
                    // way to pick accounts.
                    .frame(minWidth: 660)
                #if os(macOS)
                if showsDocumentPane, let documentURL {
                    Divider()
                    EmbeddedQuickLook(url: documentURL)
                        .frame(minWidth: 320, idealWidth: 420)
                }
                #endif
            }
        }
        .frame(minWidth: showsDocumentPane ? 1020 : 700, minHeight: 540)
    }

    private var editorForm: some View {
            Form {
                if categorising {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Categorising from the linked transaction…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // The register row itself — the same view the account register
                // edits with, opened out, hosted beside the document. One
                // editing UI, not a resembling copy: same cells, same cursor,
                // same ⇥ order, same ⏎ saves / ⎋ cancels. ("Having two
                // different UIs for editing transactions will confuse the
                // user" — this sheet was the second UI.) The sheet's own
                // machinery — prefill, adopt-existing, invoice splitting, the
                // FX converter — keeps writing the same state; the row simply
                // becomes how that state is edited by hand.
                Section {
                    TransactionRowView(
                        model: model,
                        row: hostRow,
                        metrics: rowMetrics,
                        accounts: model.postableAccounts,
                        currencyCode: displayCurrency.mnemonic,
                        showsAccountColumn: false,
                        showsBalanceColumn: true,
                        isExpanded: true,
                        isSelected: true,
                        restSplits: [],
                        showsSecondLine: true,
                        dateText: { dateFormat.short($0) },
                        parseDate: { dateFormat.parseShort($0) },
                        draft: rowDraft,
                        cursor: $cursor,
                        focusAccountID: nil,
                        cycleReconcile: { _ in },
                        beginEdit: {},
                        expandEdit: {},
                        save: commit,
                        cancel: close)
                        .equatable()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: {
                            rowSize = $0
                            rowWidth = ($0.width / 8).rounded() * 8
                        }
                        .contentShape(.rect)
                        // Same outer-edge spatial tap as the register — the
                        // only position gestures reliably fire from.
                        .onTapGesture { point in
                            let target = RegisterTapMap.target(
                                point: point, rowSize: rowSize, metrics: rowMetrics,
                                draft: rowDraft.wrappedValue,
                                isExpanded: true, showsSecondLine: true,
                                showsAccountColumn: false, showsBalanceColumn: true,
                                focusAccountID: nil,
                                accounts: model.postableAccounts,
                                currencyCode: displayCurrency.mnemonic,
                                restSplitCount: 0)
                            switch target {
                            case .cursor(let field): cursor = field
                            case .removeSplit(let at): lines.remove(at: at)
                            case .appendSplit: lines.append(EditableSplit())
                            default: break
                            }
                        }
                }

                Section {
                    if !isEditing {
                        let suggestions = model.descriptionSuggestions(prefix: description)
                        if !suggestions.isEmpty {
                            Menu("Fill from recent…") {
                                ForEach(suggestions, id: \.self) { suggestion in
                                    Button(suggestion) { applyTemplate(suggestion) }
                                }
                            }
                        }
                    }
                    if model.isIntelligenceAvailable {
                        Button {
                            #if os(macOS)
                            if let url = MacFilePanel.open(types: [.pdf],
                                                           title: "Choose an invoice (PDF)") {
                                analyzeInvoice(url)
                            }
                            #else
                            invoicePickerShown = true
                            #endif
                        } label: {
                            Label(analyzingInvoice ? "Reading invoice…" : "Split from Invoice…",
                                  systemImage: "sparkles")
                        }
                        .disabled(analyzingInvoice)
                        .help("Read an invoice PDF and split this transaction across its line items")
                    }
                    // Fed by `Book.allTags`: the Tags cell is free text, so
                    // reusing a tag means remembering how you spelled it — the
                    // menu completes the tag in progress instead.
                    let tagSuggestions = model.tagSuggestions(prefix: tagFragment,
                                                              excluding: parsedTags)
                    if !tagSuggestions.isEmpty {
                        Menu("Add existing tag…") {
                            ForEach(tagSuggestions.prefix(20), id: \.self) { tag in
                                Button(tag) { appendTag(tag) }
                            }
                        }
                    }
                }

                Section {
                    if let foreign = fxCurrencyOverride {
                        // The transaction IS foreign-denominated: show the FX
                        // facts computed from the splits themselves — always in
                        // sync, impossible to be blank.
                        fxSummary(foreign)
                    } else {
                        DisclosureGroup(isExpanded: $fxShown) {
                            fxConverter
                        } label: {
                            Label("Foreign Amount", systemImage: "dollarsign.arrow.circlepath")
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Out of balance")
                        Spacer()
                        Text(AmountFormat.string(imbalance, code: displayCurrency.mnemonic))
                            .monospacedDigit()
                            .foregroundStyle(imbalance == 0 ? Color.secondary : Color.red)
                    }
                    if let commitError {
                        Text(commitError).scaledFont(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Transaction" : "New Transaction")
            // Esc cancels even while a text field has focus (cancelOperation
            // bubbles up the responder chain; .cancelAction alone doesn't).
            .onEscapeCommand { close() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                }
                if documentPrefill != nil {
                    ToolbarItem {
                        Button("Link to Existing…", systemImage: "link") { linkPickerShown = true }
                            .help("Attach this document to an existing transaction instead of creating a new one")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(commitTitle) { commit() }
                        .disabled(!isBalanced && linkingToID == nil)
                }
            }
            .onAppear(perform: loadIfNeeded)
            // Same AppKit-level ⇥ capture as the register (the key never
            // reaches per-field handlers on macOS).
            .captureTabs(while: true) { backwards in
                guard let draft = rowDraft.wrappedValue else { return }
                let order = draft.fieldOrder(metrics: rowMetrics,
                                             expandedOnScreen: true,
                                             showsSecondLine: true,
                                             showsBalanceColumn: true,
                                             focusAccountID: nil,
                                             accounts: model.postableAccounts,
                                             currencyCode: displayCurrency.mnemonic)
                if let next = draft.nextField(after: cursor, backwards: backwards, in: order) {
                    cursor = next
                }
            }
            .fileImporter(isPresented: $invoicePickerShown,
                          allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result { analyzeInvoice(url) }
            }
            .sheet(isPresented: $linkPickerShown) {
                if let prefill = documentPrefill {
                    LinkToTransactionSheet(model: model,
                                           match: AppModel.AttachmentMatch(url: prefill.url)) { id in
                        adoptExisting(id)
                    }
                }
            }
    }

    private var commitTitle: String {
        if linkingToID != nil { return "Link & Save" }
        return documentPrefill != nil ? "Add & Attach" : (isEditing ? "Save" : "Add")
    }

    /// Adopts an existing transaction for the document. All the work — attach,
    /// categorise, FX restructure — happens in ONE model call
    /// (``AppModel/adoptDocument``); the editor then reloads the finished
    /// transaction from the book. No view-state choreography to go wrong.
    private func adoptExisting(_ id: GncGUID) {
        guard let prefill = documentPrefill else { return }
        linkingToID = id
        reloadFromBook(id)   // show the picked transaction immediately
        categorising = true
        Task {
            defer { categorising = false }
            await model.adoptDocument(url: prefill.url,
                                      foreignAmount: prefill.amount,
                                      currencyCode: prefill.currencyCode,
                                      into: id)
            reloadFromBook(id)
            // Amounts mismatch but the document named no currency: hand the
            // converter every fact — the currency pick is the one human step.
            if fxCurrencyOverride == nil, prefill.currencyCode == nil,
               let docAmount = prefill.amount, docAmount > 0,
               let local = lines.compactMap({ $0.amount == 0 ? nil : abs($0.amount) }).max(),
               docAmount != local {
                fxAmountText = NSDecimalNumber(decimal: docAmount).stringValue
                fxLocalText = NSDecimalNumber(decimal: local).stringValue
                let implied = local / docAmount
                let sixDp = Decimal(NSDecimalNumber(decimal: implied * 1_000_000).intValue) / 1_000_000
                fxRateText = NSDecimalNumber(decimal: sixDp).stringValue
                fxShown = true
            }
        }
    }

    /// One reload point: the editor's state always mirrors the book's version
    /// of the transaction, FX currency override included.
    private func reloadFromBook(_ id: GncGUID) {
        guard let edit = model.editData(forTransaction: id) else { return }
        date = edit.date
        description = edit.description
        notes = edit.notes
        lines = edit.splits.map { EditableSplit($0) }
        tagsText = edit.tags.joined(separator: ", ")
        let derived = model.transactionCurrency(for: edit.splits.compactMap(\.accountID))
        fxCurrencyOverride = edit.currency != derived ? edit.currency : nil
    }

    /// Reads a linked invoice PDF and replaces the counter-splits with its
    /// categorised line items (`FR-AI-03`). The funding leg keeps its amount
    /// when one exists, so a mismatch with the invoice total shows up in the
    /// imbalance readout instead of being papered over.
    private func analyzeInvoice(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let data else { return }
        analyzingInvoice = true
        commitError = nil
        Task {
            defer { analyzingInvoice = false }
            do {
                let analysis = try await model.analyzeInvoicePDF(data)
                applyInvoice(analysis)
            } catch {
                commitError = error.localizedDescription
            }
        }
    }

    private func applyInvoice(_ analysis: InvoiceAnalysis) {
        if description.isEmpty { description = analysis.vendor }
        if !isEditing, let invoiceDate = analysis.date { date = invoiceDate }
        // Keep the existing funding row itself — identity included. Rebuilding
        // it as a fresh EditableSplit dropped its `splitID`, so saving an
        // existing transaction replaced every split and silently cleared the
        // funding leg's reconcile state (the exact regression the split-reuse
        // mechanism in updateTransaction exists to prevent).
        var funding = lines.first ?? EditableSplit()
        if funding.amount == 0 {
            funding.amountText = NSDecimalNumber(decimal: -analysis.total).stringValue
        }
        let items = analysis.lineItems.map {
            EditableSplit(accountID: $0.suggestedCategoryID,
                          amountText: NSDecimalNumber(decimal: $0.amount).stringValue)
        }
        guard !items.isEmpty else {
            commitError = "No line items were found in this invoice."
            return
        }
        lines = [funding] + items
    }

    /// The commodity a leg's own amount is denominated in, when it is not the
    /// transaction's currency — "USD" for a foreign account, "BHP" for shares.
    /// `nil` for an ordinary leg, which has one amount and needs one field.
    private func foreignUnit(of line: EditableSplit) -> String? {
        guard let id = line.accountID,
              let node = model.postableAccounts.first(where: { $0.id == id }),
              node.currencyCode != displayCurrency.mnemonic
        else { return nil }
        return node.currencyCode
    }

    /// The exchange rate the two amounts imply, stated so it can be checked
    /// against a statement: "10 BHP @ 40 AUD".
    private func rateDescription(of line: EditableSplit, unit: String) -> String {
        guard let quantity = line.quantity, quantity != 0, line.amount != 0 else {
            return "Amount in \(unit)"
        }
        let rate = line.amount / quantity
        let rounded = NSDecimalNumber(decimal: displayCurrency.round(rate)).stringValue
        return "\(NSDecimalNumber(decimal: quantity).stringValue) \(unit) @ \(rounded) \(displayCurrency.mnemonic)"
    }

    private var fxAmount: Decimal? { EditableSplit.strictDecimal(
        fxAmountText.trimmingCharacters(in: .whitespaces)) }
    private var fxRate: Decimal? { EditableSplit.strictDecimal(
        fxRateText.trimmingCharacters(in: .whitespaces)) }
    private var fxLocal: Decimal? { EditableSplit.strictDecimal(
        fxLocalText.trimmingCharacters(in: .whitespaces)) }

    /// The FX facts of a foreign-denominated transaction, read straight off
    /// the split lines: foreign total (positive values), local total (positive
    /// quantities), and the implied rate. No state to fill, nothing to desync.
    @ViewBuilder
    private func fxSummary(_ foreign: Commodity) -> some View {
        let foreignTotal = lines.filter { $0.amount > 0 }.reduce(Decimal(0)) { $0 + $1.amount }
        let localTotal = lines.reduce(Decimal(0)) { total, line in
            let local = line.quantity ?? line.amount
            return local > 0 ? total + local : total
        }
        let localCode = model.transactionCurrency(for: lines.compactMap(\.accountID)).mnemonic
        LabeledContent("Foreign amount") {
            Text("\(AmountFormat.string(foreignTotal, code: foreign.mnemonic))")
                .monospacedDigit()
        }
        LabeledContent("Local amount") {
            Text("\(AmountFormat.string(localTotal, code: localCode))")
                .monospacedDigit()
        }
        if foreignTotal > 0 {
            LabeledContent("Rate") {
                Text("1 \(foreign.mnemonic) = \(NSDecimalNumber(decimal: Decimal(NSDecimalNumber(decimal: localTotal / foreignTotal * 1_000_000).intValue) / 1_000_000).stringValue) \(localCode)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        Button("Remove Foreign Amount", role: .destructive) {
            // Back to a plain local transaction: values return to the local
            // amounts the quantities carry.
            for index in lines.indices {
                if let quantity = lines[index].quantity {
                    lines[index].amountText = NSDecimalNumber(decimal: quantity).stringValue
                    lines[index].quantityText = ""
                }
            }
            fxCurrencyOverride = nil
        }
        .help("Re-denominate in \(model.transactionCurrency(for: lines.compactMap(\.accountID)).mnemonic), discarding the foreign figures")
    }

    /// Enter the foreign amount; the rate fills from the book (or a live
    /// fetch); the local amount computes. Typing the local amount you *know*
    /// (the card charge) back-solves the implied rate — the truest rate for
    /// this purchase — and Apply teaches it to the price DB.
    @ViewBuilder
    private var fxConverter: some View {
        HStack(spacing: 8) {
            TextField("Amount", text: $fxAmountText)
                .multilineTextAlignment(.trailing)
                .frame(width: amountWidth)
                .onChange(of: fxAmountText) { recomputeLocal() }
            Picker("", selection: $fxCode) {
                ForEach(model.fxCurrencyCodes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: fxCode) { lookUpRate() }
            Text("@").foregroundStyle(.secondary)
            TextField("Rate", text: $fxRateText)
                .multilineTextAlignment(.trailing)
                .frame(width: amountWidth)
                .onChange(of: fxRateText) { recomputeLocal() }
            Button {
                fetchRate()
            } label: {
                if fxFetching { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.triangle.2.circlepath") }
            }
            .help("Fetch the live rate")
            .disabled(fxFetching)
        }
        HStack(spacing: 8) {
            Text("= \(displayCurrency.mnemonic)").foregroundStyle(.secondary)
            TextField("Local amount", text: $fxLocalText)
                .multilineTextAlignment(.trailing)
                .frame(width: amountWidth)
                .onChange(of: fxLocalText) { backSolveRate() }
            Spacer()
            Button("Apply to Splits") { applyFx() }
                .disabled(fxLocal == nil || fxLocal == 0)
                .help("Fill the split amounts with the local value, note the foreign amount in the memo, and record the rate")
        }
        .onAppear { if fxRateText.isEmpty { lookUpRate() } }
        if let fxError {
            Text(fxError).scaledFont(.caption).foregroundStyle(.red)
        }
    }

    private func lookUpRate() {
        guard let rate = model.storedFxRate(code: fxCode, on: date) else { return }
        fxRateText = NSDecimalNumber(decimal: displayCurrency.round(rate * 10_000) / 10_000).stringValue
        recomputeLocal()
    }

    private func fetchRate() {
        fxFetching = true
        fxError = nil
        Task {
            defer { fxFetching = false }
            do {
                let rate = try await model.fetchLiveFxRate(code: fxCode)
                fxRateText = NSDecimalNumber(decimal: rate).stringValue
                recomputeLocal()
            } catch {
                fxError = "Rate fetch failed: \(error.localizedDescription)"
            }
        }
    }

    private func recomputeLocal() {
        guard let fxAmount, let fxRate else { return }
        fxLocalText = NSDecimalNumber(decimal: displayCurrency.round(fxAmount * fxRate)).stringValue
    }

    /// Local edited by hand: derive the implied rate instead of fighting it.
    private func backSolveRate() {
        guard let fxAmount, fxAmount != 0, let fxLocal else { return }
        let implied = fxLocal / fxAmount
        let rounded = NSDecimalNumber(decimal: (implied * 1_000_000)).intValue
        let display = Decimal(rounded) / 1_000_000
        let current = fxRate ?? 0
        // Only rewrite when meaningfully different, or typing loops.
        if abs(current - display) > Decimal(string: "0.000001")! {
            fxRateText = NSDecimalNumber(decimal: display).stringValue
        }
    }

    /// Applies the conversion **structurally** (GnuCash's multi-currency form,
    /// not a memo): the transaction is denominated in the foreign currency —
    /// split `value`s carry ±1,773.84 MYR and balance the transaction — while
    /// each split's `quantity` carries ±600 AUD, which is what moves the
    /// account. The rate is thereby embedded as value/quantity, auditable and
    /// GnuCash-round-trippable; it is also recorded in the price DB.
    private func applyFx() {
        guard let fxLocal, fxLocal != 0, let fxAmount, fxAmount != 0 else { return }
        let foreign = model.currencyCommodity(fxCode)
        // The rate's local side is the accounts' own currency — captured
        // BEFORE the override flips `displayCurrency` to the foreign one.
        let localCurrency = model.transactionCurrency(for: lines.compactMap(\.accountID))
        let foreignText = NSDecimalNumber(decimal: foreign.round(fxAmount)).stringValue
        let localText = NSDecimalNumber(decimal: fxLocal).stringValue
        if lines.count < 2 { lines = [EditableSplit(), EditableSplit()] }
        fxCurrencyOverride = foreign
        // Money out of the first leg, into the category leg — values in the
        // foreign currency, quantities in the accounts' own (the local amount).
        lines[0].amountText = "-" + foreignText
        lines[0].quantityText = "-" + localText
        lines[1].amountText = foreignText
        lines[1].quantityText = localText
        // The implied/entered rate is real data — teach the price DB. Stored as
        // local-per-foreign against the accounts' own currency.
        if let fxRate { model.recordFxRate(code: fxCode, rate: fxRate, date: date, in: localCurrency) }
        fxShown = false
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let editingID, let edit = model.editData(forTransaction: editingID) {
            date = edit.date
            description = edit.description
            notes = edit.notes
            lines = edit.splits.map { EditableSplit($0) }
            tagsText = edit.tags.joined(separator: ", ")
            // An FX transaction's currency is its own fact — re-deriving it
            // from the accounts would re-save the values in the wrong unit.
            let derived = model.transactionCurrency(for: edit.splits.compactMap(\.accountID))
            if edit.currency != derived { fxCurrencyOverride = edit.currency }
        } else if let prefill = documentPrefill {
            if let d = prefill.date { date = d }
            if let desc = prefill.description, !desc.isEmpty { description = desc }
            if let code = prefill.currencyCode { fxCode = code }
            // A spending line prefilled with the read amount; the user picks the
            // paid-from and category accounts.
            if let amount = prefill.amount, amount != 0 {
                lines = [EditableSplit(amountText: NSDecimalNumber(decimal: -amount).stringValue),
                         EditableSplit(amountText: NSDecimalNumber(decimal: amount).stringValue)]
            }
        }
        // The cursor opens in the description, as the register's ⌘E does.
        cursor = .description
    }

    private func applyTemplate(_ suggestion: String) {
        description = suggestion
        if let template = model.template(forDescription: suggestion) {
            lines = template.map { EditableSplit($0) }
        }
    }

    /// Closes the editor, and clears the register's editing id with it — the
    /// same transaction is not left open out in the register behind a sheet
    /// that has just been dismissed.
    private func close() {
        model.editingTransactionID = nil
        dismiss()
    }

    private func commit() {
        let inputs = lines
            .filter { $0.accountID != nil }
            .map(\.asInput)
        let currency = displayCurrency
        do {
            let targetID = linkingToID ?? editingID
            if let targetID {
                try model.updateTransaction(id: targetID, date: date, description: description,
                                            currency: currency, splits: inputs,
                                            tags: parsedTags, notes: notes)
            } else {
                let newID = try model.addTransaction(date: date, description: description,
                                                     currency: currency, splits: inputs,
                                                     tags: parsedTags, notes: notes)
                // Recording a document: copy it into the folder and link it.
                if let prefill = documentPrefill,
                   let data = try? Data(contentsOf: prefill.url) {
                    model.attachDocumentReporting(named: prefill.url.lastPathComponent,
                                                  data: data, to: newID)
                }
            }
            close()
        } catch {
            // Keep the sheet up — the user's entry must not silently vanish.
            commitError = error.localizedDescription
        }
    }
}

// MARK: - Edit account

struct EditAccountSheet: View {
    @Bindable var model: AppModel
    let accountID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var name = ""
    @State private var code = ""
    @State private var description = ""
    @State private var notes = ""
    @State private var isPlaceholder = false
    @State private var isHidden = false
    @State private var hasColor = false
    @State private var color: Color = .appAccent
    @State private var parentID: GncGUID?
    @State private var originalParentID: GncGUID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                TextField("Code", text: $code)
                TextField("Description", text: $description)
                TextField("Notes", text: $notes, axis: .vertical)
                Picker("Parent", selection: $parentID) {
                    Text("Top level").tag(GncGUID?.none)
                    ForEach(model.validParents(forAccount: accountID)) { node in
                        Text(node.fullName).tag(GncGUID?.some(node.id))
                    }
                }
                Toggle("Group", isOn: $isPlaceholder)
                Toggle("Hidden", isOn: $isHidden)

                // GnuCash account colour — shown as a dot in the sidebar.
                Toggle("Colour", isOn: $hasColor.animation())
                if hasColor {
                    ColorPicker("Account colour", selection: $color, supportsOpacity: false)
                }

                Section {
                    Button("Renumber Sub-Accounts") {
                        model.renumberChildren(of: accountID)
                    }
                } footer: {
                    Text("Assigns sequential codes (010, 020, …) to this account's children.")
                }
            }
            .navigationTitle("Edit Account")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.updateAccount(id: accountID, name: name, code: code,
                                            description: description, notes: notes,
                                            isPlaceholder: isPlaceholder, isHidden: isHidden)
                        model.setAccountColor(accountID,
                                              colorString: hasColor ? GnuCashColor.gnuCashString(from: color) : nil)
                        if parentID != originalParentID {
                            model.moveAccount(accountID, under: parentID)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if !loaded, let edit = model.editData(forAccount: accountID) {
                    loaded = true
                    name = edit.name; code = edit.code; description = edit.description
                    notes = edit.notes; isPlaceholder = edit.isPlaceholder; isHidden = edit.isHidden
                    if let existing = model.accountColor(accountID).flatMap(GnuCashColor.color(from:)) {
                        hasColor = true
                        color = existing
                    }
                    parentID = model.parentID(ofAccount: accountID)
                    originalParentID = parentID
                }
                focusSoon { nameFocused = true }
            }
        }
    }
}
