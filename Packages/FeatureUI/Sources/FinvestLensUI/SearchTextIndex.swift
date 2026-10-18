//
//  SearchTextIndex.swift
//  FinvestLens — FeatureUI
//
//  The search bar's text, folded once per book change.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Every transaction's searchable text — its description and number, each
/// leg's memo and account name — folded once and laid end to end, so a
/// keystroke is one scan of bytes instead of a walk of the book that
/// lowercases every string it meets.
///
/// Reported on build 4: "It takes seconds to enter a key into the search box
/// as it dynamically tries to search after every key." On the reference book
/// the walk alone was 73–286 ms a keystroke, before a row was drawn.
///
/// The fields are the ones the free-text token has always matched
/// (`matchesFreeText`), each folded as it was — lowercased — and kept apart
/// by a separator no typed text contains, so a match can no more span two
/// fields here than it could when each was tested on its own.
struct SearchTextIndex {
    /// The transactions, in book order.
    let transactions: [Transaction]
    /// Each transaction's folded fields, separated by `0x1F`, the whole
    /// followed by a 0.
    private let bytes: [UInt8]
    /// Where each transaction's text begins in `bytes`, with one entry past
    /// the end so transaction `i` is `starts[i]..<starts[i + 1]`.
    private let starts: [Int]

    init(_ transactions: [Transaction]) {
        self.transactions = transactions
        var bytes: [UInt8] = []
        bytes.reserveCapacity(transactions.count * 96)
        var starts: [Int] = []
        starts.reserveCapacity(transactions.count + 1)
        func add(_ text: String) {
            guard !text.isEmpty else { return }
            Self.appendFolded(text, to: &bytes)
            bytes.append(0x1F)
        }
        // A few hundred accounts name a hundred thousand legs: each name is
        // folded once per build, not once a leg.
        var names: [ObjectIdentifier: [UInt8]] = [:]
        for txn in transactions {
            starts.append(bytes.count)
            add(txn.transactionDescription)
            add(txn.number)
            for split in txn.splits {
                add(split.memo)
                guard let account = split.account else { continue }
                let key = ObjectIdentifier(account)
                if names[key] == nil {
                    var folded: [UInt8] = []
                    Self.appendFolded(account.name, to: &folded)
                    names[key] = folded
                }
                if let folded = names[key], !folded.isEmpty {
                    bytes.append(contentsOf: folded)
                    bytes.append(0x1F)
                }
            }
            bytes.append(0)
        }
        starts.append(bytes.count)
        self.bytes = bytes
        self.starts = starts
    }

    /// How text and needle are both compared: lowercased, as the matcher
    /// always did, and in one canonical form — so a match's bytes are the
    /// needle's bytes, whichever way either was typed or imported.
    static func fold(_ text: String) -> String {
        text.lowercased().precomposedStringWithCanonicalMapping
    }

    /// ``fold(_:)``'s bytes, appended: ASCII — nearly every bank description
    /// — lowercased byte by byte, which is what `lowercased()` does to it and
    /// is already in canonical form; anything else through ``fold(_:)``.
    static func appendFolded(_ text: String, to bytes: inout [UInt8]) {
        let utf8 = text.utf8
        if utf8.allSatisfy({ $0 < 0x80 }) {
            for byte in utf8 { bytes.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) }
        } else {
            bytes.append(contentsOf: fold(text).utf8)
        }
    }

    /// The positions in ``transactions`` whose text contains `needle`, in
    /// ascending order — of every transaction, or only of `candidates`
    /// (themselves ascending), which is how a longer query narrows a shorter
    /// one's results instead of starting again.
    func positions(containing needle: String, among candidates: [Int]? = nil) -> [Int] {
        let pattern = Array(Self.fold(needle).utf8)
        guard !pattern.isEmpty else { return candidates ?? Array(transactions.indices) }
        return bytes.withUnsafeBufferPointer { hay -> [Int] in
            pattern.withUnsafeBufferPointer { needle -> [Int] in
                guard let base = hay.baseAddress, let key = needle.baseAddress else { return [] }
                var out: [Int] = []
                if let candidates {
                    for index in candidates {
                        let start = starts[index], length = starts[index + 1] - start
                        if memmem(base + start, length, key, needle.count) != nil { out.append(index) }
                    }
                    return out
                }
                // One pass over the whole text: each hit names its transaction,
                // and the scan resumes at the next one's start.
                var offset = 0
                var index = 0
                while offset < hay.count,
                      let hit = memmem(base + offset, hay.count - offset, key, needle.count) {
                    let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    index = owner(of: at, from: index)
                    out.append(index)
                    offset = starts[index + 1]
                }
                return out
            }
        }
    }

    /// The transaction whose text holds byte `offset`, searching from `low`
    /// (hits arrive in order, so the answer never moves backwards).
    private func owner(of offset: Int, from low: Int) -> Int {
        var low = low, high = transactions.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
