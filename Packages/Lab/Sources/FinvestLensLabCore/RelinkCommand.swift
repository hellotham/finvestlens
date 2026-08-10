//
//  RelinkCommand.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import FinvestLensUI

/// `finlab relink` — point document links back at the filed originals.
///
/// This exists because of a defect in this tool. `finlab documents` attached
/// matches with `attachDocument(named:data:to:)`, whose contract is to *copy*
/// the file into the document folder — and that folder defaults to the folder
/// holding the book. One ingest therefore duplicated 189 receipts onto the NAS
/// beside the book and pointed every link at the duplicate. The archive the
/// user files documents into is the archive; the book records *where* a
/// document is, not a second copy of it.
///
/// The repair walks every linked transaction and rewrites its link to the
/// original's path **relative to whichever configured root contains it**, so
/// nothing embeds a home directory or a cloud-provider path that differs on the
/// next machine. A copy is only ever matched to an original it is byte-identical
/// to: names are the fast index, the SHA-256 is what actually decides.
///
///     finlab relink --file BOOK.finvestlens \
///         --primary ~/…/Invoices --secondary ~/…/Finance [--apply] [--prune]
///
/// Dry-run by default. `--prune` additionally removes a copy beside the book,
/// and only when an identical file is confirmed present under a root — so the
/// bytes always survive the deletion.
enum RelinkCommand {

    @MainActor
    static func run(_ options: LabOptions, log: LabLog) async throws {
        let file = try options.existingURL("file")
        let primary = try options.existingURL("primary")
        let secondary = options.string("secondary").map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        let apply = options.flag("apply")
        let prune = options.flag("prune")

        let model = AppModel()
        let (_, openSeconds) = try await Stopwatch.measure {
            try await model.open(at: file, breakStaleLock: true)
        }
        defer { model.close() }
        log(Fmt.row("open \(file.lastPathComponent)", Fmt.time(openSeconds)))
        guard !model.isReadOnly else { throw LabError.message("book opened read-only") }

        // The roots the links become relative to. Setting them on the model is
        // also what lets `linkedDocumentURL` resolve a rewritten link, so the
        // verification below exercises the same path the app will.
        model.configuredDocumentFolder = primary
        model.secondaryDocumentFolder = secondary
        let roots = model.documentFolders
        log("  primary:   \(primary.path)")
        if let secondary { log("  secondary: \(secondary.path)") }

        // 1 — index the archive: by name for speed, by content hash for truth.
        var (index, indexSeconds) = try Stopwatch.measure { try Archive(roots: roots) }
        log(Fmt.row("index \(index.count) archived file(s)", Fmt.time(indexSeconds)))
        guard index.count > 0 else {
            throw LabError.message("no files under the given root(s) — check the paths")
        }

        let bookFolder = file.deletingLastPathComponent().standardizedFileURL

        var rewritten: [(from: String, to: String)] = []
        var alreadyRelative = 0
        var unresolved: [String] = []
        var claimedOriginals = Set<String>()

        for document in model.linkedDocuments() {
            let link = document.link
            guard !link.hasPrefix("http://"), !link.hasPrefix("https://") else { continue }
            guard let current = model.linkedDocumentURL(for: document.id) else { continue }
            let currentPath = current.standardizedFileURL.path

            // Already relative to a root and resolving — nothing to do.
            if !link.hasPrefix("/"), !link.hasPrefix("file://"),
               roots.contains(where: { currentPath.hasPrefix($0.standardizedFileURL.path + "/") }),
               FileManager.default.fileExists(atPath: currentPath) {
                alreadyRelative += 1
                continue
            }

            // Find the filed original this link's target is a copy of.
            guard let original = index.original(matching: current, named: document.displayName) else {
                unresolved.append(link)
                continue
            }
            claimedOriginals.insert(original.standardizedFileURL.path)

            let replacement = AppModel.relativeLink(for: original, under: roots)
            guard replacement != link else { alreadyRelative += 1; continue }
            rewritten.append((from: link, to: replacement))
            if apply { model.setDocumentLink(replacement, for: document.id) }
        }

        log("")
        log("  \(rewritten.count) link(s) to rewrite, \(alreadyRelative) already relative to a root, "
            + "\(unresolved.count) unresolved")
        for row in rewritten.prefix(12) { log("    \(row.from)  →  \(row.to)") }
        if rewritten.count > 12 { log("    … and \(rewritten.count - 12) more") }
        for row in unresolved.prefix(10) { log("    ⚠︎ no original found for: \(row)") }

        guard apply else {
            log("  (dry run — pass --apply to rewrite them)")
            return
        }

        let (_, saveSeconds) = try Stopwatch.measure { try model.save() }
        log(Fmt.row("save", Fmt.time(saveSeconds)))

        // 2 — verify every link resolves before anything is deleted.
        let broken = model.linkedDocuments().filter { !$0.isWeb && !$0.exists }
        guard broken.isEmpty else {
            log("  ⚠︎ \(broken.count) link(s) do not resolve after the rewrite — not pruning.")
            for row in broken.prefix(10) { log("    \(row.link)") }
            return
        }
        log("  every link resolves.")

        guard prune else {
            log("  (pass --prune to remove the now-unreferenced copies beside the book)")
            return
        }

        // 3 — remove copies beside the book, but only ones whose bytes are
        // provably still in the archive.
        var removed = 0, kept = 0
        let beside = (try? FileManager.default.contentsOfDirectory(
            at: bookFolder, includingPropertiesForKeys: nil)) ?? []
        for candidate in beside {
            let ext = candidate.pathExtension.lowercased()
            guard !["finvestlens", "lock", "log"].contains(ext) else { continue }
            guard index.hasTwin(of: candidate) else { kept += 1; continue }
            do { try FileManager.default.removeItem(at: candidate); removed += 1 }
            catch { kept += 1; log("    ⚠︎ could not remove \(candidate.lastPathComponent)") }
        }
        log("  pruned \(removed) copy(ies) beside the book; kept \(kept) file(s) with no archived twin.")
    }
}

/// The filed archive, indexed twice: by file name to find candidates fast, and
/// by SHA-256 to decide between them. Name alone is not enough — two months of
/// statements can both be `statement.pdf` — and hash alone would be a full
/// re-read of every candidate for every link.
private struct Archive {
    private var byName: [String: [URL]] = [:]
    private var digests: Set<String> = []
    private(set) var count = 0

    init(roots: [URL]) throws {
        for root in roots {
            let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = files?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                byName[url.lastPathComponent.lowercased(), default: []].append(url)
                count += 1
            }
        }
    }

    static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Is a byte-identical file already in the archive?
    ///
    /// Asked of a copy beside the book, immediately before deleting it, so it
    /// must be answered from the archive itself and not from a set of files
    /// this run happened to touch — most links needed no rewrite, so their
    /// originals were never opened, and trusting that set would have kept
    /// every one of their copies. Same name, same bytes, or no deletion.
    func hasTwin(of file: URL) -> Bool {
        guard let wanted = try? Self.digest(of: file) else { return false }
        let candidates = byName[file.lastPathComponent.lowercased()] ?? []
        return candidates.contains { (try? Self.digest(of: $0)) == wanted }
    }

    /// The archived original `copy` was made from: the same name when that is
    /// unambiguous, otherwise the one whose bytes match.
    mutating func original(matching copy: URL, named displayName: String) -> URL? {
        let candidates = byName[copy.lastPathComponent.lowercased()]
            ?? byName[displayName.lowercased()] ?? []
        if candidates.count == 1 { return remember(candidates[0]) }
        guard let wanted = try? Self.digest(of: copy) else {
            guard let first = candidates.first else { return nil }
            return remember(first)
        }
        for candidate in candidates where (try? Self.digest(of: candidate)) == wanted {
            return remember(candidate)
        }
        return nil
    }

    private mutating func remember(_ url: URL) -> URL {
        if let digest = try? Self.digest(of: url) { digests.insert(digest) }
        return url
    }
}
