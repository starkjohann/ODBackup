import AppKit
import Foundation
import os
import ServiceManagement

@MainActor
class DaemonProxy {

    static let shared = DaemonProxy()

    static let lineBufferDispatchQueue = DispatchQueue(label: "lineBufferDispatchQueue", attributes: [])  // serial queue

    private let myBundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private let daemonService = SMAppService.daemon(plistName: "at.obdev.odbackup.daemon.plist")

    private var _daemonConnection: NSXPCConnection? // storage for computed property below
    var daemonConnection: NSXPCConnection? {
        get async {
            if _daemonConnection == nil {
                _daemonConnection = await connectToDaemon()
            }
            return _daemonConnection
        }
    }

    private var shouldReloadLogFilesModel = false

    private var lastIncompleteLine = Data()     // accessed from lineBufferDispatchQueue
    private var lineBuffer = [String]()         // accessed from lineBufferDispatchQueue
    private var didScheduleLineBufferProcessing = false // accessed from lineBufferDispatchQueue
    private var stdoutHandler: ((Data) -> Void)?

    func unregisterLaunchDaemon() {
        do {
            try daemonService.unregister()
            NSApp.terminate(nil)
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }

    private func registerLaunchDaemon() -> SMAppService.Status {
        var status = SMAppService.Status.notRegistered
        var lastError: Error?
        for remainingIterations in (0 ..< 10).reversed() {
            try? daemonService.unregister() // restart from scratch to update LaunchDaemon service
            do {
                // We get a runtime warning that this call may block the main thread for a while.
                // In fact, it seems to take about 40 ms in our case and we want to use the result
                // synchronously, so we ignore the warning.
                try daemonService.register()
            } catch {
                lastError = error
                os_log("Error registering daemon service: %{public}@, retrying %ld more times", error.localizedDescription, remainingIterations)
            }
            status = daemonService.status
            if status == .enabled || status == .requiresApproval {
                break
            }
            // If registration fails for no apparent reason, it usually succeeds after
            // waiting for a while. So try a couple of times and wait 100ms in between.
            usleep(100_1000)
        }
        if status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Waiting for approval"
            alert.informativeText = "Please allow ODBackup to launch a privileged daemon in System Settings > General > Login Items."
            alert.addButton(withTitle: "Open System Settings")
            alert.runModal()
            SMAppService.openSystemSettingsLoginItems()
        } else if status != .enabled {
            let alert: NSAlert
            if let lastError = lastError {
                alert = NSAlert(error: lastError)
                alert.informativeText = "Failed to register privileged daemon. This daemon is required to perform a backup."
            } else {
                alert = NSAlert()
                alert.messageText = "Error registering privileged helper daemon"
            }
            alert.runModal()
        }
        return status
    }

    private func connectToDaemon() async -> NSXPCConnection? {
        for remainingIterations in (0 ..< 5).reversed() {
            let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: BackupDaemonProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: BackupClientProtocol.self)
            connection.exportedObject = self
            // no need for a weak self here because this class is a singleton anyway
            connection.invalidationHandler = {
                os_log("daemon connection invalidated")
                self._daemonConnection = nil
            }
            connection.interruptionHandler = {
                os_log("daemon connection interrupted")
                self._daemonConnection = nil
            }
            connection.resume()
            let daemonBundleVersion: String? = await withCheckedContinuation { continuation in
                // If the launchd registration of our daemon is broken, connecting to the
                // daemon will hang indefinitely. The `bundleVersion()` call below should
                // finish in milliseconds. Set up a 1 second timeout.
                var workItem: DispatchWorkItem?
                workItem = DispatchWorkItem {
                    workItem = nil
                    os_log("timeout connecting to backup daemon")
                    continuation.resume(returning: nil)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0, execute: workItem!)
                guard let daemon = connection.remoteObjectProxyWithErrorHandler({ _ in
                    if let workItem {
                        workItem.cancel()
                        continuation.resume(returning: nil) // we don't care about the exact error
                    }
                }) as? BackupDaemonProtocol else {
                    fatalError("daemon proxy is nil")
                }
                daemon.bundleVersion(clientBundleversion: myBundleVersion) {
                    if let workItem {
                        workItem.cancel()
                        continuation.resume(returning: $0)
                    }
                }
            }
            if let daemonBundleVersion = daemonBundleVersion {
                if daemonBundleVersion != myBundleVersion {
                    os_log("bundle version mismatch: %{public}@ vs %{public}@", daemonBundleVersion, self.myBundleVersion)
                } else {
                    // success, we have a connection and the versions match.
                    return connection
                }
            } else {
                os_log("could not connect to daemon")
            }
            // failed for some reaons. Retry.
            if registerLaunchDaemon() != .enabled {
                return nil  // useless to retry, return an error
            }
            os_log("retrying \(remainingIterations) more times")
        }
        return nil
    }

}

extension DaemonProxy {

    func sshPublicKey() async -> String? {
        guard let connection = await daemonConnection else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: nil)
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.getSSHPublicKey {
                continuation.resume(returning: $0)
            }
        }
    }

    func setSSHKeys(public publicKey: String, private privateKey: String) async -> NSError? {
        guard let connection = await daemonConnection else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: error as NSError)
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.setSSHKeys(public: publicKey, private: privateKey) {
                continuation.resume(returning: $0)
            }
        }
    }

    // returns error message from ssh-keygen on error, `nil` on success
    func generateNewSSHKeys() async -> String? {
        guard let connection = await daemonConnection else {
            return "Error connecting to daemon"
        }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: error.localizedDescription)
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.generateNewSSHKeys {
                continuation.resume(returning: $0)
            }
        }
    }

    private func checkFullDiskAccess() async -> (Int32, String) {
        guard let connection = await daemonConnection else {
            return (-1, "Error connecting to backup daemon")
        }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (-1, error.localizedDescription))
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.checkFullDiskAccess() {
                continuation.resume(returning: ($0, $1))
            }
        }
    }

    func haveFullDiskAccess() async -> Bool {
        let (rval, stderr) = await checkFullDiskAccess()
        if rval != 0 && stderr.firstRange(of: "Operation not permitted") != nil {
            // the script returned an error code and the error text contains
            // "EPERM", so we assume that we are lacking full disk access
            return false
        } else {
            return true
        }
    }

    func terminate() async {
        if let connection = await daemonConnection {
            (connection.remoteObjectProxy as? BackupDaemonProtocol)?.terminate()
        }
    }

    func initializeRepository(_ repository: String, passPhrase: String, rshCommand: String) async -> (Int32, String) {
        guard let connection = await daemonConnection else {
            return (-1, "Error connecting to backup daemon")
        }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (-1, error.localizedDescription))
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.initializeRepository(repository, passPhrase: passPhrase, rshCommand: rshCommand) {
                continuation.resume(returning: ($0, $1))
            }
        }
    }

    func performBackup(backupRoots: [String], excludePatterns: [String], repository: String, repositoryName: String, passPhrase: String, rateLimitKBytes: Int, rshCommand: String, pruneKeepHourly: Int, pruneKeepDaily: Int, pruneKeepWeekly: Int, pruneKeepMonthly: Int) async -> (Int32, String) {
        guard let connection = await daemonConnection else {
            return (-1, "Error connecting to backup daemon")
        }
        shouldReloadLogFilesModel = true
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (-1, error.localizedDescription))
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.performBackup(backupRoots: backupRoots, excludePatterns: excludePatterns, repository: repository, repositoryName: repositoryName, passPhrase: passPhrase, rateLimitKBytes: rateLimitKBytes, rshCommand: rshCommand, pruneKeepHourly: pruneKeepHourly, pruneKeepDaily: pruneKeepDaily, pruneKeepWeekly: pruneKeepWeekly, pruneKeepMonthly: pruneKeepMonthly) {
                continuation.resume(returning: ($0, $1))
            }
        }
    }

    func listArchives(repository: String, repositoryName: String, passPhrase: String, rshCommand: String) async -> (Int32, stdout: String, stderr: String) {
        guard let connection = await daemonConnection else {
            return (-1, "", "Error connecting to backup daemon")
        }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (-1, "", error.localizedDescription))
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.listArchives(repository: repository, repositoryName: repositoryName, passPhrase: passPhrase, rshCommand: rshCommand) {
                continuation.resume(returning: ($0, $1, $2))
            }
        }
    }

    func listFiles(repository: String, repositoryName: String, archive: String, passPhrase: String, rshCommand: String, lineCallback: @escaping ([String]) -> Void) async -> (Int32, String) {
        guard let connection = await daemonConnection else {
            return (-1, "Error connecting to backup daemon")
        }
        stdoutHandler = { self.flushListingLines(buffer: $0, reportCallback: lineCallback) }
        defer { stdoutHandler = nil }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (-1, error.localizedDescription))
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.listFiles(repository: repository, repositoryName: repositoryName, archive: archive, passPhrase: passPhrase, rshCommand: rshCommand) { [self] in
                flushListingLines(buffer: nil, reportCallback: lineCallback)
                continuation.resume(returning: ($0, $1))
            }
        }
    }

    func extractFiles(repository: String, repositoryName: String, archive: String, path: String?, passPhrase: String, rshCommand: String) async -> (Int32, String) {
        guard let connection = await daemonConnection else {
            return (-1, "Error connecting to backup daemon")
        }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (-1, error.localizedDescription))
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.extractFiles(repository: repository, repositoryName: repositoryName, archive: archive, path: path, passPhrase: passPhrase, rshCommand: rshCommand) {
                continuation.resume(returning: ($0, $1))
            }
        }
    }

    func logToBackupLog(repositoryName: String, exitStatus: Int32, logMessage: String) async -> (Int32, String) {
        guard let connection = await daemonConnection else {
            return (-1, "Error connecting to backup daemon")
        }
        return await withCheckedContinuation { continuation in
            guard let daemon = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(returning: (-1, error.localizedDescription))
            }) as? BackupDaemonProtocol else {
                fatalError("daemon proxy is nil")
            }
            daemon.logToBackupLog(repositoryName: repositoryName, exitStatus: exitStatus, logMessage: logMessage) {
                continuation.resume(returning: ($0, $1))
            }
        }
    }

    func abortBackups() async {
        guard let connection = await daemonConnection else {
            return
        }
        (connection.remoteObjectProxy as? BackupDaemonProtocol)?.abortBackups()
    }

    func abortListings() async {
        guard let connection = await daemonConnection else {
            return
        }
        (connection.remoteObjectProxy as? BackupDaemonProtocol)?.abortListings()
    }

    func abortExtractions() async {
        guard let connection = await daemonConnection else {
            return
        }
        (connection.remoteObjectProxy as? BackupDaemonProtocol)?.abortExtractions()
    }

    func scheduleWake(date: Date) async {
        guard let connection = await daemonConnection else {
            return
        }
        (connection.remoteObjectProxy as? BackupDaemonProtocol)?.scheduleWake(date: date)
    }

}

extension DaemonProxy: BackupClientProtocol {

    func reportProgress(_ info: String) {
        // may be called by XPC thread
        DispatchQueue.main.async { [self] in
            let trimmedInfo = info.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmedInfo.isEmpty {
                ProgressStatus.shared.setProgressReport(trimmedInfo)
            }
            if shouldReloadLogFilesModel {
                shouldReloadLogFilesModel = false
                LogFilesModel.shared.reload()
            }
        }
    }

    func reportListingData(_ data: Data) {
        stdoutHandler?(data)
    }

    fileprivate func flushListingLines(buffer: Data?, reportCallback: @escaping ([String]) -> Void) {
        Self.lineBufferDispatchQueue.sync {
            var lines: [Data.SubSequence]
            if let buffer {
                lines = buffer.splitAtByte(0x0a)    // we could do this outside of lineBufferDispatchQueue if this promotes concurrency
                let firstLine = lines[0]
                lastIncompleteLine.append(firstLine)
                lines[0] = lastIncompleteLine
                lastIncompleteLine = Data(lines.popLast()!)
            } else {
                lines = [lastIncompleteLine]
                lastIncompleteLine = Data()
            }
            lineBuffer += lines.map { String(data: $0, encoding: .utf8) ?? "UTF-8 encoding error" }
            if !didScheduleLineBufferProcessing {
                didScheduleLineBufferProcessing = true
                DispatchQueue.main.async { [self] in
                    var lines: [String]?
                    Self.lineBufferDispatchQueue.sync {
                        lines = lineBuffer
                        lineBuffer = []
                        didScheduleLineBufferProcessing = false
                    }
                    reportCallback(lines!)
                }
            }
        }
    }

}

private extension Data {

    // This is a performant replacement for `split(separator: ...)` of `Collection`.
    func splitAtByte(_ byte: UInt8) -> [Data.SubSequence] {
        guard !isEmpty else {
            return []
        }
        let count = count
        return withUnsafeBytes { rawBufferPointer in
            let rawBufferPointer: UnsafeRawBufferPointer = rawBufferPointer // enforce type, otherwise automatic type inference gets confused
            var subsequences = [Data.SubSequence]()
            var indexAfterMatch = 0
            var i = 0   // iterate manually instead of `for i in 0 ..< count` because that's fast even in debug builds
            while i < count {
                if rawBufferPointer[i] == byte {
                    subsequences.append(self[indexAfterMatch ..< i])
                    indexAfterMatch = i + 1
                }
                i += 1
            }
            subsequences.append(self[indexAfterMatch ..< count])
            return subsequences
        }
    }

}
