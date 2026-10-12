# Intelligence prompts — what is sent, and what was measured

> Apple, *Updating prompts for new model versions*: "When a new version of the
> foundation model your app uses becomes available, test the prompts your app
> uses against the old and new model versions … Record what output your prompt
> produces … If an update is necessary, version your prompts for each model
> your app supports." This file is that record. The prompts themselves live
> beside the code that sends them; this says which model they were last run
> on, what happened, and why each one is worded and placed as it is.
>
> Every figure in an example here is synthetic. Nothing below came from a
> real book.

## The model these were run on

| | |
|---|---|
| Date | 12 October 2026 |
| System | macOS 27.0.1 (26A434), Xcode 27.0 (27A266a) |
| Model | `SystemLanguageModel.default`, variant "AFM 3 Core Advanced" |
| Context window | 8,192 tokens, as reported by `contextSize` (Apple's *Managing the context window* still says 4,096) |
| Capabilities | guided generation, tool calling, vision; no reasoning |
| Languages | all eight the app is translated into pass `supportsLocale`, as do the regional variants tried (en_SG, de_CH, es_MX, pt_PT, zh_HK) |

FinvestLens's minimum is 27.0, so there is one model generation to support
and no `#available` branch between prompt versions yet. When Apple ships the
next model (watch [*Foundation Models updates*](https://developer.apple.com/documentation/Updates/FoundationModels)),
re-run the live suites and the two surveys first: they are the comparison
this file exists to make.

## How a request is built

Every request goes through `LanguageModels` (`respond`), which resolves the
model once and adds what a feature does not have to think about:

1. **The person's locale, first.** "The person's locale is en_AU." opens the
   instructions for every locale but U.S. English — language and region only,
   without the calendar or numbering keywords an identifier can carry. This
   is Apple's exact phrase ([*Supporting languages and locales with
   Foundation Models*](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models):
   "Start with the exact phrase in English").
2. **The language to answer in, twice**, for the four features whose answer a
   person reads: "You MUST respond in German." after the locale phrase and
   again after the feature's own instructions.
3. **Sampling by feature**: greedy for everything that reads, sorts or fills
   in a table; the model's own for the three narrators.
4. **No tools**: `toolCallingMode = .disallowed`, since no feature registers
   one yet.
5. **For a document, a cut that fits**: the document is measured by the
   model as it will be sent, cut in proportion and measured again
   (`LanguageModels.fit`), against the window less the instructions, the
   answer's schema and a reserve for the answer declared beside that schema.

A feature that sends no instructions (the document classifier) still sends
none.

## The prompts

| Feature | Source | Runs on | Sampling | Answer is checked by |
|---|---|---|---|---|
| Document classifier | `DocumentClassifier.classify` — no instructions, guidance in the prompt, first 1,500 characters | device | greedy | falls back to keywords |
| Statement extractor | `StatementExtractor.extract` — 1,000 characters a request | device | greedy | payee and amount must be printed in the slice; a row may not be reported more often than the page prints it; signs re-derived from the balance column; a failure of the model itself stops the run |
| Invoice analyser | `InvoiceAnalyzer.analyze` | the person's choice | greedy | line items reconciled against the printed total; says when only the first part was read |
| Dividend extractor | `DividendExtractor.extract` | the person's choice | greedy | `DividendReconciler` against the figures printed in the whole statement |
| Attachment insight | `AttachmentInsight.analyze` — first 1,600 characters | device | greedy | category must be in the chart offered |
| Categoriser | `TransactionCategorizer.suggest` — exactly one answer per transaction | device | greedy | category must be one that was offered; money out is never offered income |
| Budget advisor | `BudgetAdvisor.suggest` — exactly one line per category | the person's choice | greedy | category must be one that was offered; averages if the model will not write a plan |
| Review slide | `ReviewNarrator.story` — a change goes in words on the line of the figure it is a change in | the person's choice | model's own | `FigureGrounding`; clean prose; must not call unchanged what the slide says changed; language; three drafts |
| Report notes | `ReportNarrator.narrate` | the person's choice | model's own | `FigureGrounding`; clean prose; language; three drafts |
| Forecast outlook | `ForecastNarrator.narrate` | the person's choice | model's own | `FigureGrounding`, including the dates; clean prose; language; three drafts |

"The person's choice" is the device in every build so far: Private Cloud
Compute needs an entitlement no build has (deferred.md §3a).

It is also the device for any request that no command has named. A feature
runs on the person's choice only inside `LanguageModels.permittingOffDevice`,
entered by a command with the list of features it may send
(`IntelligenceCommand` in FeatureUI); the same list is what the view beside
the command reads to say where it runs. Eight commands have one:

| Command | May send | Also runs, always on the device |
|---|---|---|
| Split from Invoice; Smart Import's invoices | invoice analyser | the categoriser, for each line item the invoice read finds; the document classifier (Smart Import) |
| Smart Import's dividend statements | dividend extractor | document classifier |
| Match Attachments | dividend extractor, invoice analyser | the categoriser, for line items; attachment insight, as the fallback for a file whose invoice pass placed nothing |
| Categorise from Attachment — the Attachments panel's button, and linking a document to an existing transaction | dividend extractor, invoice analyser | attachment insight, which is what chooses the category; the categoriser, for line items |
| Suggest Budget | budget advisor | — |
| Forecast outlook | forecast narrator | — |
| Report commentary | report narrator | — |
| Review deck story | review narrator | — |

Auto-Categorise (its Read Attachments pass included), an import's category
suggestions and a PDF imported as a bank statement have no command: nothing
in them can leave. (The Record Dividend sheet can read a statement itself and
would do so as the second row's command, but Smart Import — the only thing
that opens it — hands it one already read.) What stays on the device is a
matter of command, not of document: a bank statement picked in Match
Attachments is read as an invoice, like any other file.

## What a token costs

Measured with the model's own `tokenCount(for:)`, synthetic text
(`TokenSamples` in `LanguageModelsTests`; `LiveBudgetTests` asks again):

| Text | Characters | Tokens | Characters a token |
|---|---|---|---|
| English prose | 2,200 | 382 | 5.8 |
| German prose | 2,040 | 462 | 4.4 |
| Japanese | 680 | 361 | 1.9 |
| Chinese | 500 | 321 | 1.6 |
| Invoice lines | 3,029 | 1,550 | 2.0 |
| Bank-statement rows | 2,679 | 1,760 | 1.5 |
| Rows of digits | 1,891 | 1,772 | 1.1 |

Every digit is a token, and so is nearly every mark of punctuation. The
count itself is cheap — 35 to 85 ms for anything from 6,000 to 140,000
characters, after a first call of about 370 ms — so `fit` asks the model
rather than estimating. `TokenBudget.estimate` is what stands in where a
model has a window and no counter; its per-character weights are fitted to
this table so that it is never under the model's count (1.08× on rows of
digits, 1.65× on English prose).

## What the 27 model did, and what changed because of it

Each of these was found by running the prompts, not by reading them.

**The locale phrase belongs at the start.** Appended to the end of the
dividend extractor's instructions, it made the model refuse the synthetic
dividend statement — three runs in three. At the start: three in three pass,
with every other live test. With no phrase: pass. The 26-era wording had
already shown that these prompts sit close to the guardrail; the position of
one sentence was enough to cross it.

**The language order, by placement.** The review slide's own instructions
and facts, eight drafts for each placement in each language (224 requests),
each answer's language judged by script for Japanese and Chinese and by
whose function words the sentence is made of for the rest — not by the
recogniser the code uses (`FL_LANGUAGE_SURVEY`, `LanguageOrderSurvey`):

| "You MUST respond in X." | German | French | Spanish | Italian | Japanese | Brazilian Portuguese | Simplified Chinese |
|---|---|---|---|---|---|---|---|
| Nowhere | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Start of instructions | 5 | 2 | 4 | 7 | 8 | 1 | 3 |
| End of instructions | 6 | 2 | 7 | 8 | 8 | 8 | 8 |
| Both | 8 | 5 | 8 | 8 | 8 | 8 | 8 |

Out of 8. "Both" is what ships. Without the order nothing comes back in
the language at all, so the locale phrase alone does not do this job.

A first table here, taken earlier the same day, was measured with
`NLLanguageRecognizer` over the whole answer. That recogniser calls a
Japanese or Chinese sentence English when it quotes a Latin account name,
and a French slide English when it is mostly labels, so that table measured
the instrument as much as the model; it is replaced, not kept.

**French follows the language of the facts.** French is the one language
"both" does not settle. The same slide, sixteen drafts each way: with its
labels in English ("Total spending", "Groceries"), **10 of 16** in French;
with the same labels in French ("Dépenses totales", "Alimentation"),
**16 of 16**. The review decks' labels are literals that were never
localized, so today the model is always handed English. Until they are
(deferred.md §3a, the next change), the narrators do not trust the order:
the answer's language is checked, and a sound answer in the wrong language is
kept in hand while the model is asked again — three drafts at most — then
shown if nothing better arrives.

**A ceiling is not a count.** The budget advisor's answer was capped at forty
lines. Asked in Japanese about two categories, the model filled the other
thirty-eight with categories of its own and overflowed the window after 221
seconds, twice in two. In English it stopped at two. The request is now made
against the same schema with that one count fixed to the request's
(`LanguageModels.countedSchema`; 23 seconds, two lines). The categoriser's
cap of eight became an exact count the same way.

**Narrators invent figures; only one of three was being checked.** The report
narrator wrote, in English, that income exceeded expenses by a figure 31.70
away from the net income it had been given, and in Chinese quoted two
percentage shares it had worked out, one of them wrong. The review slide's
check existed but read only English number formats, so true figures written
the French way ("66 611 AUD", "8,4 %") or the Spanish way ("66.611 AUD")
were rejected. One check, `FigureGrounding`, now serves all three narrators.

**What the check lets through, surveyed.** Three raw drafts from each
narrator in each of eight languages — 72 drafts, 240 sentences — each printed
with the check's verdict and read (`FL_GROUNDING_SURVEY`, `GroundingSurvey`).
The check rejected ten sentences. Seven were the model's own inventions and
are now regression tests:

- percentage shares it had computed ("占总开支的38.4%", "占总额的100%",
  "约38%") — three, all Chinese;
- a rent of 1,800 for a rent of 2,600, in Spanish;
- 12,480.55 and 25,680 "rounded" to 12.501 and 25.700, in Portuguese;
- two Japanese review slides that ended in the debris of the model's own
  output format: a closing bracket, `<ctrl46>`, a code fence and the start of
  a second JSON object.

Three were the check's mistake: every Japanese forecast headline wrote the
horizon as "90日間", and 日 was being read only as a day of the month. It
counts days as well, and is now read as both.

**A number is read with its unit.** The first shared check tried every
scaling on every number, so a total of 66,610.82 made a bare "67" true —
and an invented "67%" with it; it skipped any number it could not read, so
the invented figure above passed once written "24.000,98"; and it let a
forecast's day and month numbers stand in for anything ("15%" was the 15th
of August). Now a number followed by a percent sign has to be one of the
percentages given, thousands and millions are read only where the prose says
"k" or "m" (万 and 億 likewise), an amount with the currency after it is
never a date, and a number that cannot be read is not thereby true. Ratios
and counts reach the model as ratios and counts: the Highlights slide used
to say "Savings rate percent: 26.5 AUD".

**Dates have to arrive already translated — and in the calendar the list
uses.** Given "15 Aug" and told to answer in Japanese or Chinese, the model
wrote "15月15日" and "1月1日". The forecast's dates now reach it formatted
in the person's locale but always in the Gregorian calendar, which is what
the forecast list beside the outlook shows: a locale brings its own calendar
with it, and the same formatter printed 15 August as "2 Rab. I" for a Saudi
region.

**A figure the model wants, it should be given.** French forecast headlines
claimed an increase "de 135 AUD" between balances 1,351 apart, four drafts
in six. The change over the horizon is now one of the facts the model is
handed, so there is nothing to subtract.

**A refusal's explanation is not always an explanation.** Asked why it had
refused the synthetic dividend statement, the model returned the extraction
it had declined to give — a JSON object with the security, the date and
every amount. So the explanation is asked for only where one document is
being read and a person is waiting, and shown only if it is a short sentence
with no structure and no figures in it.

**Extraction is unaffected by the person's locale** on the synthetic
fixtures: the eight live feature tests pass as a German, French, Spanish,
Italian, Japanese, Brazilian Portuguese and Simplified Chinese reader — one
run each after the rework, `FL_LOCALE=de_DE swift test --filter
LiveModelTests` and so on.

**Real documents.** The three harnesses that read the owner's own archive
(`FL_STATEMENT_PDF`, `FL_SCAN_PDF`, `FL_RECEIPT_DIR`; local only, and they
report counts, never contents) pass after the rework: statements, 8 tests in
107 seconds; scans and receipts, 2 tests in 34 seconds.

**A change goes in words, with the figure it is a change in.** The review
slide's facts used to end with a list of their own — "Changes: - Total
spending: -8.4% vs prior period" — and the model mostly did not connect it
to anything. Of 128 drafts of that slide in eight languages, the number check
passed 107; 25 of those quoted the change, and 59 said spending was "stable",
"unchanged", had "remained at" its total or that there was "no change" —
sixteen of sixteen in Italian. A check that reads numbers finds nothing wrong
with that. The change now goes on the figure's own line, as a word and a
percentage ("- Total spending: 66610.82 AUD — down 8.4% on the prior
period"; on a line of its own, in the same words, where what changed is not
itself a listed figure), and the instructions ask for the direction and the
percentage where one is given and forbid describing a change, or stability,
where none is. Measured on 208 drafts across three slide shapes — a spending
total, a net worth beside five other figures, and a change with a line of its
own:

| Slide | Drafts | Declined: a number | Declined: format debris | Shown | Of those shown, quoting the change | Calling it unchanged |
|---|---|---|---|---|---|---|
| Spending (old prompt) | 128 | 18 | 7 | 48 after the word check below; 107 before it | 25 | 59 |
| Spending | 112 | 14 | 5 | 96 | 96 | 0 |
| Net-worth bridge | 48 | 5 | 2 | 43 | 43 | 0 |
| Highlights | 48 | 6 | 0 | 42 | 25 | 0 |

(A draft can be declined for both reasons. On the opening slide a story says
"net worth rose 31.2k" as readily as "8.2%", which is why not every one
quotes the percentage, and why quoting it is not required.) Behind the
prompt there is now a check as well, because the prompt's effect is the
installed model's and that model changes with the system: a story about a
slide that lists a change of a percent or more, which does not quote it and
uses one of the model's own ways of saying "nothing changed" in the eight
languages, is declined (`ReviewStoryValidator.contradictsAListedChange`). It
is the one check here that reads words rather than numbers, and it is kept
that narrow. Replayed over every draft above (`SurveyReplay`, which puts a
saved survey through today's checks without asking the model anything), it
declines the 59 and none of the 181 written under the new prompt.

**A figure cut off is the figure.** The number check held the model to
rounding: 31,150.40 could be "31.2k" and not "31.1k", and 66,610.82 could be
"66,611" and not "66,610". Twelve of forty-eight drafts of the opening slide
were declined for a "31.1k" with every other number in them right. A figure
may now be rounded to the precision it is written at *or* cut off at it —
neither invents anything — and still not written above what rounding gives
("12.49k" for 12,480.55, which the model does write) or merely somewhere
near.

**German thousands.** Asked for thousands "as k", the model wrote a German
reader "66.61 T$" in two drafts of eight — the accountant's form, as in T€
and TEUR — and both were declined as figures nobody had listed. The check
reads a capital T before a currency symbol or code as thousands (and not in a
book kept in paʻanga, whose own symbol is T$).

**What these checks cannot see.** Every number in a story being one of the
facts does not make it said of the right thing. Of 96 forecast headlines —
64 on a balance that rises and 32 on one that falls — none gave the wrong
direction, with the change handed over as a bare signed number, so that
prompt is unchanged. But four said the balance would end "higher by 9,420",
which is the closing balance and not the rise (Spanish twice, Italian twice),
and one German headline called a falling balance "negative" when its lowest
point was 2,480. And three review drafts in Portuguese wrote that expenses
were "above the opening value" — true numbers in a sentence that means
nothing, and drafts the stricter rounding had been declining only by
accident. Nothing here catches those; they are the reason the commentary is
marked as Apple Intelligence's and sits beside figures that are not.

**The live language tests ask three times.** They assert that the model can
write something the checks accept in each language, and used to fail when one
narration — three drafts — could not. That is the narrator working: it says
so, and the slide keeps its own headline. With half of all drafts declined in
one language, three in a row is one narration in eight, and a sweep before a
commit that had not touched the package failed on it in German and Japanese.
A narration is now asked for up to three times; nine drafts all declined
still fails.

## What the instrument showed

The Foundation Models instrument, recorded on 12 October 2026 with the
owner's consent to its warning that prompts and responses are stored
unencrypted in the trace and the system log. It was pointed at the test
process alone — the eight live feature tests, whose documents are synthetic
— not at every process on the Mac:

```bash
xcrun xctrace record --template 'Foundation Models' --no-prompt \
  --env DYLD_FRAMEWORK_PATH=… --env DYLD_LIBRARY_PATH=… \
  --launch -- swiftpm-testing-helper --test-bundle-path …/FinvestLensIntelligenceTests \
  --filter LiveModelTests …/FinvestLensIntelligenceTests --testing-library swift-testing
```

(`swift test` cannot be the launched process: the tests run in a helper it
spawns, and the helper needs the two library paths `swift test` gives it.
An all-processes recording works too, and then takes a quarter of an hour
to save.)

| Request | Prompt tokens | Answer tokens | To first token | Whole request |
|---|---|---|---|---|
| Statement slice (one synthetic page) | 644 | 241 | 0.97 s | 4.76 s |
| Classifier (three documents) | 225–291 | 15–17 | 0.25 s | 0.50 s |
| Categoriser batch | 316–335 | 27–61 | 0.27–0.30 s | 0.78–1.44 s |
| Invoice | 518 | 115 | 0.39 s | 2.25 s |
| Dividend statement | 496 | 89 | 0.35 s | 1.82 s |
| Budget, two categories | 421 | 185 | 0.33 s | 4.17 s |
| Report notes | 302 | 77 | 0.30 s | 2.06 s |
| Forecast outlook | 311 | 101 | 0.24 s | 2.43 s |

What it confirmed, and what it showed that nothing else had:

- The instructions the model receives open with "The person's locale is
  en_AU.", and the classifier's session has none — as intended, and now
  seen rather than inferred.
- Answers are small beside the reserves kept for them: an invoice of four
  lines is 115 tokens against a reserve of 2,000 (fifty lines), a dividend
  89 against 300, a classification 17 against 64.
- **Cached tokens: 0 on every request.** Each request is a fresh session,
  so the model re-reads the instructions every time. For a single document
  that costs a quarter of a second. For the two features that make requests
  by the dozen with identical instructions — a statement read slice by
  slice, an import categorised eight rows at a time — it is the same
  quarter of a second and the same three hundred tokens on every one. This
  is what a session held across a batch (a `DynamicProfile` whose history is
  cut back to the instructions before each request) is for; see
  deferred.md §3a.

## What has not been run

- **Private Cloud Compute.** Nothing can be sent to it without Apple's
  entitlement; a request without it ends the process. Three things wait on
  it: whether these prompts behave there as they do on the device, which
  reasoning level each feature should ask for, and how the daily allowance
  holds up in a batch.
- **A device.** Every run was on a Mac.

## Changelog

| Date | Change |
|---|---|
| 9 Oct 2026 | Classifier guidance moved from instructions into the prompt (any instructions tripped the 27 guardrail on an invoice). |
| 12 Oct 2026 | Locale phrase first; language order twice for prose; exact row counts for the budget advisor and categoriser; grounding for report and forecast narrators and number formats per language; forecast dates localised and the change given as a fact. |
| 12 Oct 2026, after review | Documents cut by the model's own count; numbers read with their units, and an unreadable number rejected; ratios and counts given as ratios and counts; forecast dates Gregorian; the locale named without keywords; language order re-measured with an independent oracle; one draft policy for the three narrators; a refusal's explanation shown only if it is one; statements read on the device whatever is chosen. |
| 12 Oct 2026, after the review of `73b2bd6` | Where a request runs is granted by the command, not assumed from the feature: Categorise from Attachment was gated and described as attachment insight (device) while it also ran the dividend extractor and the invoice analyser (the person's choice). No build could reach Private Cloud Compute, so nothing was sent. Every command that can leave the device now shows where it runs beside its control; the Settings sentence names what stays on the device by command. No prompt changed. |
| 12 Oct 2026, from the survey that followed | Review slide: a change goes in words on its figure's line, and the instructions ask for it where one is given and forbid describing one where none is ("stable" included); a story that calls unchanged what the slide says changed is declined. Number check: a figure may be cut off at its precision as well as rounded to it; German T€ / T$ / TEUR read as thousands. Forecast prompt measured on a rising and a falling balance and left as it was. |
