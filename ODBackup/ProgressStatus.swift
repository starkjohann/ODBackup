import Foundation

@objc
class ProgressStatus: NSObject {

    struct Parsed {
        let bytesChecked: String        // in format provided by Borg
        let deduplicatedBytes: String   // in format provided by Borg
        let filesProcessed: Int
        let currentFile: String
    }

    static var shared = ProgressStatus()

    @objc private(set) dynamic var lastCheckpointDate: Date?

    @objc private(set) dynamic var lastProgressReport: String?
    private(set) var parsedReport: Parsed?  // nil if not a file-related report
    private(set) var unparseableReport: String?


    func setProgressReport(_ report: String?) {
        if let report, let match = report.wholeMatch(of: /^([0-9.]+)[ \t]+([kMGT]?B)[ \t]+O[ \t]+([0-9.]+)[ \t]+([kMGT]?B)[ \t]+C[ \t]+([0-9.]+)[ \t]+([kMGT]?B)[ \t]+D[ \t]+([0-9]+)[ \t]+N[ \t]+(.*)$/) {
            // matches line like this: "3.00 GB O 2.78 GB C 2.78 GB D 1433 N Users/cs/Desktop/W...aining/christiane2.MOV"
            // or                      "165.80 MB O 164.87 MB C 164.87 MB D 6 N Users/cs/Desktop/...onist_mix_325766.mp3"
            let (_, originalBytes, originalBytesUnit, _, _, deduplicatedBytes, deduplicatedBytesUnit, fileCount, currentFile) = match.output
            parsedReport = Parsed(bytesChecked: originalBytes + " " + originalBytesUnit, deduplicatedBytes: deduplicatedBytes + " " + deduplicatedBytesUnit, filesProcessed: Int(fileCount) ?? 0, currentFile: String(currentFile))
            unparseableReport = nil
            lastProgressReport = String(format: "Checked: %6.2f %@    Sent: %6.2f %@    Files: %7ld    Current: %@", Float(originalBytes) ?? 0, String(originalBytesUnit), Float(deduplicatedBytes) ?? 0, String(deduplicatedBytesUnit), CLong(Int(fileCount) ?? 0), String(currentFile))
        } else {
            if report == "Initializing cache transaction: Reading files" {
                lastCheckpointDate = Date()
            } else if report == nil {
                parsedReport = nil
                lastCheckpointDate = nil
            }
            unparseableReport = report
            lastProgressReport = report
        }
    }

    private override init() {
    }

}
