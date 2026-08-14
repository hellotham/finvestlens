//
//  AccountField.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A searchable account chooser (GnuCash's register autocomplete) in two
//  strict modes. **Display**: the chosen account's full name, rendered
//  directly from the binding on every pass — there is no cached text to go
//  stale, so a selected account can never show a placeholder. **Search**:
//  entered by clicking, starts empty, filters as you type; pick a row or
//  press Return for the best match; clicking away cancels back to display.
//

import SwiftUI
import FinvestLensEngine

enum AccountSearch {
    /// Accounts whose full name contains every whitespace-separated term of
    /// `query` (so "joint everyday" narrows the same way GnuCash's does). An empty
    /// query returns everything, in the given order.
    static func matches(_ query: String, in nodes: [AccountNode]) -> [AccountNode] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return nodes }
        return nodes.filter { node in
            let name = node.fullName.lowercased()
            return terms.allSatisfy { name.contains($0) }
        }
    }

    static func name(of id: GncGUID?, in nodes: [AccountNode]) -> String {
        id.flatMap { target in nodes.first { $0.id == target }?.fullName } ?? ""
    }
}

struct AccountField: View {
    /// `LocalizedStringKey`, not `String`: a `String` parameter picks `Text`'s
    /// verbatim initializer, emits no catalog key, and ships the English
    /// literal in all eight languages — silently, because the localization gate
    /// can only compare against keys the compiler emits. Four prompts had gone
    /// out that way. ``AccountComboCell/placeholder`` below was already typed
    /// this way; this is the same field agreeing with it.
    var prompt: LocalizedStringKey = "Account"
    let nodes: [AccountNode]
    @Binding var selection: GncGUID?
    /// Rows shown in the dropdown at once.
    var limit: Int = 8
    /// Offers an ✕ that puts the selection back to `nil`. Off by default: most
    /// call sites require an account, and a clear button that leaves a required
    /// field empty is a trap. On where "no account" is a real choice — an
    /// import row to leave out, a rule that leaves the account alone.
    var clearable: Bool = false

    @State private var searching = false
    @State private var query = ""
    @FocusState private var focused: Bool

    private var selectedName: String { AccountSearch.name(of: selection, in: nodes) }
    private var matches: [AccountNode] { AccountSearch.matches(query, in: nodes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if searching {
                searchField
                dropdown
            } else if clearable, selection != nil {
                HStack(spacing: 4) {
                    displayButton
                    clearButton
                }
            } else {
                displayButton
            }
        }
    }

    /// Only shown when there is something to clear, so it never reads as a
    /// disabled control.
    private var clearButton: some View {
        Button {
            selection = nil
        } label: {
            Image(systemName: "xmark.circle.fill")
                .imageScale(.medium)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A bare glyph carries no VoiceOver name of its own. "Clear account"
        // was the first wording and is a trap: in German, Spanish and French it
        // reads as *delete the account*, and so does the English to anyone
        // hearing it cold. Name what it clears.
        .accessibilityLabel("Clear selected account")
        .help("Clear selected account")
    }

    // MARK: Display mode — a pure function of the selection

    private var displayButton: some View {
        Button {
            beginSearch()
        } label: {
            HStack(spacing: 4) {
                // Branch rather than a ternary: the prompt is a catalog key and
                // the account name is data. One `Text(_:)` cannot be both.
                (selectedName.isEmpty ? Text(prompt) : Text(selectedName))
                    .foregroundStyle(selectedName.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                // Ornament: the Button is already named by the text beside it,
                // so an unhidden glyph only adds "chevron up chevron down" to
                // what VoiceOver reads out.
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Same split as the label: a key when empty, the account name when not.
        .help(selectedName.isEmpty ? Text("Choose an account") : Text(selectedName))
    }

    // MARK: Search mode

    private var searchField: some View {
        HStack(spacing: 4) {
            // Ornament beside a field that already announces itself.
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Type to search", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { takeBestMatch() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.tint, lineWidth: 1.5)
        )
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            // A blur races the tap that picks a row: give the pick a moment to
            // land, then cancel back to display mode (selection untouched).
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                if !focused { searching = false }
            }
        }
    }

    @ViewBuilder
    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty {
                Text("No accounts match “\(query)”.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 3)
            } else {
                ForEach(matches.prefix(limit)) { node in
                    Button { pick(node) } label: {
                        Text(node.fullName)
                            .scaledFont(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func beginSearch() {
        query = ""
        searching = true
        // The field has to exist before it can take focus.
        Task { focused = true }
    }

    private func pick(_ node: AccountNode) {
        selection = node.id
        searching = false
        focused = false
    }

    /// Return commits the single best match of the current filter.
    private func takeBestMatch() {
        if let exact = matches.first(where: { $0.fullName.caseInsensitiveCompare(query) == .orderedSame }) {
            pick(exact)
        } else if let first = matches.first {
            pick(first)
        } else {
            searching = false
        }
    }
}

/// The register's account cell: GnuCash's ComboCell, as a text field with a
/// native suggestions dropdown.
///
/// Semantics ported from `gnucash/register/register-gnome/combocell-gnome.c`:
/// typing runs a type-ahead search over full account names, capped at 30
/// matches (`MAX_NUM_MATCHES`, `gnc_combo_cell_type_ahead_search`); an emptied
/// field offers the whole list rather than the first thirty; ⎋ with an edit in
/// progress reverts the cell to its stored value and only an unchanged cell's
/// ⎋ falls through to cancel the row (`gnc_combo_cell_direct_update`,
/// `GDK_KEY_Escape`); ⇥ commits the current match before the cursor moves.
/// HIG *Combo boxes*: the field is "populated with a meaningful default value
/// from the list" — the leg's current account — and the suggestion rows are no
/// wider than the field.
///
/// One divergence, on purpose: ⏎ resolves the typed text *and saves the
/// transaction* — GnuCash's `activate_cursor` commits the whole row too, and
/// the register's contract is that Return is the save button.
///
/// The dropdown is `.textInputSuggestions`, not a popover: a popover takes key
/// focus, and a cell that loses its field the moment it offers choices is the
/// focus fight that sank the earlier account pickers in table cells.
struct AccountComboCell: View {
    /// The leg's current account — the value ⎋ reverts to.
    let accountID: GncGUID?
    var placeholder: LocalizedStringKey = "Account"
    let nodes: [AccountNode]
    /// Whether this cell can take the cursor (its row is selected/edited).
    var isEditable = true
    /// This cell's identity in the shared cursor (see ``RegisterCell``).
    var field: TransactionEditField
    /// The shared cursor — one per register surface.
    var cursor: FocusState<TransactionEditField?>.Binding
    let metrics: RegisterMetrics
    var onFocus: () -> Void = {}
    /// Writes the chosen account into the draft.
    let onPick: (GncGUID) -> Void
    /// ⏎ once the text resolves — the register saves the transaction.
    var onReturn: () -> Void = {}

    @State private var query = ""
    @State private var hasTyped = false
    @State private var browseShown = false

    private var isFocused: Bool { cursor.wrappedValue == field }
    private var currentName: String { AccountSearch.name(of: accountID, in: nodes) }
    /// The GnuCash cap: past thirty rows a combo popup stops being a shortlist.
    private var matches: [AccountNode] {
        Array(AccountSearch.matches(hasTyped ? query : "", in: nodes).prefix(30))
    }

    var body: some View {
        Group {
            if isEditable {
                cell
            } else {
                // The cursor cannot land here: drawn text only. `field` is
                // non-optional, so this cell cannot go nil-static the way
                // ``RegisterCell`` does — this branch is its gate.
                restText
            }
        }
        .scaledFont(.body)
        .lineLimit(1)
        .padding(.horizontal, metrics.cellPaddingH)
        .padding(.vertical, metrics.cellPaddingV)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: metrics.cellCorner)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
    }

    /// The stored account as quiet text — the rest presentation for a cell
    /// whose row is not selected, occupying the field's exact box.
    private var restText: some View {
        Text(currentName)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var cell: some View {
        // HIG *Combo boxes*: "Not supported in iOS" — so only macOS gets the
        // native suggestions dropdown. iOS keeps the same typed completion
        // (GnuCash's own default is no auto-popup) and offers the list behind
        // a browse chevron instead.
        #if os(macOS)
        // Suggestions only on the focused combo: installing the suggestion
        // session on every visible row's field is the prime suspect for the
        // dead click region (never tested against the outer-tap design).
        if isFocused {
            fieldBase
                .textInputSuggestions {
                    ForEach(matches) { node in
                        Text(node.fullName)
                            .textInputCompletion(node.fullName)
                    }
                }
        } else {
            fieldBase
        }
        #else
        HStack(spacing: 2) {
            fieldBase
            if isFocused {
                Button {
                    browseShown = true
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse accounts")
                .popover(isPresented: $browseShown) {
                    NavigationStack {
                        List(matches) { node in
                            Button {
                                commit(node)
                                browseShown = false
                            } label: {
                                Text(node.fullName)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .searchable(text: $query)
                        .navigationTitle(Text(placeholder))
                    }
                    .frame(minWidth: 320, minHeight: 360)
                }
            }
        }
        #endif
    }

    /// A real field, always present, hit-gated like every register cell. At
    /// rest it shows the account name as quiet text; focused, it is the combo.
    private var fieldBase: some View {
        TextField(placeholder, text: $query)
            .textFieldStyle(.plain)
            .truncationMode(.middle)
            .foregroundStyle(isFocused || currentName.isEmpty
                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .focused(cursor, equals: field)
            .allowsHitTesting(false)   // see RegisterCell — the row maps taps
            .onAppear { if !isFocused { query = currentName } }
            .onChange(of: currentName) { _, now in if !isFocused { query = now } }
            .onChange(of: isFocused) { was, now in
                if now {
                    query = currentName
                    hasTyped = false
                    onFocus()
                } else if was {
                    // The cursor can leave without a key this cell sees — the
                    // register's ⇥ monitor, or a click on another cell.
                    // GnuCash's combo commits on leave; so does this one.
                    resolve()
                }
            }
            .onChange(of: query) { old, now in
                guard old != now, isFocused else { return }
                hasTyped = true
                // A suggestion pick sets the text to the full name; treat an
                // exact name as picked so the draft never trails the cell.
                if let exact = exactMatch(now) { commit(exact) }
            }
            // ⏎ belongs to this cell, not the row's save handler, until the
            // text is resolved into an account.
            .submitScope()
            .onSubmit { resolveThenReturn() }
            .onKeyPress(keys: [.escape]) { _ in
                guard hasTyped else { return .ignored }  // unchanged ⎋ cancels the row
                query = currentName                      // changed ⎋ reverts the cell
                hasTyped = false
                return .handled
            }
    }

    private func exactMatch(_ text: String) -> AccountNode? {
        nodes.first { $0.fullName.caseInsensitiveCompare(text) == .orderedSame }
    }

    /// Typed text → account: an exact name, else the best type-ahead match.
    /// An emptied or matchless edit commits nothing — GnuCash's strict combo
    /// refuses rather than guesses (`gnc_combo_cell_leave` keeps a changed
    /// value only when it is in the list) — and the text falls back to the
    /// stored account, so the cell never lies about where the leg posts.
    @discardableResult
    private func resolve() -> Bool {
        if let exact = exactMatch(query) { commit(exact); return true }
        if hasTyped, !query.trimmingCharacters(in: .whitespaces).isEmpty,
           let best = matches.first {
            commit(best)
            return true
        }
        query = currentName
        hasTyped = false
        return accountID != nil
    }

    private func resolveThenReturn() {
        if resolve() { onReturn() }
    }

    private func commit(_ node: AccountNode) {
        if node.id != accountID { onPick(node.id) }
        query = node.fullName
        hasTyped = false
    }
}

/// A compact searchable account chooser for dense contexts (register table
/// cells): reads as plain text, opens a search-and-pick popover on click. The
/// popover owns keyboard focus, so there is no field-blur race.
struct AccountPickerButton: View {
    var label: String
    let nodes: [AccountNode]
    let onPick: (GncGUID) -> Void

    @State private var open = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var matches: [AccountNode] { AccountSearch.matches(query, in: nodes) }

    var body: some View {
        Button { open = true } label: {
            Text(label.isEmpty ? "—" : label)
                .scaledFont(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Search accounts", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { if let first = matches.first { choose(first) } }
                    .padding(8)
                Divider()
                List(matches.prefix(60).map { $0 }) { node in
                    Button { choose(node) } label: {
                        Text(node.fullName).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 360, height: 300)
            }
            .onAppear { query = ""; searchFocused = true }
        }
    }

    private func choose(_ node: AccountNode) {
        onPick(node.id)
        open = false
    }
}
