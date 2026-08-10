//
//  HelpView.swift
//  FinvestLens — FeatureUI
//
//  The in-app help book: a topic list beside the page you are reading, with
//  search. Pages come from ``HelpBook`` as `LocalizedStringKey`s, so they
//  translate through the app's String Catalog and the same code serves macOS,
//  iPadOS and iOS — there is no separate HTML help bundle to keep in sync.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

public struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String? = HelpBook.sections.first?.topics.first?.id
    @State private var search = ""

    public init() {}

    /// Sections filtered by the search field, held in state rather than
    /// recomputed: as a computed property this ran twice per keystroke — once
    /// from `body` and again from `onChange` — and again on every unrelated
    /// re-render.
    @State private var visibleSections: [HelpSection] = HelpBook.sections

    /// A topic matches on its title, summary or keywords; an empty search
    /// shows everything.
    private static func sections(matching search: String) -> [HelpSection] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return HelpBook.sections }
        return HelpBook.sections.compactMap { section in
            let topics = section.topics.filter { $0.matches(needle) }
            return topics.isEmpty ? nil : HelpSection(id: section.id, title: section.title,
                                                      topics: topics)
        }
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(visibleSections) { section in
                    Section(section.title) {
                        ForEach(section.topics) { topic in
                            Label(topic.title, systemImage: topic.symbol)
                                .scaledFont(.callout)
                                .tag(topic.id)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: Text("Search help"))
            .navigationTitle("FinvestLens Help")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let topic = selection.flatMap(HelpBook.topic(id:)) {
                HelpTopicPage(topic: topic)
            } else {
                ContentUnavailableView("Choose a topic",
                                       systemImage: "book",
                                       description: Text("Pick a page on the left, or search."))
            }
        }
        .onEscapeCommand { dismiss() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onChange(of: search) {
            visibleSections = Self.sections(matching: search)
            // Keep the reader on a page that is still in the list.
            let visible = visibleSections.flatMap(\.topics).map(\.id)
            if let selection, visible.contains(selection) { return }
            selection = visible.first
        }
    }
}

private extension HelpTopic {
    /// Matches against the reader's own language *and* the English keywords, so
    /// searching for a term learned from GnuCash still finds the page.
    ///
    /// Reads the prebuilt index rather than reflecting on the title:
    /// `String(describing:)` of a `LocalizedStringKey` returns
    /// `LocalizedStringKey(key: "Accounts", hasFormatting: false, arguments: [])`
    /// — the English key wrapped in debug text, whatever the reader's language.
    /// That made search English-only, and made "key", "arguments" and "false"
    /// match all 25 topics.
    func matches(_ needle: String) -> Bool {
        HelpBook.searchIndex[id]?.contains(needle) ?? false
    }
}

/// One help page.
struct HelpTopicPage: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(topic.title, systemImage: topic.symbol)
                        .scaledFont(.largeTitle, weight: .semibold)
                        .labelStyle(.titleAndIcon)
                    Text(topic.summary)
                        .scaledFont(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .text(let key):
            Text(key).scaledFont(.body)

        case .heading(let key):
            Text(key)
                .scaledFont(.title3, weight: .semibold)
                .padding(.top, 6)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•").foregroundStyle(.secondary)
                        Text(item).scaledFont(.body)
                    }
                }
            }

        case .steps(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(index + 1).")
                            .scaledFont(.body, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(item).scaledFont(.body)
                    }
                }
            }

        case .table(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(row.0)
                            .scaledFont(.callout)
                            .frame(minWidth: 120, alignment: .leading)
                        Text(row.1)
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    if index < rows.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

        case .tip(let key):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.tint)
                Text(key).scaledFont(.callout)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
