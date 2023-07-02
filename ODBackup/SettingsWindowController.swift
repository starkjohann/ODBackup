import AppKit
import Foundation


class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    override var windowNibName: NSNib.Name? { "SettingsWindow" }

    @IBOutlet var backupPathsTableView: NSTableView! {
        didSet {
            backupPathsTableController = SimpleTableController.make(tableView: backupPathsTableView, observedObject: self, observedKeyPath: \.model.backupPaths)
        }
    }

    @IBOutlet var excludePatternsTableView: NSTableView! {
        didSet {
            excludePatternsTableController = SimpleTableController.make(tableView: excludePatternsTableView, observedObject: self, observedKeyPath: \.model.excludePatterns)
        }
    }

    @IBOutlet var destinationsTableView: NSTableView! {
        didSet {
            destinationsTableController = SimpleTableController.make(tableView: destinationsTableView, observedObject: self, observedKeyPath: \.model.destinations)
        }
    }

    var backupPathsTableController: SimpleTableController!
    var excludePatternsTableController: SimpleTableController!
    var destinationsTableController: SimpleTableController!

}

// MARK: - Computed properties for bindings

extension SettingsWindowController {

    @objc var model: ConfigurationModel { ConfigurationModel.shared }   // make static var an instance property for KVO and bindings

}

// MARK: - Actions

extension SettingsWindowController {

    @IBAction func addBackupPath(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.resolvesAliases = false
        openPanel.showsHiddenFiles = true
        openPanel.directoryURL = StaticConfiguration.dataVolumeURL
        if openPanel.runModal() == .OK {
            let volumePath = StaticConfiguration.dataVolumeURL.path
            let addedPaths = openPanel.urls.map { $0.path }
            var validatedPaths = [String]()
            for path in addedPaths {
                if path.hasPrefix(volumePath) {
                    validatedPaths.append(String(path.dropFirst(volumePath.count + 1)))
                } else {
                    let relativePath = String(path.dropFirst())
                    if FileManager.default.fileExists(atPath: StaticConfiguration.dataVolumeURL.appending(path: relativePath).path) {
                        validatedPaths.append(relativePath)
                    } else {
                        NSAlert.presentError("Backup directories must be on the Data Volume. The directory \(path) is not on \(StaticConfiguration.dataVolumeURL.path).", title: "Directory not on Data Volume")
                    }
                }
            }
            // Avoid empty string, replace with "current directory"
            model.backupPaths += validatedPaths.map { $0.isEmpty ? "." : $0 }
        }
    }

    @IBAction func removeBackupPaths(_ sender: Any?) {
        backupPathsTableController.delete(sender)
    }

    @IBAction func addExcludePatterns(_ sender: Any?) {
        var patterns = model.excludePatterns
        let row = patterns.count
        patterns.append("**/*.nobackup")
        model.excludePatterns = patterns
        DispatchQueue.main.async { [self] in
            // For reasons not comprehensible to me, this works only after a delay.
            excludePatternsTableView.editColumn(0, row: row, with: nil, select: true)
        }
    }

    @IBAction func removeExcludePatterns(_ sender: Any?) {
        excludePatternsTableController.delete(sender)
    }

    @IBAction func addDestination(_ sender: Any?) {
        var d = model.destinations
        let row = d.count
        d.append(BackupDestination())
        model.destinations = d
        DispatchQueue.main.async { [self] in
            // For reasons not comprehensible to me, this works only after a delay.
            destinationsTableView.editColumn(0, row: row, with: nil, select: true)
        }
    }

    @IBAction func removeDestinations(_ sender: Any?) {
        destinationsTableController.delete(sender)
    }

    @IBAction func testDestinationSelectionScript(_ sender: Any?) {
        let (destinationName, errorString) = BackupLogic.shared.destinationNameFromScript(scheduledForDate: Date())
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        if let destinationName {
            let destination = ConfigurationModel.shared.destinations.first { $0.name.lowercased() == destinationName.lowercased() }
            if let destination {
                alert.messageText = "Script returned valid destination"
                alert.informativeText = "Destination name is \"\(destinationName)\", repo URL is \"\(destination.repository)\""
            } else {
                alert.messageText = "Script returned invalid destination"
                alert.informativeText = "Destination name is \"\(destinationName)\" not found in configuration"
            }
        } else {
            alert.messageText = "Script reported an error"
            alert.informativeText = "Error: \(errorString)"
        }
        _ = alert.runModal()
    }

    @IBAction func importSSHKeys(_ sender: Any?) {
        Task { @MainActor in
            guard await allowsSSHKeyCreation() else { return }
            let openPanel = NSOpenPanel()
            openPanel.showsHiddenFiles = true
            if openPanel.runModal() == .OK {
                do {
                    guard let url = openPanel.url else { return }
                    try await ConfigurationModel.shared.loadKeysFromFile(url)
                } catch {
                    let alert = NSAlert(error: error)
                    _ = alert.runModal()
                }
            }
        }
    }

    @IBAction func generateSSHKeys(_ sender: Any?) {
        Task { @MainActor in
            guard await allowsSSHKeyCreation() else { return }
            if let errorString = await ConfigurationModel.shared.generateNewKey() {
                NSAlert.presentError(errorString, title: "Error generating SSH keypair")
            }
        }
    }

}

private extension SettingsWindowController {

    private func allowsSSHKeyCreation() async -> Bool {
        if await DaemonProxy.shared.sshPublicKey() != nil {
            let alert = NSAlert()
            alert.messageText = "Overwrite existing SSH keypair?"
            alert.informativeText = "An SSH keypair was already generated or imported. Do you really want to overwrite it?"
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        } else {
            return true
        }
    }

}
