import Foundation

enum Formatters {

    private static let byteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .decimal
        formatter.isAdaptive = false
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let timeFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        return dateFormatter
    }()

    private static let simpleISODateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return dateFormatter
    }()

    static func string(fromByteCount byteCount: Int64) -> String {
        byteCountFormatter.string(fromByteCount: byteCount)
    }

    static func string(fromFileCount fileCount: Int64) -> String {
        let fileCountString = Self.byteCountFormatter.string(fromByteCount: fileCount)
        if let match = fileCountString.firstMatch(of: /^(.*?)(B| *[Bb]ytes?)$/) {
            return String(match.output.1)
        } else {
            return fileCountString
        }
    }

    static func timeString(from date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func simpleISODateTimeString(from date: Date) -> String {
        simpleISODateFormatter.string(from: date)
    }

}
