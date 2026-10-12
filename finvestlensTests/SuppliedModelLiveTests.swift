//
//  SuppliedModelLiveTests.swift
//  finvestlensTests
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Every Apple Intelligence feature, asked of a model the person supplies —
//  a real one, run by MLX, from a folder on this Mac.
//
//  It lives here and not in a package because MLX is linked by the app
//  target alone (`MLXModelLoader`), and it goes the way the app goes: a
//  `SuppliedModelStore` is pointed at a folder, reads it, is told which
//  model to use, and hands that to `LanguageModels`; the features are then
//  called by their public entry points and know nothing of any of it.
//
//  Skipped unless a folder and a model are named. Nothing is downloaded —
//  the model has to be there already:
//
//      TEST_RUNNER_FL_MLX_FOLDER=~/.cache/huggingface/hub \
//      TEST_RUNNER_FL_MLX_MODEL=gemma-4-26b-a4b-it-4bit \
//      xcodebuild test -scheme finvestlens -destination 'platform=macOS' \
//        -only-testing:finvestlensTests/SuppliedModelLiveTests \
//        -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
//
//  The documents are the synthetic ones `LiveModelTests` asks Apple's model
//  about, as text, so the two can be compared. What is checked is substance —
//  amounts, signs, dates, which account — and never wording.
//

#if os(macOS)
import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
@testable import FinvestLensIntelligence
@testable import FinvestLensUI
@testable import finvestlens

/// The folder and model named in the environment, and the store that was
/// pointed at them.
@MainActor
enum SuppliedLive {
    static let folder = ProcessInfo.processInfo.environment["FL_MLX_FOLDER"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    static let wanted = ProcessInfo.processInfo.environment["FL_MLX_MODEL"]
    nonisolated static let isAsked =
        ProcessInfo.processInfo.environment["FL_MLX_FOLDER"]?.isEmpty == false
        && ProcessInfo.processInfo.environment["FL_MLX_MODEL"]?.isEmpty == false

    /// A store with preferences of its own: the run leaves the person's
    /// choice of model, and the folder they granted, as it found them.
    private static var prepared: SuppliedModelStore?

    static func store() async throws -> SuppliedModelStore {
        if let prepared { return prepared }
        // The app's own store read its (empty) folder at launch; let it
        // finish saying so before another says otherwise.
        await SuppliedModelStore.shared.refresh()

        let suite = "finvestlens.supplied-live.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SuppliedModelStore(defaults: defaults)
        store.install(MLXModelLoader())
        store.chooseFolder(try #require(folder))
        await store.refresh()
        let model = try #require(store.models.first { $0.name == wanted },
                                 "no runnable model named \(wanted ?? "?") among \(store.models.map(\.name))")
        store.use(model)
        await store.refreshAvailability()
        prepared = store
        return store
    }

    /// Runs `body` with the person's own model chosen, and says how long it
    /// took — the figure a person waiting on it would feel.
    static func asking<Result: Sendable>(
        _ what: String, _ body: @Sendable () async throws -> Result
    ) async throws -> Result {
        _ = try await store()
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await LanguageModels.$choiceOverride.withValue(.supplied) { try await body() }
        let seconds = Double((clock.now - started).components.seconds)
            + Double((clock.now - started).components.attoseconds) / 1e18
        note("\(what): \(String(format: "%.1f", seconds)) s")
        return result
    }

    /// One line of the run's findings — appended to the file `FL_MLX_LOG`
    /// names, because `xcodebuild` keeps no console log of a hosted run.
    nonisolated static func note(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["FL_MLX_LOG"], !path.isEmpty else {
            print("SUPPLIED-LIVE \(line)")
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// Thirty minutes a test, for the one that reads a long statement: a
// suite's limit and a test's own are both applied and the shorter wins, so
// the room has to be given here. (Qwen 3.8 27B does not finish it in ten.)
@Suite("Live: a model the person supplies", .enabled(if: SuppliedLive.isAsked),
       .timeLimit(.minutes(30)), .serialized)
@MainActor
struct SuppliedModelLiveTests {

    @Test("The folder is read, the model can run, and every feature goes to it")
    func chosen() async throws {
        // This launch is a test's host: it must not have reopened the last
        // book, which on the maintainer's Mac is a real one.
        #expect(TestHost.isActive)
        let store = try await SuppliedLive.store()
        let chosen = try #require(store.chosen)
        #expect(chosen.bytes > 1_000_000_000, "weights weigh \(chosen.bytes) bytes")
        #expect(store.availability == .available, "\(store.availability)")
        #expect(LanguageModels.supplied?.name == chosen.name)
        SuppliedLive.note("models offered: \(store.models.count); in use: \(chosen.name), type \(chosen.modelType ?? "?")")

        LanguageModels.$choiceOverride.withValue(.supplied) {
            for feature in IntelligenceFeature.allCases {
                #expect(LanguageModels.choice(for: feature) == .supplied, "\(feature)")
                #expect(!LanguageModels.leavesDevice(feature), "\(feature)")
                #expect(LanguageModels.availability(for: feature).isAvailable, "\(feature)")
            }
        }
    }

    static let statementText = """
        EXAMPLE BANK — Everyday Account Statement
        Statement period 1 March 2026 to 31 March 2026
        Opening balance 3,000.00

        Date        Description                        Debit      Credit     Balance
        02/03/2026  WOOLWORTHS METRO SYDNEY            45.20                 2,954.80
        05/03/2026  SALARY ACME PTY LTD                           5,200.00   8,154.80
        09/03/2026  TRANSPORT FOR NSW TAP               62.35                8,092.45
        14/03/2026  NETFLIX.COM                         22.99                8,069.46

        Closing balance 8,069.46
        """

    @Test("A bank statement becomes signed, dated transactions")
    func statement() async throws {
        let text = Self.statementText
        let staged = try await SuppliedLive.asking("statement") {
            try await StatementExtractor.extract(pages: [DocumentText.Page(number: 1, text: text)])
        }
        #expect(staged.count == 4, "expected 4 rows, got \(staged.map(\.payee))")
        let salary = try #require(staged.first { $0.amount > 0 })
        #expect(salary.amount == 5200)
        let woolworths = try #require(staged.first { $0.payee.uppercased().contains("WOOLWORTHS") })
        #expect(woolworths.amount == Decimal(string: "-45.20"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.month, from: woolworths.date) == 3)
        #expect(calendar.component(.year, from: woolworths.date) == 2026)
    }

    /// The statement reader keeps a row only if its date and amount parse and
    /// its payee and amount are printed in the text it was read from. This
    /// asks the model for the same page and notes each row it wrote beside
    /// the check that would drop it — the first thing to read when a supplied
    /// model returns fewer rows than the page has.
    @Test("What the model wrote for a statement page, row by row")
    func statementRows() async throws {
        let slice = Self.statementText
        let page = try await SuppliedLive.asking("statement, raw") {
            try await LanguageModels.respond(
                .statementExtractor,
                instructions: StatementExtractor.instructions,
                prompt: StatementExtractor.prompt(for: slice),
                generating: StatementExtractor.ModelPage.self)
        }
        let source = SourceGrounding.folded(slice)
        SuppliedLive.note("  opening balance written as “\(page.openingBalance)”")
        for row in page.transactions {
            var dropped: [String] = []
            if IntelligenceParsing.date(row.date) == nil { dropped.append("date") }
            if IntelligenceParsing.amount(row.amount) == nil { dropped.append("amount") }
            if !SourceGrounding.isNamePrinted(row.payee, in: source) { dropped.append("payee not printed") }
            if !SourceGrounding.isAmountPrinted(row.amount, in: source) { dropped.append("amount not printed") }
            SuppliedLive.note("  row date “\(row.date)” amount “\(row.amount)” payee “\(row.payee)” "
                + "reference “\(row.reference)” balance “\(row.balanceAfter)” → "
                + (dropped.isEmpty ? "kept" : "DROPPED: " + dropped.joined(separator: ", ")))
        }
        #expect(!page.transactions.isEmpty)
    }

    @Test("Documents are told apart")
    func classification() async throws {
        let statement = """
            EXAMPLE BANK — Everyday Account
            Period 1 May 2026 to 31 May 2026, opening 4,120.55
            04/05/2026 WOOLWORTHS 82.45 4,038.10
            07/05/2026 SALARY 5,200.00 9,238.10
            Closing 9,238.10
            """
        let dividend = """
            BHP GROUP LIMITED — DIVIDEND STATEMENT
            ASX Code: BHP — payment date 12 June 2026
            Fully franked dividend 412.30, franking credits 176.70
            Net dividend paid to your nominated account 412.30
            """
        let invoice = """
            OFFICEWORKS — TAX INVOICE #IN-559023
            1 Brother Laser Printer 499.00
            TOTAL (inc GST) 499.00
            """
        let kinds = try await SuppliedLive.asking("classification ×3") {
            [await DocumentClassifier.classify(text: statement),
             await DocumentClassifier.classify(text: dividend),
             await DocumentClassifier.classify(text: invoice)]
        }
        #expect(kinds == [.bankStatement, .dividendStatement, .invoice])
    }

    /// The one thing about the wording that no package test can see: that
    /// asking a supplied model is *recorded*, so that what is said of the
    /// request afterwards names the right model.
    @Test("What is said of a request names the model that was asked")
    func wording() async throws {
        _ = try await SuppliedLive.asking("one document's kind") {
            await DocumentClassifier.classify(text: "OFFICEWORKS — TAX INVOICE #IN-559023\nTOTAL (inc GST) 499.00")
        }
        #expect(LanguageModels.speaksOfOwnModel)
        let said = try #require(IntelligenceError.busy.errorDescription)
        #expect(said == IntelligenceError.busy.description(ofOwnModel: true))
        #expect(!said.contains("Apple Intelligence"))
        LanguageModels.$choiceOverride.withValue(.supplied) {
            #expect(LanguageModels.usesOwnModel(for: .statementExtractor))
        }
        // Forgotten, the question falls to which model a request *would* be
        // sent to — and outside the harness's own requests that is Apple's,
        // because the person's stored choice was never touched.
        LanguageModels.forgetLastAsked()
        #expect(LanguageModels.speaksOfOwnModel == (LanguageModels.choice(for: .statementExtractor) == .supplied))
    }

    @Test("Transactions are categorised onto the offered accounts, the same way twice")
    func categorisation() async throws {
        let candidates = [
            CategoryCandidate(id: .random(), fullName: "Expenses:Food:Groceries"),
            CategoryCandidate(id: .random(), fullName: "Expenses:Entertainment:Streaming"),
            CategoryCandidate(id: .random(), fullName: "Expenses:Transport:Public Transport"),
            CategoryCandidate(id: .random(), fullName: "Income:Salary", isIncome: true),
        ]
        let items = [
            CategorizationItem(payee: "WOOLWORTHS METRO SYDNEY", amount: Decimal(string: "-45.20")!),
            CategorizationItem(payee: "NETFLIX.COM", amount: Decimal(string: "-22.99")!),
            CategorizationItem(payee: "SALARY ACME PTY LTD", amount: 5200),
        ]
        let suggestions = try await SuppliedLive.asking("categorisation") {
            try await TransactionCategorizer.suggest(items: items, candidates: candidates)
        }
        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.fullName) })
        #expect(suggestions[items[0].id].map { byName[$0] } == "Expenses:Food:Groceries")
        #expect(suggestions[items[1].id].map { byName[$0] } == "Expenses:Entertainment:Streaming")
        #expect(suggestions[items[2].id].map { byName[$0] } == "Income:Salary")

        // The feature's profile asks for greedy sampling; a supplied model
        // has to honour it, or the same import categorises differently on
        // each press.
        let again = try await SuppliedLive.asking("categorisation, again") {
            try await TransactionCategorizer.suggest(items: items, candidates: candidates)
        }
        #expect(again == suggestions)
    }

    static let invoiceText = """
        HARVEY NORMAN — TAX INVOICE #INV-88231
        Date: 14 March 2026

        Qty  Item                                          Amount
        1    LG 27" 4K Monitor                             449.00
        1    Logitech MX Keys Keyboard                     199.95
        2    HDMI 2.1 Cable                                 59.90

        Subtotal (inc GST)                                708.85
        TOTAL                                             708.85
        """

    /// The invoice reader's own request, and what came back before anything
    /// was parsed or checked.
    @Test("What the model wrote for an invoice, field by field")
    func invoiceFields() async throws {
        let (invoice, truncated) = try await SuppliedLive.asking("invoice, raw") {
            try await LanguageModels.respond(
                .invoiceAnalyzer, instructions: InvoiceAnalyzer.instructions,
                document: Self.invoiceText, framing: { "Invoice text:\n\n\($0)" },
                generating: InvoiceAnalyzer.ModelInvoice.self)
        }
        SuppliedLive.note("  vendor “\(invoice.vendor)” date “\(invoice.date)” total “\(invoice.total)” truncated \(truncated)")
        for line in invoice.lineItems {
            SuppliedLive.note("  item “\(line.item)” amount “\(line.amount)” → "
                + (IntelligenceParsing.amount(line.amount).map { "\($0)" } ?? "UNPARSED"))
        }
        #expect(!truncated)
        #expect(invoice.lineItems.count == 3)
    }

    @Test("An invoice splits into line items that add up")
    func invoice() async throws {
        let text = Self.invoiceText
        let candidates = [
            CategoryCandidate(id: .random(), fullName: "Expenses:Home Office:Equipment"),
            CategoryCandidate(id: .random(), fullName: "Expenses:Food:Groceries"),
        ]
        let analysis = try await SuppliedLive.asking("invoice") {
            try await InvoiceAnalyzer.analyze(text: text, candidates: candidates)
        }
        #expect(analysis.vendor.uppercased().contains("HARVEY"))
        #expect(analysis.total == Decimal(string: "708.85"))
        #expect(analysis.lineItems.count == 3, "got \(analysis.lineItems.map(\.itemDescription))")
        #expect(analysis.lineItemSum == analysis.total,
                "items \(analysis.lineItems.map { "\($0.itemDescription)=\($0.amount)" })")
        let equipment = candidates[0].id
        let categories = analysis.lineItems.map(\.suggestedCategoryID)
        #expect(categories.allSatisfy { $0 == equipment })
    }

    @Test("A dividend statement gives its franked components and credits")
    func dividend() async throws {
        let text = """
            COMMONWEALTH BANK OF AUSTRALIA — DIVIDEND STATEMENT
            ASX Code: CBA
            Payment date: 26 March 2026

            Fully franked dividend                          217.00
            Unfranked dividend                                0.00
            Franking credits                                 93.00

            Net dividend paid to your bank account          217.00
            """
        let details = try await SuppliedLive.asking("dividend") {
            try await DividendExtractor.extract(text: text)
        }
        #expect(details.ticker == "CBA")
        #expect(details.frankedAmount == 217)
        #expect(details.unfrankedAmount == 0)
        #expect(details.frankingCredits == 93)
        #expect(details.netPayment == 217)
        #expect(details.componentsMatchPayment)
    }

    @Test("A receipt says what a transaction was and where it belongs")
    func attachment() async throws {
        let candidates = [
            CategoryCandidate(id: .random(), fullName: "Expenses:Home Office:Equipment"),
            CategoryCandidate(id: .random(), fullName: "Expenses:Food:Groceries"),
        ]
        let receipt = """
            OFFICEWORKS — TAX INVOICE #IN-559023
            1 Brother Laser Printer 499.00
            TOTAL (inc GST) 499.00
            """
        let insight = try await SuppliedLive.asking("attachment insight") {
            try await AttachmentInsight.analyze(
                documentText: receipt, currentDescription: "EFTPOS 4471 SYDNEY",
                amount: Decimal(string: "-499.00")!, candidates: candidates)
        }
        #expect(insight?.accountID == candidates[0].id)
    }

    @Test("A budget is proposed for each category, with reasons")
    func budget() async throws {
        let history = [
            SpendingHistory(categoryID: .random(), fullName: "Expenses:Food:Groceries",
                            monthlyAverage: 820, monthlyMinimum: 760, monthlyMaximum: 905),
            SpendingHistory(categoryID: .random(), fullName: "Expenses:Food:Dining Out",
                            monthlyAverage: 460, monthlyMinimum: 300, monthlyMaximum: 640),
        ]
        let suggestion = try await SuppliedLive.asking("budget") {
            try await BudgetAdvisor.suggest(history: history, monthlyIncome: 7800, currencyCode: "AUD")
        }
        #expect(!suggestion.summary.isEmpty)
        #expect(suggestion.lines.count == 2, "got \(suggestion.lines.map(\.fullName))")
        for line in suggestion.lines {
            #expect(line.monthlyAmount > 0)
        }
        // A reason for each line is asked for, and Apple's model gives one.
        // An open model may not — Qwen 3.8 27B left one of two empty — and
        // the sheet then shows that line without a reason; nothing is made
        // up in its place. Noted, not failed: it is how well the model
        // writes, which is the model's.
        let unexplained = suggestion.lines.filter { $0.rationale.trimmingCharacters(in: .whitespaces).isEmpty }
        SuppliedLive.note("  budget lines without a reason: \(unexplained.count) of \(suggestion.lines.count)")
        if let groceries = suggestion.lines.first(where: { $0.categoryID == history[0].categoryID }) {
            #expect(groceries.monthlyAmount >= 600 && groceries.monthlyAmount <= 1000,
                    "groceries suggestion \(groceries.monthlyAmount) outside sanity band")
        }
    }

    @Test("Commentary is written from computed figures, and survives the number check")
    func narration() async throws {
        let income = ReportFacts(
            reportTitle: "Income Statement", periodLabel: "FY 2025–26", currencyCode: "AUD",
            headline: [("Income", Decimal(string: "90643.50")!), ("Expenses", Decimal(string: "66610.82")!),
                       ("Net income", Decimal(string: "24032.68")!)],
            lines: [("Income:Salary", Decimal(string: "89400.00")!),
                    ("Expenses:Housing", Decimal(string: "25680.00")!)])
        let notes = try await SuppliedLive.asking("report commentary") {
            try await ReportNarrator.narrate(facts: income)
        }
        #expect((1...4).contains(notes.count), "got \(notes)")

        let spending = ReviewSlideFacts(
            kicker: "Spending", periodLabel: "FY 2025–26", currencyCode: "AUD",
            figures: [("Total spending", Decimal(string: "66610.82")!),
                      ("Groceries", Decimal(string: "12480.55")!),
                      ("Housing", Decimal(string: "25680.00")!)],
            deltaPercents: [("Total spending", Decimal(string: "-8.4")!)])
        let story = try await SuppliedLive.asking("review slide") {
            try await ReviewNarrator.story(facts: spending)
        }
        #expect(!story.headline.isEmpty)
        #expect(!story.insight.isEmpty)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func day(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        }
        let forecast = ForecastFacts(
            currencyCode: "AUD", accountName: "Everyday", horizonDays: 90,
            openingBalance: 8069, closingBalance: 9420, lowestBalance: 3105,
            lowestBalanceDate: day(8, 2),
            upcoming: [(day(8, 1), "Rent", -2600), (day(8, 15), "Salary", 5200)],
            recentMonthlyNet: 450)
        let outlook = try await SuppliedLive.asking("forecast outlook") {
            try await ForecastNarrator.narrate(facts: forecast)
        }
        #expect(!outlook.headline.isEmpty)
        #expect(outlook.insights.count <= 4)
    }

    /// A hundred and twenty rows over three pages, printed the way a bank
    /// prints: two decimals, thousands separated, a header on every page.
    /// (The first version wrote "10" and "11.1", and a model that tidied
    /// those to "10.00" had its rows dropped as amounts the page does not
    /// print — the fixture's fault, not the reader's.)
    static func longStatement() -> [DocumentText.Page] {
        let money = Decimal.FormatStyle.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_AU"))
        var rows: [String] = []
        var balance = Decimal(10_000)
        for row in 0..<120 {
            let amount = Decimal(10 + row % 37) + Decimal((row * 7) % 100) / 100
            balance -= amount
            let day = String(format: "%02d", 1 + row % 28)
            let month = String(format: "%02d", 1 + (row / 28) % 12)
            rows.append("\(day)/\(month)/2026  CARD PURCHASE \(1000 + row) SYDNEY        "
                + "\(amount.formatted(money))               \(balance.formatted(money))")
        }
        return stride(from: 0, to: rows.count, by: 40).enumerated().map { index, start in
            DocumentText.Page(number: index + 1, text: ([
                "EXAMPLE BANK — Everyday Account Statement, page \(index + 1)",
                index == 0 ? "Opening balance 10,000.00" : "",
                "Date        Description                        Debit      Credit     Balance",
            ] + rows[start..<min(start + 40, rows.count)]).joined(separator: "\n"))
        }
    }

    /// The long statement as the reader cuts it, one slice at a time, noting
    /// for each how many rows the page has, how many the model wrote, how
    /// many the reader's checks would keep, and anything that failed — the
    /// reader itself drops a slice that fails and goes on, so this is where
    /// to look when it returns fewer rows than were printed.
    @Test("Where a long statement's rows go, slice by slice")
    func longStatementSlices() async throws {
        var printed = 0, written = 0, kept = 0
        for page in Self.longStatement() {
            for slice in StatementExtractor.lineGroups(page.text, budget: StatementExtractor.sliceBudget) {
                let onPage = slice.split(separator: "\n").filter { $0.contains("CARD PURCHASE") }.count
                printed += onPage
                do {
                    let answer = try await SuppliedLive.asking("  slice of \(slice.count) characters, \(onPage) rows") {
                        try await LanguageModels.respond(
                            .statementExtractor, instructions: StatementExtractor.instructions,
                            prompt: StatementExtractor.prompt(for: slice),
                            generating: StatementExtractor.ModelPage.self)
                    }
                    let source = SourceGrounding.folded(slice)
                    let good = answer.transactions.filter {
                        IntelligenceParsing.date($0.date) != nil && IntelligenceParsing.amount($0.amount) != nil
                            && SourceGrounding.isNamePrinted($0.payee, in: source)
                            && SourceGrounding.isAmountPrinted($0.amount, in: source)
                    }
                    written += answer.transactions.count
                    kept += good.count
                    SuppliedLive.note("    wrote \(answer.transactions.count), kept \(good.count) of \(onPage)")
                    for row in answer.transactions where !good.contains(where: { $0.date == row.date && $0.amount == row.amount && $0.payee == row.payee }) {
                        SuppliedLive.note("    not kept: date “\(row.date)” amount “\(row.amount)” payee “\(row.payee.prefix(40))”")
                    }
                } catch {
                    SuppliedLive.note("    FAILED: \(error)")
                }
            }
        }
        SuppliedLive.note("long statement: printed \(printed), written \(written), kept \(kept)")
        #expect(printed == 120)
    }

    @Test("A long statement is read slice by slice, and most of its rows survive")
    func longDocument() async throws {
        // A hundred and twenty rows is a dozen requests: the reader cuts a
        // page into slices of a thousand characters whatever the model's
        // window. On a supplied model some of those answers lose their
        // place, and the reader reads those slices again in halves — which
        // is what this run is for, and why it takes as long as it does.
        let pages = Self.longStatement()
        let staged = try await SuppliedLive.asking("statement, 120 rows over \(pages.count) pages") {
            try await StatementExtractor.extract(pages: pages)
        }
        SuppliedLive.note("  kept \(staged.count) of 120 rows")
        // Not every row need survive; most must, and none may be invented.
        #expect(staged.count >= 108 && staged.count <= 120, "got \(staged.count) rows")
        #expect(staged.allSatisfy { $0.amount < 0 })
    }
}
#endif
