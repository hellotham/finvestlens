# App Store listing — 1.2

> **The copy for the version being prepared — not a record of what is live.**
> App Store Connect is the source of truth for the live listing. This exists
> as a file so `StoreListingTests`
> (`Packages/FeatureUI/Tests/FinvestLensUITests/StoreListingTests.swift`) can
> check every field against App Store Connect's limits *before* anything is
> pasted, and so the wording is reviewed like any other change. Modelled on
> HelloNotes' `docs/app-store-listing.md`, which the owner named as the
> template (10 Oct 2026).
>
> Drafted 12 October 2026 for FinvestLens 1.2 (App ID 6821468191). The tests
> hold three things about the copy to the code, because each was wrong in the
> first draft: the reviewer notes name every price provider the code has
> (`QuoteProviderKind`), the iPhone and iPad description promises no import
> or export on iPhone (`FR-PLT-06`), and nothing in the copy mentions Private
> Cloud Compute while the build cannot offer it. Everything else here is
> prose, and was read against the PRD by hand.

## App information

| Field | Value | Source |
|---|---|---|
| Name | FinvestLens | set when the record was created |
| Primary category | Finance | |
| Secondary category | Business | customers, invoices, bills, tax tables (`P7`) |
| Licence agreement | Apple's Standard Licence Agreement | as HelloNotes |
| Price | Free, no in-app purchases | the app is GPL-3.0-or-later and the DMG is free — **confirm with the owner before it is entered** |

**Attestations that are the owner's to make** (not entered without a yes):

- **Content rights.** App Store Connect asks whether the app "contains,
  shows, or accesses third-party content". The owner's position
  (12 Oct 2026): *"we do not provide APIs, or store data, everything must be
  supplied by user."* The facts the answer has to square with, from
  `QuoteProviderKind`: the app fetches security prices and exchange rates
  from eight providers. Four need a key the person obtains and enters
  (EODHD, Alpha Vantage, Finnhub, Twelve Data). Four are reached with no key
  and nothing supplied by the person beyond the choice of provider — Yahoo
  Finance (the default), Stooq, FIIG and Wilson Asset Management — and
  company data shown in the Investments hub comes from the same requests.
  Nothing is bundled, stored on a server of the publisher's, or redistributed:
  each request goes from the person's device to the provider, and prices are
  kept in the person's own book. Whether that is "accessing third-party
  content" in App Store Connect's sense is the attestation; HelloNotes
  answered *no*, and has no such feeds.
- **Age rating questionnaire.** Expected to come out at 4+: no user-generated
  content shared with others, no web browsing, no gambling, no health topics.
- **App Privacy.** Expected "Data Not Collected": the app has no account, no
  analytics and no server of the publisher's, and its privacy manifest
  declares no collected data types. Requests to a price provider or to the
  person's own Box account go from the device to that service.

## Fields for both platforms

**Subtitle** (≤30 chars):
```
Double-entry accounting
```

**Promotional text** (≤170 chars, editable any time without review):
```
Rigorous double-entry accounting for a household or a small business, with investments, budgets and reports. Your book is one file you own. No account, no subscription.
```

**Keywords** (≤100 chars, comma-separated):
```
accounting,double entry,bookkeeping,budget,investments,portfolio,net worth,invoice,dividends,ledger
```

**Support URL**
```
https://hellotham.com/finvestlens/support/
```

**Marketing URL**
```
https://hellotham.com/finvestlens/
```

**Privacy Policy URL**
```
https://hellotham.com/finvestlens/privacy/
```

**Copyright**
```
2026 Hello Tham Pty. Ltd.
```

**Version** — What's New in 1.2:
```
FinvestLens comes to the App Store, and to iPhone.

• iPhone: a layout of its own, with a tab for each area, a register you can read at a glance, and a form for entering a transaction.
• Opening a book no longer stalls after the app was closed unexpectedly: a lock left by a copy that is no longer running on the same device is cleared by itself.
• Apple Intelligence features are rebuilt for the new on-device model: a long bank statement is read to its last page, summaries are written in your language, and every figure in a summary is checked against your own numbers before you see it.
• Saving no longer holds the window, and everyday edits in large books are faster.
• Choosing another report while one is open now shows that report.

FinvestLens 1.2 requires iOS 27, iPadOS 27 or macOS 27.
```

## Description

**Description** — iPhone and iPad (≤4000 chars):
```
FinvestLens is double-entry accounting for people who want their books to be right. It keeps a household's or a small business's accounts with the rigour of a professional ledger, and it is built for iPhone and iPad from the ground up.

Your book is a single file you own. There is no account to create, no subscription, and no server of ours for your data to reach.

REAL DOUBLE-ENTRY
• Every transaction balances, across as many accounts as it needs
• A full chart of accounts: assets, liabilities, equity, income and expenses, with sub-accounts
• Multiple currencies, with exchange rates and a price history
• Reconcile an account against its statement
• Scheduled transactions and bill reminders

INVESTMENTS
• Shares, funds and bonds held in their own accounts, with lots and cost basis
• Capital gains by FIFO, LIFO or average cost
• Dividends, reinvestment, returns of capital and stock splits
• Price updates from the provider you choose
• A portfolio view with allocation and return

BUDGETS, PLANNING AND REPORTS
• Budgets by category, with rollover
• Balance sheet, income statement, cash flow, net worth and more, set out the way an annual report is
• A debt reduction planner, a long-range planner and a tax estimator: every assumption is visible and editable, and none of it is advice
• A dashboard that shows where you stand without scrolling

SMALL BUSINESS
• Customers, vendors and employees
• Invoices, bills and credit notes, with payments and aging
• Tax tables, billing terms and jobs

APPLE INTELLIGENCE, ON YOUR DEVICE
• Suggested categories for transactions
• A proposed budget from your own spending
• Plain-language notes on a report or a forecast, in your language, with every figure checked against your numbers
These run on your device with Apple Intelligence, where it is available and turned on. Your figures are not sent to us or to anyone else.

YOURS TO KEEP
• Keep your book on your device, in iCloud Drive or on a network share, and open it on your Mac as well
• Works with books created by FinvestLens for Mac, which reads and writes GnuCash files
• English, German, Spanish, French, Italian, Japanese, Brazilian Portuguese and Simplified Chinese
• VoiceOver, Dynamic Type and Dark Mode throughout

On iPhone, FinvestLens opens, creates and edits books. Importing bank files and exporting are done on iPad or Mac.

FinvestLens is free software, released under the GNU General Public License.

Privacy Policy: https://hellotham.com/finvestlens/privacy/
```

**Description** — Mac (≤4000 chars):
```
FinvestLens is double-entry accounting for people who want their books to be right. It keeps a household's or a small business's accounts with the rigour of a professional ledger, in an app that belongs on a Mac.

Your book is a single file you own. There is no account to create, no subscription, and no server of ours for your data to reach.

REAL DOUBLE-ENTRY
• Every transaction balances, across as many accounts as it needs
• A full chart of accounts: assets, liabilities, equity, income and expenses, with sub-accounts
• Multiple currencies, with exchange rates and a price history
• A register built for the keyboard, with autocomplete from your own history
• Reconcile an account against its statement
• Scheduled transactions and bill reminders

BRING YOUR BOOKS WITH YOU
• Import a GnuCash file and export one back: the round trip is lossless
• Ledger plain-text journals in and out
• Bank statements as CSV, QIF, OFX and QFX, SWIFT MT940 and MT942, and ISO 20022 CAMT.053
• Duplicates are recognised, and a transfer seen from both accounts is recorded once

INVESTMENTS
• Shares, funds and bonds held in their own accounts, with lots and cost basis
• Capital gains by FIFO, LIFO or average cost
• Dividends, reinvestment, returns of capital and stock splits
• Price updates from the provider you choose, with history
• A portfolio view with allocation and return

BUDGETS, PLANNING AND REPORTS
• Budgets by category, with rollover
• Balance sheet, income statement, cash flow, net worth and more, set out the way an annual report is, and exported as PDF
• A debt reduction planner, a long-range planner and a tax estimator: every assumption is visible and editable, and none of it is advice
• A dashboard that shows where you stand without scrolling

SMALL BUSINESS
• Customers, vendors and employees
• Invoices, bills and credit notes, with payments and aging
• Tax tables, billing terms, jobs and printable invoices

APPLE INTELLIGENCE, ON YOUR MAC
• Read a PDF bank statement, an invoice or a dividend statement into transactions you review before anything is posted
• Suggested categories, and a proposed budget from your own spending
• Plain-language notes on a report or a forecast, in your language, with every figure checked against your numbers
These run on your Mac with Apple Intelligence, where it is available and turned on. Your figures are not sent to us or to anyone else.

YOURS TO KEEP
• Keep your book on your Mac, in iCloud Drive or on a network share, and open it on iPhone and iPad as well
• Rules, tags, saved searches and attached documents
• English, German, Spanish, French, Italian, Japanese, Brazilian Portuguese and Simplified Chinese
• VoiceOver, keyboard navigation and Dark Mode throughout

FinvestLens is free software, released under the GNU General Public License.

Privacy Policy: https://hellotham.com/finvestlens/privacy/
```

## Notes to reviewer (both platforms)

```
FinvestLens is a double-entry accounting app. Nothing needs to be set up and there is no account or sign-in: choose New Book on the welcome screen to create an empty book with a standard chart of accounts, then add a transaction with New Transaction.

All data stays in the book file the person creates. The app has no server and collects nothing.

NETWORK. The app contacts a network service in two situations, both started by the person: fetching security prices and exchange rates from the price provider they choose (Yahoo Finance, Stooq, FIIG and Wilson Asset Management need no key; EODHD, Alpha Vantage, Finnhub and Twelve Data use a key the person enters, which is stored in the Keychain), and, optionally, signing in to their own Box account to open a book stored there. Box sign-in uses Box's own page in a system web authentication session and requires the person's own Box developer app credentials, entered in Settings; it is not needed for any other feature and can be ignored for review.

APPLE INTELLIGENCE. Category suggestions, budget proposals, document reading and report notes run on Apple Foundation Models on the device, where Apple Intelligence is available and turned on. Where it is not, those commands are disabled and say why; every other feature works without it. The app contains no third-party AI services and no API keys for any.

The app makes no in-app purchases and shows no advertising.
```

## Private Cloud Compute

**Not in this copy, deliberately.** The owner wants Private Cloud Compute to
be the default wherever a build can offer it (12 Oct 2026), and the code is
ready for it (`FR-AI-13`). Offering it needs Apple's managed entitlement, and
Apple's request form currently answers that the account is not enrolled in the
Small Business Program although the approval has arrived; the owner has a
support request open. Until the entitlement is assigned the build does not
offer the model at all — `LanguageModels.privateCloudComputeEnabled` — so the
listing must not mention it, and `StoreListingTests` fails if it does.

When it arrives, in the same change as the entitlement and the
`PRIVATE_CLOUD_COMPUTE` condition: add it to the promotional text and both
Apple Intelligence sections; replace "These run on your device…" and "Your
figures are not sent to us or to anyone else", which stop being true of
receipts, invoices, dividend statements, attachments and summaries; add the paragraph below to the
privacy policy; and rewrite the three help passages
`PrivateCloudComputeBuildTests` names. That test fails until the help and the
policy are done, so the entitlement cannot land alone.

## Before 1.2 is submitted

- **The privacy policy needs additions**, and it is published under the
  company's name, so the wording is the owner's to approve — nothing below
  has been published. As published (25 July 2026, `website/src/pages/privacy.astro`)
  it says the app makes network requests "in exactly one situation", price
  fetching, and names six providers. Two more shipped in 1.1 and are not on
  the list (FIIG, Wilson Asset Management), and 1.2 can also connect to the
  person's own Box account. Proposed wording:

  > **Network requests.** FinvestLens contacts a network service in two
  > situations, both started by you.
  >
  > *Fetching prices.* When you update prices, the app asks the price
  > provider you chose for the securities and currencies in your book: Yahoo
  > Finance, Stooq, EODHD, Alpha Vantage, Finnhub, Twelve Data, FIIG (bond
  > prices) or Wilson Asset Management (its own funds' unit prices). The
  > request carries the ticker, ISIN or fund name — never an amount, a balance
  > or anything else from your book — and goes from your device straight to
  > that provider, under its own privacy policy. A key you enter for a
  > provider is kept in your device's Keychain.
  >
  > *Your own Box account.* If you connect a Box account, the app signs you
  > in on Box's own page and then reads and writes the book files you choose
  > there, directly between your device and Box. We never see your Box
  > credentials or your files.

  And, only with the Private Cloud Compute entitlement:

  > *Apple's Private Cloud Compute.* Where it is available, FinvestLens can
  > use Apple's Private Cloud Compute. Match Attachments, Categorise from
  > Attachment and Split from Invoice send the documents they read; Smart
  > Import sends the invoices and dividend statements it finds; and
  > commentary on reports and reviews, budget suggestions and the forecast
  > outlook send the figures they are written from. Apple states that data
  > processed by Private Cloud Compute is not stored or made accessible to
  > Apple. You can keep everything on your device instead, in Settings ▸
  > Apple Intelligence. A PDF imported as a bank statement is always read on
  > your device, and Auto-Categorise and an import's category suggestions
  > always run on it.

  (Corrected twice on 12 Oct 2026, before anything was published. The first
  draft ended "categorising transactions and reading bank statements always
  stay on your device"; Categorise from Attachment does not — it chooses the
  category on the device but reads the attachment as an invoice and as a
  dividend statement. The second said "bank statements are always read on
  your device"; a statement picked in Match Attachments, or attached to a
  transaction, is read as an invoice like any other file. So the paragraph
  now names commands, as the Settings sentence does, because commands are
  what the routing is decided by.)

- **Screenshots** are uploaded for Mac, iPad 13", iPhone 6.3" and 6.9"
  ([app-store.md](app-store.md)).
- **Build.** The newest uploaded build is attached to each platform's 1.2.
