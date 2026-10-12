//
//  SuppliedModelTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A model the person supplies: what a folder of models is read as, and
//  where a request goes when one is chosen. No model is loaded here — what
//  runs one is the app target's.
//

import Foundation
import Testing
import FoundationModels
@testable import FinvestLensIntelligence

@Suite("A folder of models a person points at")
struct SuppliedModelFolderTests {

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func write(_ text: String, to url: URL) throws { try write(Data(text.utf8), to: url) }

    /// A model as a Hub client leaves it: files once in `blobs/`, the revision
    /// a folder of links to them, and `refs/main` naming the revision.
    private func cacheModel(_ repository: String, in folder: URL, type: String, weights: Int = 4_096) throws {
        let root = folder.appending(path: "models--" + repository.replacingOccurrences(of: "/", with: "--"))
        let blobs = root.appending(path: "blobs")
        let snapshot = root.appending(path: "snapshots/abc123")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try write("abc123", to: root.appending(path: "refs/main"))
        try write(#"{"model_type": "\#(type)"}"#, to: blobs.appending(path: "config"))
        try write(Data(count: weights), to: blobs.appending(path: "weights"))
        try FileManager.default.createSymbolicLink(
            at: snapshot.appending(path: "config.json"), withDestinationURL: blobs.appending(path: "config"))
        try FileManager.default.createSymbolicLink(
            at: snapshot.appending(path: "model.safetensors"), withDestinationURL: blobs.appending(path: "weights"))
    }

    @Test("A cache's models are found by their current revision, and weighed by what the links point to")
    func cacheLayout() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try cacheModel("mlx-community/Example-4B-4bit", in: folder, type: "qwen3", weights: 8_192)

        let models = SuppliedModelFolder.models(in: folder)
        #expect(models.map(\.name) == ["Example-4B-4bit"])
        #expect(models.first?.modelType == "qwen3")
        // The link is a few dozen bytes; the weights are what it points to.
        #expect(models.first?.bytes == 8_192)
        #expect(models.first?.directory.lastPathComponent == "abc123")
    }

    @Test("A plain model folder beside them counts too")
    func plainFolder() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(#"{"model_type": "gemma3"}"#, to: folder.appending(path: "my-model/config.json"))
        try write(Data(count: 1_024), to: folder.appending(path: "my-model/model.safetensors"))

        let models = SuppliedModelFolder.models(in: folder)
        #expect(models.map(\.name) == ["my-model"])
        #expect(models.first?.bytes == 1_024)
    }

    @Test("What is not a whole model is not listed")
    func notModels() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A download that never finished: a configuration, no weights.
        try write(#"{"model_type": "qwen3"}"#, to: folder.appending(path: "unfinished/config.json"))
        // Weights in a format the loader does not read.
        try write(#"{"model_type": "llama"}"#, to: folder.appending(path: "models--x--y-GGUF/snapshots/1/config.json"))
        try write(Data(count: 512), to: folder.appending(path: "models--x--y-GGUF/snapshots/1/model.gguf"))
        // Weights and no configuration.
        try write(Data(count: 512), to: folder.appending(path: "loose/model.safetensors"))
        // A file, not a folder.
        try write("notes", to: folder.appending(path: "README.txt"))

        #expect(SuppliedModelFolder.models(in: folder).isEmpty)
        #expect(SuppliedModelFolder.models(in: folder.appending(path: "no-such-folder")).isEmpty)
    }

    @Test("A revision still arriving does not hide the whole one beside it")
    func arriving() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try cacheModel("mlx-community/Example-4B-4bit", in: folder, type: "qwen3", weights: 8_192)
        // `refs/main` moves to the new revision as soon as its first file
        // lands, and that file is the configuration.
        let root = folder.appending(path: "models--mlx-community--Example-4B-4bit")
        try write(#"{"model_type": "qwen3"}"#, to: root.appending(path: "snapshots/def456/config.json"))
        try write("def456", to: root.appending(path: "refs/main"))

        let models = SuppliedModelFolder.models(in: folder)
        #expect(models.map(\.name) == ["Example-4B-4bit"])
        #expect(models.first?.directory.lastPathComponent == "abc123")
    }

    @Test("Weights in numbered parts are a model only when every part is there")
    func parts() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appending(path: "big-model")
        try write(#"{"model_type": "gemma4"}"#, to: model.appending(path: "config.json"))
        try write(Data(count: 1_024), to: model.appending(path: "model-00001-of-00003.safetensors"))
        try write(Data(count: 1_024), to: model.appending(path: "model-00003-of-00003.safetensors"))
        #expect(SuppliedModelFolder.models(in: folder).isEmpty)
        #expect(!SuppliedModelFolder.isWhole(model))

        try write(Data(count: 1_024), to: model.appending(path: "model-00002-of-00003.safetensors"))
        #expect(SuppliedModelFolder.models(in: folder).map(\.name) == ["big-model"])
        #expect(SuppliedModelFolder.models(in: folder).first?.bytes == 3_072)
    }

    @Test("A file that is on this device is not reported as away, through a cache's links or directly")
    func onDevice() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try cacheModel("mlx-community/Example-4B-4bit", in: folder, type: "qwen3")
        let snapshot = try #require(SuppliedModelFolder.models(in: folder).first?.directory)
        #expect(SuppliedModelFolder.firstFileNotOnDevice(in: snapshot) == nil)
    }

    @Test("Models are listed by name, numbers in order")
    func order() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["org/model-10b", "org/model-2b", "org/Alpha"] {
            try cacheModel(name, in: folder, type: "qwen3")
        }
        #expect(SuppliedModelFolder.models(in: folder).map(\.name) == ["Alpha", "model-2b", "model-10b"])
    }

    @Test("A repository folder's name is the model's")
    func names() {
        #expect(SuppliedModelFolder.displayName(ofRepositoryFolder: "models--mlx-community--gemma-3-27b-it-bf16")
                == "gemma-3-27b-it-bf16")
        #expect(SuppliedModelFolder.displayName(ofRepositoryFolder: "models--org--a--b") == "a--b")
        #expect(SuppliedModelFolder.displayName(ofRepositoryFolder: "something-else") == "something-else")
    }
}

@Suite("Where a request goes when the person has supplied a model")
struct SuppliedModelRoutingTests {

    @Test("Their model is theirs for everything, where it can serve")
    func everything() {
        for feature in IntelligenceFeature.allCases {
            #expect(LanguageModels.route(feature, wanted: .supplied, permitted: [],
                                         privateCloudServes: false, suppliedServes: true) == .supplied, "\(feature)")
        }
    }

    @Test("Where it cannot serve, Apple's model is tried, as it would have been")
    func fallsBack() {
        for feature in IntelligenceFeature.allCases {
            #expect(LanguageModels.route(feature, wanted: .supplied, permitted: Set(IntelligenceFeature.allCases),
                                         privateCloudServes: true, suppliedServes: false) == .onDevice, "\(feature)")
        }
    }

    @Test("It needs no command's leave, because nothing leaves")
    func noLeaveNeeded() {
        // Chosen and serving, a request outside any command still runs on it…
        #expect(LanguageModels.route(.invoiceAnalyzer, wanted: .supplied, permitted: [],
                                     privateCloudServes: true, suppliedServes: true) == .supplied)
        // …and the two other choices are untouched by its being there.
        #expect(LanguageModels.route(.invoiceAnalyzer, wanted: .onDevice, permitted: [.invoiceAnalyzer],
                                     privateCloudServes: true, suppliedServes: true) == .onDevice)
        #expect(LanguageModels.route(.invoiceAnalyzer, wanted: .privateCloud, permitted: [],
                                     privateCloudServes: true, suppliedServes: true) == .onDevice)
    }

    @Test("In a build with nothing to run one, the choice is not offered and a stored one reads as the default")
    func notOffered() {
        // The test process registers no loader.
        #expect(!LanguageModels.suppliesModels)
        #expect(!LanguageModels.offeredChoices.contains(.supplied))
        #expect(LanguageModels.choice(stored: "supplied") == LanguageModels.defaultChoice)
        if case .unavailable = LanguageModels.availability(of: .supplied) {} else {
            Issue.record("a supplied model reads as available with none supplied")
        }
    }

    @Test("Where their model is the one chosen and nothing can serve, the reason given is their model's")
    func whoseReason() {
        let apple = IntelligenceAvailability.unavailable(reason: "This device does not support Apple Intelligence.")
        let theirs = IntelligenceAvailability.unavailable(reason: "“model.safetensors” hasn’t downloaded to this device yet.")
        // Apple's model stands in and can serve: nobody needs a reason.
        #expect(LanguageModels.saying(.available, wanted: .supplied, own: theirs) == .available)
        // Neither can: what is wrong is what is wrong with theirs.
        #expect(LanguageModels.saying(apple, wanted: .supplied, own: theirs) == theirs)
        // They chose Apple's model: its reason, whatever state theirs is in.
        #expect(LanguageModels.saying(apple, wanted: .onDevice, own: theirs) == apple)
        // Theirs is fine and still was not what answered (a race): Apple's reason stands.
        #expect(LanguageModels.saying(apple, wanted: .supplied, own: .available) == apple)
    }

    @Test("With no model handed over, the reason is the one given for that, or to choose one")
    func noModel() {
        // Nothing in this process supplies a model, and nothing may: the
        // reason is asked for and the storage is left as it was found.
        if case .unavailable(let reason) = LanguageModels.availability(of: .supplied) {
            #expect(reason == "Choose a model of your own in Settings ▸ Apple Intelligence.")
        } else {
            Issue.record("a supplied model reads as available with none supplied")
        }
    }

    @Test("Nothing a supplied model is given leaves the device")
    func staysOnDevice() {
        LanguageModels.$choiceOverride.withValue(.supplied) {
            for feature in IntelligenceFeature.allCases {
                #expect(!LanguageModels.leavesDevice(feature), "\(feature)")
            }
        }
    }
}

@Suite("Whose model a failure is said of")
struct OwnModelFailureWordingTests {

    static let everyFailure: [IntelligenceError] = [
        .unavailable("a reason"), .emptyDocument, .guardrailDeclined, .refused("an explanation"),
        .contextOverflow, .recognitionFailed("an engine's words"), .unsupportedLanguage, .busy, .timedOut,
        .quotaReached(resetDate: nil), .networkUnavailable, .modelFailure("a detail"),
    ]

    @Test("Said of a model the person supplied, no failure names Apple Intelligence")
    func neverApple() {
        for failure in Self.everyFailure {
            #expect(!failure.description(ofOwnModel: true).contains("Apple Intelligence"), "\(failure)")
        }
    }

    @Test("The failures that name who answered name the right one; the rest read the same either way")
    func namesWhoAnswered() {
        for failure in Self.everyFailure {
            let apple = failure.description(ofOwnModel: false)
            let own = failure.description(ofOwnModel: true)
            switch failure {
            case .guardrailDeclined, .refused, .contextOverflow, .unsupportedLanguage, .busy, .timedOut, .modelFailure:
                #expect(apple.contains("Apple Intelligence"), "\(failure)")
                #expect(own.localizedCaseInsensitiveContains("your model"), "\(failure)")
            case .unavailable, .emptyDocument, .recognitionFailed, .quotaReached, .networkUnavailable:
                #expect(apple == own, "\(failure)")
            }
        }
        // What the model itself said is carried in both wordings.
        #expect(IntelligenceError.refused("an explanation").description(ofOwnModel: true).contains("an explanation"))
        #expect(IntelligenceError.modelFailure("a detail").description(ofOwnModel: true).contains("a detail"))
    }

    @Test("With no supplied model in the process, a failure is Apple Intelligence's")
    func appleByDefault() {
        // Nothing here supplies a model, so nothing can have been asked of one.
        #expect(!LanguageModels.speaksOfOwnModel)
        #expect(IntelligenceError.busy.errorDescription == IntelligenceError.busy.description(ofOwnModel: false))
        #expect(!LanguageModels.usesOwnModel(for: .invoiceAnalyzer))
    }
}

/// A model held to a grammar it was not trained on goes wrong in two ways
/// that are its own and not the page's: it spells whitespace out, and it
/// loses its place and writes a field's form where its value goes. Both
/// were seen on a real model reading a long statement (12 October 2026);
/// `SuppliedModelLiveTests` reads one again.
@Suite("What a supplied model's answer is put right of, and what marks one gone wrong")
struct SuppliedAnswerTests {

    @Test("Whitespace spelt out as text is whitespace again")
    func tidiedText() {
        // What came back, 28 rows in 102: a backslash and an "n" for a space.
        #expect(LanguageModels.tidied(#"CARD PURCHASE\n1013 SYDNEY"#) == "CARD PURCHASE 1013 SYDNEY")
        #expect(LanguageModels.tidied(#"A\tB\rC"#) == "A B C")
        // The real things too, and runs of them, and the ends.
        #expect(LanguageModels.tidied("  LG 27\" 4K\n\tMonitor  ") == "LG 27\" 4K Monitor")
        // What is already right is left as it is, to the character.
        for text in ["NETFLIX.COM", "5,200.00", "-45.20", "2026-03-05", "Café — déjeuner", ""] {
            #expect(LanguageModels.tidied(text) == text)
        }
    }

    @Test("Every string in an answer is put right, at any depth, and nothing else is touched")
    func tidiedContent() throws {
        let content = try GeneratedContent(json: #"""
            {"openingBalance":"3,000.00","transactions":[
              {"date":"2026-01-14","amount":"-23.91","payee":"CARD PURCHASE\\n1013 SYDNEY","reference":"","balanceAfter":"9,976.09"}],
             "count":2,"sure":true}
            """#)
        let tidy = LanguageModels.tidied(content)
        let read = try #require(
            try JSONSerialization.jsonObject(with: Data(tidy.jsonString.utf8)) as? [String: Any])
        let rows = try #require(read["transactions"] as? [[String: Any]])
        #expect(rows.first?["payee"] as? String == "CARD PURCHASE 1013 SYDNEY")
        #expect(rows.first?["amount"] as? String == "-23.91")
        #expect(rows.first?["reference"] as? String == "")
        #expect(read["openingBalance"] as? String == "3,000.00")
        #expect(read["count"] as? Int == 2)
        #expect(read["sure"] as? Bool == true)
        // And it is still an answer the type can be read from.
        let page = try StatementExtractor.ModelPage(tidy)
        #expect(page.transactions.first?.payee == "CARD PURCHASE 1013 SYDNEY")
    }

    @Test("Debris is a field's form where its value goes; an empty field, or anything read off a page, is not")
    func debris() {
        for value in [": ", ":", "]:", "}:", "date:", "date: ", "amount_type:", "payee:", "]: ["] {
            #expect(IntelligenceParsing.isDebris(value), "“\(value)”")
        }
        for value in ["", "   ", "2026-03-05", "5,200.00", "-45.20", "NETFLIX.COM", "SALARY ACME PTY LTD",
                      "Transfer: savings", "CR 12.00", "BP", "7-Eleven",
                      // What a page prints for "nothing here" is not the grammar's punctuation.
                      "-", "—", "***", "$", "n/a", ","] {
            #expect(!IntelligenceParsing.isDebris(value), "“\(value)”")
        }
        // A payee can be one word and a colon; a date or an amount cannot.
        #expect(IntelligenceParsing.isDebris("Interest:"))
        #expect(!IntelligenceParsing.isStructuralDebris("Interest:"))
        #expect(IntelligenceParsing.isStructuralDebris(": "))
    }

    @Test("A page is marked by debris in any field of a row — but a payee only by the grammar's own punctuation")
    func pageWithDebris() {
        func page(date: String = "2026-03-05", amount: String = "5,200.00", payee: String = "SALARY ACME PTY LTD",
                  reference: String = "", balance: String = "", opening: String = "") -> StatementExtractor.ModelPage {
            StatementExtractor.ModelPage(openingBalance: opening, transactions: [
                .init(date: "2026-03-02", amount: "-45.20", payee: "WOOLWORTHS", reference: "", balanceAfter: ""),
                .init(date: date, amount: amount, payee: payee, reference: reference, balanceAfter: balance),
            ])
        }
        #expect(!StatementExtractor.hasDebris(page()))
        #expect(StatementExtractor.hasDebris(page(date: ": ")))
        #expect(StatementExtractor.hasDebris(page(amount: "date:")))
        #expect(StatementExtractor.hasDebris(page(payee: ": ")))
        #expect(StatementExtractor.hasDebris(page(reference: "]:")))
        #expect(StatementExtractor.hasDebris(page(balance: "balanceAfter:")))
        #expect(StatementExtractor.hasDebris(page(opening: ": ")))
        // Read off a page, each of these: a payee that is a word and a
        // colon, a dash where there is no reference, a date in words.
        #expect(!StatementExtractor.hasDebris(page(payee: "Interest:")))
        #expect(!StatementExtractor.hasDebris(page(reference: "-")))
        #expect(!StatementExtractor.hasDebris(page(date: "5 March")))
    }

    @Test("A date with slashes in it comes through an answer's tidying as it went in")
    func slashes() throws {
        let content = try GeneratedContent(json: #"{"openingBalance":"","transactions":[{"date":"02/03/2026","amount":"-45.20","payee":"A/C TRANSFER","reference":"","balanceAfter":""}]}"#)
        let page = try StatementExtractor.ModelPage(LanguageModels.tidied(content))
        #expect(page.transactions.first?.date == "02/03/2026")
        #expect(page.transactions.first?.payee == "A/C TRANSFER")
    }
}
