import Foundation
import os
import SecurityFoundation

class BackupDaemon: NSObject, BackupDaemonProtocol {

    private var runningBackupProcesses = Set<Process>()
    private var runningListingProcesses = Set<Process>()
    private var runningExtractionProcesses = Set<Process>()

    func bundleVersion(clientBundleversion: String, with reply: @escaping (String) -> Void) {
        let myBundleVersion = ResourceManager.shared.resourceBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if clientBundleversion != myBundleVersion {
            os_log("client has different bundle version: %{public}@ (mine is %{public}@)", clientBundleversion, myBundleVersion ?? "<nil>")
            exit(1)
        }
        reply(myBundleVersion ?? "unknown")
    }

    func getSSHPublicKey(with reply: @escaping (String?) -> Void) {
        do {
            let key = try String(contentsOf: StaticConfiguration.sshPublicKeyFileURL)
            reply(key)
        } catch {
            reply(nil)
        }
    }

    func setSSHKeys(public publicKey: String, private privateKey: String, with reply: @escaping (NSError?) -> Void) {
        do {
            try? FileManager.default.removeItem(at: StaticConfiguration.sshPublicKeyFileURL)    // ignore errors here, file may not exist yet
            try? FileManager.default.removeItem(at: StaticConfiguration.sshPrivateKeyFileURL)   // ignore errors here, file may not exist yet
            try publicKey.write(to: StaticConfiguration.sshPublicKeyFileURL, atomically: true, encoding: .utf8)
            _ = StaticConfiguration.sshPublicKeyFileURL.withUnsafeFileSystemRepresentation { path in
                chmod(path!, 0o644)
            }
            try privateKey.write(to: StaticConfiguration.sshPrivateKeyFileURL, atomically: true, encoding: .utf8)
            _ = StaticConfiguration.sshPrivateKeyFileURL.withUnsafeFileSystemRepresentation { path in
                chmod(path!, 0o600)
            }
            reply(nil)
        } catch {
            reply(error as NSError)
        }
    }

    func generateNewSSHKeys(with reply: @escaping (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        process.currentDirectoryURL = URL(filePath: "/var/root")
        process.arguments = ["-t", "ed25519", "-N", "", "-f", StaticConfiguration.sshPrivateKeyFileURL.path]
        var stdoutData = Data()
        let stdoutReader = PipeReader { stdoutData.append($0) }
        process.standardOutput = stdoutReader.fileHandleForWriting
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            reply(error.localizedDescription)
        }
        if process.terminationStatus == 0 {
            reply(nil)
        } else {
            reply(String(decoding: stdoutData, as: UTF8.self))
        }
    }

    func checkFullDiskAccess(with reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global().async {
            let process = Process.backupProcess()

            process.arguments = ["testaccess"]

            let (terminationStatus, stderrString) = process.runBackup(stdinString: nil)
            reply(terminationStatus, stderrString)
        }
    }

    func initializeRepository(_ repository: String, passPhrase: String, rshCommand: String, with reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global().async {
            let process = Process.backupProcess()
            process.environment = [
                "BORG_REPO": repository,
                "BORG_RSH": rshCommand
            ]
            process.arguments = ["init"]

            let (terminationStatus, stderrString) = process.runBackup(stdinString: passPhrase)
            reply(terminationStatus, stderrString)
        }
    }


    func performBackup(backupRoots: [String], excludePatterns: [String], repository: String, repositoryName: String, passPhrase: String, rateLimitKBytes: Int, rshCommand: String, pruneKeepHourly: Int, pruneKeepDaily: Int, pruneKeepWeekly: Int, pruneKeepMonthly: Int, with reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global().async {
            let process = Process.backupProcess()
            self.runningBackupProcesses.insert(process)
            defer { self.runningBackupProcesses.remove(process) }
            process.environment = [
                "BORG_REPO": repository,
                "BORG_RSH": rshCommand,
                "REPO_NAME": repositoryName,
                "PRUNE_OPTIONS": "--keep-hourly=\(pruneKeepHourly) --keep-daily=\(pruneKeepDaily) --keep-weekly=\(pruneKeepWeekly) --keep-monthly=\(pruneKeepMonthly)"
            ]

            var arguments = ["backup"] + backupRoots + ["--upload-ratelimit", "\(rateLimitKBytes)"]
            for excludePattern in excludePatterns {
                arguments.append("-e")
                arguments.append(excludePattern)
            }
            process.arguments = arguments

            let stdoutReader = PipeReader { Clients.reportProgressToClients(String(decoding: $0, as: UTF8.self)) }
            process.standardOutput = stdoutReader.fileHandleForWriting

            let (terminationStatus, stderrString) = process.runBackup(stdinString: passPhrase)
            reply(terminationStatus, stderrString)
        }
    }

    func listArchives(repository: String, repositoryName: String, passPhrase: String, rshCommand: String, with reply: @escaping (Int32, _ stdout: String, _ stderr: String) -> Void) {
        DispatchQueue.global().async {
            let process = Process.backupProcess()
            self.runningListingProcesses.insert(process)
            defer { self.runningListingProcesses.remove(process) }
            process.environment = [
                "BORG_REPO": repository,
                "BORG_RSH": rshCommand,
                "REPO_NAME": repositoryName,
            ]

            process.arguments = ["list", "--format", "{archive}\t{time}\n"]

            var stdoutData = Data()
            let stdoutReader = PipeReader { stdoutData.append($0) }
            process.standardOutput = stdoutReader.fileHandleForWriting

            let (terminationStatus, stderrString) = process.runBackup(stdinString: passPhrase)

            reply(terminationStatus, String(decoding: stdoutData, as: UTF8.self), stderrString)
        }
    }

    func listFiles(repository: String, repositoryName: String, archive: String, passPhrase: String, rshCommand: String, with reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global().async {
            let process = Process.backupProcess()
            self.runningListingProcesses.insert(process)
            defer { self.runningListingProcesses.remove(process) }
            process.environment = [
                "BORG_REPO": repository,
                "BORG_RSH": rshCommand,
                "REPO_NAME": repositoryName,
            ]

            process.arguments = ["list", "::" + archive, "--format", "{mode}\t{user}\t{group}\t{size}\t{mtime}\t{path}\n"]

            var lastReportDate = Date()
            var listingData = Data()

            let stdoutReader = PipeReader {
                listingData.append($0)
                let now = Date()
                if now.timeIntervalSince(lastReportDate) > 0.5 {
                    let buffer = listingData
                    listingData = Data()
                    Clients.reportListingDataToClients(buffer)
                    lastReportDate = now
                }
            }
            process.standardOutput = stdoutReader.fileHandleForWriting

            let (terminationStatus, stderrString) = process.runBackup(stdinString: passPhrase)
            if !listingData.isEmpty {
                Clients.reportListingDataToClients(listingData)
            }

            reply(terminationStatus, stderrString)
        }
    }

    func extractFiles(repository: String, repositoryName: String, archive: String, path: String?, passPhrase: String, rshCommand: String, with reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global().async {
            let process = Process.backupProcess()
            self.runningExtractionProcesses.insert(process)
            defer { self.runningExtractionProcesses.remove(process) }
            process.environment = [
                "BORG_REPO": repository,
                "BORG_RSH": rshCommand,
                "REPO_NAME": repositoryName,
            ]

            var arguments = ["extract", "::" + archive]
            if let path {
                arguments.append(path)
                let slashCount = path.reduce(into: 0) { partialResult, c in
                    if c == "/" {
                        partialResult += 1
                    }
                }
                arguments.append("--strip-components")
                arguments.append("\(slashCount - 1)")
            }
            arguments.append("--sparse")    // create holes in files where appropriate
            process.arguments = arguments

            var lastReportDate = Date()
            var dataBuffer = Data()

            let stdoutReader = PipeReader { dataReceived in
                let now = Date()
                if now.timeIntervalSince(lastReportDate) > 0.5 {
                    dataBuffer.append(dataReceived)
                    let lf = "\n".utf8.first!
                    if let lastLF = dataBuffer.lastIndex(of: lf), let lastButOneLF = dataBuffer[..<lastLF].lastIndex(of: lf) {
                        // we have at least two LF characters, extract the last line
                        let line = dataBuffer[(lastButOneLF + 1) ..< lastLF]
                        Clients.reportListingDataToClients(line)
                        dataBuffer = Data()
                        lastReportDate = now
                    }
                }
            }
            process.standardOutput = stdoutReader.fileHandleForWriting

            let (terminationStatus, stderrString) = process.runBackup(stdinString: passPhrase)
            reply(terminationStatus, stderrString)
        }
    }

    func logToBackupLog(repositoryName: String, exitStatus: Int32, logMessage: String, with reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global().async {
            let process = Process.backupProcess()
            process.arguments = ["log", String(exitStatus), logMessage]
            process.environment = ["REPO_NAME": repositoryName]
            let (terminationStatus, stderrString) = process.runBackup(stdinString: nil)
            reply(terminationStatus, stderrString)
        }
    }

    func abortBackups() {
        for process in runningBackupProcesses {
            kill(process.processIdentifier, SIGTERM)
        }
    }

    func abortListings() {
        for process in runningListingProcesses {
            kill(process.processIdentifier, SIGTERM)
        }
    }

    func abortExtractions() {
        for process in runningExtractionProcesses {
            kill(process.processIdentifier, SIGTERM)
        }
    }


    func terminate() {
        os_log("terminating on client request")
        DispatchQueue.main.async {
            exit(0)
        }
    }

    func scheduleWake(date: Date) {
        let scheduledWake = scheduledWakeFromPmset()
        if scheduledWake == date {
            return  // nothing to do, correct wake already scheduled
        }
        if let scheduledWake {
            scheduleWakeUsingPmset(date: scheduledWake, cancelSchedule: true)
        }
        scheduleWakeUsingPmset(date: date, cancelSchedule: false)
    }

}

// pmset primitives
private extension BackupDaemon {

    private static let pmsetDateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return dateFormatter
    }()

    private static let pmsetOwnerLabel = "at.obdev.odbackup.nextbackup"

    func scheduledWakeFromPmset() -> Date? {
        do {
            let pmset = Process()
            pmset.executableURL = URL(filePath: "/usr/bin/pmset")
            pmset.arguments = ["-g", "sched"]
            var stdoutData = Data()
            let stdoutReader = PipeReader { stdoutData.append($0) }
            pmset.standardOutput = stdoutReader.fileHandleForWriting
            try pmset.run()
            pmset.waitUntilExit()
            let stdoutString = String(decoding: stdoutData, as: UTF8.self)
            for line in stdoutString.components(separatedBy: CharacterSet.newlines) {
                if let match = line.firstMatch(of: /^.*wake at ([0-9\/]+ [0-9:]+) by '?([a-zA-Z0-9.]+)'? *$/), match.output.2 == Self.pmsetOwnerLabel {
                    let scheduledDateString = String(match.output.1)
                    return Self.pmsetDateFormatter.date(from: scheduledDateString)
                }
            }
        } catch {
            os_log("error running /usr/bin/pmset -g sched: \(error)")
        }
        return nil
    }

    func scheduleWakeUsingPmset(date: Date, cancelSchedule: Bool) {
        do {
            let pmset = Process()
            pmset.executableURL = URL(filePath: "/usr/bin/pmset")
            var arguments = ["schedule"]
            if cancelSchedule {
                arguments.append("cancel")
            }
            arguments += ["wake", Self.pmsetDateFormatter.string(from: date), Self.pmsetOwnerLabel]
            pmset.arguments = arguments
            try pmset.run()
            pmset.waitUntilExit()
        } catch {
            os_log("error running /usr/bin/pmset -g sched: \(error)")
        }
    }

}

private extension Process {

    static func backupProcess() -> Process {
        let process = Process()
        process.executableURL = ResourceManager.shared.resourceBundle.url(forResource: "odbackup", withExtension: "sh")!
        process.currentDirectoryURL = URL(filePath: "/")
        return process
    }

    func runBackup(stdinString: String?) -> (returnCode: Int32, stderrString: String){
        if let borgExecutableURL = ResourceManager.shared.resourceBundle.url(forResource: "borg", withExtension: "")?.appending(path: "borg.exe") {
            var writableEnvironment = environment ?? [:]
            writableEnvironment["BORG_EXECUTABLE"] = borgExecutableURL.path
            writableEnvironment["LANG"] = "en_US.UTF-8"
            environment = writableEnvironment
        }
        var stderrData = Data()
        let stderrReader = PipeReader { stderrData.append($0) }
        standardError = stderrReader.fileHandleForWriting

        let stdinPipe = Pipe()
        standardInput = stdinPipe.fileHandleForReading

        do {
            try run()
        } catch {
            return (-1, error.localizedDescription)
        }

        // docs don't tell whether `write(contentsOf:)` writes synchronously
        // on this thread or asynchronously. Both is OK for us because we
        // are on a background thread and don't block anything important.
        // When the process terminates (and it makes sense to call `waitUntilExit()`
        // below, `write(contentsOf:)` aborts with an error anyway.
        if let stdinString = stdinString {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinString.data(using: .utf8)!)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        waitUntilExit()
        return (terminationStatus, String(decoding: stderrData, as: UTF8.self))
    }

}

