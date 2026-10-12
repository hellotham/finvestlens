//
//  SettingsSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The app's settings on iPhone and iPad.
//
//  On the Mac the five panes are the tabs of the Settings window, which the
//  system opens from the app menu. iOS has no such window, and until
//  12 October 2026 nothing presented the panes there at all: an iPad could
//  not change its accent colour, enter a price provider's key, or see where
//  Apple Intelligence runs. Here they are the rows of one list, each pushing
//  the same pane the Mac shows.
//

#if os(iOS)
import SwiftUI

struct SettingsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    GeneralSettingsView(model: model)
                } label: {
                    Label("General", systemImage: "gearshape")
                }
                NavigationLink {
                    AppearanceSettingsView()
                        .navigationTitle("Appearance")
                } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
                NavigationLink {
                    PricingSettingsView(model: model)
                        .navigationTitle("Pricing")
                } label: {
                    Label("Pricing", systemImage: "chart.line.uptrend.xyaxis")
                }
                NavigationLink {
                    DocumentSettingsView()
                        .navigationTitle("Documents")
                } label: {
                    Label("Documents", systemImage: "paperclip")
                }
                NavigationLink {
                    IntelligenceSettingsView()
                } label: {
                    Label("Apple Intelligence", systemImage: "apple.intelligence")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Settings and Help at the foot of the iPad's sidebar. They are app-wide
/// rather than part of any mode, which is why they sit below the modes' rows
/// and not among them — and they are named, because a bare gear and a bare
/// question mark are two more unlabelled glyphs.
struct SidebarFooter: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Button("Settings", systemImage: "gearshape") { model.showingSettings = true }
            Button("Help", systemImage: "questionmark.circle") { model.showingHelp = true }
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .scaledFont(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
#endif
