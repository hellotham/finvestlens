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

extension EnvironmentValues {
    /// `true` under `CompactShell` — a phone, folded or held either way, or an
    /// iPad window narrowed to a compact width. Set once at the app's root
    /// (`finvestLensShell()`), on the outside of every sheet and importer, so
    /// a sheet presented from anywhere sees it too. Views read this rather
    /// than a size class: a Max-size phone turned sideways reports a regular
    /// width, and a shell that swapped on rotation would tear down whatever
    /// was being typed.
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// The regular shell only where there is room both ways: an iPad, or
    /// iPhone Duo open — Apple: "On the inner display, your app should look
    /// like a natural extension of its iPad layout" (*Three steps to make your
    /// app shine on iPhone Duo*). It was `idiom == .phone ||` compact width,
    /// which kept the open Duo on the phone shell stretched across it. A
    /// phone held sideways, a Max-size one included, has a compact *height*,
    /// so it keeps the compact shell and never swaps on rotation; asked as
    /// `== .regular`, an absent size class takes the narrow branch.
    private var compact: Bool {
        #if os(iOS)
        !(horizontalSizeClass == .regular && verticalSizeClass == .regular)
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

    /// One layout either way — a branch here would give everything under
    /// every floor a new identity when an iPad window crosses the compact
    /// threshold, and whatever was typed in an open sheet would go with it.
    func body(content: Content) -> some View {
        #if os(iOS)
        FloorLayout(minWidth: compact ? nil : minWidth, minHeight: compact ? nil : minHeight) { content }
        #else
        content.frame(minWidth: compact ? nil : minWidth, minHeight: compact ? nil : minHeight)
        #endif
    }
}

#if os(iOS)
/// A floor that never lays content out wider, or taller, than it is offered.
///
/// On the Mac the floor is a window's minimum size, which the window obeys.
/// On iOS the system sizes the container — a sheet, a column, iPhone Duo's
/// inner display at 669 points across in portrait, narrower than any iPad —
/// and a floor above the room offered does not grow it: `.frame(minWidth:)`
/// laid the content out at the floor and the edges were cut off. Floors of
/// 700 to 980 points meet that display as soon as it is in the regular
/// shell. So here the floor is the lesser of itself and the offer; a query
/// for the floor itself (no offer, or none yet) still gets the whole floor,
/// as `.frame(minWidth:)` gave it.
private struct FloorLayout: Layout {
    let minWidth: CGFloat?
    let minHeight: CGFloat?

    private func floor(_ minimum: CGFloat?, offered: CGFloat?) -> CGFloat? {
        guard let minimum else { return nil }
        guard let offered, offered > 0, offered.isFinite else { return minimum }
        return min(minimum, offered)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = floor(minWidth, offered: proposal.width)
        let height = floor(minHeight, offered: proposal.height)
        // Offer at least the floor, as `.frame(minWidth:)` does — which, the
        // floor being no more than a real offer, is the offer itself. No offer
        // stays no offer, also as it does.
        let offer = ProposedViewSize(width: proposal.width.map { max($0, width ?? 0) },
                                     height: proposal.height.map { max($0, height ?? 0) })
        var size = subview.sizeThatFits(offer)
        if let width { size.width = max(size.width, width) }
        if let height { size.height = max(size.height, height) }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
#endif

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
