//
//  StatementRereadTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  What a statement import keeps when a model's answer goes wrong part-way.
//  The answers here are scripted: the thing under test is what is done with
//  them, which decides whether rows are found, lost or counted twice.
//

import Foundation
import Testing
@testable import FinvestLensIntelligence

@Suite("A statement slice is read again when its answer went wrong, and never at the cost of what it had")
struct StatementRereadTests {
    typealias Page = StatementExtractor.ModelPage

    /// Four lines of statement, and their halves and quarters.
    static let whole = "line 1\nline 2\nline 3\nline 4"
    static let first = "line 1\nline 2"
    static let second = "line 3\nline 4"

    /// A page whose one row is named for the slice it answers, so that what
    /// was kept can be read back.
    static func sound(_ name: String) -> Page {
        Page(openingBalance: "", transactions: [
            .init(date: "2026-03-05", amount: "-45.20", payee: name, reference: "", balanceAfter: ""),
        ])
    }

    /// The same, followed by a row that has lost its place.
    static func gone(_ name: String) -> Page {
        Page(openingBalance: "", transactions: [
            .init(date: "2026-03-05", amount: "-45.20", payee: name, reference: "", balanceAfter: ""),
            .init(date: ": ", amount: "-9.99", payee: "LOST", reference: "", balanceAfter: ""),
        ])
    }

    /// What a slice is answered with, by its text; anything not scripted is
    /// a sound page named for the slice. Records every slice it was asked.
    final class Reader {
        var answers: [String: Result<Page, any Error>] = [:]
        private(set) var asked: [String] = []

        func read(_ slice: String) throws -> Page {
            asked.append(slice)
            return try (answers[slice] ?? .success(StatementRereadTests.sound(slice))).get()
        }
    }

    /// Runs the reading, returning the payee of each page kept and the slice
    /// it was kept for, in order.
    private func run(_ reader: Reader, rereads: Int = 2) async throws -> [String] {
        var kept: [String] = []
        try await StatementExtractor.reading(Self.whole, rereads: rereads, read: { try reader.read($0) }) { page, slice in
            kept.append("\(page.transactions.first?.payee ?? "?") ⟵ \(slice)")
        }
        return kept
    }

    @Test("A sound answer is kept, and nothing is read twice")
    func sound() async throws {
        let reader = Reader()
        #expect(try await run(reader) == ["\(Self.whole) ⟵ \(Self.whole)"])
        #expect(reader.asked == [Self.whole])
    }

    @Test("An answer that lost its place is replaced by its two halves, in the order they were printed")
    func readAgain() async throws {
        let reader = Reader()
        reader.answers[Self.whole] = .success(Self.gone("whole"))
        #expect(try await run(reader) == ["\(Self.first) ⟵ \(Self.first)", "\(Self.second) ⟵ \(Self.second)"])
        #expect(reader.asked == [Self.whole, Self.first, Self.second])
    }

    @Test("If a half fails, the first answer is what is kept — not half of the second")
    func aHalfFails() async throws {
        let reader = Reader()
        reader.answers[Self.whole] = .success(Self.gone("whole"))
        reader.answers[Self.second] = .failure(IntelligenceError.modelFailure("would not decode"))
        // The first half was read, and read soundly; kept on its own it
        // would be half a slice where the answer it replaces had most of one.
        #expect(try await run(reader) == ["whole ⟵ \(Self.whole)"])
        #expect(reader.asked == [Self.whole, Self.first, Self.second])
    }

    @Test("A failure of the model itself is not papered over with the first answer")
    func theModelFails() async throws {
        let reader = Reader()
        reader.answers[Self.whole] = .success(Self.gone("whole"))
        reader.answers[Self.first] = .failure(IntelligenceError.busy)
        await #expect(throws: IntelligenceError.self) { _ = try await run(reader) }
        #expect(reader.asked == [Self.whole, Self.first])

        let cancelled = Reader()
        cancelled.answers[Self.whole] = .success(Self.gone("whole"))
        cancelled.answers[Self.first] = .failure(CancellationError())
        await #expect(throws: CancellationError.self) { _ = try await run(cancelled) }
    }

    @Test("Reading again stops: after two halvings, what came back is kept as it is")
    func itStops() async throws {
        let reader = Reader()
        for slice in [Self.whole, Self.first, Self.second, "line 1", "line 2", "line 3", "line 4"] {
            reader.answers[slice] = .success(Self.gone(slice))
        }
        // One request, two halves, four quarters — and no eighth.
        #expect(try await run(reader) == ["line 1", "line 2", "line 3", "line 4"].map { "\($0) ⟵ \($0)" })
        #expect(reader.asked.count == 7)

        // And with no rereads allowed at all, the first answer stands.
        let once = Reader()
        once.answers[Self.whole] = .success(Self.gone("whole"))
        #expect(try await run(once, rereads: 0) == ["whole ⟵ \(Self.whole)"])
        #expect(once.asked == [Self.whole])
    }

    @Test("A slice of one line cannot be halved, so its answer is kept whatever it is")
    func oneLine() async throws {
        let reader = Reader()
        reader.answers["line 1"] = .success(Self.gone("one"))
        var kept = 0
        try await StatementExtractor.reading("line 1", read: { try reader.read($0) }) { _, _ in kept += 1 }
        #expect(kept == 1)
        #expect(reader.asked == ["line 1"])
    }

    @Test("A slice that will not fit is halved until it does, as before — and a line that will not is a failure")
    func overflow() async throws {
        let reader = Reader()
        reader.answers[Self.whole] = .failure(IntelligenceError.contextOverflow)
        #expect(try await run(reader) == ["\(Self.first) ⟵ \(Self.first)", "\(Self.second) ⟵ \(Self.second)"])

        // Halving for overflow keeps what was read before the line that
        // would not go through, as it always has.
        let stuck = Reader()
        for slice in [Self.whole, Self.second, "line 3"] {
            stuck.answers[slice] = .failure(IntelligenceError.contextOverflow)
        }
        var kept: [String] = []
        await #expect(throws: IntelligenceError.self) {
            try await StatementExtractor.reading(Self.whole, read: { try stuck.read($0) }) { _, slice in kept.append(slice) }
        }
        #expect(kept == [Self.first])
        #expect(stuck.asked == [Self.whole, Self.first, Self.second, "line 3"])
    }

    @Test("An overflow beneath a second reading costs the second reading, and no half is read twice")
    func overflowBeneathAReread() async throws {
        let reader = Reader()
        reader.answers[Self.whole] = .success(Self.gone("whole"))
        reader.answers[Self.first] = .failure(IntelligenceError.contextOverflow)
        reader.answers["line 1"] = .failure(IntelligenceError.contextOverflow)
        #expect(try await run(reader) == ["whole ⟵ \(Self.whole)"])
        #expect(reader.asked == [Self.whole, Self.first, "line 1"])
    }
}
