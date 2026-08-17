//
//  AppImportTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Bank import pipeline")
struct AppImportTests {

    @Test("Parse → match → import posts new rows and skips duplicates")
    func endToEnd() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))

        // History: a Woolworths purchase, so it can be detected as a duplicate.
        model.addTransfer(from: bank, to: groceries, amount: Decimal(string: "52.30")!,
                          date: Date(timeIntervalSince1970: 1_600_000_000), description: "Woolworths")
        // addTransfer(from bank to groceries, amount) → groceries +52.30, bank -52.30.

        let qif = """
        !Type:Bank
        D09/13/2020
        T-52.30
        PWoolworths
        ^
        D09/20/2020
        T-19.99
        PNetflix
        ^
        """
        let staged = model.parseBankFile(Data(qif.utf8), format: .qif)
        #expect(staged.count == 2)

        let results = model.matchStaged(staged, intoAccountID: bank)
        let woolworths = try #require(results.first { $0.staged.payee == "Woolworths" })
        let netflix = try #require(results.first { $0.staged.payee == "Netflix" })
        #expect(woolworths.isDuplicate)                 // matches the history row
        #expect(!netflix.isDuplicate)

        // Assign Netflix → Subscriptions; import (skipping the duplicate).
        let imported = model.importMatched(results, intoAccountID: bank,
                                           assignments: [netflix.staged.id: subs])
        #expect(imported == 1)

        // Bank now reflects history (−52.30) + Netflix (−19.99).
        let bankNode = try #require(model.accountTree.first { $0.name == "Bank" })
        #expect(bankNode.balance == Decimal(string: "-72.29"))
        _ = groceries
    }

    @Test("A QIF split record imports as a multi-category transaction (FR-XIO-01)")
    func splitImport() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        _ = try #require(model.addAccount(name: "Groceries", type: .expense))
        _ = try #require(model.addAccount(name: "Household", type: .expense))

        let qif = """
        !Type:Bank
        D01/15/2024
        T-120.00
        PSupermarket
        SGroceries
        $-90.00
        SHousehold
        $-30.00
        ^
        """
        let staged = model.parseBankFile(Data(qif.utf8), format: .qif)
        #expect(staged.first?.isSplit == true)

        let results = model.matchStaged(staged, intoAccountID: bank)
        #expect(model.importMatched(results, intoAccountID: bank) == 1)

        // Bank −120; each category leg posted to its account.
        let bankNode = try #require(model.accountTree.first { $0.name == "Bank" })
        #expect(bankNode.balance == Decimal(string: "-120.00"))
        let groceriesNode = try #require(model.accountTree.first { $0.name == "Groceries" })
        #expect(groceriesNode.balance == Decimal(string: "90.00"))
        let householdNode = try #require(model.accountTree.first { $0.name == "Household" })
        #expect(householdNode.balance == Decimal(string: "30.00"))
    }

    @Test("GnuCash import preserves prices, book GUID, and KVP into the saved document")
    func gnuCashImportKeepsEverything() async throws {
        let bookGUID = GncGUID.random().hexString
        let root = GncGUID.random().hexString
        let bank = GncGUID.random().hexString
        let priceGUID = GncGUID.random().hexString
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <gnc-v2>
        <gnc:book version="2.0.0">
        <book:id type="guid">\(bookGUID)</book:id>
        <book:slots><slot><slot:key>feature-x</slot:key>
          <slot:value type="string">on</slot:value></slot></book:slots>
        <gnc:commodity version="2.0.0">
          <cmdty:space>ASX</cmdty:space><cmdty:id>BHP</cmdty:id>
          <cmdty:name>BHP Group</cmdty:name><cmdty:fraction>10000</cmdty:fraction>
        </gnc:commodity>
        <gnc:pricedb version="1">
          <price>
            <price:id type="guid">\(priceGUID)</price:id>
            <price:commodity><cmdty:space>ASX</cmdty:space><cmdty:id>BHP</cmdty:id></price:commodity>
            <price:currency><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></price:currency>
            <price:time><ts:date>2026-06-01 00:00:00 +0000</ts:date></price:time>
            <price:value>4512/100</price:value>
          </price>
        </gnc:pricedb>
        <gnc:account version="2.0.0">
          <act:name>Root Account</act:name><act:id type="guid">\(root)</act:id><act:type>ROOT</act:type>
        </gnc:account>
        <gnc:account version="2.0.0">
          <act:name>Bank</act:name><act:id type="guid">\(bank)</act:id><act:type>BANK</act:type>
          <act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity>
          <act:parent type="guid">\(root)</act:parent>
        </gnc:account>
        </gnc:book>
        </gnc-v2>
        """
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).gnucash")
        let destination = tempURL()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data(xml.utf8).write(to: source)

        let model = AppModel()
        await model.importGnuCashBook(from: source, saveAs: destination)
        #expect(model.documentError == nil)
        try #require(model.isOpen)

        // In memory: the price, book GUID, and book KVP came across.
        #expect(model.book?.prices.count == 1)
        #expect(model.book?.guid.hexString == bookGUID)
        #expect(model.book?.kvp["feature-x"] == .string("on"))
        try model.save()
        model.close()

        // On disk (after reopen): all of it persisted.
        try await model.open(at: destination)
        defer { model.close() }
        #expect(model.book?.prices.count == 1)
        #expect(model.book?.prices.first?.value == Decimal(string: "45.12"))
        #expect(model.book?.guid.hexString == bookGUID)
        #expect(model.book?.kvp["feature-x"] == .string("on"))
    }

    @Test("Format is inferred from the extension")
    func formatDetection() {
        #expect(BankFileFormat.forExtension("CSV") == .csv)
        #expect(BankFileFormat.forExtension("qif") == .qif)
        #expect(BankFileFormat.forExtension("qfx") == .ofx)
        #expect(BankFileFormat.forExtension("sta") == .mt940)
        #expect(BankFileFormat.forExtension("940") == .mt940)
        #expect(BankFileFormat.forExtension("c53") == .camt)
        #expect(BankFileFormat.forExtension("pdf") == .pdf)  // via Apple Intelligence (FR-AI-01)
        #expect(BankFileFormat.forExtension("docx") == nil)
    }

    @Test("Unknown extensions fall back to content sniffing (FR-XIO-04)")
    func contentSniffing() {
        let camt = Data("""
        <?xml version="1.0"?>
        <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.02">
        <BkToCstmrStmt/></Document>
        """.utf8)
        #expect(BankFileFormat.detect(camt, extension: "xml") == .camt)

        let mt940 = Data(":20:REF1\n:25:AU/1\n:61:2606010601D52,30NMSC//X\n".utf8)
        #expect(BankFileFormat.detect(mt940, extension: "txt") == .mt940)

        let ofx = Data("OFXHEADER:100\nDATA:OFXSGML\n<OFX>...".utf8)
        #expect(BankFileFormat.detect(ofx, extension: "txt") == .ofx)

        // The extension still wins when it is decisive.
        #expect(BankFileFormat.detect(camt, extension: "c53") == .camt)
        #expect(BankFileFormat.detect(Data("hello".utf8), extension: "bin") == nil)
    }

    @Test("Importing the other side of a transfer heals the wash leg (FR-XIO-05)")
    func transferHeal() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let cma = try #require(model.addAccount(name: "CMA", type: .bank))
        let cmaa = try #require(model.addAccount(name: "CMAA", type: .bank))
        let wash = try #require(model.addAccount(name: "Unspecified", type: .income))
        // The CMAA statement went first: its side of the transfer is in, the
        // other leg parked in the wash account.
        model.addTransfer(from: cmaa, to: wash, amount: Decimal(5000),
                          date: Date(timeIntervalSince1970: 1_770_000_000),
                          description: "To Smsf Pty Ltd Atf Internal transfer")

        // Now the CMA statement reports the same $5,000 arriving.
        let staged = [StagedTransaction(date: Date(timeIntervalSince1970: 1_770_000_000),
                                        amount: Decimal(5000), payee: "From Smsf Pty Ltd Atf",
                                        reference: "RCPT-72063013",
                                        referenceIsBankUnique: true)]
        let results = model.matchStaged(staged, intoAccountID: cma)
        let row = try #require(results.first)
        #expect(row.transferSplitID != nil)
        #expect(row.suggestedAccountID == cmaa)

        #expect(model.importMatched(results, intoAccountID: cma) == 1)

        // One transaction, legs CMA/CMAA, wash account emptied — not a mirror pair.
        let book = try #require(model.book)
        #expect(book.transactions.count == 1)
        #expect(book.splits(for: book.account(with: wash)!).isEmpty)
        let healed = try #require(book.splits(for: book.account(with: cma)!).first)
        #expect(healed.value == Decimal(5000))
        #expect(healed.kvp["online_id"] == .string("RCPT-72063013"))
        #expect(book.splits(for: book.account(with: cmaa)!).first?.value == Decimal(-5000))
    }

    @Test("Skipped duplicates get the statement reference stamped for exact re-imports")
    func duplicateReferenceStamp() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        model.addTransfer(from: bank, to: groceries, amount: Decimal(string: "52.30")!,
                          date: Date(timeIntervalSince1970: 1_600_000_000), description: "Woolworths")

        let staged = [StagedTransaction(date: Date(timeIntervalSince1970: 1_600_000_000),
                                        amount: Decimal(string: "-52.30")!, payee: "Woolworths",
                                        reference: "FIT-777",
                                        referenceIsBankUnique: true)]
        let results = model.matchStaged(staged, intoAccountID: bank)
        #expect(results.first?.isDuplicate == true)
        #expect(model.importMatched(results, intoAccountID: bank) == 0)

        let book = try #require(model.book)
        let bankSplit = try #require(book.splits(for: book.account(with: bank)!).first)
        #expect(bankSplit.kvp["online_id"] == .string("FIT-777"))
    }

    @Test("Rows without a destination fall back to the imbalance account when asked")
    func imbalanceFallback() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let imbalance = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))

        let staged = [StagedTransaction(date: Date(timeIntervalSince1970: 1_700_000_000),
                                        amount: Decimal(string: "-42.00")!, payee: "Mystery Shop")]
        let results = model.matchStaged(staged, intoAccountID: bank)
        #expect(results.first?.suggestedAccountID == nil)

        // Without the fallback the row is skipped; with it, it posts to Imbalance.
        #expect(model.importMatched(results, intoAccountID: bank) == 0)
        #expect(model.importMatched(results, intoAccountID: bank, fallbackToImbalance: true) == 1)
        let book = try #require(model.book)
        #expect(book.splits(for: book.account(with: imbalance)!).first?.value == Decimal(42))
    }

    /// A row the user cleared must leave the import entirely — the review sheet
    /// drops it from the array rather than merely un-assigning it.
    ///
    /// Two ways to get this wrong, both of which shipped:
    /// `assignments[id] = nil` *removes* the key, so the row falls back to the
    /// matcher's suggestion; and a row with no destination is swept into
    /// Imbalance by `fallbackToImbalance`, which is on by default. Excluding by
    /// destination alone therefore imports the row twice over.
    @Test("A cleared row stays out, even with the imbalance fallback on")
    func clearedRowIsExcluded() throws {
        let dropped = Decimal(string: "-99.00")!
        let kept = Decimal(string: "-10.00")!

        /// Runs one import and returns (rows imported, every split value).
        /// `exclude` is what the review sheet does when a row is cleared.
        func importRun(excludingDropped exclude: Bool) throws -> (Int, [Decimal]) {
            let url = tempURL()
            let model = AppModel()
            try model.newDocument(at: url)
            defer { model.close(); try? FileManager.default.removeItem(at: url) }

            let bank = try #require(model.addAccount(name: "Bank", type: .bank))
            let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
            _ = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))

            let day = Date(timeIntervalSince1970: 1_700_000_000)
            let results = model.matchStaged([
                StagedTransaction(date: day, amount: kept, payee: "Keep This"),
                StagedTransaction(date: day, amount: dropped, payee: "Drop This"),
            ], intoAccountID: bank)
            let keep = try #require(results.first { $0.staged.payee == "Keep This" })
            let drop = try #require(results.first { $0.staged.payee == "Drop This" })

            let posting = exclude ? results.filter { $0.staged.id != drop.staged.id } : results
            let count = model.importMatched(posting, intoAccountID: bank,
                                            assignments: [keep.staged.id: groceries],
                                            fallbackToImbalance: true)
            let book = try #require(model.book)
            return (count, book.transactions.flatMap(\.splits).map(\.value))
        }

        // Dropping the row from the array is what leaves it out.
        let (excludedCount, excludedAmounts) = try importRun(excludingDropped: true)
        #expect(excludedCount == 1)
        #expect(excludedAmounts.contains(kept))
        #expect(!excludedAmounts.contains(dropped))

        // The counterfactual, and the reason the sheet cannot merely un-assign
        // the row: left in the array with no destination, `fallbackToImbalance`
        // — on by default — sweeps it into Imbalance and imports it anyway.
        let (keptCount, keptAmounts) = try importRun(excludingDropped: false)
        #expect(keptCount == 2)
        #expect(keptAmounts.contains(dropped))
    }
}

@Suite("Import target from the file name")
struct ImportFileNameMatchTests {

    private func candidates(_ names: [String]) -> [(id: GncGUID, name: String)] {
        names.map { (id: GncGUID.random(), name: $0) }
    }

    @Test("The bank's own export name picks the account")
    func matchesExportName() {
        let list = candidates(["Everyday", "Visa", "Savings"])
        let visa = list[1].id
        #expect(ImportFileNameMatch.account(forFileNamed: "Visa.ofx", in: list) == visa)
        // Noise words, the format and the date are stripped before matching.
        #expect(ImportFileNameMatch.account(
            forFileNamed: "Visa Statement 2026-05-01.ofx", in: list) == visa)
        #expect(ImportFileNameMatch.account(
            forFileNamed: "transactions_visa_20260501.csv", in: list) == visa)
    }

    @Test("Two accounts matching equally well means no suggestion")
    func abstainsOnATie() {
        // "Visa" alone cannot choose between these, so it must not try: the
        // wrong answer posts a statement into the wrong account.
        let ambiguous = candidates(["Visa Personal", "Visa Business"])
        #expect(ImportFileNameMatch.account(forFileNamed: "Visa.ofx", in: ambiguous) == nil)
        // An exact name outranks the two partial matches.
        let withExact = ambiguous + candidates(["Visa"])
        #expect(ImportFileNameMatch.account(forFileNamed: "Visa.ofx", in: withExact)
                == withExact.last?.id)
    }

    @Test("A file name carrying nothing identifying suggests nothing")
    func abstainsOnNoiseOnly() {
        let list = candidates(["Everyday", "Visa"])
        #expect(ImportFileNameMatch.account(forFileNamed: "statement.ofx", in: list) == nil)
        #expect(ImportFileNameMatch.account(forFileNamed: "20260501.csv", in: list) == nil)
        #expect(ImportFileNameMatch.account(forFileNamed: "export (1).qif", in: list) == nil)
        // A real name that matches no account is also no suggestion.
        #expect(ImportFileNameMatch.account(forFileNamed: "Mortgage.ofx", in: list) == nil)
    }
}

@Suite("Remembered account identifier")
struct OnlineIDMatchTests {

    private func stored(_ ids: [String]) -> [(id: GncGUID, onlineID: String)] {
        ids.map { (id: GncGUID.random(), onlineID: $0) }
    }

    @Test("An exact identifier picks its account")
    func exactMatch() {
        let list = stored(["062000/12345678", "062000/99999999"])
        #expect(OnlineIDMatch.account(forIdentifier: "062000/12345678", in: list) == list[0].id)
        #expect(OnlineIDMatch.account(forIdentifier: "062000/00000000", in: list) == nil)
    }

    @Test("A stored identifier matches a longer incoming one, longest wins")
    func prefixMatch() {
        // GnuCash's rule: banks are inconsistent about how much of the id they
        // put in a file, so a stored prefix still identifies the account.
        let list = stored(["062000", "062000/12345678"])
        #expect(OnlineIDMatch.account(forIdentifier: "062000/12345678/AUD", in: list) == list[1].id)
        // With only the short one stored, it still matches.
        let shortOnly = stored(["062000"])
        #expect(OnlineIDMatch.account(forIdentifier: "062000/12345678", in: shortOnly) == shortOnly[0].id)
    }

    @Test("Two accounts with the same identifier are refused")
    func ambiguousIsRefused() {
        let list = stored(["062000", "062000"])
        #expect(OnlineIDMatch.account(forIdentifier: "062000/12345678", in: list) == nil)
        // An exact match still wins over two ambiguous prefixes.
        let withExact = list + stored(["062000/12345678"])
        #expect(OnlineIDMatch.account(forIdentifier: "062000/12345678", in: withExact)
                == withExact.last?.id)
    }

    @Test("Padding and empty identifiers do not match")
    func paddingAndEmpties() {
        let list = stored(["062000/12345678 "])   // exporters pad the field
        #expect(OnlineIDMatch.account(forIdentifier: "062000/12345678", in: list) == list[0].id)
        #expect(OnlineIDMatch.account(forIdentifier: "", in: list) == nil)
        #expect(OnlineIDMatch.account(forIdentifier: "062000/12345678", in: stored([""])) == nil)
    }
}

@MainActor
@Suite("Import target default")
struct ImportTargetDefaultTests {

    @Test("A remembered identifier outranks the file name and the register")
    func rememberedIdentifierWins() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let everyday = try #require(model.addAccount(name: "Everyday", type: .bank))
        let card = try #require(model.addAccount(name: "Card", type: .credit))

        // Nothing remembered yet: the file name is what decides.
        model.selectedAccountID = everyday
        let byName = try #require(model.suggestedImportTarget(
            forFileNamed: "Card.ofx", accountIdentifier: "062000/12345678"))
        #expect(byName.id == card)
        #expect(byName.source == .fileName)

        // Remember the statement's own id against Everyday — deliberately the
        // account the file name does *not* point at, so the ranking is visible.
        model.rememberImportAccount("062000/12345678", for: everyday)
        let remembered = try #require(model.suggestedImportTarget(
            forFileNamed: "Card.ofx", accountIdentifier: "062000/12345678"))
        #expect(remembered.id == everyday)
        #expect(remembered.source == .rememberedIdentifier)

        // It survives the file being renamed to something meaningless.
        let renamed = try #require(model.suggestedImportTarget(
            forFileNamed: "download (3).ofx", accountIdentifier: "062000/12345678"))
        #expect(renamed.id == everyday)

        // Remembering never overwrites an established mapping.
        model.rememberImportAccount("999999/00000000", for: everyday)
        let book = try #require(model.book)
        #expect(book.account(with: everyday)?.onlineID == "062000/12345678")
    }

    @Test("Falls back to the open register, and never to an income account")
    func fallsBackToCurrentRegister() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let everyday = try #require(model.addAccount(name: "Everyday", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))

        // Nothing selected, nothing in the name: no guess.
        #expect(model.suggestedImportTarget(forFileNamed: "statement.ofx") == nil)

        // Sitting on a register the statement could post to.
        model.selectedAccountID = everyday
        let fromRegister = try #require(model.suggestedImportTarget(forFileNamed: "statement.ofx"))
        #expect(fromRegister.id == everyday)
        #expect(fromRegister.source == .currentRegister)

        // The file name outranks the register when it identifies an account.
        model.selectedAccountID = salary
        _ = try #require(model.addAccount(name: "Mortgage", type: .liability))
        let byName = try #require(model.suggestedImportTarget(forFileNamed: "Mortgage.ofx"))
        #expect(byName.source == .fileName)

        // An income register is not a place a statement can land, so even
        // selected it is never suggested.
        #expect(model.suggestedImportTarget(forFileNamed: "statement.ofx") == nil)
    }
}
