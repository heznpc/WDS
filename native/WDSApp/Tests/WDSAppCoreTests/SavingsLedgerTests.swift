import XCTest
@testable import WDSAppCore

final class SavingsLedgerTests: XCTestCase {
    private let weekA = 202_601
    private let weekB = 202_602

    func testNewLedgerIsEmpty() {
        let ledger = SavingsLedger()
        XCTAssertEqual(ledger.lifetimeTokens, 0)
        XCTAssertEqual(ledger.lifetimePhrases, 0)
        XCTAssertEqual(ledger.periodTokens, 0)
        XCTAssertEqual(ledger.periodPhrases, 0)
        XCTAssertEqual(ledger.tokens(inPeriod: weekA), 0)
    }

    func testRecordAccumulatesLifetimeAndPeriod() {
        var ledger = SavingsLedger()
        ledger.record(savedTokens: 6, periodKey: weekA)
        ledger.record(savedTokens: 4, periodKey: weekA)

        XCTAssertEqual(ledger.lifetimeTokens, 10)
        XCTAssertEqual(ledger.lifetimePhrases, 2)
        XCTAssertEqual(ledger.periodTokens, 10)
        XCTAssertEqual(ledger.periodPhrases, 2)
        XCTAssertEqual(ledger.tokens(inPeriod: weekA), 10)
    }

    func testNewPeriodResetsPeriodButKeepsLifetime() {
        var ledger = SavingsLedger()
        ledger.record(savedTokens: 6, periodKey: weekA)
        ledger.record(savedTokens: 9, periodKey: weekB)

        XCTAssertEqual(ledger.lifetimeTokens, 15)
        XCTAssertEqual(ledger.lifetimePhrases, 2)
        XCTAssertEqual(ledger.periodKey, weekB)
        XCTAssertEqual(ledger.periodTokens, 9)
        XCTAssertEqual(ledger.periodPhrases, 1)
        // Asking about the previous week no longer returns its total.
        XCTAssertEqual(ledger.tokens(inPeriod: weekA), 0)
        XCTAssertEqual(ledger.tokens(inPeriod: weekB), 9)
    }

    func testNegativeSavingIsClampedButPhraseCounted() {
        var ledger = SavingsLedger()
        ledger.record(savedTokens: -5, periodKey: weekA)

        XCTAssertEqual(ledger.lifetimeTokens, 0)
        XCTAssertEqual(ledger.lifetimePhrases, 1)
        XCTAssertEqual(ledger.periodTokens, 0)
        XCTAssertEqual(ledger.periodPhrases, 1)
    }

    func testCodableRoundTrip() throws {
        var ledger = SavingsLedger()
        ledger.record(savedTokens: 7, periodKey: weekA)
        ledger.record(savedTokens: 3, periodKey: weekA)

        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(SavingsLedger.self, from: data)

        XCTAssertEqual(decoded, ledger)
    }
}

final class SavingsPeriodTests: XCTestCase {
    private func utcISOCalendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testWeekKeyIsStableForTheSameISOWeek() {
        let calendar = utcISOCalendar()
        // 1970-01-01 (Thu) and 1970-01-03 (Sat) are both in ISO week 1 of 1970.
        let thursday = Date(timeIntervalSince1970: 0)
        let saturday = Date(timeIntervalSince1970: 2 * 86_400)

        let keyThursday = SavingsPeriod.weekKey(for: thursday, calendar: calendar)
        let keySaturday = SavingsPeriod.weekKey(for: saturday, calendar: calendar)

        XCTAssertEqual(keyThursday, 197_001)
        XCTAssertEqual(keyThursday, keySaturday)
    }

    func testWeekKeyAdvancesToTheNextWeek() {
        let calendar = utcISOCalendar()
        let week1 = SavingsPeriod.weekKey(for: Date(timeIntervalSince1970: 0), calendar: calendar)
        // +7 days lands on 1970-01-08 (Thu), ISO week 2 of 1970.
        let week2 = SavingsPeriod.weekKey(for: Date(timeIntervalSince1970: 7 * 86_400), calendar: calendar)

        XCTAssertEqual(week2, 197_002)
        XCTAssertGreaterThan(week2, week1)
    }

    func testDefaultLocalCalendarPathIsUsableAndMonotonic() {
        // Exercises the shipped default argument (device-local time zone) without
        // pinning a calendar. Machine-independent: the same instant maps to one
        // key, and +8 days always crosses at least one ISO week in any zone, so
        // the key strictly increases (and never breaks across a year boundary).
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let plus8Days = base.addingTimeInterval(8 * 86_400)

        XCTAssertEqual(SavingsPeriod.weekKey(for: base), SavingsPeriod.weekKey(for: base))
        XCTAssertLessThan(SavingsPeriod.weekKey(for: base), SavingsPeriod.weekKey(for: plus8Days))
    }
}
