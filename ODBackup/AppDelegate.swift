import Cocoa
import ServiceManagement
import os

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet var menuController: MenuController!


    @IBAction func unregisterLaunchDaemon(_ sender: Any?) {
        DaemonProxy.shared.unregisterLaunchDaemon()
    }

    private func validateDaemonConnection() {
        if !ConfigurationModel.shared.isEmpty {
            Task { @MainActor in
                _ = await DaemonProxy.shared.daemonConnection
            }
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        validateDaemonConnection()
        _ = BackupLogic.shared  // ensure that the shared instance is allocated and runs its background tasks
        menuController.showStatusItem()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            menuController.settings(nil)
            return true
        } else {
            return false
        }
    }

}

