//
//  Timing.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A monotonic stopwatch.
///
/// `ContinuousClock` rather than `Date`: a wall-clock difference can go
/// backwards across an NTP correction, and a benchmark that reports a negative
/// duration once a fortnight is worse than no benchmark.
struct Stopwatch {
    private let started = ContinuousClock.now

    /// Seconds since the stopwatch was made.
    var seconds: Double { (ContinuousClock.now - started).asSeconds }

    /// Runs `work`, returning its value alongside how long it took.
    ///
    /// `@MainActor` because every caller is: the commands drive `AppModel`,
    /// which is main-actor isolated, so a nonisolated helper would only force
    /// each call site to prove its closure can safely cross actors when it
    /// never leaves this one.
    @MainActor
    static func measure<T>(_ work: () throws -> T) rethrows -> (value: T, seconds: Double) {
        let started = ContinuousClock.now
        let value = try work()
        return (value, (ContinuousClock.now - started).asSeconds)
    }

    /// Async twin of ``measure(_:)``.
    @MainActor
    static func measure<T>(_ work: () async throws -> T) async rethrows -> (value: T, seconds: Double) {
        let started = ContinuousClock.now
        let value = try await work()
        return (value, (ContinuousClock.now - started).asSeconds)
    }
}

extension Duration {
    /// This duration in seconds, as a `Double`.
    var asSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Formatting shared by every command, so two runs are always comparable.
enum Fmt {

    /// A duration: milliseconds under a second, seconds above it.
    static func time(_ seconds: Double) -> String {
        seconds < 1
            ? String(format: "%.0f ms", seconds * 1000)
            : String(format: "%.2f s", seconds)
    }

    /// A byte count in the units a person reads.
    static func bytes(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
    }

    /// A count with thousands separators.
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// `label` padded to `width`, so a column of timings lines up.
    static func row(_ label: String, _ value: String, width: Int = 40) -> String {
        let pad = max(0, width - label.count)
        return "  \(label)\(String(repeating: " ", count: pad))\(value)"
    }
}

/// The size of a file, or 0 when it is not there.
func fileSize(at url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

/// Whether `url` sits on a volume the OS considers local.
///
/// This is the fact the whole direct-mode-versus-working-copy question turns
/// on (architecture.md §6.2), so it is worth reading from the filesystem
/// rather than guessing from the path: a `/Volumes/...` prefix says nothing —
/// an external SSD lives there too — and a network share can be mounted
/// anywhere, including under a home directory.
func isOnLocalVolume(_ url: URL) -> Bool {
    // Ask the enclosing directory when the file itself is not there yet —
    // an import is told where to *put* a book, and `resourceValues` on a
    // path with nothing at it throws. Defaulting to "local" on that throw
    // reported an SMB share as local for exactly as long as it took to
    // notice, which is the kind of wrong that quietly invalidates a
    // measurement rather than failing it.
    for candidate in [url, url.deletingLastPathComponent()] {
        if let value = try? candidate.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal {
            return value
        }
    }
    return true
}
