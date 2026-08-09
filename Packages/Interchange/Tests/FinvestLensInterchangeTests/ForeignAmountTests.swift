//
//  ForeignAmountTests.swift
//  FinvestLens — Interchange
//
//  Every narrative below is the shape a real ANZ export produced, mangled fee
//  field and all — merchant names changed. Decimal expectations are written
//  `Decimal(string:)`, never as literals: a bare 72.11 is a Double first and
//  reaches Decimal as an approximation that does not compare equal.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import FinvestLensInterchange

@Suite("Foreign amounts in a card narrative")
struct ForeignAmountTests {

    private func amounts(_ text: String, own: String = "AUD") -> [ForeignAmount] {
        ForeignAmountScanner.scan(text, excluding: own)
    }

    @Test("The amount charged overseas is read, the conversion fee is not")
    func readsTheChargedAmount() {
        let narrative = "THE SQUARE RESTAURANT     CHRISTCHURCH  72.11  NZD 2.18 AUD"
        let found = amounts(narrative)
        #expect(found == [ForeignAmount(amount: Decimal(string: "72.11")!, currencyCode: "NZD")])
    }

    @Test("A missing space before the code still parses")
    func noSpaceBeforeTheFee() {
        // `MYR22.68 AUD` — the fee runs straight into the code.
        let found = amounts("RCP-Booking               George Town  1773.84  MYR22.68 AUD")
        #expect(found.count == 1)
        #expect(found.first?.amount == Decimal(string: "1773.84"))
        #expect(found.first?.currencyCode == "MYR")
    }

    @Test("A mangled fee field is ignored rather than guessed at")
    func mangledFee() {
        // Real exports carry these. The foreign amount is clean in all of them;
        // the fee is not, and nothing here tries to rescue it.
        for narrative in ["ALPINE PARROT   QUEENSTOWN  51.40  NZD 1.1.56 AUD",
                          "GREAT PASTRY SHOP  CHRISTCHURCH  9.00  NZD 00.27 AUD",
                          "SOME CAFE  BANGKOK  219.00  THB 0.0.29 AUD"] {
            let found = amounts(narrative)
            #expect(found.count == 1, "expected exactly one foreign amount in \(narrative)")
        }
        #expect(amounts("ALPINE PARROT   QUEENSTOWN  51.40  NZD 1.1.56 AUD").first?.amount
                == Decimal(string: "51.40"))
    }

    @Test("A thousands separator survives")
    func thousandsSeparator() {
        #expect(amounts("HOTEL  TOKYO  1,234.50  JPY 3.20 AUD").first?.amount
                == Decimal(string: "1234.50"))
    }

    @Test("The book's own currency is never a foreign amount")
    func ownCurrencyExcluded() {
        // This is the whole reason the caller passes its currency: the fee tail
        // is itself a well-formed amount-and-code pair, and reading it as a
        // foreign amount would make every domestic fee look like a purchase
        // abroad.
        #expect(amounts("THE SQUARE RESTAURANT  CHRISTCHURCH  72.11  NZD 2.18 AUD")
                .allSatisfy { $0.currencyCode != "AUD" })
        // A book kept in NZD sees the same line the other way round.
        let inNZD = amounts("THE SQUARE RESTAURANT  CHRISTCHURCH  72.11  NZD 2.18 AUD", own: "NZD")
        #expect(inNZD == [ForeignAmount(amount: Decimal(string: "2.18")!, currencyCode: "AUD")])
    }

    @Test("Three letters that are not a currency are not money")
    func notEveryTripletIsACurrency() {
        // "GST" and "TAX" sit next to amounts on ordinary domestic receipts.
        #expect(amounts("WOOLWORTHS 3421  TOTAL 45.67  GST 4.15 INC").isEmpty)
        #expect(amounts("INVOICE TOTAL 120.00 TAX INCLUDED").isEmpty)
    }

    @Test("A number that merely precedes a word is not an amount")
    func requiresTheGap() {
        // No decimals, or no separating space, means no pairing.
        #expect(amounts("ORDER 12345 NZD").isEmpty)
        #expect(amounts("REF 9.00NZD").isEmpty)
    }

    @Test("An ordinary domestic narrative yields nothing")
    func domesticIsSilent() {
        #expect(amounts("COLES 5773                CHATSWOOD").isEmpty)
        #expect(amounts("Direct Credit 513275").isEmpty)
        #expect(amounts("").isEmpty)
    }

    @Test("Several foreign amounts in one narrative all come back")
    func multiple() {
        let found = amounts("SPLIT BILL  9.00  NZD  and  12.90  NZD 0.39 AUD")
        #expect(found.count == 2)
        #expect(found.map(\.currencyCode) == ["NZD", "NZD"])
    }
}
