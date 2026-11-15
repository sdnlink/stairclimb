import Foundation

struct ShanghaiDay: Equatable {
    static let timeZoneID = "Asia/Shanghai"
    static let timeZone = TimeZone(identifier: timeZoneID)!
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    let date: String
    let start: Date
    let end: Date

    init(containing instant: Date) {
        start = Self.calendar.startOfDay(for: instant)
        end = Self.calendar.date(byAdding: .day, value: 1, to: start)!
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: instant)
        date = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    func contains(_ instant: Date) -> Bool { instant >= start && instant < end }

    static func timeLabel(for instant: Date) -> String {
        timeFormatter.string(from: instant)
    }
}
