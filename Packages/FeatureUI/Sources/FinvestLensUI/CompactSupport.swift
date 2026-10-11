//
//  CompactSupport.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  What the rest of FeatureUI needs to know about the compact shell, in one
//  place: whether it is inside one, how to own a navigation stack only when
//  nothing above already does, and how the title rule changes there.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension EnvironmentValues {
    /// `true` under `CompactShell` — the phone, or an iPad window narrowed to
    /// a compact width. Set once at the app's root (`finvestLensShell()`), on
    /// the outside of every sheet and importer, so a sheet presented from
    /// anywhere sees it too. Views read this rather than the size class: a
    /// Max-size phone turned sideways reports a regular width, and a shell
    /// that swapped on rotation would tear down whatever was being typed.
    @Entry var isCompactShell = false
}

public extension View {
    /// Decides which shell the app is in and says so to everything below.
    /// Applied once, on the root view of the main window.
    func finvestLensShell() -> some View {
        modifier(ShellEnvironment())
    }
}

private struct ShellEnvironment: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// The phone always; an iPad only while its window is compact.
    private var compact: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    func body(content: Content) -> some View {
        content.environment(\.isCompactShell, compact)
    }
}

extension View {
    /// A minimum size for a window, a sheet or a pane — the floor under a
    /// layout that starves below it. A floor is a promise about the
    /// container, and the compact shell's container is the screen: a floor
    /// wider than a phone does not widen the phone, it lays the content out
    /// at that width and cuts both edges off (the whole app at 860, the
    /// editor at 700, New Security at 520 — each seen on a phone before its
    /// floor was routed through here). So there it is not applied, and the
    /// view is expected to fit what it is given.
    func windowFloor(minWidth: CGFloat? = nil, minHeight: CGFloat? = nil) -> some View {
        modifier(WindowFloor(minWidth: minWidth, minHeight: minHeight))
    }
}

private struct WindowFloor: ViewModifier {
    @Environment(\.isCompactShell) private var compact
    let minWidth: CGFloat?
    let minHeight: CGFloat?

    /// One `frame` either way — a branch here would give everything under
    /// every floor a new identity when an iPad window crosses the compact
    /// threshold, and whatever was typed in an open sheet would go with it.
    func body(content: Content) -> some View {
        content.frame(minWidth: compact ? nil : minWidth, minHeight: compact ? nil : minHeight)
    }
}

/// A `NavigationStack` for a destination that needs one to hang a toolbar
/// from — in the split view's detail column, or as a sheet — and nothing at
/// all when the compact shell has already pushed the destination onto its own
/// stack. A stack inside a pushed destination draws a second navigation bar.
struct DestinationStack<Content: View>: View {
    @Environment(\.isCompactShell) private var compact
    @Environment(\.isEmbeddedDestination) private var embedded
    @ViewBuilder let content: () -> Content

    var body: some View {
        if compact, embedded {
            content()
        } else {
            NavigationStack { content() }
        }
    }
}

extension View {
    /// **The main window never titles** (navigation-design §4.4a): the sidebar
    /// and the tab strip already name what is open, and a title put the same
    /// word twice a few pixels apart. A compact stack has neither, so there
    /// the title is the only name on screen and the stack's wrapper sets it
    /// (`CompactDestinations`, `CompactModeRoot`). An inner `.navigationTitle`
    /// beats an outer one, which is why every destination routes through
    /// this rather than clearing the title itself.
    func untitledInRegularWidth() -> some View {
        modifier(TitleRule(title: nil, embedded: true))
    }

    /// For a view that is a destination *and* a sheet: no title when embedded
    /// in the regular shell (the strip names it), its own title as a sheet,
    /// and its own title again on a compact stack.
    func embeddedTitle(_ title: Text, embedded: Bool) -> some View {
        modifier(TitleRule(title: title, embedded: embedded))
    }
}

private struct TitleRule: ViewModifier {
    @Environment(\.isCompactShell) private var compact
    let title: Text?
    let embedded: Bool

    func body(content: Content) -> some View {
        if embedded, !compact {
            content.navigationTitle(Text(verbatim: ""))
        } else if let title {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}
