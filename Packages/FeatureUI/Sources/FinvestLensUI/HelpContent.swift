//
//  HelpContent.swift
//  FinvestLens — FeatureUI
//
//  The help book, as data. Every string here is a `LocalizedStringKey`, so the
//  pages translate through the app's String Catalog like the rest of the UI —
//  there is no separate HTML help bundle to keep in sync, and the same pages
//  serve macOS, iPadOS and iOS.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// One piece of a help page.
///
/// Deliberately **not** `Identifiable`: the only identity it ever needed was
/// its position in a topic, and the previous `id` built one by interpolating a
/// `LocalizedStringKey` — which resolves through reflection metadata, produced
/// a 485-character string per block on every render pass, and would have
/// collapsed every paragraph in a topic to one id had that metadata ever been
/// stripped. The renderer indexes instead, as it already does for the lists.
public enum HelpBlock: @unchecked Sendable {
    /// A paragraph of prose.
    case text(LocalizedStringKey)
    /// A sub-heading inside a topic.
    case heading(LocalizedStringKey)
    /// A bulleted list.
    case bullets([LocalizedStringKey])
    /// Numbered steps for a task the reader is meant to follow.
    case steps([LocalizedStringKey])
    /// A key/value table — shortcuts, search operators, menu paths.
    case table([(LocalizedStringKey, LocalizedStringKey)])
    /// A short aside worth setting apart.
    case tip(LocalizedStringKey)

}

public struct HelpTopic: Identifiable, @unchecked Sendable {
    public let id: String
    /// `LocalizedStringResource`, not `LocalizedStringKey`: both are extracted
    /// by the compiler, but only this one can be *read back* as a String at
    /// runtime. Search needs that — a `LocalizedStringKey` can only be
    /// rendered, so matching against one silently matches English alone.
    public let title: LocalizedStringResource
    public let summary: LocalizedStringResource
    public let symbol: String
    /// Untranslated search terms — the topic's own English words plus obvious
    /// synonyms, so search finds a page even when the reader types the term
    /// they knew from GnuCash.
    public let keywords: String
    public let blocks: [HelpBlock]
}

public struct HelpSection: Identifiable, @unchecked Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let topics: [HelpTopic]
}

public enum HelpBook {

    public static let sections: [HelpSection] = [
        HelpSection(id: "basics", title: "Basics", topics: [
            gettingStarted, dashboard, accounts, transactions, findingThings, keepingSafe,
        ]),
        HelpSection(id: "everyday", title: "Everyday money", topics: [
            importing, smartImport, categorising, reconciling, scheduled, budgets, documents, tags,
        ]),
        HelpSection(id: "growing", title: "Investments & planning", topics: [
            investments, currencyTransfer, reports, yearEnd, planning, goals,
        ]),
        HelpSection(id: "more", title: "More", topics: [
            business, emergencyRecords, interchange, outsideTheApp, shortcuts,
        ]),
    ]

    public static let allTopics: [HelpTopic] = sections.flatMap(\.topics)

    /// Built once: `topic(id:)` is called from `body`, so a linear scan over a
    /// freshly rebuilt array would run on every render pass.
    private static let topicsByID: [String: HelpTopic] =
        Dictionary(allTopics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    public static func topic(id: String) -> HelpTopic? { topicsByID[id] }

    /// Lowercased search text per topic id: the title and summary **as the
    /// reader sees them**, plus the English keywords so a term learned from
    /// GnuCash still finds the page.
    ///
    /// Built once. `String(localized:)` goes through the bundle, which is far
    /// too expensive to repeat for 25 topics on every keystroke.
    static let searchIndex: [String: String] = Dictionary(
        allTopics.map { topic in
            (topic.id, [String(localized: topic.title),
                        String(localized: topic.summary),
                        topic.keywords].joined(separator: " ").lowercased())
        },
        uniquingKeysWith: { first, _ in first })

    // MARK: Basics

    static let gettingStarted = HelpTopic(
        id: "getting-started",
        title: "Getting started",
        summary: "Create a book, or bring one over from GnuCash.",
        symbol: "sparkles",
        keywords: "start begin new book open gnucash import migrate first date dates format order weekday",
        blocks: [
            .text("""
                A **book** is your whole set of accounts and transactions, kept in one \
                file you own. FinvestLens never uploads it anywhere.
                """),
            .heading("Start a book"),
            .steps([
                "Choose File ▸ New Book… (⌥⌘N) and pick where to keep the file.",
                "Choose a starter chart of accounts, or start empty and add your own.",
                "Add your bank and credit-card accounts, and enter their opening balances.",
            ]),
            .heading("Coming from GnuCash"),
            .text("""
                Choose File ▸ Import GnuCash… and pick your `.gnucash` file. Accounts, \
                transactions, prices, scheduled transactions and business records all come \
                across, and you can export back to GnuCash at any time.
                """),
            .heading("How dates are written"),
            .text("""
                You choose the **order** — day/month/year, month.day.year or \
                year-month-day — in Settings ▸ General ▸ Dates. You never choose how \
                much of a date is spelled out: FinvestLens picks that from where the \
                date is and how much room it has, always in your order. Tables use \
                digits, labels and documents spell the month out, and a headline date \
                adds the weekday.
                """),
            .tip("""
                Narrow a register and the year shortens — 24/12/2026 becomes 24/12/26 — \
                so the date stays whole instead of being cut off. You can type either \
                form back into the cell; a two-digit year always means this century.
                """),
            .tip("""
                Everything you do is undoable with ⌘Z — including imports. If a change \
                looks wrong, undo it rather than repairing it by hand.
                """),
        ])

    static let accounts = HelpTopic(
        id: "accounts",
        title: "Accounts",
        summary: "The chart of accounts, and how the sidebar is organised.",
        symbol: "list.bullet.indent",
        keywords: "account chart tree parent placeholder hidden favourite type asset liability equity income expense",
        blocks: [
            .text("""
                Accounts form a tree. A parent account shows the total of everything \
                beneath it, so you can group *Expenses:Car:Fuel* and *Expenses:Car:Insurance* \
                under one *Car* heading and still see them separately.
                """),
            .heading("Account types"),
            .table([
                ("Asset", "What you own — bank accounts, cash, investments, property."),
                ("Liability", "What you owe — credit cards, loans, mortgages."),
                ("Income", "Money coming in — salary, dividends, interest."),
                ("Expense", "Money going out — the categories you spend in."),
                ("Equity", "Opening balances and retained earnings."),
            ]),
            .heading("Keeping the sidebar tidy"),
            .bullets([
                "**Favourites** pin the accounts you use most to the top of the sidebar.",
                "**Placeholder** accounts group children but take no transactions of their own.",
                "**Hidden** accounts stay out of the sidebar until you switch them back on.",
                "The filter box at the top of the sidebar narrows the tree as you type.",
            ]),
        ])

    static let transactions = HelpTopic(
        id: "transactions",
        title: "Recording transactions",
        summary: "The register, splits, and editing a row in place.",
        symbol: "square.and.pencil",
        keywords: "transaction register enter split memo transfer edit double entry balance style columns void unvoid reverse reversing cheque check print",
        blocks: [
            .text("""
                Select an account in the sidebar to open its **register** — one row per \
                transaction, with a running balance. The row at the bottom is where you \
                type a new one.
                """),
            .heading("Entering a transaction"),
            .steps([
                "Type the date, then the description — earlier entries autocomplete as you type.",
                "Choose the other account (the category, or where the money went).",
                "Enter the amount and press ⏎.",
            ]),
            .text("""
                Every transaction moves money **between two accounts**, so it always \
                balances. That is what makes the reports add up.
                """),
            .heading("Splits"),
            .text("""
                A transaction can touch more than two accounts — a pay slip split into \
                salary, tax and superannuation, or a shopping trip split across categories. \
                Select the row and press ⌘E, or click its disclosure arrow, to open it \
                out — notes, tags and every leg, edited in the register itself.
                """),
            .tip("""
                How much each row shows is up to you: View ▸ Register Style switches \
                between one line per transaction (Basic Ledger), detail on the selected \
                row (Auto Details), and every row open (Transaction Journal). View ▸ \
                Columns switches off the columns you do not use.
                """),
            .heading("Void, reverse and print"),
            .text("""
                Deleting a transaction removes it. Sometimes that is wrong — a payment that \
                bounced, or a cheque never banked, is part of the record. **Void Transaction** \
                keeps the row and its history but takes it out of your balances; **Unvoid \
                Transaction** puts it back, though the reconcile marks its splits carried are \
                not restored. **Add Reversing Transaction** leaves the original alone and \
                writes a second, opposite entry beside it on the same date, so the correction \
                shows in the record rather than being hidden by an edit.
                """),
            .text("""
                **Print Check…** prints the selected transaction as a cheque.
                """),
        ])

    static let findingThings = HelpTopic(
        id: "finding",
        title: "Finding transactions",
        summary: "Search operators, saved searches, and jumping around.",
        symbol: "magnifyingglass",
        keywords: "search find filter query operator saved tag amount date jump",
        blocks: [
            .text("""
                The search box above the register searches the description, amount and \
                date. It also understands operators, which can be combined:
                """),
            .table([
                ("`tag:holiday`", "Transactions carrying a tag."),
                ("`account:Groceries`", "Postings to a matching account (`category:` also works)."),
                ("`memo:refund`", "Text in the split memo."),
                ("`desc:coles`", "Text in the description."),
                ("`amount:>200`", "Amounts above (or `<` below) a figure."),
                ("`from:-3m`", "On or after a date — or `today`, `-7d`, `-2w`, `-3m`, `-1y`."),
                ("`to:2026/06/30`", "On or before a date."),
                ("`type:transfer`", "A kind of transaction."),
                ("`has:attachment`", "Only transactions with a document attached."),
            ]),
            .text("Put `-` in front of any term to exclude it — `-tag:work` hides work spending."),
            .heading("Elsewhere"),
            .bullets([
                "**Find…** (⌘F) searches across every account, not just the open one.",
                "**Find Account…** (⌘I) jumps straight to an account by name.",
                "Save a search you keep repeating, and it comes back in the search menu.",
            ]),
        ])

    static let keepingSafe = HelpTopic(
        id: "safety",
        title: "Saving and keeping the book safe",
        summary: "Saving, autosave, locking, network drives, and the audit log.",
        symbol: "lock.shield",
        keywords: "save autosave lock nas smb network shared backup audit undo repair",
        blocks: [
            .heading("Saving"),
            .text("""
                Your changes are held in a working copy and written back to the file when \
                you press ⌘S, when autosave runs, or when you close the book. Autosave and \
                its interval live in Settings ▸ General.
                """),
            .heading("Sharing a book across machines"),
            .text("""
                A book can live on a NAS or shared folder. FinvestLens takes a lock while \
                it is open so a second machine cannot overwrite your work; if the app \
                behind a lock has gone away, you can break the lock and open anyway.
                """),
            .heading("Locking the screen"),
            .text("""
                Security ▸ Lock Now (⇧⌘L) hides the book until you authenticate. Turn on \
                *Require Authentication to Open* to be asked every time.
                """),
            .heading("If something looks wrong"),
            .bullets([
                "⌘Z undoes anything, including an import.",
                "**Book ▸ Repair Book** runs the same checks as GnuCash's Check & Repair, and changes nothing until you choose Clean Up.",
                "Repair Book also names any transaction posted in an impossible year. A mistyped year hides well — the entry still balances and still reconciles, it has just left the period it belongs to, so it drops out of every report that goes by date. It is reported rather than corrected, because only you know which year was meant.",
                "An audit log is kept beside the book, recording each edit.",
            ]),
        ])

    // MARK: Everyday money

    static let importing = HelpTopic(
        id: "import",
        title: "Importing bank files",
        summary: "CSV, QIF, OFX, MT940 and CAMT.053 — and how matching works.",
        symbol: "square.and.arrow.down",
        keywords: "import bank csv qif ofx qfx mt940 camt statement download duplicate match profile",
        blocks: [
            .text("""
                Choose Book ▸ Import Bank File… (⌥⌘I) and pick what your bank gave you. \
                The format is detected from the file itself — CSV, QIF, OFX/QFX, SWIFT \
                MT940/MT942 and ISO 20022 CAMT.053 are all read.
                """),
            .heading("The review screen"),
            .text("""
                Nothing is written until you say so. Each row shows what FinvestLens \
                intends to do, and you can change the account, the category or the date \
                before importing.
                """),
            .bullets([
                "Rows you have already imported are marked as duplicates and skipped.",
                "A payment that matches the other side of a transfer already in the book is completed rather than duplicated.",
                "Rows nothing could categorise still import — parked in Imbalance for the Uncategorised review to sweep up later.",
            ]),
            .heading("CSV columns"),
            .text("""
                For CSV, tell FinvestLens which column is the date, description and amount. \
                Save that as a profile and the next file from the same bank is set up for you.
                """),
        ])

    static let smartImport = HelpTopic(
        id: "smart-import",
        title: "Reading PDFs with Apple Intelligence",
        summary: "Turn statements, invoices and dividend notices into transactions.",
        symbol: "wand.and.stars",
        keywords: "pdf smart import apple intelligence ocr scan statement invoice dividend attachment",
        blocks: [
            .text("""
                Book ▸ Smart Import PDFs… (⇧⌘I) reads bank statements, dividend statements \
                and invoices **on this device** and turns them into transactions for you to \
                review. Nothing is sent anywhere.
                """),
            .heading("What it does"),
            .bullets([
                "Reads the rows out of the document, including scanned pages.",
                "Matches each one to a transaction already in your book, in any account.",
                "Links the PDF to that transaction, and suggests a category.",
            ]),
            .text("""
                **Match Attachments…** (⇧⌘M) does the same for receipts you already have — \
                PDFs or photos: pick the files, and each is paired with its transaction \
                and filed.
                """),
            .text("""
                Receipts from a trip match too. A card charged overseas posts in your own \
                currency, so nothing on the receipt looks like the amount in your book — \
                but the card issuer writes the original into the transaction, and that \
                figure is matched exactly. No exchange rate, nothing to set up.
                """),
            .tip("""
                A file that matches nothing keeps its row and says why. **Manually Edit…** \
                opens the transaction editor with the document's date, vendor and amount \
                already filled in — for a cash purchase that was never on a statement, or \
                one whose statement you have not imported yet.
                """),
            .tip("""
                Always read the review screen. On-device reading is good but not perfect — \
                statements with unsigned debit and credit columns and no running balance are \
                the case most worth checking.
                """),
        ])

    static let categorising = HelpTopic(
        id: "categorise",
        title: "Categorising and rules",
        summary: "Auto-categorise from your own history, and write rules.",
        symbol: "wand.and.rays",
        keywords: "categorise categorize rule auto uncategorised imbalance payee learn bulk",
        blocks: [
            .heading("Auto-categorise"),
            .text("""
                FinvestLens learns from work you have already done: when a payee has been \
                categorised before, it proposes the same treatment — including the split \
                breakdown for things like salary or dividends. Where a payee is genuinely \
                ambiguous it abstains rather than guessing.
                """),
            .heading("Rules"),
            .text("""
                A rule matches on the description, amount, account or tag and then sets a \
                category, renames the transaction, adds tags, or links a payment to a bill. \
                Rules run when you import, and you can apply them to history at any time.
                """),
            .heading("Bulk editing"),
            .text("""
                Select several transactions and use Bulk Edit to apply one change to all of \
                them. Only the fields you switch on are changed; everything else is left \
                alone.
                """),
        ])

    static let reconciling = HelpTopic(
        id: "reconcile",
        title: "Reconciling an account",
        summary: "Agree your book with a bank statement, to the cent.",
        symbol: "checkmark.circle",
        keywords: "reconcile reconciliation statement cleared balance tick difference",
        blocks: [
            .text("""
                Reconciling proves your records match the bank's. Choose Book ▸ Reconcile \
                Account… (⇧⌘R) with the account selected.
                """),
            .steps([
                "Enter the statement's closing balance and date.",
                "Tick the transactions that appear on the statement — matching ones are ticked for you.",
                "When the difference reaches zero, choose Finish.",
            ]),
            .text("""
                Finished transactions are marked **reconciled** and are protected from \
                casual edits. If you need to go back, Re-open Last Reconciliation… returns \
                them to cleared so you can work through the statement again.
                """),
            .tip("""
                A difference that will not close is usually a missing transaction, a \
                duplicate, or an amount typed with digits transposed. The running \
                difference at the bottom tells you exactly how much you are looking for.
                """),
        ])

    static let scheduled = HelpTopic(
        id: "scheduled",
        title: "Scheduled transactions and bills",
        summary: "Recurring entries, reminders, and what is coming up.",
        symbol: "calendar.badge.clock",
        keywords: "scheduled recurring repeat bill reminder due loan mortgage formula",
        blocks: [
            .text("""
                A scheduled transaction repeats on a pattern you choose — weekly, monthly, \
                on a day of the month, or any interval. FinvestLens tells you when one is \
                due and enters it when you confirm.
                """),
            .bullets([
                "**Up Next** on the dashboard shows what is due and what is overdue.",
                "Set a schedule to be created a few days early if you like to see it coming.",
                "A schedule can use a **formula** — you are asked for the varying amount each time it falls due.",
            ]),
            .heading("Loans"),
            .text("""
                The Loan Calculator builds a repayment schedule and can create the \
                scheduled payment for you, split into interest and principal.
                """),
            .heading("Bills"),
            .text("""
                A rule can mark a payment as settling a particular bill, so the reminder \
                clears exactly rather than by guessing at the name.
                """),
        ])

    static let budgets = HelpTopic(
        id: "budgets",
        title: "Budgets",
        summary: "Plan what you mean to spend, then see how it went.",
        symbol: "chart.pie",
        keywords: "budget plan spending actual variance auto suggest",
        blocks: [
            .text("""
                A budget sets a planned amount per account per period. Open it with \
                Book ▸ Budget… (⌘B).
                """),
            .bullets([
                "**Auto-budget** fills in amounts from what you actually spent.",
                "**Suggest Budget** proposes monthly figures from six months of spending, using Apple Intelligence on this device.",
                "The dashboard's Cashflow vs Budget card shows how the current period is tracking.",
            ]),
            .text("""
                Budget-versus-actual is a report like any other, so you can export it or \
                keep it as a favourite.
                """),
        ])

    static let documents = HelpTopic(
        id: "documents",
        title: "Receipts and documents",
        summary: "Attach files to transactions and keep the links working.",
        symbol: "paperclip",
        keywords: "attachment document receipt invoice link file folder relative path",
        blocks: [
            .text("""
                Any transaction can have documents attached — a receipt, an invoice, a \
                dividend statement. The Attachments panel beside the register shows the \
                selected transaction's file; turn it on with **View ▸ Attachments** in the \
                register toolbar.
                """),
            .heading("Where files live"),
            .text("""
                Your files stay where you filed them. Attaching one records **where it is**, \
                not a second copy of it — so the folder you scan into stays the single \
                archive, and tidying it there tidies it everywhere.
                """),
            .text("""
                Settings ▸ Documents takes two folders, a primary and a secondary — receipts \
                in one and statements in the other, say. A file inside either is linked \
                **relatively**, the same way GnuCash does it, so the book and its documents \
                can move together — onto a NAS, or to a new Mac — without breaking. A file \
                outside both is linked by its full path, which still works but does not \
                travel.
                """),
            .bullets([
                "**Link File…** points at a file where it already is.",
                "**Add Web Link…** stores a URL instead of a file.",
                "**Remove Link** unlinks only — your file is never deleted.",
            ]),
            .tip("""
                Matching a folder of receipts in bulk — **Match Attachments…** — links them \
                where they lie too. Point it at the folder you already file into.
                """),
        ])

    // MARK: Investments & planning

    static let investments = HelpTopic(
        id: "investments",
        title: "Investments",
        summary: "Holdings, how current their prices are, and what to fix.",
        symbol: "chart.line.uptrend.xyaxis",
        keywords: "investment security share stock price quote portfolio dividend capital gain cost basis ticker holding stale coverage watch list target isin identifier chart export csv lot average cost provenance source",
        blocks: [
            .text("""
                **Investments** shows what you hold, what it is worth, and — first of \
                all — whether those figures can be trusted. A security account holds \
                units: shares, units in a fund, or a currency. Buys, sells, dividends \
                and returns of capital are recorded through the Stock Transaction \
                sheet, which works out the cost basis and any gain for you.
                """),
            .heading("Can I trust today's figures?"),
            .text("""
                The band at the top answers that in one number: the share of your \
                holdings' **value** that is priced as of the market's most recent \
                trading day. Value, not count — one large holding left behind matters \
                more than several small ones.
                """),
            .bullets([
                "A holding is **current** when it is priced on the latest day its market traded, so a Friday close still counts as current on a Monday.",
                "**Needs attention** lists only what a person has to act on, with the fix beside it. On a healthy book it is not there at all.",
                "Missing days *inside a period you held something* are called out separately: those are the ones that make past valuations wrong.",
            ]),
            .heading("Holdings"),
            .bullets([
                "Each row shows the units you hold and what you paid for them, then what they are worth now, the return since you bought, and how old the price is.",
                "**Price History** in the toolbar sets the period every small chart covers — a month through five years. The period is named above the first group, and remembered with the book.",
                "Every chart uses **the same time axis**, so the same position means the same date on every row: a line that stops short of the right-hand edge is one whose prices stop there.",
                "**A break in the line means missing prices** — it is never drawn through days that have none. What counts as a break scales with the period, so a week's absence shows over a month and not over five years.",
                "Heights are *not* comparable between rows. Each chart uses its own scale, because two securities' prices have no common measure.",
                "**Valued by hand** collects securities no price service covers, such as super funds. They are not failures; enter their prices from **More ▸ Enter a Price…**, and set how often you expect a new figure with **Valuation Cadence…** on the row — quarterly by default, so a fund is not called stale every Tuesday the market trades.",
                "**Closed positions** are hidden. Show them from **More ▸ Show Closed Positions**; their history is always kept for capital gains.",
            ]),
            .heading("One security's page"),
            .text("""
                Click any holding to open everything about it on one page: what it \
                is worth now and what it cost, how it has performed, its whole price \
                history as a chart, your own transactions, your open tax lots, every \
                recorded price, and its settings.
                """),
            .bullets([
                "**The chart draws your book on the market.** The line is the price; green triangles are your buys and red diamonds your sells, each placed at what you actually paid or received; the dashed line is your average cost; the shaded band is the period you held it.",
                "A marker **above** the line is a purchase made above the market of the day, and one below it a bargain — which is what the chart is for.",
                "**While held** is the period that judges your own decisions. Everything before you bought is somebody else's story.",
                "**Prices** is the only price table in the app, and it shows **where each price came from** — a quote provider, or typed by hand. Click any figure to correct it; a corrected price is recorded as typed, because it is.",
                "**Export…** writes this security's prices as a CSV you can open in a spreadsheet and import back.",
                "**Update** in the toolbar fetches only this security. **Rebuild History from Scratch** replaces its prices — but only if the fetch returns data, so a failed run can never wipe good history.",
            ]),
            .heading("Company data"),
            .text("""
                A security's page can also show who and what the company is, its \
                financial statements, and the dividends the issuer declared. \
                This is **fetched and cached on your device, never stored in \
                your book** — clearing it from Settings ▸ Pricing loses nothing.
                """),
            .bullets([
                "Every section says **where it came from and when**, and offers **Refetch** — a figure you doubt should never need waiting out.",
                "A section that cannot be filled says so plainly. Company data is a bonus, not a requirement: prices come from a different service and are unaffected.",
                "**If you have set an API key**, that service is asked before the keyless default — it is a documented service you signed up to. Yahoo covers everything without a key, so nothing is required of you.",
                "A **bond** shows its coupon, frequency, maturity, call date and yield instead — a better profile than any share service could give.",
                "Declared dividends are what the **issuer** paid per unit. What your book recorded is under *Your transactions*, and the difference is the next section.",
            ]),
            .heading("Checks"),
            .text("""
                **Checks** compares what the issuer declared against what your \
                book records — a job that needs both the ledger and the market, \
                so no portfolio tracker and no accounting package can do it \
                alone. Nothing is ever changed for you.
                """),
            .bullets([
                "**A declared dividend that is not in your book** means income — and tax — is understated.",
                "**Income with no matching declaration** is usually a special dividend, sometimes a wrong date or the wrong security.",
                "**An amount that differs** points at withholding, franking, or a reinvestment recorded at the wrong price.",
                "**A split that was never recorded** is the quiet one: every price before that date disagrees with the units you held, so past valuations and the whole chart are wrong.",
                "**A price far from the ones around it** catches a decimal slip or a figure typed in cents — the errors most likely to hide in hand-entered prices.",
            ]),
            .heading("Identifiers"),
            .text("""
                Settings on a security's page hold two identifiers, and they do \
                different jobs. **Quote symbol** overrides the ticker sent to a price \
                provider — set it when a security trades under a different code than \
                its name here. **ISIN or exchange code** identifies the security \
                itself; providers that key by identifier rather than ticker, as bond \
                services do, need it to find your holding at all.
                """),
            .heading("Updating prices"),
            .bullets([
                "**Update Prices** (⇧⌘U) fills in everything missing, including gaps in the middle of a history.",
                "The arrow beside it sets **what a run covers** — all holdings, only what is behind, or holdings plus closed positions with gaps. A closed position is not worth today's price, but a hole inside the period you *did* hold it makes every past valuation wrong, so it is worth fetching once.",
                "**Preview This Run…** shows what will happen before it happens: which securities, which providers, and how many requests. Some providers answer for a whole group in one request, so the count of securities is not the cost.",
                "The same menu chooses a different provider for one run.",
                "Yahoo and Stooq need no key; EODHD, Alpha Vantage, Finnhub and Twelve Data take a free API key, set in Settings ▸ Pricing.",
                "Keys are kept in your keychain on this device — never in the book file.",
            ]),
            .heading("Bonds"),
            .text("""
                A corporate bond has no ticker, so no share-price service can \
                find it. **FIIG** prices Australian corporate bonds by **ISIN** \
                instead, needs no key, and is chosen per security — so one \
                update run can serve your shares and your bonds at once.
                """),
            .bullets([
                "When a holding carries an ISIN, **Needs attention** offers to point it at FIIG. Choosing it changes nothing but which service is asked; no price moves until the next update.",
                "Bond prices are recorded **relative to face value** — 0.985 means the bond is worth 98.5% of its face, which is how the market quotes it and how the book has always stored it.",
                "FIIG publishes today's price and no past series, so a bond's history builds up from each day's update rather than arriving all at once.",
                "A bond FIIG does not list is reported by name after an update, rather than silently skipped. Usually the ISIN needs correcting on that security's page.",
            ]),
            .heading("Exchange rates"),
            .text("""
                A holding priced in another currency needs a rate before it can be \
                valued in yours. The rates line says whether every currency you use \
                has one, and **Add Rate…** fills a gap.
                """),
            .heading("Watching and targets"),
            .text("""
                **More ▸ Watch Security…** follows something you do not own. \
                Right-click any row to set a price target, and the dashboard tells you \
                when the latest quote crosses it.
                """),
            .heading("Dividends and franking"),
            .text("""
                Record Dividend… books the cash and, where it applies, the franking \
                credits — so the tax reports have what they need at the end of the year.
                """),
            .tip("""
                Prices are never listed as one long table. To work with a security's \
                own history, open that security — everything about it is in one place.
                """),
        ])

    static let reports = HelpTopic(
        id: "reports",
        title: "Reports and statements",
        summary: "Statements, charts, decks and the end-of-year pack.",
        symbol: "doc.text",
        keywords: "report statement balance sheet income profit loss trial cash flow pdf export deck review",
        blocks: [
            .text("""
                Reports ▸ Reports… (⌘R) opens the gallery: balance sheet, income statement, \
                trial balance, cash flow, budget, tax, investment and business reports.
                """),
            .bullets([
                "Change the period and options at the top of any report.",
                "Save a report with its settings as a **favourite** to come back to it.",
                "Export any report as a PDF, or share it.",
            ]),
            .heading("Presentation decks"),
            .text("""
                **Financial Review** presents a period as a slide deck — one message per \
                slide, with charts and commentary written on this device from the figures \
                on the slide. **Investment Review** does the same for the portfolio.
                """),
            .heading("End of year"),
            .text("""
                The **Financial Year Pack** gathers the statements you need at tax time \
                into one PDF, in reading order.
                """),
        ])

    static let planning = HelpTopic(
        id: "planning",
        title: "Planning ahead",
        summary: "Debts, a lifetime plan, tax estimates and a wellbeing score.",
        symbol: "chart.line.flattrend.xyaxis",
        keywords: "plan planner debt avalanche snowball retirement lifetime tax estimate wellbeing forecast",
        blocks: [
            .heading("Debt Reduction Planner"),
            .text("""
                Enter what you can put toward debts each month and compare **avalanche** \
                (highest rate first) with **snowball** (smallest balance first) — you see \
                the payoff date and the interest saved against paying minimums.
                """),
            .heading("Lifetime Planner"),
            .text("""
                A long-range projection seeded from your own book, with assumptions you can \
                edit and one-off life events you can add. Figures can be shown in today's money.
                """),
            .heading("Tax estimator"),
            .text("""
                An estimate built from the accounts you mark as income and deductions, using \
                editable brackets that default to Australian resident rates.
                """),
            .heading("Financial Wellbeing"),
            .text("""
                A transparent score from four measures in your own books — savings rate, \
                months of spending covered by cash, non-mortgage debt against income, and \
                the recent spending trend. Every component is shown, with how it was worked out.
                """),
            .tip("""
                These are estimates from your own figures and assumptions. They are not \
                financial or tax advice.
                """),
        ])

    static let dashboard = HelpTopic(
        id: "dashboard",
        title: "The dashboard",
        summary: "The board you land on: what matters today, at a glance.",
        symbol: "square.grid.2x2",
        keywords: "dashboard home overview net worth tiles cards alerts up next customise board",
        blocks: [
            .text("""
                The dashboard is the book at a glance — net worth and its twelve-month trend, \
                anything the alerts have flagged, your account balances, bills coming up, and \
                how the budget is tracking. A new book opens here; a book you have used before \
                opens where you left off.
                """),
            .text("""
                It is a board rather than a page: it never scrolls. Cards are packed into the \
                window you actually have, and any that will not fit are left out rather than \
                pushed below the fold — so a wider window shows more of them. Resize it and \
                the board re-packs itself.
                """),
            .heading("Choosing what appears"),
            .text("""
                Not every card suits every book. **Customise**, in the dashboard’s toolbar, \
                turns cards off one by one, and the rest close the gap. A card with nothing to \
                report — no bills due, no goals set — gives up its place rather than showing \
                you an empty box.
                """),
            .tip("""
                ⌘1 returns to Overview from anywhere — every mode has its own number, \
                ⌘1 to ⌘7. **Up Next** is the card to read first: it lists what is most \
                worth doing in the book right now.
                """),
        ])

    static let yearEnd = HelpTopic(
        id: "year-end",
        title: "End of the financial year",
        summary: "Close the year off, and produce the papers it calls for.",
        symbol: "calendar.badge.checkmark",
        keywords: "year end financial year close book closing entries retained earnings tax pack passport summary",
        blocks: [
            .text("""
                At the end of a financial year, income and expense accounts have done their \
                job: they describe a period that is now over. Closing the year sweeps their \
                balances into equity so the next year starts them at zero, and what they \
                earned or cost is preserved as retained earnings.
                """),
            .heading("Closing the year"),
            .steps([
                "Choose **Book ▸ Close Financial Year…**",
                "Set the closing date and pick the equity account to close into — Retained Earnings, typically.",
                "Read the preview: it names how many accounts will be closed, and the totals per currency.",
                "Post it. Undo takes the whole closing back in one step; a book with more than one currency gets one closing entry per currency.",
            ]),
            .tip("""
                You need an equity account to close into before you start. If the book has \
                none, the sheet says so rather than inventing one.
                """),
            .heading("The papers"),
            .text("""
                The **Financial Year Pack** (in Reports) gathers the statements tax time asks \
                for into one document. **Reports ▸ Financial Summary (Passport)…** is the \
                different, shorter thing: a single page — net worth, savings rate, the \
                twelve-month trend — for when someone needs a picture of your position rather \
                than your accounts. It says on its face that it is a snapshot prepared from \
                your own records, not a verified statement.
                """),
        ])

    static let outsideTheApp = HelpTopic(
        id: "outside-the-app",
        title: "Outside the app",
        summary: "Widgets, Quick Look and Shortcuts — the book without opening it.",
        symbol: "square.grid.3x3.topleft.filled",
        keywords: "widget widgets control centre control center quick look preview spotlight shortcuts siri notification alert",
        blocks: [
            .heading("Widgets"),
            .text("""
                Two widgets read the book you have open: **Net Worth**, and **Alerts** for \
                anything wanting attention. They show a snapshot written when you save — they \
                never open the book themselves, so nothing is locked. Close the book and they \
                empty until you open it again.
                """),
            .text("""
                There is also a Control Centre button that opens FinvestLens.
                """),
            .heading("Quick Look"),
            .text("""
                Press Space on a book in the Finder to see inside it without opening it — \
                FinvestLens documents, and GnuCash files too, in all three shapes GnuCash \
                writes them.
                """),
            .heading("Alerts and Shortcuts"),
            .text("""
                Alerts can arrive as notifications, so a bill due or a balance heading \
                negative reaches you without the app in front of you. They are scheduled from \
                the open book and cleared when you close it. FinvestLens also publishes \
                Shortcuts actions, so the book can take part in an automation.
                """),
        ])

    static let tags = HelpTopic(
        id: "tags",
        title: "Tags",
        summary: "Label transactions across accounts, then find them again.",
        symbol: "tag",
        keywords: "tag tags label keyword holiday trip project deductible search filter rule",
        blocks: [
            .text("""
                A tag is a free-form label on a transaction. Where an account says what \
                something *was*, a tag says what it *belonged to* — a holiday, a renovation, \
                a client, everything you mean to claim at tax time. One transaction can carry \
                several, and a tag can span any number of accounts.
                """),
            .heading("Adding tags"),
            .steps([
                "Open the transaction out in the register — select it and press ⌘E, or click its disclosure arrow.",
                "Type into the **Tags** line, separating tags with commas.",
                "Press ⌘⏎, or click away, to commit the row.",
            ]),
            .text("""
                Rules can apply them for you: a rule action **Set tags** puts the same labels \
                on every transaction it matches, as it is imported. See Categorising and rules.
                """),
            .heading("Finding them again"),
            .table([
                ("`tag:holiday`", "Everything tagged holiday"),
                ("`-tag:holiday`", "Everything *not* tagged holiday"),
                ("`tag:holiday amount:>500`", "Combine with any other search term"),
            ]),
            .text("""
                Type these into Find Transactions (⌘F). A tag search reaches across every \
                account at once, which is the point of tagging rather than filing.
                """),
            .tip("""
                Tags are stored in the transaction itself and survive a GnuCash round-trip, \
                so exporting and re-importing keeps them. Duplicating a transaction (⌘D) \
                copies its tags too.
                """),
        ])

    static let currencyTransfer = HelpTopic(
        id: "currency-transfer",
        title: "Moving money between currencies",
        summary: "Record a transfer where the two sides are in different currencies.",
        symbol: "arrow.left.arrow.right",
        keywords: "currency transfer foreign exchange fx rate convert trading account multi-currency",
        blocks: [
            .text("""
                An ordinary transfer moves one amount between two accounts. When the accounts \
                are in different currencies there are *two* amounts — what left, and what \
                arrived — and the rate between them is whatever the bank actually gave you.
                """),
            .steps([
                "Choose **Transaction ▸ Currency Transfer…**",
                "Pick the account the money left and the account it arrived in.",
                "Enter both amounts: what was taken out, and what was received.",
                "Check the date and give it a description, then click **Transfer**.",
            ]),
            .text("""
                The sheet shows the rate your two amounts imply — `1 AUD = 0.92 NZD` — so you \
                can see at a glance whether you have typed them the right way round. That rate \
                is saved as a price, so reports can value either currency afterwards.
                """),
            .heading("Trading accounts"),
            .text("""
                Turn on **Use trading accounts** in the sheet and the transfer also posts to a \
                pair of trading accounts, so the books balance in *each* currency rather than \
                only by value. This is GnuCash's approach, and it is what captures unrealised \
                gains when a rate moves. Leave it off and the transfer is a plain two-sided \
                entry. The choice is remembered in the book.
                """),
            .tip("""
                The menu item is unavailable until the book holds at least two currencies — \
                add a foreign-currency account first.
                """),
        ])

    static let goals = HelpTopic(
        id: "goals",
        title: "Savings goals",
        summary: "Set money aside toward something, and track the push.",
        symbol: "target",
        keywords: "goal saving target challenge set aside holiday emergency fund deposit",
        blocks: [
            .text("""
                A goal earmarks part of an account toward something — a holiday, an \
                emergency fund, a deposit. The money stays where it is; the goal just \
                tracks how much of it is spoken for.
                """),
            .bullets([
                "Add or withdraw against a goal as you save.",
                "A goal can have a target amount and a target date, and shows what is left to go.",
                "A **challenge** is a time-boxed push on one goal, if you like a deadline.",
            ]),
        ])

    // MARK: More

    static let business = HelpTopic(
        id: "business",
        title: "Small business",
        summary: "Customers, suppliers, invoices, bills and billable time.",
        symbol: "building.2",
        keywords: "business customer vendor supplier invoice bill payment aging receivable payable job employee tax invoice time mileage",
        blocks: [
            .text("""
                Business ▸ Customers, Vendors & Invoices… (⇧⌘B) opens the business hub: \
                customers, vendors, employees, jobs, invoices, bills and billing terms.
                """),
            .heading("Invoicing"),
            .steps([
                "Create an invoice for a customer and add its line items.",
                "Post it — that books the amount to accounts receivable.",
                "When you are paid, use Process Payment to settle it.",
            ]),
            .heading("Reports"),
            .bullets([
                "**Receivable Aging** and **Payable Aging** show what is owed and how late it is.",
                "An invoice can be printed as an Australian Tax Invoice.",
                "A **credit note** reduces what is owed, rather than adding to it.",
            ]),
            .heading("Time and mileage"),
            .text("""
                Log billable hours or travel, then gather them onto a customer invoice.
                """),
        ])

    static let emergencyRecords = HelpTopic(
        id: "emergency",
        title: "Emergency records",
        summary: "Key details kept with the book, behind authentication.",
        symbol: "cross.case",
        keywords: "emergency record insurance policy contact account number authentication touch id",
        blocks: [
            .text("""
                Emergency Records keeps the details someone would need in a hurry — \
                insurance policies, account numbers, contacts — alongside the book rather \
                than scattered across notes and drawers.
                """),
            .text("""
                The screen asks for Touch ID or your password each time it opens, and the \
                records stay inside your book file.
                """),
        ])

    static let interchange = HelpTopic(
        id: "interchange",
        title: "GnuCash, Ledger and the command line",
        summary: "Move your data in and out, and script reports.",
        symbol: "terminal",
        keywords: "gnucash ledger export import cli finlens command line journal interchange csv spreadsheet",
        blocks: [
            .heading("GnuCash"),
            .text("""
                FinvestLens reads and writes GnuCash XML, so you can move a book either \
                way without losing detail — accounts, splits, prices, schedules and \
                business records all survive the trip.
                """),
            .heading("Spreadsheets"),
            .text("""
                File ▸ Export CSV, on the Mac, writes plain spreadsheet files — your \
                accounts, your transactions, or your price history — for anything that \
                reads a table.
                """),
            .heading("Ledger journals"),
            .text("""
                File ▸ Export Ledger Journal… (⇧⌘E) writes a plain-text Ledger journal, \
                and File ▸ Import Ledger Journal… reads one back.
                """),
            .heading("The finlens command line"),
            .text("""
                `finlens` is a read-only command-line reporter over your book, modelled on \
                Ledger's. It is safe to run while the app has the book open — it takes no \
                lock and never writes.
                """),
            .table([
                ("`finlens -f Book.finvestlens bal`", "Account balances."),
                ("`finlens -f Book.finvestlens reg Groceries`", "A register of matching postings."),
                ("`finlens -f Book.finvestlens print`", "The book as a Ledger journal."),
            ]),
        ])

    static let shortcuts = HelpTopic(
        id: "shortcuts",
        title: "Keyboard shortcuts",
        summary: "Everything you can reach without the mouse.",
        symbol: "keyboard",
        keywords: "shortcut keyboard key command hotkey",
        blocks: [
            .heading("Books and files"),
            .table([
                ("⌥⌘N", "New book"),
                ("⌘O", "Open a book"),
                ("⌘S", "Save"),
                ("⇧⌘W", "Close the book"),
                ("⌥⌘I", "Import a bank file"),
                ("⇧⌘I", "Smart Import PDFs"),
                ("⇧⌘M", "Match attachments"),
                ("⇧⌘E", "Export a Ledger journal"),
            ]),
            .heading("Moving around"),
            .table([
                ("⌘1", "Overview"),
                ("⌘2", "Accounts"),
                ("⌘3", "Investments"),
                ("⌘4", "Reports"),
                ("⌘5", "Business"),
                ("⌘6", "Planning"),
                ("⌘7", "Records"),
                ("⌘F", "Find transactions"),
                ("⌘I", "Find an account"),
            ]),
            .heading("Working in the book"),
            .table([
                ("⌘N", "New transaction"),
                ("⇧⌘N", "New transaction, all fields"),
                ("⌘E", "Open the selected transaction out for editing"),
                ("⌘D", "Duplicate the selected transaction"),
                ("⌘⌫", "Delete the selected transaction"),
                ("⌘J", "Go to the other account in this transaction"),
                ("⌘G", "Go to date"),
                ("⌘↑ / ⌘↓", "Oldest / newest transaction"),
                ("⌘⏎", "Commit the row you are entering"),
                ("⇧⌘R", "Reconcile the selected account"),
                ("⌘B", "Budget"),
                ("⇧⌘U", "Update prices"),
                ("⌘Z", "Undo"),
            ]),
            .heading("Windows and views"),
            .table([
                ("⌘R", "Reports"),
                ("⇧⌘B", "Customers, vendors and invoices"),
                ("⇧⌘L", "Lock the book now"),
                ("⌘?", "This help"),
                ("⌘,", "Settings"),
            ]),
        ])
}
