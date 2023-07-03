import AppKit
import Foundation
import os

@objc
class ExtractWindowController: NSWindowController {

    enum Status {
        case showingBackups
        case showingFiles
        case showingExtractionProgress
    }

    static let shared = ExtractWindowController()

    override var windowNibName: NSNib.Name? { "ExtractWindow" }

    @IBOutlet var title: NSTextField!
    @IBOutlet var sectionView: NSView!
    @IBOutlet var progressIndicator: NSProgressIndicator!
    @IBOutlet var stopButton: NSButton!
    @IBOutlet var backButton: NSButton!
    @IBOutlet var continueButton: NSButton!

    @IBOutlet var listingOfBackups: NSView!
    @IBOutlet var listingOfFiles: NSView!
    @IBOutlet var extractionInfo: NSView!

    @IBOutlet var backupsTableView: NSTableView! {
        didSet {
            backupsTableController = SimpleTableController.make(tableView: backupsTableView, observedObject: self, observedKeyPath: \.backupsArray)
            backupsTableView.delegate = self
        }
    }

    @IBOutlet var fileListOutlineView: NSOutlineView! {
        didSet {
            fileListOutlineView.dataSource = self
            fileListOutlineView.delegate = self
        }
    }
    @IBOutlet var fileAttributesTextField: NSTextField!
    @IBOutlet var extractedPathTextField: NSTextField!
    @IBOutlet var extractionCompleteTextField: NSTextField!

    // list of backups available at destination:
    private var backupsTableController: SimpleTableController!
    @objc private dynamic var backupsArray = [BackupNode]()

    private var rootFileNode = FileNode(name: "")

    private var status = Status.showingBackups {
        didSet { switchViewForNewStatus() }
    }
    private var inProgress = false {
        didSet { updateProgressIndication() }
    }
    private var destination: BackupDestination?
    private var archiveName: String?
    private var extractedPath: String?

    func startWithDestination(_ destination: BackupDestination) {
        loadWindow()
        if !inProgress {
            resetFileListing()
            fileListOutlineView.reloadItem(nil, reloadChildren: true)
            archiveName = nil
            extractedPath = nil
            loadAvailableBackups(destination: destination)
        }
    }

}

// MARK: - Extract Logic

private extension ExtractWindowController {

    private func loadAvailableBackups(destination: BackupDestination) {
        self.destination = destination
        status = .showingBackups
        Task {
            inProgress = true
            // defer { inProgress = false }  requires Xcode 15
            backupsArray = []
            let (rval, stdout, stderr) = await DaemonProxy.shared.listArchives(repository: destination.repository, repositoryName: destination.name, passPhrase: destination.passPhrase, rshCommand: ConfigurationModel.shared.effectiveRSHCommand)
            if rval != 0 {
                NSAlert.presentError(stderr, title: "Error obtaining list of backups")
            } else {
                var array = stdout.split(separator: "\n", omittingEmptySubsequences: true).map { BackupNode(outputLine: String($0)) }
                // borg delivers backups sorted by increasing date. We want to have the newest backup on top, so reverse order:
                array.reverse()
                backupsArray = array
            }
            inProgress = false
        }
    }

    private func resetFileListing() {
        rootFileNode.reset()
        fileListOutlineView.reloadItem(nil, reloadChildren: true)
        updateFileAttributes()
    }

    private func loadFileListing(archiveName: String) {
        guard let destination = destination else { return }
        self.archiveName = archiveName
        status = .showingFiles
        resetFileListing()
        Task {
            let startDate = Date()
            inProgress = true
            // defer { inProgress = false }  requires Xcode 15

            let (rval, stderr) = await DaemonProxy.shared.listFiles(repository: destination.repository, repositoryName: destination.name, archive: archiveName, passPhrase: destination.passPhrase, rshCommand: ConfigurationModel.shared.effectiveRSHCommand) { [self] lines in
                self.rootFileNode.addChildren(listingLines: lines) { [self] fileNode in
                    if fileNode === self.rootFileNode {
                        fileListOutlineView.reloadItem(nil, reloadChildren: true)
                    } else {
                        fileListOutlineView.reloadItem(fileNode, reloadChildren: true)
                    }
                }
            }
            let duration = -startDate.timeIntervalSinceNow
            os_log("File listing took \(duration) seconds")
            if rval != 0 {
                NSAlert.presentError(stderr, title: "Error listing files in backup")
            }
            inProgress = false
        }
    }

    private func extractFromArchive(path: String?) {
        guard let destination = destination, let archiveName = archiveName else { return }
        extractedPath = path
        status = .showingExtractionProgress
        Task {
            let startDate = Date()
            inProgress = true
            // defer { inProgress = false }  requires Xcode 15
            let (rval, stderr) = await DaemonProxy.shared.extractFiles(repository: destination.repository, repositoryName: destination.name, archive: archiveName, path: path, passPhrase: destination.passPhrase, rshCommand: ConfigurationModel.shared.effectiveRSHCommand)
            let duration = -startDate.timeIntervalSinceNow
            os_log("File extraction took \(duration) seconds")
            if rval != 0 {
                NSAlert.presentError(stderr, title: "Error during extract")
            }
            inProgress = false
        }
    }


}

// MARK: - Computed properties for bindings from XIB

extension ExtractWindowController {

    @objc var monospacedDigitFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
    }

}

// MARK: - IBActions

extension ExtractWindowController {

    @IBAction func continueAction(_ sender: Any?) {
        switch status {
        case .showingBackups:
            let rowIndex = backupsTableView.selectedRow
            guard rowIndex >= 0 && rowIndex < backupsArray.count else { return }
            loadFileListing(archiveName: backupsArray[rowIndex].name)

        case .showingFiles:
            let rowIndex = fileListOutlineView.selectedRow
            var path: String?
            if rowIndex >= 0, let selectedFile = fileListOutlineView.item(atRow: rowIndex) as? FileNode {
                var node: FileNode? = selectedFile
                path = selectedFile.name
                while node != nil {
                    node = fileListOutlineView.parent(forItem: node) as? FileNode
                    path = (node?.name ?? "") + "/" + path!
                }
            }
            print("path = \(path ?? "<nil>")")
            extractFromArchive(path: path)

        case .showingExtractionProgress:
            break
        }
    }

    @IBAction func stopAction(_ sender: Any?) {
        Task {
            switch status {
            case .showingBackups, .showingFiles:
                await DaemonProxy.shared.abortListings()

            case .showingExtractionProgress:
                await DaemonProxy.shared.abortExtractions()
            }
        }
    }

    @IBAction func backAction(_ sender: Any?) {
        switch status {
        case .showingBackups:
            break

        case .showingFiles:
            archiveName = nil
            status = .showingBackups

        case .showingExtractionProgress:
            extractedPath = nil
            status = .showingFiles
        }
    }
}

// MARK: - View update logic

private extension ExtractWindowController {

    private func switchViewForNewStatus() {
        switch status {
        case .showingBackups:
            title.stringValue = "Backups found in \(destination?.name ?? "<nil>")"
            listingOfBackups.frame = sectionView.bounds
            sectionView.subviews = [listingOfBackups]

        case .showingFiles:
            title.stringValue = "Files in \(destination?.name ?? "<nil>") \(archiveName ?? "<nil>")"
            listingOfFiles.frame = sectionView.bounds
            sectionView.subviews = [listingOfFiles]

        case .showingExtractionProgress:
            title.stringValue = "Restoring from \(destination?.name ?? "<nil>") \(archiveName ?? "<nil>")"
            extractionInfo.frame = sectionView.bounds
            sectionView.subviews = [extractionInfo]
            updateExtractedPath()
        }
        updateExtractionComplete()
        updateContinueButton()
        updateBackButtonVisibility()
    }

    private func updateProgressIndication() {
        window?.standardWindowButton(.closeButton)?.isHidden = inProgress
        progressIndicator.isHidden = !inProgress
        stopButton.isHidden = !inProgress
        updateContinueButton()
        updateBackButtonVisibility()
        if inProgress {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        updateExtractionComplete()
    }

    private func updateBackButtonVisibility() {
        backButton.isHidden = inProgress || status == .showingBackups
    }

    private func updateContinueButton() {
        switch status {
        case .showingBackups:
            continueButton.isEnabled = !inProgress && backupsTableView.selectedRow >= 0
            continueButton.isHidden = false
            continueButton.title = "Continue"
        case .showingFiles:
            continueButton.isEnabled = !inProgress  // we don't need a selection, we can extract the entire archive
            continueButton.isHidden = false
            continueButton.title = "Extract"
        case .showingExtractionProgress:
            continueButton.isHidden = true
        }
    }

    private func updateFileAttributes() {
        let rowIndex = fileListOutlineView.selectedRow
        guard rowIndex >= 0, let selectedFile = fileListOutlineView.item(atRow: rowIndex) as? FileNode else {
            fileAttributesTextField.stringValue = ""
            return
        }
        fileAttributesTextField.stringValue = String(format: "%@ %@ %@ %@   %@   %@",
            selectedFile.mode.leftPad(10),
            selectedFile.owner.leftPad(10),
            selectedFile.group.leftPad(10),
            selectedFile.sizeDisplayString.leftPad(9),
            selectedFile.mtimeDisplayString.leftPad(20),
            selectedFile.fileCountDisplayString
        )
    }

    private func updateExtractedPath() {
        extractedPathTextField.stringValue = extractedPath ?? "(Entire Archive)"
    }

    private func updateExtractionComplete() {
        extractionCompleteTextField.isHidden = status != .showingExtractionProgress || inProgress
    }
}

// MARK: - Delegate and Data Source implementations

extension ExtractWindowController: NSTableViewDelegate {

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateContinueButton()
    }

}

extension ExtractWindowController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let fileNode = item as? FileNode ?? rootFileNode
        return fileNode.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let fileNode = item as? FileNode ?? rootFileNode
        return fileNode.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let fileNode = item as? FileNode ?? rootFileNode
        return fileNode.mode.isEmpty || fileNode.mode.hasPrefix("d")
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        item as? FileNode ?? rootFileNode
    }

}

extension ExtractWindowController: NSOutlineViewDelegate {

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateFileAttributes()
        updateContinueButton()
    }

}

// MARK: - Helper Classes

@objc
class BackupNode: NSObject {
    @objc dynamic let name: String
    @objc dynamic let date: String

    init(outputLine: String) {
        let components = outputLine.split(separator: "\t", omittingEmptySubsequences: false)
        name = String(components[0])
        if components.count > 1 {
            date = String(components[1])
        } else {
            date = ""
        }
    }

}

private extension String {

    func leftPad(_ size: Int) -> String {
        if count == size {
            return self
        } else if count > size {
            return String(prefix(size))
        } else {
            return String(repeating: " ", count: size - count) + self
        }
    }
}
