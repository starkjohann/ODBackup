import AppKit
import Foundation

class LogFilesWindowController: NSWindowController {

    static let shared = LogFilesWindowController()

    override var windowNibName: NSNib.Name? { "LogFilesWindow" }

    @IBOutlet var logFilesTableView: NSTableView! {
        didSet {
            logFilesTableController = SimpleTableController.make(tableView: logFilesTableView, observedObject: self, observedKeyPath: \.logFilesModel.logFiles)
            logFilesTableView.doubleAction = #selector(tableDoubleClickAction(_:))
        }
    }
    private var logFilesTableController: SimpleTableController!

    // for KVO
    @objc private var logFilesModel: LogFilesModel {
        LogFilesModel.shared
    }

    @IBAction func tableDoubleClickAction(_ sender: Any?) {
        NSWorkspace.shared.open(logFilesModel.logFiles[logFilesTableView.selectedRow].fileURL)
    }

}

// for UI
extension LogFile {

    @objc dynamic var textColor: NSColor? {
        status == .error ? NSColor.red : nil
    }

    @objc var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
    }

}
