import AppKit
import Foundation

// This controller is for the following menu items:
// - last successful backup
// - current backup status
// - backup now


@objc
class MenuController: NSObject {

    var lastCheckpointObservation: NSKeyValueObservation?
    var lastProgressReportObservation: NSKeyValueObservation?
    var logFilesObservation: NSKeyValueObservation?
    var destinationsObservation: NSKeyValueObservation?
    var isRunningObservation: NSKeyValueObservation?
    var nextBackupTimeObservation: NSKeyValueObservation?

    @IBOutlet var fileMenu: NSMenu!
    @IBOutlet var backupInfoMenuItem: NSMenuItem!
    @IBOutlet var currentBackupCheckpoint: NSMenuItem!
    @IBOutlet var lastSuccessfulBackup: NSMenuItem!
    @IBOutlet var abortCurrentBackupItem: NSMenuItem!

    @IBOutlet var backupNowMenu: NSMenu!
    @IBOutlet var extractMenu: NSMenu!

    private var statusItem: NSStatusItem?

    private var isRunningAnimationTimer: Timer?
    private var isRunningAnimationCounter = 0
    @objc private(set) dynamic var backupIsRunning = false {
        didSet { updateIsRunningAnimation() }
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        let progressStatus = ProgressStatus.shared
        lastCheckpointObservation = progressStatus.observe(\.lastCheckpointDate, options: .initial) { [weak self] progressStatus, _ in
            self?.updateCheckpointInfo(progressStatus: progressStatus)
        }
        lastProgressReportObservation = progressStatus.observe(\.lastProgressReport, options: .initial) { [weak self] progressStatus, _ in
            self?.updateBackupProgress(progressStatus: progressStatus)
        }
        logFilesObservation = LogFilesModel.shared.observe(\.logFiles, options: .initial) { [weak self] logFilesModel, _ in
            self?.updateLastSuccessfulBackup(logFilesModel: logFilesModel)
        }
        destinationsObservation = ConfigurationModel.shared.observe(\.destinations, options: .initial) { [weak self] configuration, _ in
            self?.updateBackupDestinations(configuration: configuration)
        }
        isRunningObservation = BackupLogic.shared.observe(\.destinationOfRunningBackup, options: .initial) { [weak self] backupLogic, _ in
            self?.backupIsRunning = backupLogic.destinationOfRunningBackup != nil
        }
        nextBackupTimeObservation = BackupLogic.shared.observe(\.nextBackupTime, options: .initial) { [weak self] backupLogic, _ in
            self?.updateLastSuccessfulBackup(logFilesModel: LogFilesModel.shared)
        }
    }

}

extension MenuController {

    @IBAction func abortCurrentBackup(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Really abort running backup?"
        alert.addButton(withTitle: "Abort Backup")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // assuming that we always have only one backup running
        BackupLogic.shared.abortAllBackups()
    }

    @IBAction func backupNow(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        guard let destination = menuItem.representedObject as? BackupDestination else { return }
        Task {
            await BackupLogic.shared.performBackupNow(to: destination)
        }
    }

    @IBAction func settings(_ sender: Any?) {
        guard let window = SettingsWindowController.shared.window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func logFiles(_ sender: Any?) {
        guard let window = LogFilesWindowController.shared.window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func extract(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        guard let destination = menuItem.representedObject as? BackupDestination else { return }
        ExtractWindowController.shared.startWithDestination(destination)
        guard let window = ExtractWindowController.shared.window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

}

// Handling of Status Menu Item
extension MenuController {

    func statusItemImage(rotatedBy angle: CGFloat) -> NSImage? {
        let image = NSImage(named: "StatusMenuItem")
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        return image?.rotated(by: angle)
    }

    func showStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        statusItem.menu = fileMenu
        if let button = statusItem.button {
            button.image = statusItemImage(rotatedBy: 0)
            button.alignment = .center
            button.font = NSFont.systemFont(ofSize: 0, weight: .bold)
        }
        updateStatusItemFailureIndication()
    }

    private func updateStatusItemFailureIndication() {
        statusItem?.button?.title = LogFilesModel.shared.lastCompletedBackupLog?.status == .error ? "!" : ""
    }

    private func updateIsRunningAnimation() {
        guard backupIsRunning != (isRunningAnimationTimer != nil) else { return }   // nothing to do
        if backupIsRunning {
            isRunningAnimationCounter = 0
            isRunningAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.statusItem?.button?.image = self.statusItemImage(rotatedBy: CGFloat(self.isRunningAnimationCounter))
                self.isRunningAnimationCounter += 8
                self.isRunningAnimationCounter %= 360
            }
            // We want to have the animation running even when the menu is open
            RunLoop.current.add(isRunningAnimationTimer!, forMode: .eventTracking)
            RunLoop.current.add(isRunningAnimationTimer!, forMode: .modalPanel)
        } else {
            isRunningAnimationTimer?.invalidate()
            isRunningAnimationTimer = nil
            statusItem?.button?.image = statusItemImage(rotatedBy: 0)
        }
    }
}

private extension MenuController {

    private func updateCheckpointInfo(progressStatus: ProgressStatus) {
        if let lastCheckpoint = progressStatus.lastCheckpointDate, BackupLogic.shared.destinationOfRunningBackup != nil {
            currentBackupCheckpoint.title = "Last Checkpoint: \(Formatters.timeString(from: lastCheckpoint))"
            currentBackupCheckpoint.isHidden = false
        } else {
            currentBackupCheckpoint.isHidden = true
        }
    }

    private func updateBackupProgress(progressStatus: ProgressStatus) {
        let destinationName = BackupLogic.shared.destinationOfRunningBackup
        let backupIsRunning = destinationName != nil

        backupInfoMenuItem.isHidden = !backupIsRunning
        abortCurrentBackupItem.isHidden = !backupIsRunning
        if backupIsRunning {
            let normalSizeAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0)]
            let smallSizeAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
            let info = NSMutableAttributedString()
            info.appendLine("Backing up to " + (destinationName ?? "<nil>"), attributes: normalSizeAttributes)
            if let parsedReport = progressStatus.parsedReport {
                info.appendLine("\t\(Formatters.string(fromFileCount: Int64(parsedReport.filesProcessed))) files processed", attributes: smallSizeAttributes)
                info.appendLine("\t\(parsedReport.bytesChecked) checked", attributes: smallSizeAttributes)
                info.appendLine("\t\(parsedReport.deduplicatedBytes) archived", attributes: smallSizeAttributes)
                info.appendLine("\t" + (progressStatus.unparseableReport ?? parsedReport.currentFile), attributes: smallSizeAttributes)
            } else if let reportString = progressStatus.lastProgressReport {
                // If we have no file progress info, show any info we have
                info.appendLine("\t" + reportString, attributes: smallSizeAttributes)
            }
            let paragraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
            paragraphStyle.tabStops = [
                NSTextTab(type: .leftTabStopType, location: 8),
            ]
            info.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: info.length))
            backupInfoMenuItem.attributedTitle = info
        }
    }

    private func updateLastSuccessfulBackup(logFilesModel: LogFilesModel) {
        var lines = [String]()
        let lastSuccessfulBackupLog = logFilesModel.lastSuccessfulBackupLog
        updateStatusItemFailureIndication()
        if let lastBackupLog = logFilesModel.lastCompletedBackupLog {
            if lastBackupLog != lastSuccessfulBackupLog {
                lines.append("Backup failed at \(lastBackupLog.timestamp)")
            }
            if let lastSuccessfulBackupLog {
                lines.append("Last successful backup\n\(lastSuccessfulBackupLog.timestamp) to \(lastSuccessfulBackupLog.destinationName)")
            }
        } else {
            lines.append("No backup so far")
        }
        if let nextBackupTime = BackupLogic.shared.nextBackupTime {
            if nextBackupTime.timeIntervalSinceNow < 0 {
                lines.append("Next backup: now")
            } else {
                lines.append("Next backup: \(Formatters.timeString(from: nextBackupTime))")
            }
        } else {
            lines.append("No automatic backup scheduled.")
        }
        lastSuccessfulBackup.attributedTitle = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: NSFont.systemFont(ofSize: 11)])
    }

    private func updateBackupDestinations(configuration: ConfigurationModel) {
        backupNowMenu.items = configuration.destinations.map { destination in
            let menuItem = NSMenuItem(title: "To " + destination.name, action: #selector(backupNow(_:)), keyEquivalent: "")
            menuItem.representedObject = destination
            menuItem.target = self
            return menuItem
        }
        extractMenu.items = configuration.destinations.map { destination in
            let menuItem = NSMenuItem(title: "From " + destination.name + "…", action: #selector(extract(_:)), keyEquivalent: "")
            menuItem.representedObject = destination
            menuItem.target = self
            return menuItem
        }
    }

}

private extension NSMutableAttributedString {

    func appendLine(_ string: String, attributes: [NSAttributedString.Key: Any]?) {
        let length = length
        if length != 0 {
            replaceCharacters(in: NSRange(location: length, length: 0), with: "\n")
        }
        append(NSAttributedString(string: string, attributes: attributes))
    }

}

private extension NSImage {
    // Rotates around center
    func rotated(by angle: CGFloat) -> NSImage {
        let image = NSImage(size: self.size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.size.width / 2, yBy: rect.size.height / 2)
            transform.rotate(byDegrees: angle)
            transform.translateX(by: -rect.size.width / 2, yBy: -rect.size.height / 2)
            transform.concat()
            self.draw(in: rect)
            return true
        }
        image.isTemplate = self.isTemplate
        return image
    }
}
