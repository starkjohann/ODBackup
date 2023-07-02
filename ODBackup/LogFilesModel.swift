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
                            //   1                            2         3         4           5    6
    static let fileNameRegex = /^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\.(.*?)(\.error|\.inprogress)?\.log$/

    // This archive:                3.29 GB              3.07 GB              3.07 GB
    static let byteCountRegex = /\nThis archive: *([0-9.]+ .?B) *([0-9.]+ .?B) *([0-9.]+ .?B)\n/

    // Number of files: 1473
    static let fileCountRegex = /\nNumber of files: ([0-9]+)\n/


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
                if match.output.6 == ".inprogress" {
                    status = .inProgress
                } else if match.output.6 == nil {
                    status = .success
                } else {
                    status = .error
                }
                let fileURL = url.appending(path: file)
                var size = "0"
                var fileCount = 0

                if  status == .success,
                    let fileHandle = try? FileHandle(forReadingFrom: fileURL),
                    let content = try? fileHandle.read(upToCount: 2048)
                {
                    let logContent = String(decoding: content, as: UTF8.self)

                    if let sizeMatch = logContent.firstMatch(of: Self.byteCountRegex) {
                        // let originalSize = sizeMatch.output.1
                        // let compressedSize = sizeMatch.output.2
                        let deduplicatedSize = sizeMatch.output.3
                        size = String(deduplicatedSize)
                    }
                    if let countMatch = logContent.firstMatch(of: Self.fileCountRegex) {
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
        case error
    }

    @objc dynamic let name: String
    @objc dynamic let timestamp: String
    @objc dynamic let destinationName: String
    @objc dynamic let bytesSent: String
    let status: Status
    @objc dynamic let fileCount: Int

    @objc dynamic var bytesSentColumn: String {
        switch status {
        case .inProgress:
            return "in progress"
        case .success:
            return bytesSent
        case .error:
            return "error"
        }
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
