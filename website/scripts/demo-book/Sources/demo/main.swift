//
//  main.swift — demo book generator
//
//  Builds a synthetic .finvestlens book for screenshots and marketing, so no
//  real financial data is ever published. Everything here is invented: the
//  names, the employer, the balances, the holdings.
//

import Foundation
import FinvestLensEngine
import FinvestLensPersistence

let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d))!
}

let aud = Commodity(namespace: .currency, mnemonic: "AUD", fullName: "Australian Dollar",
                    smallestFraction: 100)
let book = Book(baseCurrency: aud)

// MARK: Chart of accounts

@MainActor @discardableResult
func account(_ name: String, _ type: AccountType, under parent: Account? = nil,
             commodity: Commodity = aud, code: String = "") -> Account {
    let a = Account(name: name, type: type, commodity: commodity)
    a.code = code
    return book.addAccount(a, under: parent ?? book.rootAccount)
}

let assets = account("Assets", .asset, code: "1000")
let current = account("Current Assets", .asset, under: assets)
let everyday = account("Everyday Account", .bank, under: current, code: "1010")
let savings = account("Savings", .bank, under: current, code: "1020")
let cash = account("Cash", .cash, under: current)

let investments = account("Investments", .asset, under: assets, code: "1500")
let brokerage = account("Brokerage Cash", .bank, under: investments)

let property = account("Property", .asset, under: assets, code: "1800")
let home = account("Home", .asset, under: property)

let liabilities = account("Liabilities", .liability, code: "2000")
let card = account("Visa Card", .credit, under: liabilities, code: "2010")
let mortgage = account("Home Loan", .liability, under: liabilities, code: "2100")

let equity = account("Equity", .equity, code: "3000")
let opening = account("Opening Balances", .equity, under: equity)

let income = account("Income", .income, code: "4000")
let salary = account("Salary", .income, under: income, code: "4010")
let dividends = account("Dividends", .income, under: income, code: "4020")
// Dividends ▸ TICKER ▸ …: the shape the investment reports attribute income by.
let vasIncome = account("VAS", .income, under: dividends)
let vasFranked = account("Franked", .income, under: vasIncome)
let vasCredits = account("Imputation Credit", .income, under: vasIncome)
let ndqIncome = account("NDQ", .income, under: dividends)
let ndqUnfranked = account("Unfranked", .income, under: ndqIncome)
let interest = account("Interest", .income, under: income)

let expenses = account("Expenses", .expense, code: "5000")
let groceries = account("Groceries", .expense, under: expenses, code: "5010")
let dining = account("Dining Out", .expense, under: expenses, code: "5020")
let transport = account("Transport", .expense, under: expenses, code: "5030")
let utilities = account("Utilities", .expense, under: expenses, code: "5040")
let insurance = account("Insurance", .expense, under: expenses, code: "5050")
let health = account("Health", .expense, under: expenses)
let subscriptions = account("Subscriptions", .expense, under: expenses)
let homeExp = account("Home", .expense, under: expenses)
let interestExp = account("Loan Interest", .expense, under: expenses, code: "5900")
let creditOffset = account("Imputation Credit Offset", .expense, under: expenses)

// Securities: two invented holdings, and an invented index to compare them with
// (named to sort last, so Price History opens on a holding).
let vas = Commodity(namespace: .security("ASX"), mnemonic: "VAS",
                    fullName: "Australian Shares ETF", smallestFraction: 1000)
let ndq = Commodity(namespace: .security("ASX"), mnemonic: "NDQ",
                    fullName: "Global Technology ETF", smallestFraction: 1000)
let idx = Commodity(namespace: .security("INDEX"), mnemonic: "XDM",
                    fullName: "Demo Market Index", smallestFraction: 100)
book.registerCommodity(vas)
book.registerCommodity(ndq)
book.registerCommodity(idx)
let vasAcct = account("VAS", .stock, under: investments, commodity: vas)
let ndqAcct = account("NDQ", .stock, under: investments, commodity: ndq)

// MARK: Transactions

@MainActor @discardableResult
func post(_ date: Date, _ description: String, _ legs: [(Account, Decimal)],
          reconciled: Bool = true, num: String = "") -> Transaction {
    let t = Transaction(currency: aud, datePosted: date, description: description)
    t.number = num
    for (acct, amount) in legs {
        let s = Split(account: acct, value: amount)
        s.reconcileState = reconciled ? .reconciled : .notReconciled
        t.addSplit(s)
    }
    return book.addTransaction(t)
}

// Opening balances.
post(day(2025, 7, 1), "Opening Balances", [
    (everyday, 4_820.15), (savings, 26_400), (brokerage, 1_240.55),
    (home, 780_000), (mortgage, -512_400), (card, -1_180.40),
    (opening, -298_880.30),
])

// Sixteen months of everyday life, to the end of October 2026, generated with a
// little variation so the charts and reports have something honest-looking to
// show — and something in the financial year a screenshot opens on.
var seed: UInt64 = 20_260_725
@MainActor func rnd(_ lo: Double, _ hi: Double) -> Decimal {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let unit = Double(seed >> 11) / Double(UInt64(1) << 53)
    let cents = Int(((lo + unit * (hi - lo)) * 100).rounded())
    return Decimal(cents) / 100
}

for month in 0..<16 {
    let base = calendar.date(byAdding: .month, value: month, to: day(2025, 7, 1))!
    func at(_ d: Int) -> Date { calendar.date(bySetting: .day, value: d, of: base)! }

    let pay: Decimal = 7_450
    let tax: Decimal = 2_015
    let t = Transaction(currency: aud, datePosted: at(15), description: "Northwind Pty Ltd — salary")
    t.addSplit(Split(account: everyday, value: pay - tax))
    t.addSplit(Split(account: expenses, value: tax))
    t.addSplit(Split(account: salary, value: -pay))
    for s in t.splits { s.reconcileState = .reconciled }
    book.addTransaction(t)

    post(at(2), "Home loan repayment", [
        (mortgage, 1_180), (interestExp, 2_140), (everyday, -3_320),
    ])
    let power = rnd(180, 320)
    post(at(3), "Sunfield Energy", [(utilities, power), (everyday, -power)])
    post(at(4), "Harbour Insurance", [(insurance, 214.50), (everyday, -214.50)])
    post(at(6), "Streamly", [(subscriptions, 22.99), (card, -22.99)])
    post(at(20), "Transfer to savings", [(savings, 900), (everyday, -900)])

    var charged = Decimal(22.99)   // the subscription above
    for (dayOfMonth, payee, acct, lo, hi) in [
        (5, "Greenway Grocers", groceries, 90.0, 210.0),
        (9, "Corner Market", groceries, 40.0, 120.0),
        (12, "The Roastery", dining, 12.0, 48.0),
        (16, "Greenway Grocers", groceries, 95.0, 230.0),
        (18, "Metro Transit", transport, 30.0, 60.0),
        (22, "Bistro Nine", dining, 55.0, 140.0),
        (24, "Greenway Grocers", groceries, 80.0, 190.0),
        (26, "Fuel Stop", transport, 55.0, 95.0),
    ] as [(Int, String, Account, Double, Double)] {
        let amount = rnd(lo, hi)
        charged += amount
        post(at(dayOfMonth), payee, [(acct, amount), (card, -amount)],
             reconciled: month < 15)
    }

    // Settle last month's statement, so the card carries a believable balance.
    var raw = charged * 92 / 100
    var settle = Decimal()
    NSDecimalRound(&settle, &raw, 2, .bankers)
    post(at(27), "Visa Card payment", [(card, settle), (everyday, -settle)])

    if month % 3 == 1 {
        post(at(8), "Dr Lin — consultation", [(health, 95), (everyday, -95)])
    }
    if month % 6 == 2 {
        let repair = rnd(300, 900)
        post(at(11), "Roof gutter repair", [(homeExp, repair), (everyday, -repair)])
    }
    let earned = rnd(28, 46)
    post(at(28), "Savings interest", [(savings, earned), (interest, -earned)])
}

// Investments: three purchases, a distribution a quarter, and two parcels sold —
// one held over twelve months and one under — so Capital Gains has both to show.
@MainActor func buy(_ date: Date, _ acct: Account, _ units: Decimal, _ price: Decimal, _ fee: Decimal) {
    let total = units * price + fee
    let t = Transaction(currency: aud, datePosted: date, description: "Buy \(acct.name)")
    let leg = Split(account: acct, value: units * price, quantity: units)
    leg.reconcileState = .reconciled
    t.addSplit(leg)
    t.addSplit(Split(account: expenses, value: fee))
    t.addSplit(Split(account: brokerage, value: -total))
    book.addTransaction(t)
}
buy(day(2025, 8, 12), vasAcct, 120, 92.40, 9.50)
buy(day(2025, 11, 4), ndqAcct, 65, 48.15, 9.50)
buy(day(2026, 3, 18), vasAcct, 40, 97.80, 9.50)

@MainActor func sell(_ date: Date, _ acct: Account, _ units: Decimal, _ price: Decimal) {
    let t = Transaction(currency: aud, datePosted: date, description: "Sell \(acct.name)")
    let leg = Split(account: acct, value: -(units * price), quantity: -units)
    leg.reconcileState = .reconciled
    t.addSplit(leg)
    t.addSplit(Split(account: brokerage, value: units * price))
    book.addTransaction(t)
}
sell(day(2026, 9, 15), vasAcct, 40, 106.20)     // from the Aug 2025 parcel: over twelve months
sell(day(2026, 10, 6), ndqAcct, 15, 57.10)      // from the Nov 2025 parcel: under twelve months

// A franked distribution carries its credit, offset by an expense the way the
// book records one; each transaction has one distribution in it.
for (date, cash, credit) in [
    (day(2025, 10, 2), Decimal(318.40), Decimal(136.46)),
    (day(2026, 1, 8), Decimal(344.10), Decimal(147.47)),
    (day(2026, 4, 2), Decimal(402.75), Decimal(172.61)),
    (day(2026, 7, 2), Decimal(418.30), Decimal(179.27)),
    (day(2026, 10, 2), Decimal(366.05), Decimal(156.88)),
] {
    post(date, "VAS distribution", [(brokerage, cash), (vasFranked, -cash),
                                    (vasCredits, -credit), (creditOffset, credit)])
}
for (date, cash) in [(day(2026, 1, 8), Decimal(96.20)), (day(2026, 7, 2), Decimal(112.45))] {
    post(date, "NDQ distribution", [(brokerage, cash), (ndqUnfranked, -cash)])
}

// Top the brokerage account up so it is not overdrawn.
post(day(2025, 8, 1), "Transfer to brokerage", [(brokerage, 18_000), (savings, -18_000)])

// Prices, every weekday for two and a bit years, so the portfolio values itself
// and Price History has averages, crosses and a benchmark to draw: each series
// walks a little around straight lines between these invented levels — a rise,
// a fall early in 2025, and the recovery the purchases and sales sit on.
@MainActor func addDailyPrices(_ commodity: Commodity, _ path: [(Date, Double)], wobble: Double) {
    var drift = 0.0
    var date = path[0].0
    let last = path[path.count - 1].0
    while date <= last {
        let weekday = calendar.component(.weekday, from: date)
        if weekday != 1 && weekday != 7 {
            let next = path.firstIndex { $0.0 >= date } ?? path.count - 1
            let (from, to) = (path[max(next - 1, 0)], path[next])
            let span = to.0.timeIntervalSince(from.0)
            let level = span > 0
                ? from.1 + (to.1 - from.1) * date.timeIntervalSince(from.0) / span
                : to.1
            drift = drift * 0.9 + NSDecimalNumber(decimal: rnd(-wobble, wobble)).doubleValue
            let cents = Int(((level + drift) * 100).rounded())
            book.addPrice(Price(commodity: commodity, currency: aud, date: date,
                                value: Decimal(cents) / 100, source: "demo"))
        }
        date = calendar.date(byAdding: .day, value: 1, to: date)!
    }
}
addDailyPrices(vas, [
    (day(2024, 7, 1), 86.0), (day(2024, 12, 2), 94.0), (day(2025, 4, 7), 82.0),
    (day(2025, 8, 12), 92.4), (day(2026, 1, 15), 95.5), (day(2026, 3, 18), 97.8),
    (day(2026, 6, 15), 101.0), (day(2026, 9, 15), 106.2), (day(2026, 10, 30), 108.4),
], wobble: 0.45)
addDailyPrices(ndq, [
    (day(2024, 7, 1), 37.5), (day(2025, 1, 15), 44.0), (day(2025, 4, 7), 36.5),
    (day(2025, 11, 4), 48.15), (day(2026, 3, 2), 46.0), (day(2026, 6, 1), 51.0),
    (day(2026, 10, 6), 57.1), (day(2026, 10, 30), 58.2),
], wobble: 0.3)
addDailyPrices(idx, [
    (day(2024, 7, 1), 7_800), (day(2024, 12, 2), 8_400), (day(2025, 4, 7), 7_500),
    (day(2025, 11, 4), 8_700), (day(2026, 3, 2), 8_600), (day(2026, 10, 30), 9_150),
], wobble: 28)

// MARK: Write it out

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)
let store = try SQLiteDocumentStore(path: out.path)
try store.write(book)

print("wrote \(out.path)")
print("  accounts: \(book.accounts.count)")
print("  transactions: \(book.transactions.count)")
print("  prices: \(book.prices.count)")
