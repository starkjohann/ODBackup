import AppKit
import Foundation
import os
import SystemConfiguration
import UserNotifications

// We decide to run the backup logic as user in the app, not in a root-owned
// background process because this gives us access to the login keychain which is
// more secure than the System keychain and to the user's defaults.
// This means that no backups are made while the user is logged out. That's not
// a problem, IMHO, because the user can't modify any data and mails are not
// fetched while being logged out. It may become problematic if the computer
// has two accounts. In this case install in both accounts and consider replacing
// the storage mechanism in `ConfigurationModel` with something global.

@objc
class BackupLogic: NSObject {

    static let shared = BackupLogic()

    @objc private(set) dynamic var nextBackupTime: Date? {
        didSet {
            os_log("Scheduling next backup for: %{public}@", self.nextBackupTime?.description ?? "<never>")
            if let nextBackupTime {
                Task {
                    await DaemonProxy.shared.scheduleWake(date: nextBackupTime + 10)  // schedule 10 seconds late to ensure that we trigger the backup
                }
            }
            recomputePollTimer()
        }
    }
    private weak var pollTimer: Timer?
    private var observationHandle: NSKeyValueObservation?

    @objc private(set) dynamic var destinationOfRunningBackup: String?    // destination name

    private override init() {
        super.init()
        // Instead of scheduling a timer directly to the `nextBackupTime`, we poll in
        // one minute interval and compare. We do this because for `Timer` time stands
        // still while the computer is in sleep.
        observationHandle = ConfigurationModel.shared.observe(\.backupTimes, options: .initial) { [weak self] _, _ in
            self?.nextBackupTime = Self.nextBackupTimeAfter(Date())
        }
        recomputePollTimer()
    }

    private func recomputePollTimer() {
        // Since timers don't proceed durint system sleep, we schedule the next
        // fire time no longer than 60 seconds into the future. We also do not
        // schedule it shorter than 5 seconds to prevent hugging the CPU in case
        // of a bug.
        let timeInterval = max(5.0, min(60.0, (nextBackupTime ?? Date.distantFuture).timeIntervalSinceNow))
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [self] _ in
            performTimedBackups()
            recomputePollTimer()
        }
    }

    private static func nextBackupTimeAfter(_ date: Date) -> Date? {
        let (today, tomorrow) = todayAndTomorrow6am(forDate: date)
        // DateFormatter is picky about the format. Every deviation from the format
        // string is an error. We want to be tolerant because the string is from a
        // user, so parse with regex.
        let timeRegex = /^ *(mon|tue|wed|thu|fri|sat|sun)? *([0-9]{1,2})(:([0-9]{1,2})(:([0-9]{1,2}))?)? *$/.ignoresCase()
        var datesToConsider = [Date]()
        for timeString in ConfigurationModel.shared.backupTimes.components(separatedBy: ",") {
            if let match = try? timeRegex.firstMatch(in: timeString) {
                //let weekday = match.1.map { String($0).lowercased() }
                // Weekday specific backups are currently not implemented because we don't need them.
                let hours = Int(String(match.2))!
                let minutes = Int(String(match.4 ?? "0"))!
                let seconds = Int(String(match.6 ?? "0"))!
                let secondsSince6am = seconds + (minutes + (hours - 6) * 60) * 60
                datesToConsider.append(today + TimeInterval(secondsSince6am))
                datesToConsider.append(tomorrow + TimeInterval(secondsSince6am))
            } else {
                os_log("could not parse date specification %{public}@", timeString)
            }
        }
        datesToConsider.sort()
        return datesToConsider.first { $0 >= date }
    }

    private static func todayAndTomorrow6am(forDate now: Date) -> (Date, Date) {
        // The code below looks a bit complicated, but before you simplify take
        // into account that we only want to take one clock value (because time may
        // advance to the next day in between two clock samples) and that the
        // current time may not exist or exist twice tomorrow due to daylight
        // saving time changes.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd 06:00"
        let todayString = dateFormatter.string(from: now)
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let todayDate = dateFormatter.date(from: todayString)!
        dateFormatter.dateFormat = "yyyy-MM-dd 06:00"
        let tomorrowString = dateFormatter.string(from: todayDate + 86400)
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let tomorrowDate = dateFormatter.date(from: tomorrowString)!
        return (todayDate, tomorrowDate)
    }

}

extension BackupLogic {

    private func performTimedBackups() {
        guard let nextBackupTime = nextBackupTime else { return }   // no backup scheduled
        let now = Date()
        if now >= nextBackupTime {
            let (destinationName, errorString) = self.destinationNameFromScript(scheduledForDate: nextBackupTime)
            var shouldRetrySoon = false
            if let destinationName {
                let destination = ConfigurationModel.shared.destinations.first { $0.name.lowercased() == destinationName.lowercased() }
                if let destination {
                    os_log("starting automatic backup to %{public}@", destination.name)
                    Task {
                        await performBackupNow(to: destination)
                    }
                } else if destinationName == StaticConfiguration.destinationNameForSkipBackup || destinationName.isEmpty {
                    Task {
                        await DaemonProxy.shared.logToBackupLog(repositoryName: destinationName, exitStatus: 1, logMessage: "### Skipping backup because script returned \"\(destinationName)\"\n\(errorString)")
                    }
                    os_log("Skipping backup because script returned %{public}@", destinationName)
                } else if destinationName == StaticConfiguration.destinationNameForDeferBackup {
                    shouldRetrySoon = true
                    os_log("deferring because script returned  %{public}@", destinationName)
                } else {
                    NSAlert.presentError("The destination selection script returned the destination name \(destinationName). This name was not found in the current configuration, which contains only \(ConfigurationModel.shared.destinations.map({ $0.name }).joined(separator: ", ")).", title: "Destination for automatic backup not found")
                }
            } else {
                NSAlert.presentError("Error returned by script: \(errorString)", title: "Automatic backup selection script error")
                os_log("error in selection script: %{public}@", errorString)
            }
            if !shouldRetrySoon {
                self.nextBackupTime = Self.nextBackupTimeAfter(now)
            }
        } else {
            os_log("deferring next backup to %{public}@", nextBackupTime.description)
        }
    }

    @MainActor
    func performBackupNow(to destination: BackupDestination) async {
        if let destinationOfRunningBackup {
            _ = await DaemonProxy.shared.logToBackupLog(repositoryName: destination.name, exitStatus: 1, logMessage: "### Skipping backup to \(destination.name) because a backup to \(destinationOfRunningBackup) is currently running.")
            return
        }
        destinationOfRunningBackup = destination.name   // set before status so that it's valid in status observer
        ProgressStatus.shared.setProgressReport("Starting borg")
        let haveFullDiskAccess = await DaemonProxy.shared.haveFullDiskAccess()
        if !haveFullDiskAccess {
            await DaemonProxy.shared.terminate()
            let alert = NSAlert()
            alert.messageText = "Full Disk Access required for Backup"
            alert.informativeText = "Please open System Settings, go to Privacy & Security > Full Disk Access and enable access for ODBackup."
            alert.addButton(withTitle: "Open System Settings")
            _ = alert.runModal()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        } else {
            let model = ConfigurationModel.shared
            while true {
                let (returnCode, errorString) = await DaemonProxy.shared.performBackup(backupRoots: model.backupPaths, excludePatterns: model.excludePatterns, repository: destination.repository, repositoryName: destination.name, passPhrase: destination.passPhrase, rateLimitKBytes: model.rateLimitKBytesPerSecond, rshCommand: model.effectiveRSHCommand, pruneKeepHourly: model.pruneKeepHourly, pruneKeepDaily: model.pruneKeepDaily, pruneKeepWeekly: model.pruneKeepWeekly, pruneKeepMonthly: model.pruneKeepMonthly)
                os_log("backup result = %d, %{public}@", returnCode, errorString)
                LogFilesModel.shared.reload()
                if returnCode == 0 {
                    break   // success
                } else if returnCode == 2 && errorString.firstRange(of: "does not exist.") != nil {
                    // error message: "Repository xxxx does not exist."
                    let alert = NSAlert()
                    alert.messageText = "Repository not initialized or nonexistent"
                    alert.informativeText = "\(destination.repository) is not a valid borg repository. Should we try to initialize it?"
                    alert.addButton(withTitle: "Initialize")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() != .alertFirstButtonReturn {
                        break   // user cancelled
                    }
                    let (returnCode, errorString) = await DaemonProxy.shared.initializeRepository(destination.repository, passPhrase: destination.passPhrase, rshCommand: model.effectiveRSHCommand)
                    if returnCode != 0 {
                        NSAlert.presentError(errorString, title: (returnCode == 1 ? "Warning" : "Error") + " while initializing repository")
                        if returnCode == 2 {
                            break
                        }
                    }
                } else {
                    // other error or warning
                    NSAlert.presentError(errorString, title: (returnCode == 1 ? "Warning" : "Error") + " during backup")
                    break
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.destinationOfRunningBackup = nil   // set before status so that it's valid in status observer
            ProgressStatus.shared.setProgressReport(nil)
        }
    }

    func abortAllBackups() {
        Task {
            await DaemonProxy.shared.abortBackups()
        }
    }

}

extension BackupLogic {

    static func runScript(_ script: String, environment: [String: String]) -> (exitStatus: Int32, stdout: String, stderr: String) {
        var shell = "/bin/zsh"
        if let newline = script.firstIndex(of: "\n"), let match = script.prefix(upTo: newline).firstMatch(of: /^#! *([^ ]+)$/) {
            shell = String(match.output.1)
        }
        os_log("running shell %{public}@", shell)
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-c", script]
        process.environment = environment
        var stdoutData = Data()
        let stdoutReader = PipeReader { stdoutData.append($0) }
        var stderrData = Data()
        let stderrReader = PipeReader { stderrData.append($0) }
        process.standardOutput = stdoutReader.fileHandleForWriting
        process.standardError = stderrReader.fileHandleForWriting
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        do {
            try process.run()
        } catch {
            return (128 + 9, "", error.localizedDescription)
        }
        process.waitUntilExit()
        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? "<invalid UTF-8>"
        let stderrString = String(data: stderrData, encoding: .utf8) ?? "<invlaid UTF-8>"
        return (process.terminationStatus, stdoutString, stderrString)
    }

    func destinationNameFromScript(scheduledForDate: Date) -> (destinationName: String?, stderr: String) {
        let environment = [
            "SCHEDULED_DATETIME": Formatters.simpleISODateTimeString(from: scheduledForDate),
            "WIFI_SSID": Self.wifiSSID() ?? "<not connected>"
        ]
        let (exitStatus, stdout, stderr) = Self.runScript(ConfigurationModel.shared.destinationSelectionScript, environment: environment)
        if exitStatus == 0 && !stdout.isEmpty {
            return (stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), stderr)
        } else {
            return (nil, stderr.isEmpty ? "exit status = \(exitStatus), no error output" : stderr)
        }
    }

}

private extension BackupLogic {

    private static func wifiSSID() -> String? {
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if  SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeIEEE80211,
                let name = SCNetworkInterfaceGetBSDName(interface) as? String,
                let interfaceInfo = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/AirPort" as CFString) as? [String: Any],
                let ssidData = interfaceInfo["SSID"] as? Data
            {
                return String(data: ssidData, encoding: .utf8)
            }
        }
        return nil
    }

}
