//
//  GncGUID.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A 128-bit identifier compatible with GnuCash's GUID format.
///
/// GnuCash serialises GUIDs as **32 lowercase hexadecimal characters with no
/// dashes** — *not* RFC-4122 formatting (Architecture ADR-3). Imported GUIDs
/// must round-trip byte-for-byte, so this type owns its own hex codec and never
/// relies on `Foundation.UUID`'s dashed/uppercase string form.
public struct GncGUID: Hashable, Sendable, CustomStringConvertible {

    /// The 16 raw bytes, most-significant first.
    public let bytes: [UInt8]

    /// Creates a GUID from exactly 16 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// Parses a 32-character hex string (dashes are tolerated on input and
    /// stripped, but canonical output never contains them).
    ///
    /// One pass over the UTF-8 bytes, no intermediate strings: a book load
    /// parses a GUID for every account, transaction, split and price, so the
    /// old `replacingOccurrences` + `lowercased()` + per-pair `UInt8(_:radix:)`
    /// was paid half a million times per open.
    public init?(hex rawInput: String) {
        var out = [UInt8]()
        out.reserveCapacity(16)
        var high: UInt8?
        for char in rawInput.utf8 {
            if char == UInt8(ascii: "-") { continue }
            let nibble: UInt8
            switch char {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = char - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = char - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = char - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let pending = high {
                out.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil, out.count == 16 else { return nil }
        self.bytes = out
    }

    /// The canonical 32-character lowercase hex string (no dashes).
    ///
    /// Table-driven: `String(format: "%02x")` per byte — sixteen Foundation
    /// format calls per GUID — was the single hottest line of a whole-book
    /// save (5.6 s of an 8.6 s write on the reference book, measured 9 Oct
    /// 2026), and the same line sits under every export and every load.
    public var hexString: String {
        var ascii = [UInt8](repeating: 0, count: 32)
        for (index, byte) in bytes.enumerated() {
            ascii[index * 2] = Self.hexDigits[Int(byte >> 4)]
            ascii[index * 2 + 1] = Self.hexDigits[Int(byte & 0x0F)]
        }
        return String(decoding: ascii, as: UTF8.self)
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    public var description: String { hexString }

    /// Generates a random GUID from the system CSPRNG.
    public static func random() -> GncGUID {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        // Force-unwrap is safe: exactly 16 bytes were produced.
        return GncGUID(bytes: bytes)!
    }
}

extension GncGUID: Identifiable {
    /// A GUID is its own identity.
    public var id: GncGUID { self }
}

// MARK: - Codable (as the canonical hex string)

extension GncGUID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let guid = GncGUID(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid GnuCash GUID hex string: \(hex)"
            )
        }
        self = guid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}
