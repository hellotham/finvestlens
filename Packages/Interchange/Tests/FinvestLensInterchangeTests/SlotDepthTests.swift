//
//  SlotDepthTests.swift
//  FinvestLens — Interchange
//
//  A crafted GnuCash file with pathologically nested KVP slots must degrade to
//  dropped slots, never to a crash. The importer converts the slot tree
//  recursively (`kvpValue(of:)`), and a deep tree of `SlotNode` classes even
//  deallocates recursively — before the parse-time depth cap, ~50,000 nested
//  frames were a stack overflow delivered by opening a file.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensInterchange

struct SlotDepthTests {

    /// The ImporterTests minimal book — AUD, root + Bank — with an `act:slots`
    /// of the requested nesting depth on Bank.
    private func book(withSlotNesting depth: Int) -> Data {
        var slots = "<act:slots>"
        for _ in 0..<depth { slots += "<slot><slot:key>k</slot:key><slot:value type=\"frame\">" }
        slots += "<slot><slot:key>leaf</slot:key><slot:value type=\"string\">v</slot:value></slot>"
        for _ in 0..<depth { slots += "</slot:value></slot>" }
        slots += "</act:slots>"
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <gnc-v2 xmlns:gnc="http://www.gnucash.org/XML/gnc" xmlns:act="http://www.gnucash.org/XML/act" xmlns:slot="http://www.gnucash.org/XML/slot" xmlns:cmdty="http://www.gnucash.org/XML/cmdty" xmlns:book="http://www.gnucash.org/XML/book">
        <gnc:book version="2.0.0">
        <book:id type="guid">a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6</book:id>
        <gnc:commodity version="2.0.0"><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id><cmdty:fraction>100</cmdty:fraction></gnc:commodity>
        <gnc:account version="2.0.0"><act:name>Root Account</act:name><act:id type="guid">00000000000000000000000000000000</act:id><act:type>ROOT</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity></gnc:account>
        <gnc:account version="2.0.0"><act:name>Bank</act:name><act:id type="guid">11111111111111111111111111111111</act:id><act:type>BANK</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity>\(slots)<act:parent type="guid">00000000000000000000000000000000</act:parent></gnc:account>
        </gnc:book>
        </gnc-v2>
        """
        return Data(xml.utf8)
    }

    @Test("A 50,000-deep slot nest imports without crashing")
    func hostileDepthSurvives() throws {
        // Before the cap this call did not return — it took the process down.
        let result = try GnuCashXMLImporter.importBook(from: book(withSlotNesting: 50_000))
        #expect(result.book.accounts.contains { $0.name == "Bank" })
    }

    @Test("Sane nesting is preserved untouched")
    func saneDepthRoundTrips() throws {
        let result = try GnuCashXMLImporter.importBook(from: book(withSlotNesting: 6))
        let root = try #require(result.book.accounts.first { $0.name == "Bank" })
        // Six frames down, the leaf value is still there.
        var frame = root.kvp
        for _ in 0..<6 {
            guard case let .frame(inner)? = frame["k"] else {
                Issue.record("nested frame dropped at sane depth")
                return
            }
            frame = inner
        }
        #expect(frame["leaf"] == .string("v"))
    }
}
