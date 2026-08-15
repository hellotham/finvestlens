# Records and Rules — design research

Status: **research and proposal** (15 Aug 2026). Nothing here is built.

Companions: [Navigation design](navigation-design.md) · [PRD](prd.md) ·
[Planning design](planning-design.md)

---

## Part 1 — Records

### 1.1 Why the mode exists at all

The ledger is built from bank statements. The ATO says that is not evidence
("Records you need to keep", last updated 8 June 2026, read 15 Aug 2026):

> "A bank or credit card statement **on its own isn't written evidence**
> because it isn't from the supplier and generally doesn't include all the
> information required."

That single sentence is the justification for Records as a mode. Everything the
app already holds — accounts, transactions, splits — is the part the ATO says is
insufficient. Records is where the *sufficient* part lives, and it hangs off the
transactions rather than replacing them.

The same page lists what a record can be, and it maps almost one-to-one onto the
collections proposed below:

> "written evidence from a supplier (like a receipt or invoice) · spreadsheets
> or **timesheets** (where you enter information) · **logbooks** (for example,
> to document work-related car use) · diary or calendar entries · employment
> contracts or agreements, duty statements or letter from your employer"

### 1.2 What a deduction record must carry

Per the same page, to claim a work-related expense you must have written
evidence showing:

> "cost of the item or service · name of the supplier · nature of the expense ·
> date you buy or pay for the expense · date the written evidence was prepared"

and separately

> "a record that shows how the expense relates to earning your income, for
> example, a note or similar document explaining **how you calculated the amount
> of your claim** · your **work-related versus private use** (you can only claim
> the work-related portion)."

So a deduction record is not a flag on a transaction. It is: the transaction, a
document, a supplier, a nature, a **business-use percentage**, and the
**working** behind that percentage. The app already links documents to
transactions (759 links on the reference book) — this adds the reasoning the ATO
asks for, which no bank feed can supply.

### 1.3 Retention is computable

> "You must keep your written evidence for **5 years from the date you lodge
> your tax return** … 5 years from the date of your **last claim for decline in
> value**, if you claim a deduction for the decline in value of depreciating
> assets … **5 years after it is certain that no capital gains tax (CGT) event
> can happen**, if you acquire or dispose of a CGT asset"

Three different clocks, and the app knows all three inputs: lodgement date,
the final depreciation entry, and the disposal date. A "keep until" column that
is *derived* rather than typed is something a shoebox of receipts cannot do, and
it is the feature that makes Records worth opening. Note the second and third
clocks can run for decades — a record cannot be archived on age alone.

> "You can keep your records in paper or electronic format, including photos of
> your written evidence. If you make paper or electronic copies of your records,
> they must be a true and clear copy of the original record."

Photographs count, which means capture-from-phone is a legitimate path, not a
convenience.

### 1.4 Depreciation, from the accounting oracle

GnuCash's *Tutorial and Concepts Guide*, ch. 16 (read 15 Aug 2026,
https://www.gnucash.org/docs/v5/C/gnucash-guide/chapter_dep.html):

> "Depreciation is used in personal finances to periodically lower an asset's
> value to give you an accurate estimation of your current net worth. …
> Depreciation for personal finance has **no tax implications**, it is simply
> used to help you estimate your net worth. Because of this, **there are no
> rules for how you estimate depreciation, use your best judgement**."

> "you need only track depreciation on assets of notable worth that you could
> potentially sell, such as a car or boat."

Two different jobs, and the app must not conflate them:

| | Book depreciation | Tax depreciation |
|---|---|---|
| Purpose | net worth is honest | the deduction is defensible |
| Method | your judgement | prescribed |
| Posts to the ledger | yes | not necessarily |

The guide's vocabulary is the model: **original cost** (including "shipping,
installation costs, special training"), **salvage value**, **accumulated
depreciation**, **net book value**, **fair market value**.

Its three schemes (§16.2.1), with the guide's own worked example of a $1,500
computer over 5 years:

- **Linear** — a fixed amount each period; $300/yr to zero.
- **Geometric** — a fixed percentage of the *previous* value; 30% gives 450,
  315, 220.50 … never reaching zero, which "is probably more realistic".
- **Sum of digits** — front-weighted, reaching zero.

The guide also warns that jurisdictions vary the first period: "in Canada …
they permit only a half share of 'Capital Cost Allowance' in the first year."
Any schedule generator needs a first-period rule, not just a scheme.

### 1.5 The collections

| Collection | What it is | Links to |
|---|---|---|
| **Assets** | Things of notable worth: car, boat, computer, artwork. Original cost, acquisition date, serial/VIN, photos, insurance details | the purchase transaction |
| **Depreciation schedules** | Per asset: scheme, life, salvage, first-period rule; generates entries | the asset; optionally posts to the ledger |
| **Deductions** | Claimable expenses with supplier, nature, business-use %, and the working | the transaction + document |
| **Logbooks** | Vehicle trips (date, km, purpose) and work-from-home hours — the ATO's "logbooks" and "diary entries" | the vehicle asset; feeds the deduction % |
| **Timesheets** | Hours worked, for salary verification and for billable work | salary transactions; invoices (Business mode) |
| **Emergency records** | Already built — the things someone else needs if you cannot act | — |
| **Audit log** | Already built — what the book did to itself | — |

**The link direction matters.** A record references a transaction, never the
reverse: the ledger stays a ledger, and a book opened in GnuCash is unaffected.
Stored the way every other extension in this app is stored — a kvp slot on the
split or transaction, so it round-trips.

**What the user's examples become:**

- *"A transaction buying an iPad could be added to an asset list."* — from the
  register, "Add to Assets…"; the asset takes the transaction's date and amount
  as its original cost, and offers a depreciation schedule.
- *"Salary payments could be linked to timesheet items."* — a timesheet period
  links to the salary transaction, so the hours behind a payment are recoverable
  and the ATO's "how you calculated" question has an answer.

### 1.6 What Records must not become

A second ledger. Every figure that is money must come from the book — a
deduction's amount is the transaction's amount, an asset's cost is what was
paid. Records adds *meaning* (this was 60% work use, this is depreciating over
5 years, this receipt is the evidence), never a parallel set of numbers that can
disagree with the ledger.

---

## Part 2 — Rules

### 2.1 What the app has today

`Packages/Rules` (`RuleModels.swift`): rule **groups** → ordered **rules** →
**triggers** + **actions**, with `matchAll` (all/any), `stopProcessing`, and
`isActive` at rule and group level.

- **Trigger fields (4)**: description, memo, amount, account
- **Operators (6)**: contains, equals, startsWith, endsWith, greaterThan, lessThan
- **Actions (6)**: setAccount, setNotes, setTags, setDescription,
  allocateToGoal, linkToBill
- Runs at **import** (`AppModel+Import.swift:277`) and **retroactively** with a
  preview — `previewHistoricalRules()` (`AppModel+Rules.swift`, FR-RULE-02)

### 2.2 A documented comparison

Firefly III's rule engine (https://docs.firefly-iii.org/how-to/firefly-iii/features/rules/,
read 15 Aug 2026) — an open-source personal finance app whose engine is
specified in public:

> "Rules are divided in rule groups. Each rule group has rules in a specific
> order."

> "Rules can be set to be 'strict' or not. If a rule is set to be strict, ALL
> triggers must match for the rule to fire. If a rule is not strict, ANY trigger
> is enough."

> "**Triggers can be inverted**, in which case they do the exact opposite."

> "**Stop processing** … other rules … other triggers … other actions"

> "You cannot fire other rules from a rule."

Structurally FinvestLens already matches: groups, ordering, strict/non-strict,
stop-processing, enable/disable, apply-to-existing. **The gap is vocabulary, not
architecture**, plus three specific mechanics:

| Missing | Why it matters here |
|---|---|
| **Invert a trigger** | "everything from this payee *except* refunds" is currently impossible |
| **Stop-processing per action** | only per rule today, so a rule cannot try one thing then fall through |
| **More trigger fields** | no date/day-of-month, reconcile state, tag, currency, has-attachment, split count, account *type* |
| **Richer operators** | no regex, no is-empty, no between |

Notably Firefly also offers an escape hatch — an expression engine — for what
the fixed vocabulary cannot say. Worth knowing exists; not worth copying until
the fixed vocabulary is demonstrably short.

### 2.3 The finding that matters more than any of that

**This app has two categorisation systems that do not know about each other.**

1. **Explicit rules** — `RuleEngine`, deterministic, user-authored.
2. **Learned categorisation** — the smart categoriser, which learns each payee
   from prior work, with an ambiguity guard that abstains
   (`AppModel+SmartImport`), plus the import matcher's own payee→account
   frequency table (`ImportMatcher.match`).

GnuCash has only the second (its Bayesian `import-map-bayes` slots are present
in the reference book — four accounts carry them). Firefly III has only the
first. FinvestLens has both, and nothing arbitrates between them: at import,
rules win and the heuristic is a fallback (`AppModel+Import.swift:277-300`),
which is a reasonable default nobody chose deliberately.

The design questions that follow are the interesting ones, and they are not
about adding triggers:

- **Can the learner propose a rule?** "You have categorised 14 transactions
  from PAYPAL to Subscriptions — make that a rule?" turns invisible learning
  into something inspectable and editable.
- **Should a rule be able to say "leave this to the learner"?** An explicit
  abstention is different from no rule at all.
- **Why did this get categorised?** One answer surface — "rule *Groceries*" or
  "learned from 14 similar" — makes both systems debuggable. Today the user
  cannot tell which fired.

That third one is the highest value for the least work, and it is the same
principle already applied to the import sheet's duplicate badge: a claim the
user can check beats a claim they must trust.

### 2.4 Order of work

1. **Explain the outcome** — show which system categorised a row, and why.
2. **Invert a trigger** — one boolean, removes a whole class of impossibility.
3. **Trigger fields**: date/day-of-month, has-attachment, tag, account type.
4. **Learner proposes rules** — the feature that makes the two systems one.
5. Regex and stop-processing-per-action only if the simpler vocabulary is shown
   to be short.
