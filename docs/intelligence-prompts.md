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
4. **No tools**, with one exception: `toolCallingMode = .disallowed` for
   every request but the one that shows the model a picture, which is
   offered Vision's readers and may call them.

   Both are declared by the session's profile
   (`LanguageModels.FeatureProfile`, a `LanguageModelSession.DynamicProfile`:
   instructions, model, sampling mode, tool-calling mode), not passed with
   each request.
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
| Invoice analyser | `InvoiceAnalyzer.analyze` — as text; and, where one document is read and it is a picture, the picture first with Vision's `OCRTool` (and `BarcodeReaderTool` if Vision finds a code on the page) | the person's choice | greedy | line items reconciled against the printed total; says when only the first part was read; of two readings, the one whose total is printed on the page and whose lines add up; a reference only as the barcode reader returned it |
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

**A true number said of the wrong thing.** Every number in a story being one
of the facts does not make it said of the right thing. Of 96 forecast
headlines — 64 on a balance that rises and 32 on one that falls — none gave
the wrong direction, with the change handed over as a bare signed number, so
that prompt is unchanged. But four said the balance would end "higher by
9,420", which is the closing balance and not the rise ("supera el saldo
inicial en 9420", "è superiore di 9420 rispetto al saldo iniziale" — Spanish
twice, Italian twice), and one German headline gave a balance whose lowest
point is 2,480 "einen negativen Saldo". And three review drafts in Portuguese
put expenses of 66.6k "acima do valor inicial de 381,2 mil AUD" — above an
opening net worth almost six times larger, or above themselves.

The first measure is the prompts, because a check can only turn a wrong
story into no story. Each narrator now hands the model what each figure *is*
in words on its line, and the relations it has — the shape the review slide's
prompt was given for changes, above:

- **Forecast:** "Projected balance at the end: 9420 AUD — up 1351 AUD on
  today's balance"; "Recent months, on average: income exceeded spending by
  450 AUD a month"; "Rent — 2600 AUD out, leaving 5469 AUD"; "Scheduled over
  the horizon: 6315 AUD in, 4964 AUD out". No minus signs: a sign is what the
  model echoed back as "negative" of things that were not. The balance each
  movement leaves and the horizon's totals were added after the review of
  17 October: four of the five outlooks the checks declined that day had
  worked one of them out for itself.
- **Review slides:** a role on each figure the deck knows — "as at the end
  of the period", "as at the start of the period", "money in over the
  period", "money out over the period", "the change over the period", "value
  added over the period, not money in" — passed by the deck (`FigureRole`);
  and the relation the deck computed a figure from, where it is one of its
  figures less another ("Net surplus: 24032.68 AUD — Income less Expenses"),
  passed by the deck too (`FigureRelation`). The roles were first worded as
  kinds — "a balance at a point in time" — and the model took the noun for a
  name: net worth became "balance", "saldo", "余额" in 13 or more of 64 opening
  and bridge drafts, against 2 before. The relations were first worked out
  from the numbers, as the one of a triple smaller than both others, which
  names the wrong pair whenever the difference is not the smallest: expenses
  as "Income less Net surplus" at a savings rate over a half, liabilities as
  "Assets less Equity" on most balance sheets. A valuation of nothing has no
  role; it had been told it was a rise. The shared instruction that "money
  in and money out are totals for the period" went too: the investment
  deck's Money In is a lifetime total.
- **Report notes:** the roles and relations each report computed — a balance
  sheet's three balances and equity as assets less liabilities, an income
  statement's net income as income less expenses, the Net Worth report's
  start, end and change — and each line's side. A cash flow lists its sources
  and destinations unsigned, and without a side its commentary had salary as
  an expense.

Behind the prompts, four checks of words (`FigureAttribution.swift`), each as
narrow as the unchanged-word check above, each declining a draft rather than
repairing it, and each reading the numbers the number check read —
`FigureGrounding.resolve` decides what a sentence's numbers are once, for
both:

- **A balance given as the size of a change** — a word of change right beside
  a balance ("by", "um", "supera … en", "superiore di", "uma queda de",
  "增长", "の増加"). A number reached *to* ("aumenta a 9420", "增长至9420"), a
  range ("cai de 9420 para 6105"), and a balance after a preposition that also
  means "of" or "at" with no word of change before it are left alone.
- **A change said the other way** — a word that says up beside a change that
  went down, or the reverse ("una disminución de 31.150,4 AUD" of a net worth
  that rose by that). Comparatives that measure a difference ("1100 AUD
  上回って", "1,100 more than income") are not words of direction.
- **A negative balance** said of a forecast that never goes below zero —
  not "einen negativen Saldoänderungstrend", a falling trend, which is true,
  nor any sentence with a negation in it.
- **A comparison its own figures contradict** (all three narrators): the
  first figure the subject, the second within a few words, and the larger one
  not the one the words say — including the Japanese order "AにたいしBが上回った".
  A figure right beside "above" is the size of a difference and is not read.

The review of 17 October ran each check against sentences built to break it,
with a control beside each, and found the words matching too much or too
little in ways no survey draft had shown yet. Each is fixed and has a test
built from the sentence:

- a negation was matched as characters anywhere, and in any language read —
  "未来90天" ("the next ninety days"), "不断", "はず", "わずか", and English
  "no" in the Portuguese "no final de agosto" — so false negative balances
  were let through; it is matched as a word, in the language of the words it
  negates, near them in Chinese and Japanese. "won’t" with a curly apostrophe
  was not a negation at all.
- "falls by 1,351 to 9,420" was read as a range and switched off two checks;
  a range now needs a word that can mean "from", and an amount — not a date —
  at its other end.
- English direction words were only the inflected ones; "will fall by",
  "expected to decline by", "up by", "down by" said no direction.
- what follows a number was stepped over by a list of its own, which missed
  "A$" after a number, "Millionen", "millones de AUD" and thin spaces; it
  now steps over what the number check reads as a unit.
- Chinese "A高于B" and "A比B多", and any comparison with its first figure in
  brackets, were never read; Japanese "より少ない" never counted; "quarterly",
  "sometimes" and 上半期 counted as multipliers; a figure written with a
  minus sign was compared as a magnitude.
- Spanish and Portuguese "su punto más bajo en 3105" (the lowest point) and
  "supera al inicial y se sitúa en 9420" (a second clause) were taken for
  changes; "un saldo negativo de 1100 AUD al mes", the monthly net, for a
  balance below zero.
- the number check took a run of numbers apart again at every separator: a
  draft with twenty numbers none of which was a fact took 25 seconds to
  decline. Each stretch of a run is decided once, and the check stops at the
  first number that is not a fact.

**Measured on three surveys, read draft by draft** — counting what the checks
decline is half a measurement, and the first version of this section was
written from it alone. Reading every draft of a fresh survey on 17 October
2026 (543 drafts, the old prompts) found that the checks then declined one
draft while about a dozen misstated something; the review's own reviewers
found it, not the count.

| | 12 Oct (old prompts, recovered) | 17 Oct (old prompts) | 17 Oct (new prompts) | 17 Oct (after the review) |
|---|---|---|---|---|
| Drafts | 185 | 543 | 543 | 541 |
| Declined by these checks | 8 | 6 | 2 | 1 |
| Of those, wrongly | 0 | 0 | 0 | 0 |
| Opening and bridge slides misstating, read by hand | — | 13 of 64 | 5 of 64 | 6 of 64 |
| … of which "expenses above income", Japanese | — | 4 of 4 | 0 of 4 | 0 of 4 |
| Net worth called a "balance", "saldo", "余额" | — | 2 of 64 | 13 of 64 | 0 of 64 |
| Bridge's change put down to the wrong cause | — | — | about 6 of 32 | 1 of 32 |
| Forecast outlooks working out a figure the projection holds | — | 1 | 4 | 0 |
| Report notes with salary as an expense | — | — | 4 | 1 |

The last column is the survey after the review's changes (17 October,
four drafts of each in each language), and it differs from the others in one
more way: the slides and the report reach the model with the app's own labels
in each language, as they do in the app, where the earlier surveys sent
English labels everywhere. Its one decline is right (an Italian headline
giving the closing balance as the growth). Two things it showed were the
number check's, and are fixed: "2025–26年度", the period written the Chinese
way, read as the year 26 (four report notes declined), and "31.1k増加", a
"k" before a Japanese word read as no unit (one headline). What it still
shows is the residue above — a cause or a name the model gets wrong, with no
word a check could read: three Chinese slides inventing a stability or a cause,
"trimestre précédent" for the prior year, salary called an expense once.

On the review slides the prompt is what helped: the opening slide went from
about six misstatements in 32 to none, and the bridge from about seven to
four, two of them declined. On the forecast headlines and the report notes
no change can be told at four drafts a language — three and about five
misstatements under the new prompts, one and about five under the old.
Every decline in all three surveys was read and is a real misattribution;
the checks were changed once on that reading, when the first version of the
direction check took 上回る — "exceeds" — for a word of rising and declined a
true sentence.

What neither the prompts nor the checks reach is a figure given the wrong
name or the wrong cause, with nothing about it a word could read as wrong:
the salary called rent, the whole change put down to the valuation movement,
"la spesa maggiore è rappresentata dallo stipendio". About 17 of the 543
drafts under the new prompts are like that — roughly three in a hundred.
That is why the commentary stays marked as the model's and sits beside
figures that are not.

**The decks' own words are in the reader's language, and that is no longer
what the model's language turns on.** Before the change above, the review
slide's facts in English got a French reader an answer in French ten times in
sixteen, and the same facts with French labels sixteen in sixteen — so the
decks' 133 bare literals looked like the root of it. They are localized now
(a slide's labels, headline and footnote come from the string catalog, and so
do the labels in its facts). Re-measured with the change in words: sixteen in
sixteen with English labels as well. The decks needed it for what is on the
screen; the model, on this slide, no longer does.

**The live language tests ask three times.** They assert that the model can
write something the checks accept in each language, and used to fail when one
narration — three drafts — could not. That is the narrator working: it says
so, and the slide keeps its own headline. With half of all drafts declined in
one language, three in a row is one narration in eight, and a sweep before a
commit that had not touched the package failed on it in German and Japanese.
A narration is now asked for up to three times; nine drafts all declined
still fails.

**One session for a batch is not worth keeping.** A statement is read a
thousand characters a request and an import is categorised eight rows a
request, all under the same instructions, so a session kept for the batch —
with a profile's stateless history transform sending each request without the
ones before it — should let the model reuse what it has already worked out
about the instructions. It was built and measured, three rounds each way:

| Batch | A session for each request | One session kept | Same answers |
|---|---|---|---|
| Categoriser, 6 requests (48 rows, 40 categories) | 16.80, 16.85, 16.82 s | 16.75, 16.78, 16.80 s | every run |
| Statement, 3 requests (60 rows) | 84.95, 85.73, 83.57 s | 85.19, 85.17, 82.98 s | every run |

The instrument says why. The prefix cache does engage — 381 of about 670
prompt tokens were served from it on every request of the kept session after
the first, and none with a session each — and it takes the part of a request
before generation from about 455 ms to about 440. The request then generates
for 2.3 seconds (some 130 tokens). So a session is still made for each
request, and the profile declares it; the pool of kept sessions was removed.

Two things the probe for it established about `historyTransform`, which the
documentation does not say. The history it is handed is everything about to
be sent: the instructions entry first, the prompt being asked last, every
earlier prompt and answer between. And returning an empty array is therefore
an error, not "no history" — "Transcript must end with a .prompt or
.toolOutput entry".

**A picture, with Vision's tools — and where it is worth it.** The model
sees (`capabilities` includes `vision`), and Vision's `OCRTool` and
`BarcodeReaderTool` can be offered to it. Whether to show it a receipt was
measured before it was built, on fifteen invented pages — a supermarket
receipt, a restaurant bill and a tabular invoice, each drawn clean, as a
photograph, in a handwriting face, faint at low resolution, and badly tilted
— read four ways (`ReceiptImages.swift`; the probe's four routes, then
`PictureSurvey` for the code the app runs):

| Route | Vendor | Date | Total | Line items (the 10 pages where which lines count is not arguable) | Median |
|---|---|---|---|---|---|
| Vision's text, read by the model (the route until now) | 15 | 15 | 13 | 6 | 3.0 s |
| The picture alone | 15 | 14 | 13 | 6 | 3.2 s |
| The picture, with `OCRTool` offered | 15 | 15 | 15 | 10 | 4.5 s |
| Vision's text and the picture, no tool | 15 | 15 (three in the wrong format) | 15 | 8 | 2.6 s without the recognition |

The picture alone is no better than the text and reads digits worse: a wrong
date and a wrong total on the photographed pages, where every wrong figure is
a plausible one. The picture *with the text reader as a tool* was right on
every field of every page; the text alone took the subtotal for the total on
the photographed invoice and the faint one, and got the invoice's line items
wrong in four of its five drawings.

On real receipts the difference is smaller. Sixteen photographs sampled
evenly from the owner's archive, read both ways by the app's code, tallies
only: each route read fifteen; in all fifteen the two gave the same total,
and every total was a figure printed on the page; the lines added up to the
total in nine of the text's readings and ten of the picture's; 48 seconds
for the text and 94 for the picture.

So the picture is shown where one document is read and a person is waiting —
Split from Invoice, Smart Import's invoices, Categorise from Attachment —
and not in Match Attachments, which is matched on totals, by the dozen. The
rules around it:

- The picture is read first. The text is read as well only if the picture's
  total is not a figure printed in the document (as Vision read it); and of
  two readings the picture's is kept unless the text's stands better — total
  printed, then lines adding up. Asking for the text whenever the picture's
  lines did not add up was a second request on most documents (a tax line is
  enough) that changed the answer on none of the fifteen, and took the
  median from 9.0 seconds to 7.1 — against 3.7 for text in the same run.
- The barcode reader is offered, and a reference asked for, only where
  Vision has already found a code on the page. Offered and unasked, the
  model did not call it; asked, it returned a QR code's payload exactly. A
  reference is kept only if it is in what the tool returned.
- A picture's tokens cannot be counted (`tokenCount(for:)` throws for a
  prompt with an attachment), so a picture is not fitted to the window. A
  request that overflows fails like any other, and the text is there.
- The tools are in an overlay the iOS Simulator's SDK does not have; there,
  and for a model that does not see, the request is not made at all.

**A photograph knows which way up it is, and the decoder was not asking.**
A phone stores a portrait shot as landscape pixels with a note of the turn.
The image was decoded without it, so Vision was given a receipt lying on its
side: it still found the characters — which is how this went unnoticed — but
not the lines. A fourteen-line receipt came back as thirty-three fragments
and a twelve-row invoice as four runs, and a line is what joins an item to
its price. The turn is applied now, for recognition and for the picture the
model is shown; with it removed again, all three test receipts fail.

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

## A model the person supplies

Settings ▸ Apple Intelligence can put an open model of the person's own in
Apple's place (`FR-AI-14`): a folder of MLX models they point the app at,
and one of them chosen. The prompts are the same. Four things about the
*request* are not, each because of something read or measured.

| | |
|---|---|
| Date | 12 October 2026 |
| System | macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Apple M3 Max, 128 GB |
| What runs it | mlx-swift-lm at `3e6ea1e` (`MLXFoundationModels`), mlx-swift 0.31.6, swift-transformers 1.3.5 |
| Models asked | `gemma-4-26b-a4b-it-4bit` (14 GB) and `Qwen3.8-27B-4bit` (15 GB), both `mlx-community` conversions, as they lay in the Hugging Face cache |
| Declared as | guided generation and nothing else: shown no pictures, offered no tools, not asked to reason |
| Window planned against | 16,384 tokens on a Mac, 8,192 elsewhere. There is no token counter for these, so a document is fitted by the estimate |

Every figure below is from invented documents — five invoices and receipts
and three statement pages written for the purpose, and the pages
`LiveModelTests` asks Apple's model about.

### 1. The answer's schema goes into the instructions

Apple's models are given a request's schema with the request, and the model
reads each `@Guide`. MLX uses the schema as a grammar and nothing else: its
adapter makes a system message of the instructions and a user message of the
prompt, compiles the schema into a constraint on the tokens that may come
next, and never shows it to the model
(`MLXFoundationModels/TranscriptConverter.swift`, `runSchemaGeneration`). The
model writes the right keys knowing them only by name — and the guides are
where a feature says that a date is `yyyy-MM-dd`, that money out is
negative, that a reference is empty when the page shows none.

So the schema is written out (`SchemaGuide`). **In what form was decided by
a survey, and the first form tried was the wrong one.** Forty-four things to
get right — vendor, date, total, the number of lines and their sum, for five
invoices; each row's date and amount, the row count and the date format, for
three statement pages:

| What the model was told about the answer | Gemma 4 26B | Qwen 3.8 27B |
|---|---|---|
| Nothing (the request as MLX makes it) | 35 of 44 | 28 of 44 |
| A list in words — `- total: Grand total of the invoice as printed` — after the instructions | 31 | 37 |
| The same list, before the instructions | 27, and one answer that ran for minutes and did not decode | 37 |
| The schema as `JSONEncoder` writes it, after | 43 | 44 |
| **The schema with its properties in declared order, after** | **44** | **44** |
| The same, before | 44 | 44 |

With nothing said, dates came back as printed ("14 March 2026", "03 May"
with no year — which no row survives), the whole row was copied into
"reference", and quantities stayed on the item names. A list in words was
worse than that on one model: `name: meaning` reads as the *form of the
answer*, and the model wrote `vendor: ` and `lineItems: [` into string
values while the grammar forced JSON around them. JSON Schema says the same
things in the notation the model is being held to.

What is sent is the schema's own encoding with two changes: properties in
the order the type declares (which is the order the grammar makes the model
write them in — the encoder's order is a dictionary's, different on every
launch), and three keys left out that say nothing (`x-order`, `title`,
`additionalProperties`). `SchemaGuideTests` holds the text for a statement
page word for word.

### 2. The person's locale goes last, not first

For Apple's model the locale phrase opens the instructions, and at the end
it made the 27 model refuse a document (above). Gemma is the other way
about. The same eight documents, asked twice each (76 things to get right a
form), with "The person's locale is en_AU." in four places:

| Where the phrase was | Right |
|---|---|
| First, as Apple's model is given it | 74 of 76 — and 72 of 76 through the app's own request path |
| After the feature's instructions, before the schema | 76 |
| **Last, after the schema** | **76** |
| Left out | 76 — and 76 of 76 through the app's own request path |

Six wrong in 152 with the phrase first, none in 304 without it there: an
amount or a payee came back as `": "`, and on one page the rows stopped
after the second. The same request did not always fail the same way — one
pass lost two rows, the next wrote all four with a Cyrillic letter in a
payee — so a supplied model's answer is not reproducible request for
request, although its sampling is greedy.

So for a supplied model the order is: the feature's instructions, the
schema, the locale (`LanguageModels.suppliedInstructions`). The language
order for prose is at both ends, as for Apple's model; that has **not** been
measured on a supplied model, in any language but English.

### 3. An answer has a ceiling

Left alone, MLX stops an answer at 4,096 tokens. On a 26-billion-parameter
model that is three minutes, and it is what one badly formed guide cost in
a trial: 186 seconds of a string value filling with the model arguing with
itself until the tokens ran out. Each feature's request to a supplied model carries a
ceiling of some three times its largest real answer
(`IntelligenceFeature.suppliedAnswerCeiling`: 128 tokens for a document's
kind, 1,024 for a slide, 3,072 for a statement slice, 4,096 for an invoice
or a budget). An answer that reaches it comes back cut short, fails to
decode, and is reported as a failure. No request to Apple's models sets one:
their own window is the bound.

### 4. An answer is put right before it is read, and read again if it lost its place

Two things go wrong that are the model's and not the page's, both seen on a
120-row statement:

- **Whitespace spelt out.** Part-way through an answer the model starts
  writing a gap as a backslash and an "n": `CARD PURCHASE\n1013 SYDNEY`
  where the page has a space. Twenty-seven of the 102 rows written came back
  that way in one run, and every one was dropped — a payee with a stray "n"
  in it is not a name printed on the page. In every string of a supplied model's answer
  a line break or tab, real or spelt out, becomes a space
  (`LanguageModels.tidied`), once, at the seam.
- **A field's form where its value goes.** A date comes back as `": "`, and
  the rows after it are missing: eighteen of 120 were never written. The
  statement reader takes that as the mark of an answer that lost its place
  (`IntelligenceParsing.isDebris`: the grammar's own punctuation and nothing
  else, or — for a date, an amount or a balance — a bare word and a colon)
  and reads the slice again in two halves, at most twice
  (`StatementExtractor.reading`). The second reading is held until both
  halves are in: if either fails, the first reading is what is kept, checked
  as it always was. A dash where a page shows no amount, or a payee printed
  as "Interest:", is not debris.

The same 120 rows, three ways:

| | Rows kept of 120 | Time |
|---|---|---|
| As first built | 74, 105 and 106 in three runs | 414–454 s |
| With answers put right | 99 and 118 in two runs | (one request a slice: 353 and 391 s) |
| And slices read again | **120**, in both runs made | 499 and 566 s |

Neither is specific to statements in what it guards against, and only the
first is applied everywhere: an invoice or a budget whose answer loses its
place is not asked for again. The second applies to whichever model reads
the statement — Apple's has not been seen to write debris, and would be read
again if it did.

### What each feature did

`SuppliedModelLiveTests`, in the app's own test target, points a
`SuppliedModelStore` at a folder, chooses a model the way Settings does, and
calls each feature by its public entry point. On the code as committed,
one request at a time — fourteen tests, all passing on Gemma; Qwen's column
is from the run before the review's fixes, with its long statement run
again after them:

| Feature, on an invented document | Gemma 4 26B | Qwen 3.8 27B |
|---|---|---|
| Statement page, four rows — signed and dated | right, 16 s | right, 23 s |
| Three documents told apart | right, 2.7 s | right, 6.8 s |
| Three transactions categorised, and the same again | right both times, 6 s each | right both times, 11 s each |
| Invoice of three lines, split and categorised | right, 14 s | right, 23.5 s |
| Dividend statement — franked, unfranked, credits | right, 6.1 s | right, 10.6 s |
| A receipt naming a transaction's category | right, 2.2 s | right, 4.8 s |
| Budget for two categories, with reasons | right, 8.8 s | amounts right; one line of two given no reason, in both runs made, 10–11 s |
| Report notes, a review slide, a forecast outlook — each passing the number check | written, 6–8 s each | written, 11–17 s each |
| Statement of 120 rows over three pages | 120 rows, 566 s | 120 rows, 825 s |

The first request after launch also loads the model, and that is in the
first figure it appears in. The times are one run each on a machine doing
other work, and are for scale, not for comparison.

**Nothing was fetched.** The loader is handed a downloader that refuses, and
for a model given as a folder MLX never asks it
(`MLXLMCommon/ModelFactory.swift`, `resolve`); the tokenizer is read from
the folder with `FileManager`
(`swift-transformers`, `Hub.swift`, `loadConfig(modelFolder:)`). Checked from
outside as well: the test host's open network sockets were listed every ten
seconds through a whole run — the model loading and every request above —
and there were none in 105 samples (`lsof -a -p <pid> -i`, which showed four
for another process on the same machine when it was first tried). That is a sample, not
a trace: a connection opened and closed inside ten seconds would not be in
it.

## What has not been run

- **Private Cloud Compute.** Nothing can be sent to it without Apple's
  entitlement; a request without it ends the process. Three things wait on
  it: whether these prompts behave there as they do on the device, which
  reasoning level each feature should ask for, and how the daily allowance
  holds up in a batch.
- **A device.** Every run was on a Mac.
- **A supplied model, beyond what is above.** Two models, of one size, on one
  Mac. Not run: a small model (the kind an iPhone has room for), any model
  on an iPhone or iPad (MLX cannot run in the Simulator), prose in any
  language but English, a document long enough to be cut to fit a supplied
  model's window, and a model asked to reason first or shown a picture —
  neither of which the app does.

## Changelog

| Date | Change |
|---|---|
| 9 Oct 2026 | Classifier guidance moved from instructions into the prompt (any instructions tripped the 27 guardrail on an invoice). |
| 12 Oct 2026 | Locale phrase first; language order twice for prose; exact row counts for the budget advisor and categoriser; grounding for report and forecast narrators and number formats per language; forecast dates localised and the change given as a fact. |
| 12 Oct 2026, after review | Documents cut by the model's own count; numbers read with their units, and an unreadable number rejected; ratios and counts given as ratios and counts; forecast dates Gregorian; the locale named without keywords; language order re-measured with an independent oracle; one draft policy for the three narrators; a refusal's explanation shown only if it is one; statements read on the device whatever is chosen. |
| 12 Oct 2026, after the review of `73b2bd6` | Where a request runs is granted by the command, not assumed from the feature: Categorise from Attachment was gated and described as attachment insight (device) while it also ran the dividend extractor and the invoice analyser (the person's choice). No build could reach Private Cloud Compute, so nothing was sent. Every command that can leave the device now shows where it runs beside its control; the Settings sentence names what stays on the device by command. No prompt changed. |
| 12 Oct 2026, from the survey that followed | Review slide: a change goes in words on its figure's line, and the instructions ask for it where one is given and forbid describing one where none is ("stable" included); a story that calls unchanged what the slide says changed is declined. Number check: a figure may be cut off at its precision as well as rounded to it; German T€ / T$ / TEUR read as thousands. Forecast prompt measured on a rising and a falling balance and left as it was. |
| 12 Oct 2026, the decks | The review decks' labels reach the model in the reader's language (they were English literals). The two month counts on the cash-flow slide go as counts; they went as amounts ("Months positive: 7 AUD"). The decks take dividend figures from `dividendBreakdown`, not by looking them up under the report's English labels. |
| 12 Oct 2026, profiles | Every request's session is built from a `LanguageModelSession.DynamicProfile` that declares its instructions, model, sampling and tool-calling mode; requests no longer carry options. A session kept for a batch was measured and not adopted. No prompt changed. |
| 12 Oct 2026, pictures | The invoice reader is shown a document's picture where one document is read and it is one, with Vision's `OCRTool` and — where Vision finds a code — `BarcodeReaderTool`; the reading kept is chosen against the document's own text. Image decoding honours the photograph's orientation. The text prompt is unchanged. |
| 12 Oct 2026, a model of the person's own | A model the person supplies (MLX) can stand in Apple's place for every feature. For it alone: the answer's schema is written into the instructions as JSON Schema in declared order; the locale phrase goes last; each feature's answer has a token ceiling; an answer's strings are put right of whitespace spelt out as text; and the statement reader reads a slice again in halves when an answer shows it lost its place (this last for any model). No prompt sent to Apple's models changed. |
| 17 Oct 2026 | Each narrator says what each figure is on its line, and its relations: the forecast's balances, change and movements in words with no minus sign; the review slides' and the reports' roles (`FigureRole`) and relations (`FigureRelation`) as the deck or report computed them. Four checks of words (`FigureAttribution.swift`) decline a balance said as a change, a change said the other way, a negative balance that is not, and a comparison its figures contradict. After the review the same day: roles worded by when a figure was ("as at the end of the period"), not by kind; relations given, not worked out from the numbers; no role for a valuation of nothing, and no shared sentence calling money in and out period totals; reports' lines carry their side; each forecast movement's resulting balance and the horizon's totals; the checks corrected as listed under "A true number said of the wrong thing". The survey sends the app's own labels in each language. |
