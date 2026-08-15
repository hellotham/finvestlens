//
//  ImportView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensInterchange

/// A file the user chose to import, with its detected format. PDF statements
/// arrive with `prestaged` rows already extracted by Apple Intelligence.
struct ImportPayload: Identifiable {
    let id = UUID()
    let data: Data
    let format: BankFileFormat
    var prestaged: [StagedTransaction]?
    /// The name the file was downloaded under — banks name exports after the
    /// account, so it is the sheet's best guess at where the rows belong.
    var fileName: String?

    init(data: Data, format: BankFileFormat, prestaged: [StagedTransaction]? = nil,
         fileName: String? = nil) {
        self.data = data
        self.format = format
        self.prestaged = prestaged
        self.fileName = fileName
    }
}

/// Reviews a bank file before import: pick the target account, preview matched
/// rows (with duplicate flags and suggested destinations), then post
/// (`FR-XIO-03/05`).
struct ImportView: View {
    @Environment(\.appDateFormat) private var appDateFormat
    @Bindable var model: AppModel
    let payload: ImportPayload
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 96 * appFontScale }

    @State private var targetID: GncGUID?
    /// The account the sheet pre-filled and why, kept so the note under the
    /// field disappears the moment the user picks something else.
    @State private var suggestedID: GncGUID?
    @State private var suggestedSource: ImportTargetSource?
    /// The bank's own id for the account this file came from, where the format
    /// carries one — stamped on the chosen account after a successful import so
    /// the next statement from the same account needs no choosing.
    @State private var fileAccountID: String?
    @State private var results: [MatchResult] = []
    @State private var assignments: [UUID: GncGUID] = [:]
    /// Rows the user cleared, to leave out of the import. A separate set
    /// because `assignments[id] = nil` *removes* the key rather than storing an
    /// empty choice, so the row would fall straight back to its suggestion —
    /// which is exactly what the old "— none —" menu item silently did.
    @State private var excluded: Set<UUID> = []
    @State private var skipDuplicates = true
    @State private var markMatchedCleared = true
    @State private var fallbackToImbalance = true
    @State private var suggesting = false
    @State private var suggestError: String?

    // CSV column mapping (only shown for CSV).
    @State private var dateCol = 0
    @State private var amountCol = 1
    @State private var payeeCol = 2
    @State private var memoCol = -1
    @State private var refCol = -1
    @State private var skipRows = 0
    @State private var dateFormat = "yyyy-MM-dd"
    @State private var hasHeader = true
    /// The shape worked out from the file's own header, and whether the user
    /// asked to set the columns themselves anyway.
    @State private var csvDetection: CSVFormatDetection?
    @State private var csvManualOverride = false
    @State private var showingSaveProfile = false
    @State private var newProfileName = ""

    // Investment (security) rows — imported via the Stock Assistant path.
    @State private var investments: [StagedTransaction] = []
    /// Rows whose broker reference is already posted (see `loadAndMatch`).
    @State private var invAlreadyImported: Set<UUID> = []
    @State private var invSecurity: [UUID: GncGUID] = [:]
    @State private var invSettlement: GncGUID?
    @State private var invIncome: GncGUID?
    @State private var invError: String?
    @State private var invCreated = 0

    private var accounts: [AccountNode] { model.postableAccounts }
    /// Whether the book has an imbalance account rows without a destination
    /// can fall back to.
    private var hasImbalanceFallback: Bool {
        guard let targetID, let account = model.book?.account(with: targetID) else { return false }
        return model.imbalanceFallback(for: account) != nil
    }
    /// Every row still in the import — a cleared row leaves entirely, so the
    /// imbalance fallback cannot sweep it back in.
    private var includedResults: [MatchResult] {
        excluded.isEmpty ? results : results.filter { !excluded.contains($0.staged.id) }
    }
    private var importCount: Int {
        includedResults.filter {
            !(skipDuplicates && $0.isDuplicate)
                && (destination(for: $0) != nil || (fallbackToImbalance && hasImbalanceFallback))
        }.count
    }

    var body: some View {
        NavigationStack {
            // A lazy List, not a Form. A Form materialises every row at once,
            // and a statement of a couple of hundred rows against a book of a
            // few hundred accounts overflows SwiftUI's attribute graph and
            // aborts the process — measured to fail between 150 and 175 rows on
            // a 550-account book, where a real card statement runs to 220. The
            // sibling Categorise sheet hit this first and is built the same way.
            List {
                Section {
                    AccountField(nodes: accounts, selection: $targetID)
                    // Say where a pre-filled account came from. The sheet posts
                    // real money, and a guess the user cannot distinguish from
                    // their own earlier choice is worse than no guess at all.
                    if let suggestedSource, targetID == suggestedID {
                        switch suggestedSource {
                        case .rememberedIdentifier:
                            Label("Remembered from a previous import.", systemImage: "checkmark.seal")
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        case .fileName:
                            Label("Matched from the file name.", systemImage: "doc.text.magnifyingglass")
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        case .currentRegister:
                            Label("The account you were viewing.", systemImage: "list.bullet.rectangle")
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Import into")
                }

                if payload.format == .csv, let csvDetection, !csvManualOverride {
                    Section {
                        if let name = csvDetection.name {
                            Label("Recognised a \(name) export.", systemImage: "checkmark.seal")
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Columns read from the file's own header.",
                                  systemImage: "tablecells")
                                .foregroundStyle(.secondary)
                        }
                        if csvDetection.preambleRows > 0 {
                            Text("Skipping \(csvDetection.preambleRows) rows above the header.")
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        Button("Set Columns Manually") { csvManualOverride = true }
                    } header: {
                        Text("CSV columns")
                    }
                } else if payload.format == .csv {
                    Section("CSV columns (0-based)") {
                        if !model.csvImportProfiles.isEmpty {
                            Menu("Load Profile") {
                                ForEach(model.csvImportProfiles) { profile in
                                    Button(profile.name) { applyProfile(profile) }
                                }
                                Divider()
                                ForEach(model.csvImportProfiles) { profile in
                                    Button(role: .destructive) {
                                        model.deleteCSVImportProfile(profile.id)
                                    } label: { Label("Delete “\(profile.name)”", systemImage: "trash") }
                                }
                            }
                        }
                        Stepper("Date column: \(dateCol)", value: $dateCol, in: 0...40)
                        Stepper("Amount column: \(amountCol)", value: $amountCol, in: 0...40)
                        Stepper("Payee column: \(payeeCol)", value: $payeeCol, in: 0...40)
                        // Memo and reference were on the mapping all along and
                        // had no control, so no hand-mapped import could carry
                        // a narrative or a statement reference. −1 is "none".
                        Stepper(memoCol < 0 ? "Memo column: none" : "Memo column: \(memoCol)",
                                value: $memoCol, in: -1...40)
                        Stepper(refCol < 0 ? "Reference column: none" : "Reference column: \(refCol)",
                                value: $refCol, in: -1...40)
                        TextField("Date format", text: $dateFormat)
                        Toggle("Has header row", isOn: $hasHeader)
                        // Exports routinely put a title or account block above
                        // the header; without this there was no way to say so.
                        Stepper("Rows above the header: \(skipRows)", value: $skipRows, in: 0...20)
                        Button("Save as Profile…") { newProfileName = ""; showingSaveProfile = true }
                    }
                }

                Section {
                    Button("Preview") { preview() }
                        .disabled(targetID == nil)
                }

                if !results.isEmpty {
                    Toggle("Skip duplicates", isOn: $skipDuplicates)
                    if results.contains(where: \.isDuplicate) {
                        Toggle("Mark matched transactions as cleared", isOn: $markMatchedCleared)
                            .help("Reconcile register entries that this statement confirms")
                    }
                    if hasImbalanceFallback, includedResults.contains(where: { destination(for: $0) == nil }) {
                        Toggle("Post unmatched rows to the imbalance account", isOn: $fallbackToImbalance)
                            .help("Rows nothing categorised still import, parked in Imbalance for the Uncategorised review to sweep")
                    }
                    if model.isIntelligenceAvailable {
                        Section {
                            Button {
                                suggestCategories()
                            } label: {
                                Label(suggesting ? "Suggesting…" : "Suggest Categories",
                                      systemImage: "sparkles")
                            }
                            .disabled(suggesting)
                            .help("Let Apple Intelligence propose a destination account for each row")
                            if let suggestError {
                                Text(suggestError).scaledFont(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    Section {
                        // Built once per pass, not once per row: the filter is
                        // O(accounts) and there is one row per statement line.
                        let destinations = accounts.filter { $0.id != targetID }
                        ForEach(results) { result in
                            row(result, destinations: destinations)
                        }
                    } header: {
                        Text("\(results.count) transactions")
                    } footer: {
                        Text("Clear a row's account to leave that row out of the import.")
                    }
                }

                if !investments.isEmpty {
                    investmentSection
                }
            }
            .navigationTitle("Import \(payload.format.rawValue.uppercased())")
            .onAppear {
                // Read the statement's account id whatever happens — it is
                // needed after the import too, to remember the mapping.
                let identifier = model.bankFileAccountID(payload.data, format: payload.format)
                fileAccountID = identifier
                if payload.format == .csv, csvDetection == nil,
                   let found = CSVFormatDetector.detect(payload.data) {
                    csvDetection = found
                    // Seed the manual controls from it, so "Set Columns
                    // Manually" starts from what was found rather than from
                    // zeros the user then has to rediscover.
                    dateCol = found.mapping.date
                    amountCol = found.mapping.amount ?? amountCol
                    payeeCol = found.mapping.payee ?? payeeCol
                    memoCol = found.mapping.memo ?? -1
                    refCol = found.mapping.reference ?? -1
                    skipRows = found.mapping.skipRows
                    dateFormat = found.mapping.dateFormat
                    hasHeader = found.mapping.hasHeader
                }
                // Only ever fills an empty field, so re-entering the sheet
                // never overrides a choice the user already made.
                guard targetID == nil,
                      let suggestion = model.suggestedImportTarget(
                        forFileNamed: payload.fileName, accountIdentifier: identifier)
                else { return }
                targetID = suggestion.id
                suggestedID = suggestion.id
                suggestedSource = suggestion.source
            }
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(importCount)") {
                        if let targetID {
                            let posting = includedResults
                            _ = model.importMatched(posting, intoAccountID: targetID,
                                                    assignments: assignments,
                                                    skipDuplicates: skipDuplicates,
                                                    fallbackToImbalance: fallbackToImbalance)
                            if markMatchedCleared {
                                model.reconcileMatchedDuplicates(posting)
                            }
                            // Learn the mapping from what the user actually
                            // chose, not from what was suggested — a corrected
                            // suggestion is exactly the case worth remembering.
                            if let fileAccountID {
                                model.rememberImportAccount(fileAccountID, for: targetID)
                            }
                        }
                        dismiss()
                    }
                    .disabled(importCount == 0
                              && !(markMatchedCleared && includedResults.contains(where: \.isDuplicate)))
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .alert("Save Import Profile", isPresented: $showingSaveProfile) {
            TextField("Profile name", text: $newProfileName)
            Button("Save") {
                let name = newProfileName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                model.saveCSVImportProfile(CSVImportProfile(
                    name: name, dateColumn: dateCol, amountColumn: amountCol,
                    payeeColumn: payeeCol, dateFormat: dateFormat, hasHeader: hasHeader,
                    memoColumn: memoCol < 0 ? nil : memoCol,
                    referenceColumn: refCol < 0 ? nil : refCol, skipRows: skipRows))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save these column settings to reuse on the next import from this bank.")
        }
    }

    private func applyProfile(_ profile: CSVImportProfile) {
        dateCol = profile.dateColumn
        amountCol = profile.amountColumn
        payeeCol = profile.payeeColumn
        memoCol = profile.memoColumn ?? -1
        refCol = profile.referenceColumn ?? -1
        skipRows = profile.skipRows ?? 0
        dateFormat = profile.dateFormat
        hasHeader = profile.hasHeader
        // Choosing a profile is choosing a mapping, so it outranks whatever
        // the file's header suggested.
        csvManualOverride = true
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ result: MatchResult, destinations: [AccountNode]) -> some View {
        let staged = result.staged
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                AdaptiveDate(staged.date)
                    .foregroundStyle(.secondary)
                    .frame(width: dateWidth, alignment: .leading)
                Text(staged.payee.isEmpty ? staged.memo : staged.payee)
                if result.isDuplicate {
                    Text("duplicate").scaledFont(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.yellow.opacity(0.3), in: Capsule())
                        // Name the entry it matched. A flag the user cannot
                        // check is one they have to take on trust, and this one
                        // decides whether a row is imported at all. The text is
                        // the matched transaction itself, so it needs no key.
                        .help(Text(matchedSummary(for: result)))
                }
                if result.transferSplitID != nil {
                    Text("transfer").scaledFont(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.blue.opacity(0.2), in: Capsule())
                        .help("Completes a transfer already recorded by the other account's statement")
                }
                Spacer()
                Text(AmountFormat.string(staged.amount, code: targetCode))
                    .monospacedDigit()
                    .foregroundStyle(staged.amount < 0 ? .red : .primary)
            }
            // A searchable field, not a Picker: a Picker builds one menu item
            // per account per row, which is the fan-out that overflowed the
            // attribute graph. This builds one button until it is clicked.
            AccountField(nodes: destinations,
                         selection: destinationBinding(for: result),
                         clearable: true)
                .disabled(skipDuplicates && result.isDuplicate)
        }
    }

    /// The existing entry a duplicate flag points at, as its own date and
    /// description — verbatim book data, not a translatable phrase.
    private func matchedSummary(for result: MatchResult) -> String {
        guard let book, let id = result.matchedSplitID,
              let transaction = book.split(with: id)?.transaction
        else { return "" }
        let date = transaction.datePosted.formatted(date: .abbreviated, time: .omitted)
        let description = transaction.transactionDescription
        return description.isEmpty ? date : "\(date) · \(description)"
    }

    private var book: Book? { model.book }

    private var targetCode: String {
        accounts.first { $0.id == targetID }?.currencyCode ?? model.reportCurrency.mnemonic
    }

    private func destination(for result: MatchResult) -> GncGUID? {
        if excluded.contains(result.staged.id) { return nil }
        return assignments[result.staged.id] ?? result.suggestedAccountID
    }

    private func destinationBinding(for result: MatchResult) -> Binding<GncGUID?> {
        Binding(
            get: { destination(for: result) },
            set: { chosen in
                let id = result.staged.id
                // Clearing has to be recorded, not merely un-assigned: dropping
                // the key restores the matcher's suggestion.
                if let chosen {
                    assignments[id] = chosen
                    excluded.remove(id)
                } else {
                    assignments[id] = nil
                    excluded.insert(id)
                }
            }
        )
    }

    private func preview() {
        guard let targetID else { return }
        // The detected shape wins unless the user asked to set the columns.
        let mapping = (csvManualOverride ? nil : csvDetection?.mapping)
            ?? CSVColumnMapping(date: dateCol, amount: amountCol, payee: payeeCol,
                                memo: memoCol < 0 ? nil : memoCol,
                                reference: refCol < 0 ? nil : refCol,
                                dateFormat: dateFormat, hasHeader: hasHeader,
                                skipRows: skipRows)
        let staged = payload.prestaged
            ?? model.parseBankFile(payload.data, format: payload.format, csvMapping: mapping)
        results = model.matchStaged(staged, intoAccountID: targetID)
        assignments = [:]
        excluded = []

        // Security rows take the Stock-Assistant path, pre-matching each to a
        // security account by name/ticker where one exists. Rows whose broker
        // reference is already stamped on a posted transaction are flagged as
        // duplicates — investment rows bypass the cash matcher, so without
        // this a re-imported overlapping broker file re-created every trade.
        investments = model.investmentRows(from: staged)
        let importedRefs = model.importedInvestmentReferences()
        invAlreadyImported = Set(investments
            .filter { !$0.reference.isEmpty && importedRefs.contains($0.reference) }
            .map(\.id))
        invSecurity = [:]
        for row in investments {
            invSecurity[row.id] = model.matchingSecurityAccount(for: row)
        }
        invSettlement = targetID
        invCreated = 0
    }

    // MARK: Investment rows (FR-XIO-01/02)

    private var securityAccounts: [AccountNode] { model.securityAccountNodes }
    private var incomeAccounts: [AccountNode] { model.incomeAccountNodes }
    private var creatableInvestments: [StagedTransaction] {
        investments.filter { row in
            guard let inv = row.investment, !invAlreadyImported.contains(row.id)
            else { return false }
            let hasSecurity = invSecurity[row.id] != nil
            let hasIncome = invIncome != nil
            switch inv.action {
            case .buy, .sell: return hasSecurity && invSettlement != nil
            case .dividend: return hasIncome && invSettlement != nil
            case .reinvestDividend: return hasSecurity && hasIncome
            case .returnOfCapital: return hasSecurity && invSettlement != nil
            case .other: return false
            }
        }
    }

    @ViewBuilder
    private var investmentSection: some View {
        Section("\(investments.count) investment transactions") {
            LabeledContent("Settlement account") {
                AccountField(nodes: model.settlementAccountNodes, selection: $invSettlement)
            }
            LabeledContent("Dividend income account") {
                AccountField(nodes: incomeAccounts, selection: $invIncome)
            }
            ForEach(investments) { row in
                investmentRow(row)
            }
            if let invError {
                Text(invError).scaledFont(.caption).foregroundStyle(.red)
            }
            if invCreated > 0 {
                Label("Created \(invCreated) investment transactions.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).scaledFont(.caption)
            }
            Button("Create \(creatableInvestments.count) Investment Transactions") {
                createInvestments()
            }
            .disabled(creatableInvestments.isEmpty)
        }
    }

    @ViewBuilder
    private func investmentRow(_ row: StagedTransaction) -> some View {
        let inv = row.investment
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                AdaptiveDate(row.date)
                    .foregroundStyle(.secondary).frame(width: dateWidth, alignment: .leading)
                Text(inv?.action.rawValue.capitalized ?? "—").fontWeight(.medium)
                Text(inv?.security ?? "").foregroundStyle(.secondary)
                Spacer()
                if invAlreadyImported.contains(row.id) {
                    Label("Already imported", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary).scaledFont(.caption)
                }
                Text(AmountFormat.string(row.amount, code: targetCode)).monospacedDigit()
            }
            if let inv, inv.quantity != 0 {
                Text("\(inv.quantity.formatted()) @ \(AmountFormat.string(inv.pricePerShare, code: targetCode))"
                     + (inv.commission != 0 ? " · fee \(AmountFormat.string(inv.commission, code: targetCode))" : ""))
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
            if inv?.action != .dividend {
                // Same reason as the cash rows above: one field, not one menu
                // item per security per row. Smaller fan-out — securities are a
                // fraction of the account tree — but the shape is what fails,
                // not the number, and a broker file can carry hundreds of rows.
                AccountField(prompt: "Choose security…",
                             nodes: securityAccounts,
                             selection: Binding(get: { invSecurity[row.id] },
                                                set: { invSecurity[row.id] = $0 }),
                             clearable: true)
                    .scaledFont(.caption)
            }
        }
    }

    private func createInvestments() {
        invError = nil
        // Track exactly which rows were posted so a mid-batch failure can't leave
        // an already-created row in the list — re-clicking would post it twice.
        var createdIDs: [UUID] = []
        for row in investments {
            guard creatableInvestments.contains(where: { $0.id == row.id }) else { continue }
            do {
                if try model.recordStagedInvestment(
                    row, securityID: invSecurity[row.id], settlementID: invSettlement,
                    incomeID: invIncome) != nil {
                    createdIDs.append(row.id)
                }
            } catch {
                invError = "Couldn't create “\(row.investment?.security ?? "")”: \(error.localizedDescription)"
            }
        }
        invCreated = createdIDs.count
        // Drop the ones that were actually created (even if a later row failed) so
        // the list reflects what's left and nothing is posted a second time.
        let done = Set(createdIDs)
        investments.removeAll { done.contains($0.id) }
    }

    /// Fills empty destinations with on-device model suggestions (`FR-AI-02`).
    /// Deterministic suggestions (rules/history/heuristics) are never replaced.
    private func suggestCategories() {
        suggesting = true
        suggestError = nil
        let pending = results
        Task {
            defer { suggesting = false }
            do {
                let suggested = try await model.suggestCategories(for: pending)
                for (stagedID, accountID) in suggested where destinationForStagedID(stagedID) == nil {
                    assignments[stagedID] = accountID
                }
            } catch {
                suggestError = error.localizedDescription
            }
        }
    }

    private func destinationForStagedID(_ id: UUID) -> GncGUID? {
        guard let result = results.first(where: { $0.staged.id == id }) else { return nil }
        return destination(for: result)
    }
}
