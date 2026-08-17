//
//  BankImportTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

@Suite("CSV import")
struct CSVImportTests {

    @Test("Parses a signed-amount CSV with a header")
    func signedAmount() {
        let csv = """
        Date,Description,Amount
        2026-01-15,Woolworths,-52.30
        2026-01-16,"Salary, Employer Pty",1000.00
        """
        let mapping = CSVColumnMapping(date: 0, amount: 2, payee: 1, dateFormat: "yyyy-MM-dd")
        let rows = CSVTransactionImporter.parse(csv, mapping: mapping)
        #expect(rows.count == 2)
        #expect(rows[0].amount == Decimal(string: "-52.30"))
        #expect(rows[0].payee == "Woolworths")
        #expect(rows[1].payee == "Salary, Employer Pty")   // quoted comma preserved
        #expect(rows[1].amount == Decimal(1000))
    }

    @Test("Parses separate debit/credit columns")
    func debitCredit() {
        let csv = """
        15/01/2026,Rent,800.00,
        16/01/2026,Refund,,25.00
        """
        let mapping = CSVColumnMapping(date: 0, debit: 2, credit: 3, payee: 1,
                                       dateFormat: "dd/MM/yyyy", hasHeader: false)
        let rows = CSVTransactionImporter.parse(csv, mapping: mapping)
        #expect(rows[0].amount == Decimal(-800))           // debit → money out
        #expect(rows[1].amount == Decimal(25))             // credit → money in
    }
}

@Suite("QIF import")
struct QIFImportTests {

    @Test("Parses a bank QIF")
    func bankQIF() {
        let qif = """
        !Type:Bank
        D01/15/2026
        T-52.30
        PWoolworths
        MGroceries
        NCARD
        LExpenses:Groceries
        ^
        D01/16/2026
        T1,000.00
        PEmployer
        ^
        """
        let rows = QIFImporter.parse(qif)
        #expect(rows.count == 2)
        #expect(rows[0].payee == "Woolworths")
        #expect(rows[0].amount == Decimal(string: "-52.30"))
        #expect(rows[0].category == "Expenses:Groceries")
        #expect(rows[1].amount == Decimal(1000))
    }

    @Test("Handles apostrophe-year dates")
    func apostropheYear() {
        let rows = QIFImporter.parse("D01/15'26\nT-10.00\nPShop\n^")
        #expect(rows.count == 1)
    }

    @Test("Two-digit day-first years land in this century, not year 26 AD")
    func twoDigitDayFirstYears() {
        // AU-bank style: `30/06/26` proves day-first; `08/06/26` alone would be
        // ambiguous but must follow the file's orientation (8 June, not 6 Aug) —
        // and both must parse as 2026, not literal year 26.
        let qif = """
        !Type:Bank
        D30/06/26
        PInterest Paid
        T126.20
        ^
        D08/06/26
        PDirect Debit
        T-4439.95
        ^
        """
        let rows = QIFImporter.parse(qif)
        #expect(rows.count == 2)
        #expect(rows[0].date == day(2026, 6, 30))
        #expect(rows[1].date == day(2026, 6, 8))
    }

    @Test("Two-digit years without day-first evidence stay month-first")
    func twoDigitMonthFirstYears() {
        let rows = QIFImporter.parse("D06/08/26\nT-10.00\nPShop\n^")
        #expect(rows.count == 1)
        #expect(rows[0].date == day(2026, 6, 8))
    }
}

@Suite("OFX import")
struct OFXImportTests {

    @Test("Parses OFX v1 (SGML, unclosed tags)")
    func ofxV1() {
        let ofx = """
        OFXHEADER:100
        DATA:OFXSGML

        <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260115120000
        <TRNAMT>-52.30
        <FITID>ABC123
        <NAME>Woolworths
        </STMTTRN>
        <STMTTRN>
        <TRNTYPE>CREDIT
        <DTPOSTED>20260116
        <TRNAMT>1000.00
        <FITID>ABC124
        <NAME>Employer
        </STMTTRN>
        </BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.count == 2)
        #expect(rows[0].payee == "Woolworths")
        #expect(rows[0].amount == Decimal(string: "-52.30"))
        #expect(rows[0].reference == "ABC123")
        #expect(rows[1].amount == Decimal(1000))
    }

    @Test("Parses OFX v2 (XML, closed tags)")
    func ofxV2() {
        let ofx = """
        <?xml version="1.0"?>
        <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
          <STMTTRN>
            <TRNTYPE>DEBIT</TRNTYPE>
            <DTPOSTED>20260115</DTPOSTED>
            <TRNAMT>-52.30</TRNAMT>
            <FITID>X1</FITID>
            <NAME>Cafe</NAME>
          </STMTTRN>
        </BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.count == 1)
        #expect(rows[0].payee == "Cafe")
        #expect(rows[0].amount == Decimal(string: "-52.30"))
    }
}

@Suite("Import matcher")
struct ImportMatcherTests {

    /// Bank with an existing "Woolworths" expense so history can suggest.
    private func makeBook() -> (Book, bank: Account, groceries: Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(2026, 1, 15), description: "Woolworths")
        txn.addSplit(account: groceries, value: Decimal(string: "52.30")!)
        txn.addSplit(account: bank, value: Decimal(string: "-52.30")!)
        book.addTransaction(txn)
        return (book, bank, groceries)
    }

    @Test("Flags duplicates and suggests from history")
    func matching() {
        let (book, bank, groceries) = makeBook()
        let staged = [
            // Same amount/payee, same day → duplicate; suggests Groceries.
            StagedTransaction(date: day(2026, 1, 15), amount: Decimal(string: "-52.30")!, payee: "Woolworths"),
            // New transaction → not a duplicate; no history for this payee.
            StagedTransaction(date: day(2026, 2, 1), amount: Decimal(string: "-19.99")!, payee: "Netflix"),
        ]
        let results = ImportMatcher.match(staged, into: bank, book: book)

        #expect(results[0].isDuplicate)
        #expect(results[0].suggestedAccountID == groceries.guid)
        #expect(!results[1].isDuplicate)
        #expect(results[1].suggestedAccountID == nil)
    }

    /// Repeating an amount is ordinary life. Amount and date alone used to be
    /// enough to flag a duplicate, so a different payee for the same money on
    /// the same day was hidden behind a flag the user had to disprove — and a
    /// statement's rows are rarely duplicates of anything at all.
    @Test("Same amount and day but a different payee is not a duplicate")
    func differentPayeeIsNotADuplicate() {
        let (book, bank, _) = makeBook()
        let sameMoneySameDay = StagedTransaction(
            date: day(2026, 1, 15), amount: Decimal(string: "-52.30")!,
            payee: "Bunnings Warehouse")
        let results = ImportMatcher.match([sameMoneySameDay], into: bank, book: book)
        #expect(!results[0].isDuplicate)
    }

    @Test("The same payee for the same money on the same day still is one")
    func samePayeeStillDuplicates() {
        let (book, bank, _) = makeBook()
        // The statement's raw narrative against the book's tidied description:
        // the shared "woolworths" token is what carries the match.
        let raw = StagedTransaction(
            date: day(2026, 1, 15), amount: Decimal(string: "-52.30")!,
            payee: "WOOLWORTHS 1234 CHATSWOOD NSW")
        #expect(ImportMatcher.match([raw], into: bank, book: book)[0].isDuplicate)
    }

    @Test("A statement row with no narrative can still be recognised on re-import")
    func silentRowStillDuplicates() {
        let (book, bank, _) = makeBook()
        // Nothing to contradict with, so amount and date remain the evidence —
        // vetoing here would stop a genuine re-import being caught.
        let silent = StagedTransaction(date: day(2026, 1, 15),
                                       amount: Decimal(string: "-52.30")!, payee: "")
        #expect(ImportMatcher.match([silent], into: bank, book: book)[0].isDuplicate)
    }

    /// A statement none of whose rows exist in the book must flag nothing —
    /// even when a daily payment limit chunks one large movement into identical
    /// amounts on consecutive days, which is precisely when amount-and-date
    /// matching goes wrong.
    ///
    /// This is the property the live harness asserted against a real disjoint
    /// statement. That premise is gone for good: the book has since had all
    /// four statements imported, the QIF files carry no reference to identify
    /// their rows by (`N` is empty, so only the matcher's own heuristic could
    /// find them — circular), and the Aug 12 backup contains three of the four
    /// statements too. Synthetic data reproduces the shape exactly and cannot
    /// rot the way a book snapshot does.
    @Test("A disjoint statement flags nothing, even with daily-limit chunking")
    func disjointStatementFlagsNothing() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Everyday", type: .bank, commodity: .aud))
        let expense = book.addAccount(Account(name: "Contributions", type: .expense, commodity: .aud))
        // Two earlier chunks of the same round amount already in the book.
        for d in [26, 27] {
            let txn = Transaction(currency: .aud, datePosted: day(2026, 4, d),
                                  description: "Transfer To Smsf")
            txn.addSplit(account: expense, value: Decimal(20000))
            txn.addSplit(account: bank, value: Decimal(-20000))
            book.addTransaction(txn)
        }

        // A later statement: four more chunks of the same amount on consecutive
        // days, none of them the April pair.
        let staged = [1, 2, 4, 5].map {
            StagedTransaction(date: day(2026, 5, $0), amount: Decimal(-20000),
                              payee: "Transfer To Smsf")
        }
        let results = ImportMatcher.match(staged, into: bank, book: book)
        #expect(results.allSatisfy { !$0.isDuplicate },
                "flagged \(results.filter(\.isDuplicate).count) rows of a disjoint statement")
    }

    @Test("Re-importing that same statement flags every row")
    func reimportFlagsEveryRow() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Everyday", type: .bank, commodity: .aud))
        let expense = book.addAccount(Account(name: "Contributions", type: .expense, commodity: .aud))
        for d in [1, 2, 4, 5] {
            let txn = Transaction(currency: .aud, datePosted: day(2026, 5, d),
                                  description: "Transfer To Smsf")
            txn.addSplit(account: expense, value: Decimal(20000))
            txn.addSplit(account: bank, value: Decimal(-20000))
            book.addTransaction(txn)
        }
        let staged = [1, 2, 4, 5].map {
            StagedTransaction(date: day(2026, 5, $0), amount: Decimal(-20000),
                              payee: "Transfer To Smsf")
        }
        let results = ImportMatcher.match(staged, into: bank, book: book)
        // One-to-one: four rows claim four legs, none doubling up.
        #expect(results.allSatisfy { $0.isDuplicate })
        #expect(Set(results.compactMap(\.matchedSplitID)).count == 4)
    }

    @Test("A matching FITID in a split's online_id is a definitive duplicate")
    func onlineIDDedup() {
        let (book, bank, _) = makeBook()
        // Tag the existing bank split with an OFX FITID (GnuCash's online_id).
        let bankSplit = book.splits(for: bank).first!
        bankSplit.kvp["online_id"] = .string("FIT-12345")

        // A re-imported row with the same FITID but a wildly different amount
        // and a date months away — GnuCash still dedupes it on online_id.
        let offAmount = StagedTransaction(date: day(2026, 6, 30),
            amount: Decimal(string: "-999")!, payee: "SomethingElse", reference: "FIT-12345",
            referenceIsBankUnique: true)
        let fresh = StagedTransaction(date: day(2026, 6, 30),
            amount: Decimal(string: "-77")!, payee: "New", reference: "FIT-99999",
            referenceIsBankUnique: true)
        let results = ImportMatcher.match([offAmount, fresh], into: bank, book: book)
        #expect(results[0].isDuplicate)          // online_id definitive
        #expect(!results[1].isDuplicate)         // different id + amount
    }

    @Test("Different bank references veto an amount+date match")
    func referenceMismatchVeto() {
        let (book, bank, _) = makeBook()
        // Last statement's entry, stamped with its FITID.
        book.splits(for: bank).first!.kvp["online_id"] = .string("FIT-OLD")

        // This statement's row: same amount, next day — but its own FITID.
        // A bank never re-issues an event under a new id: not a duplicate.
        let staged = [StagedTransaction(date: day(2026, 1, 16), amount: Decimal(string: "-52.30")!,
                                        payee: "Woolworths", reference: "FIT-NEW",
                                        referenceIsBankUnique: true)]
        let results = ImportMatcher.match(staged, into: bank, book: book)
        #expect(!results[0].isDuplicate)
    }

    @Test("A repeating free-text reference is not a duplicate on its own")
    func freeTextReferenceIsNotAnIdentifier() {
        let (book, bank, _) = makeBook()
        // A CSV "Reference" column lands in the same `online_id` slot, but it
        // is whatever the payer typed and repeats every month.
        book.splits(for: bank).first!.kvp["online_id"] = .string("RENT")

        // Next month's rent: same reference text, different amount and date.
        // Treating the text as an identifier skipped this payment entirely.
        let staged = [StagedTransaction(date: day(2026, 2, 16),
                                        amount: Decimal(string: "-2600")!,
                                        payee: "Landlord", reference: "RENT")]
        let results = ImportMatcher.match(staged, into: bank, book: book)
        #expect(!results[0].isDuplicate)
    }

    @Test("Each book entry absorbs at most one statement row")
    func oneToOneClaiming() {
        let (book, bank, _) = makeBook()
        // Two identical rows against ONE book entry: the second must import.
        let rows = [
            StagedTransaction(date: day(2026, 1, 15), amount: Decimal(string: "-52.30")!, payee: "Woolworths"),
            StagedTransaction(date: day(2026, 1, 16), amount: Decimal(string: "-52.30")!, payee: "Woolworths"),
        ]
        let results = ImportMatcher.match(rows, into: bank, book: book)
        #expect(results.filter(\.isDuplicate).count == 1)
    }

    @Test("History learned from money-leg memos, not just descriptions")
    func memoHistory() {
        let (book, bank, groceries) = makeBook()
        // A renamed transaction: friendly description, raw narrative in the
        // bank leg's memo (how the smart categoriser leaves them).
        let txn = Transaction(currency: .aud, datePosted: day(2026, 2, 1), description: "Digidirect")
        txn.addSplit(account: groceries, value: Decimal(string: "150")!)
        txn.addSplit(account: bank, value: Decimal(string: "-150")!,
                     memo: "PAYPAL AUSTRALIA 1051339327183")
        book.addTransaction(txn)

        let staged = [StagedTransaction(date: day(2026, 6, 1), amount: Decimal(string: "-88")!,
                                        payee: "PAYPAL AUSTRALIA 1051339327183")]
        let results = ImportMatcher.match(staged, into: bank, book: book)
        #expect(results[0].suggestedAccountID == groceries.guid)
    }

    @Test("A recycled cheque number with a different amount is not a duplicate")
    func referenceNeedsMatchingAmount() {
        let (book, bank, groceries) = makeBook()
        // A three-year-old cheque numbered "105" for $120.
        let old = Transaction(currency: .aud, datePosted: day(2023, 3, 1),
                              number: "105", description: "Plumber")
        old.addSplit(account: groceries, value: Decimal(120))
        old.addSplit(account: bank, value: Decimal(-120))
        book.addTransaction(old)

        // A new $500 cheque re-using the number must import, not vanish —
        // but a genuine re-import (same number, same amount) still dedupes.
        let rows = [
            StagedTransaction(date: day(2026, 3, 1), amount: Decimal(-500),
                              payee: "Cheque", reference: "105"),
            StagedTransaction(date: day(2026, 3, 2), amount: Decimal(-120),
                              payee: "Cheque", reference: "105"),
        ]
        let results = ImportMatcher.match(rows, into: bank, book: book)
        #expect(!results[0].isDuplicate)
        #expect(results[1].isDuplicate)
    }

    @Test("Wash accounts are never learned as payee suggestions")
    func washNotLearned() {
        let (book, bank, groceries) = makeBook()
        let imbalance = book.addAccount(Account(name: "Imbalance-AUD", type: .bank, commodity: .aud))
        // The same payee parked in Imbalance twice (fallback imports), but
        // categorised to Groceries once — the real category must win, and a
        // wash suggestion must never suppress better fallbacks.
        for dayOfMonth in [2, 3] {
            let parked = Transaction(currency: .aud, datePosted: day(2026, 2, dayOfMonth),
                                     description: "WOOLWORTHS 1234")
            parked.addSplit(account: imbalance, value: Decimal(50))
            parked.addSplit(account: bank, value: Decimal(-50))
            book.addTransaction(parked)
        }
        let categorised = Transaction(currency: .aud, datePosted: day(2026, 2, 4),
                                      description: "WOOLWORTHS 1234")
        categorised.addSplit(account: groceries, value: Decimal(60))
        categorised.addSplit(account: bank, value: Decimal(-60))
        book.addTransaction(categorised)

        let staged = [StagedTransaction(date: day(2026, 6, 1), amount: Decimal(-45),
                                        payee: "WOOLWORTHS 1234")]
        let results = ImportMatcher.match(staged, into: bank, book: book)
        #expect(results[0].suggestedAccountID == groceries.guid)
    }
}

@Suite("Import matcher — transfers")
struct ImportTransferMatchTests {

    /// Two banks and a wash account, with one transfer already imported from
    /// the CMAA side: CMAA −5000, the other leg parked in "Unspecified".
    private func makeBook() -> (Book, cma: Account, cmaa: Account, wash: Account, washSplit: Split) {
        let book = Book(baseCurrency: .aud)
        let cma = book.addAccount(Account(name: "CMA", type: .bank, commodity: .aud))
        let cmaa = book.addAccount(Account(name: "CMAA", type: .bank, commodity: .aud))
        let wash = book.addAccount(Account(name: "Unspecified", type: .income, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(2026, 5, 20),
                              description: "To Smsf Pty Ltd Internal transfer")
        txn.addSplit(account: cmaa, value: Decimal(-5000))
        let washSplit = txn.addSplit(account: wash, value: Decimal(5000))
        book.addTransaction(txn)
        return (book, cma, cmaa, wash, washSplit)
    }

    @Test("The other side of a transfer heals the wash leg instead of duplicating")
    func transferCounterpartDetected() {
        let (book, cma, cmaa, _, washSplit) = makeBook()
        let staged = [StagedTransaction(date: day(2026, 5, 20), amount: Decimal(5000),
                                        payee: "From Smsf Pty Ltd Atf")]
        let results = ImportMatcher.match(staged, into: cma, book: book)
        #expect(!results[0].isDuplicate)
        #expect(results[0].transferSplitID == washSplit.guid)
        #expect(results[0].suggestedAccountID == cmaa.guid)
    }

    @Test("A transfer match requires the same day and the exact amount")
    func transferBounds() {
        let (book, cma, _, _, _) = makeBook()
        // Banks post both sides of a transfer on the same day — and a daily
        // payment limit produces identical amounts on consecutive days, so
        // even one day off is no evidence of being the same movement.
        let nextDay = StagedTransaction(date: day(2026, 5, 21), amount: Decimal(5000),
                                        payee: "From Smsf Pty Ltd Atf")
        let wrongAmount = StagedTransaction(date: day(2026, 5, 20), amount: Decimal(4999),
                                            payee: "From Smsf Pty Ltd Atf")
        let results = ImportMatcher.match([nextDay, wrongAmount], into: cma, book: book)
        #expect(results[0].transferSplitID == nil)
        #expect(results[1].transferSplitID == nil)
    }

    @Test("A wash-parked book entry only matches a row on the exact same day")
    func washHalfSameDayOnly() {
        let (book, cma, _, wash, _) = makeBook()
        // Last statement's final chunk, still uncategorised in CMA itself.
        let older = Transaction(currency: .aud, datePosted: day(2026, 5, 19),
                                description: "From Smsf Pty Ltd Atf")
        older.addSplit(account: cma, value: Decimal(5000))
        older.addSplit(account: wash, value: Decimal(-5000))
        book.addTransaction(older)

        // Next chunk of the same movement, one day later (daily payment
        // limit): a distinct transaction, not a duplicate.
        let nextChunk = StagedTransaction(date: day(2026, 5, 21), amount: Decimal(5000),
                                          payee: "From Smsf Pty Ltd Atf")
        // A true re-import of the same statement row: same day → duplicate.
        let reImport = StagedTransaction(date: day(2026, 5, 19), amount: Decimal(5000),
                                         payee: "From Smsf Pty Ltd Atf")
        let results = ImportMatcher.match([nextChunk, reImport], into: cma, book: book)
        #expect(!results[0].isDuplicate)
        #expect(results[1].isDuplicate)
    }

    @Test("Equal amount and date alone don't make a transfer — narratives must agree")
    func transferNarrativeGate() {
        let (book, cma, _, _, _) = makeBook()
        // Same $5,000, same day — but a completely unrelated story (a term
        // deposit maturing, say). Must NOT be healed into the pending transfer.
        let coincidence = StagedTransaction(date: day(2026, 5, 20), amount: Decimal(5000),
                                            payee: "Myer Sydney City Refund")
        let results = ImportMatcher.match([coincidence], into: cma, book: book)
        #expect(results[0].transferSplitID == nil)
    }

    @Test("A transaction already posted to the target is a duplicate, not a transfer")
    func completeTransferIsDuplicate() {
        let (book, cma, cmaa, _, _) = makeBook()
        // The completed transfer: both real legs present.
        let txn = Transaction(currency: .aud, datePosted: day(2026, 6, 8), description: "Card payment")
        txn.addSplit(account: cma, value: Decimal(string: "-4439.95")!)
        txn.addSplit(account: cmaa, value: Decimal(string: "4439.95")!)
        book.addTransaction(txn)

        let staged = [StagedTransaction(date: day(2026, 6, 8),
                                        amount: Decimal(string: "-4439.95")!, payee: "Direct Debit")]
        let results = ImportMatcher.match(staged, into: cma, book: book)
        #expect(results[0].isDuplicate)
        #expect(results[0].transferSplitID == nil)
    }

    @Test("Completing a transfer beats matching a wash-parked half of the same amount")
    func healBeatsWashHalfDuplicate() {
        let (book, cma, cmaa, wash, washSplit) = makeBook()
        // The book also holds a same-day wash-parked deposit of the same amount
        // in the target account itself — a still-uncategorised earlier entry.
        let older = Transaction(currency: .aud, datePosted: day(2026, 5, 20),
                                description: "From Smsf Pty Ltd Atf")
        older.addSplit(account: cma, value: Decimal(5000))
        older.addSplit(account: wash, value: Decimal(-5000))
        book.addTransaction(older)

        // The row matches both the older half (a would-be duplicate) and the
        // pending CMAA transfer, on the same day. Completing the transfer is
        // the stronger read: a wash-parked half proves the amount recurs, not
        // that this row is already recorded.
        let staged = [StagedTransaction(date: day(2026, 5, 20), amount: Decimal(5000),
                                        payee: "From Smsf Pty Ltd Atf")]
        let results = ImportMatcher.match(staged, into: cma, book: book)
        #expect(!results[0].isDuplicate)
        #expect(results[0].transferSplitID == washSplit.guid)
        _ = cmaa
    }

    @Test("Credit-card payment rows fall back to the historical funding account")
    func fundingFallback() {
        let book = Book(baseCurrency: .aud)
        let card = book.addAccount(Account(name: "Visa", type: .credit, commodity: .aud))
        let everyday = book.addAccount(Account(name: "Everyday Card", type: .bank, commodity: .aud))
        for month in 1...3 {
            let txn = Transaction(currency: .aud, datePosted: day(2026, month, 9),
                                  description: "Direct Debit ANZ CREDIT CARD")
            txn.addSplit(account: card, value: Decimal(2000 + month))
            txn.addSplit(account: everyday, value: Decimal(-2000 - month))
            book.addTransaction(txn)
        }

        let payment = StagedTransaction(date: day(2026, 6, 8), amount: Decimal(string: "4439.95")!,
                                        memo: "PAYMENT - THANK YOU")
        let charge = StagedTransaction(date: day(2026, 6, 9), amount: Decimal(string: "-49.10")!,
                                       memo: "WW METRO CHATSWOOD")
        let results = ImportMatcher.match([payment, charge], into: card, book: book)
        #expect(results[0].suggestedAccountID == everyday.guid)   // funded from Everyday Card
        #expect(results[1].suggestedAccountID == nil)         // charges don't infer funding
    }
}

@Suite("Amount notation")
struct AmountNotationTests {

    @Test("DR and CR name the side, outranking the bare magnitude")
    func debitCreditMarkers() {
        // The character filter used to strip the letters and read a debit as
        // a deposit — every withdrawal in such a file imported with the wrong
        // sign.
        #expect(ImportParsing.amount("500.00 DR") == Decimal(-500))
        #expect(ImportParsing.amount("500.00 CR") == Decimal(500))
        #expect(ImportParsing.amount("500.00DR") == Decimal(-500))
        #expect(ImportParsing.amount("DR 500.00") == Decimal(-500))
        #expect(ImportParsing.amount("Cr. 1,250.50") == Decimal(string: "1250.50"))
        #expect(ImportParsing.amount("$500.00 DB") == Decimal(-500))
        // Authoritative: a DR marker wins over a magnitude already signed.
        #expect(ImportParsing.amount("-500.00 CR") == Decimal(500))
    }

    @Test("A currency code is not a side marker")
    func currencyCodesSurvive() {
        // "IDR" ends in "DR" and "DRAWINGS" starts with one; neither names a
        // side, and treating them as one flipped good rows.
        #expect(ImportParsing.amount("500.00 IDR") == Decimal(500))
        #expect(ImportParsing.amount("500.00 EUR") == Decimal(500))
        // A bare number is untouched.
        #expect(ImportParsing.amount("500.00") == Decimal(500))
        #expect(ImportParsing.amount("-500.00") == Decimal(-500))
    }
}

@Suite("Multi-statement files")
struct MultiStatementTests {

    @Test("An OFX response carrying two accounts labels each row with its own")
    func ofxTwoStatements() {
        let ofx = """
        <OFX><BANKMSGSRSV1><STMTTRNRS>
        <STMTRS><CURDEF>AUD</CURDEF>
        <BANKACCTFROM><BANKID>062000</BANKID><ACCTID>11111111</ACCTID></BANKACCTFROM>
        <BANKTRANLIST>
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260115<TRNAMT>-25.00<FITID>A1<NAME>Cafe</STMTTRN>
        </BANKTRANLIST></STMTRS>
        <STMTRS><CURDEF>AUD</CURDEF>
        <BANKACCTFROM><BANKID>062000</BANKID><ACCTID>22222222</ACCTID></BANKACCTFROM>
        <BANKTRANLIST>
        <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260116<TRNAMT>900.00<FITID>B1<NAME>Salary</STMTTRN>
        </BANKTRANLIST></STMTRS>
        </STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.count == 2)
        // Before this, both rows arrived unlabelled and the import sheet
        // posted the salary into whichever account was selected for the cafe.
        #expect(rows.first { $0.reference == "A1" }?.sourceAccountID == "062000/11111111")
        #expect(rows.first { $0.reference == "B1" }?.sourceAccountID == "062000/22222222")
        // The file-level identifier still names the first statement.
        #expect(OFXImporter.accountIdentifier(ofx) == "062000/11111111")
    }

    @Test("An MT940 file with two :25: blocks labels each statement's rows")
    func mt940TwoStatements() {
        let mt940 = """
        :20:STMT001
        :25:062000/11111111
        :60F:C260101AUD1000,00
        :61:2601150115D25,00NTRFNONREF
        :86:Cafe purchase
        :62F:C260131AUD975,00
        :20:STMT002
        :25:062000/22222222
        :60F:C260101AUD500,00
        :61:2601160116C900,00NTRFNONREF
        :86:Salary
        :62F:C260131AUD1400,00
        """
        let rows = MT940Importer.parse(mt940)
        #expect(rows.count == 2)
        #expect(rows[0].sourceAccountID == "062000/11111111")
        #expect(rows[1].sourceAccountID == "062000/22222222")
        #expect(MT940Importer.accountIdentifier(mt940) == "062000/11111111")
    }

    @Test("A single-statement file still labels its rows, and parses as before")
    func singleStatementUnchanged() {
        let ofx = """
        <OFX><STMTRS><BANKACCTFROM><ACCTID>999</ACCTID></BANKACCTFROM>
        <STMTTRN><DTPOSTED>20260115<TRNAMT>-25.00<FITID>A1<NAME>Cafe</STMTTRN>
        </STMTRS></OFX>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.count == 1)
        #expect(rows[0].sourceAccountID == "999")
        #expect(rows[0].amount == Decimal(-25))
    }

    @Test("A CAMT document with two statements keeps their entries apart")
    func camtTwoStatements() {
        let camt = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Document><BkToCstmrStmt>
        <Stmt><Acct><Id><IBAN>AU11AAAA</IBAN></Id></Acct>
        <Ntry><Amt Ccy="AUD">25.00</Amt><CdtDbtInd>DBIT</CdtDbtInd><Sts>BOOK</Sts>
        <BookgDt><Dt>2026-01-15</Dt></BookgDt><AcctSvcrRef>E1</AcctSvcrRef></Ntry>
        </Stmt>
        <Stmt><Acct><Id><IBAN>AU22BBBB</IBAN></Id></Acct>
        <Ntry><Amt Ccy="AUD">900.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Sts>BOOK</Sts>
        <BookgDt><Dt>2026-01-16</Dt></BookgDt><AcctSvcrRef>E2</AcctSvcrRef></Ntry>
        </Stmt>
        </BkToCstmrStmt></Document>
        """
        let rows = CAMTImporter.parse(camt)
        #expect(rows.count == 2)
        #expect(rows.first { $0.reference == "E1" }?.sourceAccountID == "AU11AAAA")
        #expect(rows.first { $0.reference == "E2" }?.sourceAccountID == "AU22BBBB")
        #expect(CAMTImporter.accountIdentifier(camt) == "AU11AAAA")
    }
}

@Suite("Side markers at either end")
struct SideMarkerEndTests {

    @Test("A leading DR is seen even when a currency code ends the string")
    func prefixSurvivesRejectedSuffix() {
        // "DR 500 IDR" ends in "DR" via the currency code. The boundary guard
        // correctly refuses that, but written as `if suffix … else if prefix`
        // the refusal consumed the iteration and the real leading marker was
        // never tested — the debit parsed as +500.
        #expect(ImportParsing.amount("DR 500 IDR") == Decimal(-500))
        #expect(ImportParsing.amount("CR 500 IDR") == Decimal(500))
        #expect(ImportParsing.amount("DR. 1,250.50 EUR") == Decimal(string: "-1250.50"))
    }

    @Test("Neither end marked leaves the amount alone")
    func noMarker() {
        #expect(ImportParsing.amount("500 IDR") == Decimal(500))
        #expect(ImportParsing.amount("DRAWINGS 500") == Decimal(500))
        #expect(ImportParsing.amount("500.00") == Decimal(500))
    }
}

@Suite("Statement order and account labelling")
struct StatementOrderTests {

    @Test("A card statement written before the bank statement keeps document order")
    func documentOrderNotWrapperOrder() {
        // Looping the wrapper list put every <STMTRS> before every <CCSTMTRS>
        // however the file was written, so the sheet's default statement and
        // its suggested target account came from different accounts — the
        // cheque account's rows posting into the credit card.
        let ofx = """
        <OFX>
        <CREDITCARDMSGSRSV1><CCSTMTRS>
        <CCACCTFROM><ACCTID>4111111111111111</ACCTID></CCACCTFROM>
        <STMTTRN><DTPOSTED>20260115<TRNAMT>-25.00<FITID>C1<NAME>Cafe</STMTTRN>
        </CCSTMTRS></CREDITCARDMSGSRSV1>
        <BANKMSGSRSV1><STMTRS>
        <BANKACCTFROM><BANKID>062000</BANKID><ACCTID>99999999</ACCTID></BANKACCTFROM>
        <STMTTRN><DTPOSTED>20260116<TRNAMT>900.00<FITID>B1<NAME>Salary</STMTTRN>
        </STMTRS></BANKMSGSRSV1>
        </OFX>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.first { $0.reference == "C1" }?.sourceAccountID == "4111111111111111")
        #expect(rows.first { $0.reference == "B1" }?.sourceAccountID == "062000/99999999")
        // The file-level id must name the FIRST statement in the document —
        // the card — not a splice of the card's ACCTID and the bank's BANKID.
        #expect(OFXImporter.accountIdentifier(ofx) == "4111111111111111")
    }

    @Test("An MT940 statement whose account tag is the 25P variant is not mislabelled")
    func mt940VariantAccountTag() {
        // `:20:` opens each statement, so a missing or variant `:25:` must
        // degrade to unlabelled rather than inheriting the previous account.
        let mt940 = """
        :20:STMT001
        :25:062000/11111111
        :61:2601150115D25,00NTRFNONREF
        :86:Cafe
        :20:STMT002
        :25P:062000/22222222
        :61:2601160116C900,00NTRFNONREF
        :86:Salary
        """
        let rows = MT940Importer.parse(mt940)
        #expect(rows.count == 2)
        #expect(rows[0].sourceAccountID == "062000/11111111")
        #expect(rows[1].sourceAccountID == "062000/22222222")
    }

    @Test("A statement with no account tag at all is unlabelled, not inherited")
    func missingAccountTagIsNotInherited() {
        let mt940 = """
        :20:STMT001
        :25:062000/11111111
        :61:2601150115D25,00NTRFNONREF
        :86:Cafe
        :20:STMT002
        :61:2601160116C900,00NTRFNONREF
        :86:Salary
        """
        let rows = MT940Importer.parse(mt940)
        #expect(rows[0].sourceAccountID == "062000/11111111")
        #expect(rows[1].sourceAccountID == nil)   // not "062000/11111111"
    }
}
