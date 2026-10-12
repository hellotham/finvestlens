//
//  AcknowledgementsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The open-source work the app is built with, and the licence each part of
//  it comes under.
//
//  Until 12 October 2026 the app linked one outside package (GRDB) and said
//  so only in its repository. Running a model the person supplies brought in
//  MLX and what MLX needs — ten more packages, MIT and Apache-2.0 — and both
//  licences ask that their notice goes wherever a copy of the software goes.
//  A copy from the App Store has no repository beside it, so the notices are
//  in the app: this pane names each package, and **Licences…** shows the
//  licence and notice files themselves, as their authors wrote them
//  (`ThirdPartyLicenses.txt` in the app bundle, gathered from the package
//  checkouts by `scripts/build-third-party-licenses.py` — copied, never
//  retyped). A name, an SPDX identifier and a link are not a notice.
//
//  The list is what is *linked into the app*, read off the app target's own
//  link list, and `AcknowledgementsTests` holds it against the project's
//  `Package.resolved`: a package that is resolved and neither acknowledged
//  here nor named as a build tool fails the test.
//

import SwiftUI

/// One open-source package the app links.
public struct Acknowledgement: Identifiable, Sendable {
    /// What it does here, in a phrase.
    public enum Role: Sendable {
        case store, runsModels, languageModels, tokenizers, chatTemplates, hubClient, supporting
    }

    /// Its name as its authors write it — not translated.
    public let name: String
    /// The package's identity in `Package.resolved`.
    public let identity: String
    /// Its licence, as an SPDX identifier.
    public let license: String
    public let url: URL
    public let role: Role
    /// Other people's work it carries inside it, each with its own licence.
    public let includes: String?

    public var id: String { identity }

    init(_ name: String, identity: String, license: String, url: String, role: Role, includes: String? = nil) {
        self.name = name
        self.identity = identity
        self.license = license
        self.url = URL(string: url)!
        self.role = role
        self.includes = includes
    }
}

public enum Acknowledgements {

    /// Everything linked into the app that FinvestLens's own authors did not
    /// write, in the order a reader would look for it: the store, then what
    /// runs a model, then what those are built on.
    public static let linked: [Acknowledgement] = [
        .init("GRDB.swift", identity: "grdb.swift", license: "MIT",
              url: "https://github.com/groue/GRDB.swift", role: .store),
        .init("MLX Swift", identity: "mlx-swift", license: "MIT",
              url: "https://github.com/ml-explore/mlx-swift", role: .runsModels,
              includes: "MLX, MLX C, {fmt}, JSON for Modern C++ (MIT); metal-cpp (Apache-2.0)"),
        .init("MLX Swift LM", identity: "mlx-swift-lm", license: "MIT",
              url: "https://github.com/ml-explore/mlx-swift-lm", role: .languageModels,
              includes: "XGrammar (Apache-2.0)"),
        .init("swift-transformers", identity: "swift-transformers", license: "Apache-2.0",
              url: "https://github.com/huggingface/swift-transformers", role: .tokenizers),
        .init("swift-jinja", identity: "swift-jinja", license: "Apache-2.0",
              url: "https://github.com/huggingface/swift-jinja", role: .chatTemplates),
        .init("swift-huggingface", identity: "swift-huggingface", license: "Apache-2.0",
              url: "https://github.com/huggingface/swift-huggingface", role: .hubClient),
        .init("swift-collections", identity: "swift-collections", license: "Apache-2.0",
              url: "https://github.com/apple/swift-collections", role: .supporting),
        .init("swift-numerics", identity: "swift-numerics", license: "Apache-2.0",
              url: "https://github.com/apple/swift-numerics", role: .supporting),
        .init("swift-crypto", identity: "swift-crypto", license: "Apache-2.0",
              url: "https://github.com/apple/swift-crypto", role: .supporting),
        .init("EventSource", identity: "eventsource", license: "MIT",
              url: "https://github.com/mattt/EventSource", role: .supporting),
        .init("yyjson", identity: "yyjson", license: "MIT",
              url: "https://github.com/ibireme/yyjson", role: .supporting),
    ]

    /// Resolved by the project and not linked into the app: what the
    /// packages above use to build themselves or to build their own
    /// command-line tools. Nothing of these is distributed, so nothing of
    /// them is acknowledged — and they are named here so that the test can
    /// tell "deliberately left out" from "forgotten".
    public static let buildOnly: Set<String> = ["swift-syntax", "swift-argument-parser", "swift-asn1"]

    /// The app's own source, which its licence says a copy must point to.
    public static let source = URL(string: "https://github.com/hellotham/finvestlens")!

    /// The licence and notice files of everything in ``linked``, and of the
    /// works those carry — from the app's bundle, where the app target puts
    /// them. `nil` outside the app (a package's own tests have no bundle of
    /// the app's).
    public static func licences(in bundle: Bundle = .main) -> String? {
        bundle.url(forResource: "ThirdPartyLicenses", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// Settings ▸ Acknowledgements, on every platform.
public struct AcknowledgementsView: View {
    @State private var showingLicences = false

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text("FinvestLens is built with these open-source projects. Thank you to their authors and contributors.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Open-source packages") {
                ForEach(Acknowledgements.linked) { package in
                    row(for: package)
                }
            }
            Section {
                // Shown only where there is something to show: the texts are
                // the app bundle's, and a preview or a test has none.
                if Acknowledgements.licences() != nil {
                    Button("Licences…") { showingLicences = true }
                }
                Link("Source code", destination: Acknowledgements.source)
            } footer: {
                Text("FinvestLens is free software under the GNU General Public License, version 3 or later.")
            }
        }
        .formStyle(.grouped)
        .windowFloor(minWidth: 440, minHeight: 300)
        .navigationTitle("Acknowledgements")
        .sheet(isPresented: $showingLicences) { LicencesSheet() }
    }

    /// A package: its name — which is the way to it — and its licence on one
    /// line, then what it does here and what it carries beneath. The whole
    /// row is one element to VoiceOver, read in that order and opened like
    /// the link it contains: eleven rows are eleven stops, not thirty-three.
    private func row(for package: Acknowledgement) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Link(destination: package.url) {
                    Text(verbatim: package.name)
                        .scaledFont(.body, weight: .medium)
                }
                Spacer(minLength: 8)
                Text(verbatim: package.license)
                    .scaledFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
            }
            description(of: package.role)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let includes = package.includes {
                Text("Includes \(includes)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func description(of role: Acknowledgement.Role) -> Text {
        switch role {
        case .store: Text("The book’s SQLite store")
        case .runsModels: Text("Runs a model of your own, on Apple silicon")
        case .languageModels: Text("Open language models behind Apple’s Foundation Models")
        case .tokenizers: Text("Tokenizers for those models")
        case .chatTemplates: Text("Their chat templates")
        case .hubClient: Text("A client for the Hugging Face Hub that the tokenizer library links. FinvestLens downloads nothing with it.")
        case .supporting: Text("Used by the libraries above")
        }
    }
}

/// The licence and notice files, to read: plain text, as it was written,
/// that can be selected and copied.
private struct LicencesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: Acknowledgements.licences() ?? "")
                    .scaledFont(.caption, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Licences")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Nothing here to confirm or to lose, so Escape closes
                    // it as well as the button does.
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .windowFloor(minWidth: 620, minHeight: 520)
    }
}
