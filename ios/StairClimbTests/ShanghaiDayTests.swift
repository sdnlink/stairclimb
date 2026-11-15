import XCTest
@testable import StairClimb

final class ShanghaiDayTests: XCTestCase {
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testShanghaiMidnightWithUTCInstants() {
        let before = ShanghaiDay(containing: instant("2026-11-14T15:59:59Z"))
        let after = ShanghaiDay(containing: instant("2026-11-14T16:00:00Z"))
        XCTAssertEqual(before.date, "2026-11-14")
        XCTAssertEqual(after.date, "2026-11-15")
        XCTAssertEqual(before.end, after.start)
        XCTAssertFalse(before.contains(after.start))
        XCTAssertTrue(after.contains(after.start))
        XCTAssertEqual(after.start, instant("2026-11-14T16:00:00Z"))
        XCTAssertEqual(after.end, instant("2026-11-15T16:00:00Z"))
    }

    func testDeviceTimeZonesCannotChangeShanghaiDate() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for zone in ["America/Los_Angeles", "Pacific/Honolulu", "Europe/London", "Asia/Tokyo"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let day = ShanghaiDay(containing: instant("2026-11-14T16:00:00Z"))
            XCTAssertEqual(day.date, "2026-11-15", zone)
            XCTAssertEqual(day.end.timeIntervalSince(day.start), 86_400, zone)
        }
    }

    func testMonthYearAndLeapDayTransitions() {
        for (before, expected) in [("2026-12-31T16:00:00Z", "2027-01-01"),
                                   ("2028-02-28T16:00:00Z", "2028-02-29"),
                                   ("2028-02-29T16:00:00Z", "2028-03-01")] {
            XCTAssertEqual(ShanghaiDay(containing: instant(before)).date, expected)
        }
    }

    func testReadTimestampAlwaysUsesShanghaiTime() {
        XCTAssertEqual(ShanghaiDay.timeLabel(for: instant("2026-11-14T16:01:02Z")), "00:01:02")
    }
}
