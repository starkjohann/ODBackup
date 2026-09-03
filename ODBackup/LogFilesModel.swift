import AppKit
import Foundation

@objc
class LogFilesModel: NSObject {

    static let shared = LogFilesModel()


    // We assign our regex literals to variables because this saves us the step of
    // regex compilation every time it is used (performance improvement).

    // Example file names:
    // 2023-06-05_130951._tmp_Test.log
    // 2023-06-05_141543._tmp_Test.error.log
    // 2023-06-05_152207._tmp_Test.warning.log
                            //   1                            2         3         4           5    6
    static let fileNameRegex = /^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\.(.*?)(\.error|\.warning|\.inprogress)?\.log$/

    // This archive:                3.29 GB              3.07 GB              3.07 GB
    static let byteCountRegex = /\nThis archive: *([0-9.]+ .?B) *([0-9.]+ .?B) *([0-9.]+ .?B)\n/

    // Number of files: 1473
    static let fileCountRegex = /\nNumber of files: ([0-9]+)\n/

    // Number of bytes we read from the end of a log file to find the statistics.
    static let logTailSize: UInt64 = 64 * 1024


    private var updateTimer: Timer?
    private var directorySignature: String?

    @objc dynamic var logFiles = [LogFile]()

    var lastSuccessfulBackupLog: LogFile? {
        logFiles.first { $0.status == .success }
    }

    var lastCompletedBackupLog: LogFile? {
        logFiles.first { $0.status != .inProgress }
    }

    private override init() {
        super.init()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true ) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    func reload() {
        let url = StaticConfiguration.logDirectoryURL
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let signature = directorySignature(directory: url, files: files)
        guard directorySignature != signature else {
            return  // nothing changed
        }
        directorySignature = signature
        var logFiles = [LogFile]()
        for file in files {
            if let match = file.wholeMatch(of: Self.fileNameRegex) {
                let timestamp = "\(match.output.1) \(match.output.2):\(match.output.3):\(match.output.4)"
                let destination = String(match.output.5).replacingOccurrences(of: "_", with: " ")   // spaces have been mapped to underscore by the script
                let status: LogFile.Status
                switch match.output.6 {
                case ".inprogress":
                    status = .inProgress
                case ".warning":
                    status = .warning
                case nil:
                    status = .success
                default:
                    status = .error
                }
                let fileURL = url.appending(path: file)
                var size = ""
                var fileCount = 0

                // Even a failed backup may have written statistics before it ran into
                // trouble, so we look for them regardless of the status. We search the
                // tail of the log because its main body may be full of warnings about
                // files which could not be read, and we take the last match because
                // borg's summary is the last thing it prints.
                if status != .inProgress, let logContent = tail(of: fileURL) {
                    if let sizeMatch = logContent.matches(of: Self.byteCountRegex).last {
                        // let originalSize = sizeMatch.output.1
                        // let compressedSize = sizeMatch.output.2
                        let deduplicatedSize = sizeMatch.output.3
                        size = String(deduplicatedSize)
                    }
                    if let countMatch = logContent.matches(of: Self.fileCountRegex).last {
                        fileCount = Int(countMatch.output.1) ?? 0
                    }
                }
                logFiles.append(LogFile(name: file, timestamp: timestamp, destinationName: destination, status: status, bytesSent: size, fileCount: fileCount))
            }
        }
        logFiles.sort { $0.timestamp > $1.timestamp }
        if self.logFiles != logFiles {
            self.logFiles = logFiles
        }
    }

    /// Returns the last `logTailSize` bytes of the given file, decoded as UTF-8.
    private func tail(of fileURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer {
            try? fileHandle.close()
        }
        guard let fileSize = try? fileHandle.seekToEnd() else {
            return nil
        }
        let offset = fileSize > Self.logTailSize ? fileSize - Self.logTailSize : 0
        guard (try? fileHandle.seek(toOffset: offset)) != nil, let content = try? fileHandle.readToEnd() else {
            return nil
        }
        // Cutting in the middle of a multi-byte sequence is not a problem here,
        // the decoder replaces the incomplete character and we only match ASCII.
        return String(decoding: content, as: UTF8.self)
    }

    private func directorySignature(directory: URL, files: [String]) -> String {
        // We assume that the order of names in `files` does not change on consecutive
        // calls when the directory has not been changed in any way.
        var signature = ""
        for name in files {
            let date = (try? directory.appending(path: name).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let numericValue = date?.timeIntervalSinceReferenceDate ?? 0
            signature += "\(name)/\(numericValue)|"
        }
        return signature
    }

}

@objc
class LogFile: NSObject {

    enum Status {
        case inProgress
        case success
        case warning
        case error
    }

    @objc dynamic let name: String
    @objc dynamic let timestamp: String
    @objc dynamic let destinationName: String
    @objc dynamic let bytesSent: String
    let status: Status
    @objc dynamic let fileCount: Int

    // We flag warnings and errors with an emoji (in addition to the color of the
    // line) so that the other columns are free for the counts from the log.
    @objc dynamic var destinationColumn: String {
        switch status {
        case .warning:
            return "\(destinationName) \u{26A0}\u{FE0F}"     // warning sign
        case .error:
            return "\(destinationName) \u{274C}"             // cross mark
        default:
            return destinationName
        }
    }

    // We show the byte count whenever we could derive it from the log.
    @objc dynamic var bytesSentColumn: String {
        switch status {
        case .inProgress:
            return "in progress"
        case .success:
            return bytesSent
        case .warning:
            return bytesSent.isEmpty ? "warning" : bytesSent
        case .error:
            return bytesSent.isEmpty ? "error" : bytesSent
        }
    }

    @objc dynamic var fileCountColumn: String {
        fileCount > 0 ? "\(fileCount)" : ""
    }

    var fileURL: URL {
        StaticConfiguration.logDirectoryURL.appending(path: name)
    }

    init(name: String, timestamp: String, destinationName: String, status: Status, bytesSent: String, fileCount: Int) {
        self.name = name
        self.timestamp = timestamp
        self.destinationName = destinationName
        self.status = status
        self.bytesSent = bytesSent
        self.fileCount = fileCount
    }

    // Since we are an NSObject subclass, we must implement isEqual(), not ==().
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else {
            return false
        }
        if name != other.name {
            return false
        }
        if bytesSent != other.bytesSent {
            return false
        }
        if fileCount != other.fileCount {
            return false
        }
        return true
    }

}
