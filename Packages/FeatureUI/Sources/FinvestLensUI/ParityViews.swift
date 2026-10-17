//
//  ParityViews.swift
//  FinvestLens — FeatureUI
//
//  GnuCash-parity tools that surface existing engine capability:
//  the book-wide Linked Documents list (Tools ▸ Transaction Linked Documents)
//  and the Loan Repayment Calculator (Tools ▸ Loan Repayment Calculator).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

// MARK: - Linked Documents

/// Every transaction with an attached document, in one list — the roll-up
/// GnuCash offers so links aren't reachable only one register row at a time.
struct LinkedDocumentsView: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingTransactionID: GncGUID?
    /// Gathered off the body: the list stats every linked file, and the
    /// reference book has ~760 of them on a cloud folder. `nil` until the
    /// first gather lands; re-gathered when the book changes (an edit made
    /// from this sheet included).
    @State private var docs: [AppModel.LinkedDocument]?

    var body: some View {
        NavigationStack {
            Group {
                if let docs {
                    if docs.isEmpty {
                        ContentUnavailableView("No linked documents", systemImage: "paperclip",
                            description: Text("Attach a receipt or invoice to a transaction and it appears here."))
                    } else {
                        List(docs) { doc in
                            row(doc)
                        }
                    }
                } else {
                    LoadingPlaceholder("Checking linked documents…")
                }
            }
            // `transactionRevision`: a link is a transaction fact, so a quote
            // refresh must not re-stat every file. The cancellation check keeps
            // a superseded gather from landing on top of a fresher one.
            .task(id: model.transactionRevision) {
                let fresh = await model.linkedDocumentsOffMain()
                guard !Task.isCancelled else { return }
                docs = fresh
            }
            .navigationTitle("Linked Documents")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingTransactionID) { id in
                TransactionEditor(model: model, editingID: id)
            }
        }
        .windowFloor(minWidth: 480, minHeight: 360)
    }

    private func row(_ doc: AppModel.LinkedDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: doc.isWeb ? "link" : (doc.exists ? "doc.fill" : "doc.badge.gearshape"))
                .foregroundStyle(doc.exists ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.description.isEmpty ? String(localized: "(no description)") : doc.description)
                    .scaledFont(.body)
                HStack(spacing: 6) {
                    Text(dateFormat.short(doc.date))
                    Text("·")
                    Text(doc.displayName).lineLimit(1).truncationMode(.middle)
                    if !doc.exists && !doc.isWeb {
                        Text("· missing").foregroundStyle(.red)
                    }
                }
                .scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { model.openLinkedDocument(for: doc.id) }
                .buttonStyle(.borderless)
                .disabled(!doc.exists)
            Button("Edit") { editingTransactionID = doc.id }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Tax Report Options

/// Flag income/expense accounts as tax-related, give them a tax category code,
/// and see the resulting tax schedule for a period (GnuCash's Edit ▸ Tax Report
/// Options plus its tax schedule). Flags round-trip with GnuCash via the
/// `tax-related` / `tax-US` account slots.
struct TaxOptionsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var year = TaxOptionsView.defaultYear

    private static var defaultYear: Int {
        // A fixed default; the picker covers the useful range either side.
        2026
    }

    private var range: (from: Date, to: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let from = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let to = cal.date(from: DateComponents(year: year, month: 12, day: 31))!
        return (from, to)
    }

    private var accounts: [AppModel.TaxAccount] {
        model.taxAccounts(from: range.from, to: range.to)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tax year", selection: $year) {
                    ForEach((2015...2030).reversed(), id: \.self) { Text(String($0)).tag($0) }
                }
                .pickerStyle(.menu).fixedSize().padding(8)
                Divider()
                List {
                    let flagged = accounts.filter(\.taxRelated)
                    if !flagged.isEmpty {
                        Section("Tax schedule \(String(year))") {
                            ForEach(flagged) { row in scheduleRow(row) }
                        }
                    }
                    Section("Accounts") {
                        ForEach(accounts) { row in accountRow(row) }
                    }
                }
            }
            .navigationTitle("Tax Report Options")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .windowFloor(minWidth: 520, minHeight: 480)
    }

    private func scheduleRow(_ row: AppModel.TaxAccount) -> some View {
        HStack {
            Text(row.name).scaledFont(.body)
            if let code = row.taxCode {
                Text(code).scaledFont(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            Text(AmountFormat.string(row.periodBalance, code: row.currencyCode))
                .monospacedDigit().scaledFont(.body)
        }
    }

    private func accountRow(_ row: AppModel.TaxAccount) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { row.taxRelated },
                set: { model.setAccountTax(id: row.id, related: $0, code: row.taxCode) })) {
                    Text(row.name).scaledFont(.body)
                }
                .checkboxToggleStyle()
            Spacer()
            if row.taxRelated {
                TaxCodeField(code: row.taxCode ?? "") { typed in
                    // Read the flag live: the field's teardown commit also
                    // fires when the row is unticked, and a code must not
                    // re-tick what the user just cleared.
                    guard model.book?.account(with: row.id)?.taxRelated == true else { return }
                    model.setAccountTax(id: row.id, related: true, code: typed.isEmpty ? nil : typed)
                }
                .frame(width: 110).scaledFont(.caption)
            }
        }
    }
}

/// The tax code, committed on Return or when focus leaves — not per
/// keystroke, which went through an account edit and a full refresh for
/// every character typed (Performance Review 2, R8).
private struct TaxCodeField: View {
    let code: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Code", text: $text)
            .focused($focused)
            .onAppear { text = code }
            .onChange(of: code) { text = code }
            .onSubmit { if text != code { commit(text) } }
            .onChange(of: focused) { if !focused, text != code { commit(text) } }
            // Done, Escape, or unticking the row's checkbox tear the field
            // down while it is focused; what was typed must still land.
            .onDisappear { if text != code { commit(text) } }
    }
}

// MARK: - Period-end Close Book

/// Moves income and expense balances into an equity account as of a date, so
/// the profit-and-loss accounts start the next period at zero (GnuCash's
/// Tools ▸ Close Book). Previews the effect before posting; the post is one
/// undoable action.
struct CloseBookView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var equityID: GncGUID?
    @State private var description = String(localized: "Closing Entries")
    @State private var posted: Int?

    private var equityChoices: [(id: GncGUID, name: String)] { model.equityAccountChoices }
    private var code: String { model.reportCurrency.mnemonic }

    /// What a preview was built for.
    private struct PreviewKey: Hashable {
        var date: Date
        var equityID: GncGUID?
        var revision: Int
    }

    private typealias Preview = (accounts: Int, byCurrency: [AppModel.ClosingCurrencyPreview], missingRate: String?)

    /// The preview, built by a task after the frame that asked for it: each
    /// new date or equity account walked every balance in the book inside
    /// `body` (Performance Review P3.2).
    @State private var built: (key: PreviewKey, preview: Preview?)?

    private var key: PreviewKey { PreviewKey(date: date, equityID: equityID, revision: model.bookRevision) }

    /// The preview for what is chosen now, once it has been built — or the
    /// memo's, if it is already there, drawn in the first frame.
    private var preview: Preview? {
        if built?.key == key { return built?.preview }
        return equityID.flatMap { model.cachedClosingPreview(asOf: date, equityID: $0) }
    }
    private var previewing: Bool { equityID != nil && built?.key != key && preview == nil }

    var body: some View {
        NavigationStack {
            Form {
                if equityChoices.isEmpty {
                    ContentUnavailableView("No equity account", systemImage: "building.columns",
                        description: Text("Create an equity account (e.g. Retained Earnings) to close into."))
                } else {
                    Section("Close as of") {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                        Picker("Into equity", selection: $equityID) {
                            Text("Choose…").tag(GncGUID?.none)
                            ForEach(equityChoices, id: \.id) { choice in
                                Text(choice.name).tag(GncGUID?.some(choice.id))
                            }
                        }
                        TextField("Description", text: $description)
                    }
                    Section("Preview") {
                        if previewing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Previewing…").foregroundStyle(.secondary).scaledFont(.caption)
                            }
                            // One element for VoiceOver: "Previewing…", not an
                            // unlabelled spinner beside it.
                            .accessibilityElement(children: .combine)
                        } else if let preview {
                            LabeledContent("Accounts to close") { Text("\(preview.accounts)") }
                            // One net per currency — a multi-currency book closes
                            // into a balanced transaction per currency.
                            ForEach(preview.byCurrency) { row in
                                LabeledContent("Net to equity (\(row.currencyCode))") {
                                    Text(AmountFormat.string(row.netToEquity, code: row.currencyCode))
                                        .monospacedDigit()
                                }
                            }
                            if let missing = preview.missingRate {
                                Label(missing, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange).scaledFont(.caption)
                            } else if preview.accounts == 0 {
                                Text("Nothing has a balance to close as of this date.")
                                    .foregroundStyle(.secondary).scaledFont(.caption)
                            } else if preview.byCurrency.count > 1 {
                                Text("Spans \(preview.byCurrency.count) currencies — one closing transaction each.")
                                    .foregroundStyle(.secondary).scaledFont(.caption)
                            }
                        } else {
                            Text("Choose an equity account to preview.")
                                .foregroundStyle(.secondary).scaledFont(.caption)
                        }
                    }
                    if let posted {
                        Section {
                            Label("Closed \(posted) accounts. Undo with ⌘Z.",
                                  systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .task(id: key) {
                // What was asked for, held for the whole task: `key` reads
                // the live choices, and read again after the pause it could
                // pair a new account with a preview of the old (17 October
                // review).
                let requested = key
                guard let equityID = requested.equityID else { return }
                if model.cachedClosingPreview(asOf: requested.date, equityID: equityID) == nil {
                    // Stepping the date a day at a time asks for a preview at
                    // each step; a moment's pause builds only the one the
                    // stepping stops at.
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                }
                let preview = model.closingPreview(asOf: requested.date, equityID: equityID)
                guard !Task.isCancelled else { return }
                built = (requested, preview)
            }
            .navigationTitle("Close Financial Year")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close Financial Year") {
                        if let equityID { posted = model.closeBook(asOf: date, equityID: equityID,
                                                                   description: description) }
                    }
                    .disabled(equityID == nil || previewing || (preview?.accounts ?? 0) == 0 || preview?.missingRate != nil)
                }
            }
        }
        .windowFloor(minWidth: 460, minHeight: 420)
    }
}

// MARK: - Loan Repayment Calculator

/// A fixed-rate loan calculator (GnuCash's Tools ▸ Loan Repayment Calculator).
/// Pure arithmetic — it never reads or writes the book.
struct LoanCalculatorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var principal = 300_000.0
    @State private var ratePercent = 6.0
    @State private var years = 30.0
    @State private var paymentsPerYear = 12
    @State private var showSchedule = false
    @State private var showingCreatePayment = false

    private var loan: LoanCalculator {
        LoanCalculator(principal: Decimal(principal),
                       annualRatePercent: Decimal(ratePercent),
                       years: years, paymentsPerYear: paymentsPerYear)
    }

    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        NavigationStack {
            Form {
                Section("Loan") {
                    LabeledContent("Amount") {
                        TextField("Amount", value: $principal, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 140)
                    }
                    LabeledContent("Annual rate %") {
                        TextField("Rate", value: $ratePercent, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 140)
                    }
                    LabeledContent("Years") {
                        TextField("Years", value: $years, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 140)
                    }
                    Picker("Payments / year", selection: $paymentsPerYear) {
                        Text("Monthly (12)").tag(12)
                        Text("Fortnightly (26)").tag(26)
                        Text("Weekly (52)").tag(52)
                        Text("Quarterly (4)").tag(4)
                    }
                }
                Section("Result") {
                    LabeledContent("Payment") {
                        Text(AmountFormat.string(loan.payment, code: code)).monospacedDigit().bold()
                    }
                    LabeledContent("Number of payments") { Text("\(loan.numberOfPayments)") }
                    LabeledContent("Total paid") {
                        Text(AmountFormat.string(loan.totalPaid, code: code)).monospacedDigit()
                    }
                    LabeledContent("Total interest") {
                        Text(AmountFormat.string(loan.totalInterest, code: code)).monospacedDigit()
                    }
                    DisclosureGroup("Amortisation schedule", isExpanded: $showSchedule) {
                        if showSchedule { scheduleTable }
                    }
                }
                Section {
                    Button("Create Scheduled Payment…") { showingCreatePayment = true }
                        .disabled(model.postableAccounts.count < 3)
                    Text("Generates a scheduled transaction (GnuCash's Mortgage/Loan assistant): the fixed payment, split into a variable **interest** amount — you enter each period from the schedule above — and the remaining **principal**.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Loan Calculator")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCreatePayment) {
                CreateLoanPaymentSheet(model: model, loan: loan, onCreated: { dismiss() })
            }
        }
        .windowFloor(minWidth: 460, minHeight: 460)
    }

    private var scheduleTable: some View {
        // Bounded: a 30-year weekly loan is ~1,560 uniform rows — fine for a Table.
        Table(loan.schedule()) {
            TableColumn("#") { Text("\($0.number)") }.width(36)
            TableColumn("Payment") { Text(AmountFormat.string($0.payment, code: code)).monospacedDigit() }
            TableColumn("Interest") { Text(AmountFormat.string($0.interest, code: code)).monospacedDigit() }
            TableColumn("Principal") { Text(AmountFormat.string($0.principal, code: code)).monospacedDigit() }
            TableColumn("Balance") { Text(AmountFormat.string($0.balance, code: code)).monospacedDigit() }
        }
        .frame(minHeight: 220)
    }
}

/// Picks the accounts for a loan-payment scheduled transaction and creates it
/// (GnuCash's Mortgage/Loan assistant, `FR-SCH-04`).
struct CreateLoanPaymentSheet: View {
    @Bindable var model: AppModel
    let loan: LoanCalculator
    var onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = String(localized: "Loan payment")
    @State private var startDate = Date()
    @State private var fromID: GncGUID?
    @State private var principalID: GncGUID?
    @State private var interestID: GncGUID?

    private var isValid: Bool {
        guard let fromID, let principalID, let interestID else { return false }
        return Set([fromID, principalID, interestID]).count == 3
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Payment") {
                    TextField("Name", text: $name)
                    DatePicker("First payment", selection: $startDate, displayedComponents: .date)
                    LabeledContent("Amount") {
                        Text(AmountFormat.string(loan.payment, code: model.reportCurrency.mnemonic))
                            .monospacedDigit()
                    }
                }
                Section("Accounts") {
                    accountPicker("Pay from", $fromID)
                    accountPicker("Principal (liability)", $principalID)
                    accountPicker("Interest (expense)", $interestID)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Scheduled Loan Payment")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let fromID, let principalID, let interestID else { return }
                        let sx = loan.scheduledPayment(
                            name: name, currency: model.reportCurrency, startDate: startDate,
                            from: fromID, principal: principalID, interest: interestID)
                        model.addScheduledTransaction(sx)
                        dismiss()
                        onCreated()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .windowFloor(minWidth: 420, minHeight: 320)
    }

    private func accountPicker(_ label: LocalizedStringKey,
                               _ selection: Binding<GncGUID?>) -> some View {
        LabeledContent(label) {
            AccountField(nodes: model.postableAccounts, selection: selection)
        }
    }
}
