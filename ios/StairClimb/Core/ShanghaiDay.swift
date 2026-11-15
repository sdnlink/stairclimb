import Foundation

struct ShanghaiDay: Equatable {
    static let timeZoneID = "Asia/Shanghai"
    static let timeZone = TimeZone(identifier: timeZoneID)!
    let date: String
    let start: Date
    let end: Date

    init(containing instant: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        start = calendar.startOfDay(for: instant)
        end = calendar.date(byAdding: .day, value: 1, to: start)!
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        date = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    func contains(_ instant: Date) -> Bool { instant >= start && instant < end }

    static func timeLabel(for instant: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: instant)
    }
}
