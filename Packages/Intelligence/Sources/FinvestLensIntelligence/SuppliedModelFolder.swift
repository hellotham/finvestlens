//
//  SuppliedModelFolder.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Reading a folder of models a person has pointed the app at: which models
//  are in it, and what each one is. The app supplies none and fetches none —
//  this only looks at what is already there.
//
//  The folder is normally a Hugging Face cache — `~/.cache/huggingface/hub`
//  on a Mac, where `mlx_lm` and every Hub client keep models. Each model there
//  is a `models--organisation--model` folder holding its files once in
//  `blobs/`, each revision as a folder of links in `snapshots/<revision>/`,
//  and `refs/main` naming the current one. A plain model folder dropped in
//  beside them — `config.json`, weights and tokenizer — counts too.
//
//  Access is to the whole folder, not to one model's snapshot, because the
//  sandbox does not follow a link out of the folder it was given: a snapshot's
//  files are links into `blobs/`, which is beside it and not inside it.
//
//  The shape is HelloNotes', which worked it out against the App Sandbox.
//  Nothing about a model is remembered: what it is and how big it is are read
//  from its own files each time.
//

import Foundation

/// A model in the folder. Everything here is read from the model's own files.
public struct SuppliedModelFile: Identifiable, Hashable, Sendable {
    /// Where a loader reads the model: a snapshot, or a plain model folder.
    public let directory: URL
    public let name: String
    /// What its weights weigh.
    public let bytes: Int64
    /// `model_type` from its configuration — what a loader looks an
    /// architecture up by.
    public let modelType: String?

    public var id: String { directory.standardizedFileURL.path }

    public init(directory: URL, name: String, bytes: Int64, modelType: String?) {
        self.directory = directory
        self.name = name
        self.bytes = bytes
        self.modelType = modelType
    }
}

public enum SuppliedModelFolder {

    /// Every whole model in `folder`, by name.
    public static func models(in folder: URL) -> [SuppliedModelFile] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children
            .compactMap { child -> SuppliedModelFile? in
                let name = child.lastPathComponent
                guard name.hasPrefix("models--") else { return model(at: child, name: name) }
                guard let snapshot = currentSnapshot(of: child) else { return nil }
                return model(at: snapshot, name: displayName(ofRepositoryFolder: name))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The revision `refs/main` names, or — without one — the newest snapshot
    /// that is a whole model.
    static func currentSnapshot(of repositoryFolder: URL) -> URL? {
        let snapshots = repositoryFolder.appending(path: "snapshots", directoryHint: .isDirectory)
        var candidates: [URL] = []
        if let main = try? String(contentsOf: repositoryFolder.appending(path: "refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !main.isEmpty, !main.contains("/") {
            candidates.append(snapshots.appending(path: main, directoryHint: .isDirectory))
        }
        let others = (try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        candidates += others.sorted { modified($0) > modified($1) }
        // A revision that is still arriving has its configuration before its
        // weights, and `refs/main` already names it: taken on the
        // configuration alone it hid the whole revision beside it, and the
        // model vanished from the list for as long as the download took.
        return candidates.first { isWhole($0) }
    }

    /// Whether `directory` holds a whole model: a configuration, weights,
    /// and — where the weights are in numbered parts — every part.
    static func isWhole(_ directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path)
        else { return false }
        let weights = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "safetensors" }
            .map(\.lastPathComponent)
        guard !weights.isEmpty else { return false }
        // `model-00002-of-00004.safetensors`: all four, or it is not whole.
        var parts: [String: (seen: Int, of: Int)] = [:]
        for name in weights {
            guard let match = name.wholeMatch(of: /(.*)-\d+-of-(\d+)\.safetensors/), let total = Int(match.2)
            else { continue }
            parts[String(match.1), default: (0, total)].seen += 1
        }
        return parts.values.allSatisfy { $0.seen >= $0.of }
    }

    /// The model in `directory`, if it is a whole one: a configuration and
    /// weights. A download that never finished has neither, and a folder of
    /// something else — a GGUF file, an OCR model — has no safetensors.
    static func model(at directory: URL, name: String) -> SuppliedModelFile? {
        let bytes = weightsBytes(in: directory)
        guard bytes > 0, isWhole(directory) else { return nil }
        return SuppliedModelFile(directory: directory, name: name, bytes: bytes,
                                 modelType: modelType(in: directory))
    }

    /// What a model's weights weigh. Safetensors only: the tokenizer and
    /// configuration are noise beside them.
    ///
    /// Sizes follow a cache's links. Every file in a snapshot is a symlink
    /// into `blobs/`, and a link's own size is a few dozen bytes — read
    /// without resolving them, a 17 GB model weighs 81 bytes and still counts
    /// as "has weights" (HelloNotes, September 2026).
    static func weightsBytes(in directory: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension == "safetensors" }
            .reduce(into: Int64(0)) { total, file in
                let target = file.resolvingSymlinksInPath()
                total += Int64((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }

    static func modelType(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["model_type"] as? String
    }

    /// `models--mlx-community--gemma-3-27b-it-bf16` → `gemma-3-27b-it-bf16`.
    static func displayName(ofRepositoryFolder name: String) -> String {
        let parts = name.components(separatedBy: "--")
        guard parts.count >= 3, parts[0] == "models" else { return name }
        return parts.dropFirst(2).joined(separator: "--")
    }

    /// The first file in a model's folder whose bytes are not on this device
    /// — a models folder in iCloud Drive, or in another provider's synced
    /// folder, can hold weights the system keeps online-only, and a loader's
    /// plain reads fail on those. Metadata only; nothing is fetched.
    ///
    /// Asked of what each entry *points to*: in a cache a snapshot's files
    /// are links into `blobs/`, and a link is always on the device whatever
    /// became of the file behind it. Two questions, because there are two
    /// ways a file is kept away: iCloud's own status, and the `dataless`
    /// flag every file provider sets on a file it has evicted (it is what
    /// `ls -lO` shows on one).
    public static func firstFileNotOnDevice(in directory: URL) -> String? {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.first { file in
            let target = file.resolvingSymlinksInPath()
            if let values = try? target.resourceValues(forKeys: keys), values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                return true
            }
            var information = stat()
            return stat(target.path, &information) == 0 && information.st_flags & UInt32(SF_DATALESS) != 0
        }?.lastPathComponent
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
