import Cocoa
import Foundation

class InfoWindowController: NSWindowController {

    static let shared = InfoWindowController()

    override var windowNibName: NSNib.Name? { "InfoWindow" }

    @objc dynamic var text = ""

    func showInfoText(_ text: String) {
        self.text = text
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

}
