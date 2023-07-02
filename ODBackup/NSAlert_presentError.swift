import AppKit
import Foundation

extension NSAlert {

    static func presentError(_ errorMessage: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        // Error messages may be large, truncate to a limit which the alert can handle.
        alert.informativeText = String(errorMessage.prefix(2000))
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

}
