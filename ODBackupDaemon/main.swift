import Foundation
import os

// Global XPCs survive when the app is moved to the trash or/and replaced with a new one.
// This has the effect that the new app connects to the old XPC, which is not desired
// because the new app may contain an XPC with new features and bug fixes. We therefore
// check the path when a client connects and terminate if it has changed.
// Globals in main.swift are initialized in order (not lazily), so these must be set
// before the listener is resumed, otherwise an incoming connection may read them
// uninitialized.
let myPID = getpid()
let myInitialPath = pathForPID(myPID)
os_log("ODBackupDaemon started at path %{public}@", myInitialPath)

// We need to assign the delegate to a variable because listener does not retain its delegate.
let delegate = ServiceDelegate()

let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate
listener.resume()

// Contrary to a service listener, the mach service listener returns from `resume()`.
// We therefore need a run loop.
RunLoop.current.run()
// runloop never returns
exit(0)

class ServiceDelegate: NSObject, NSXPCListenerDelegate {


    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {

        // Check only during new connections so that we don't endanger running backups when
        // the app is renamed or moved.
        checkForReplacedBinary()

        var clientAuditToken = connection.auditToken
        let attributes: [CFString: NSData] = [kSecGuestAttributeAudit: NSData(bytes: &clientAuditToken, length: MemoryLayout.size(ofValue: clientAuditToken))]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess, let code = code else {
            os_log("Cannot obtain identity of peer, rejecting connection")
            return false
        }
        guard SecCodeCheckValidityWithErrors(code, [], CodeSignatureChecking.requirement, nil) == errSecSuccess else {
            os_log("Peer does not meet requirement, rejecting connection")
            return false
        }

        connection.remoteObjectInterface = NSXPCInterface(with: BackupClientProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: BackupDaemonProtocol.self)
        connection.exportedObject = BackupDaemon()

        Clients.clientConnectionsQueue.sync {
            _ = Clients.allConnections.insert(connection)
        }
        connection.invalidationHandler = {
            os_log("Connection to peer invalidated")
            Clients.clientConnectionsQueue.sync {
                _ = Clients.allConnections.remove(connection)
            }
        }

        connection.resume()
        os_log("Accepting client connection")
        return true // accept connection
    }
}

enum Clients {

    fileprivate static let clientConnectionsQueue = DispatchQueue(label: "at.obdev.odbackup.daemon.clientConnectionsQueue")

    fileprivate static var allConnections = Set<NSXPCConnection>()

    private static func iterateConnections(block: (NSXPCConnection) -> Void) {
        let currentConnections = clientConnectionsQueue.sync { allConnections }
        for connection in currentConnections {
            block(connection)
        }
    }

    static func reportProgressToClients(_ progressInfo: String) {
        // Progress info may consist of several lines separated by "\r". Forward
        // only the last line
        let lines = progressInfo.components(separatedBy: CharacterSet.newlines)
        if let lastNonEmptyLine = lines.last(where: { !$0.isEmpty }) {
            iterateConnections { connection in
                if let client = connection.remoteObjectProxy as? BackupClientProtocol {
                    client.reportProgress(lastNonEmptyLine)
                }
            }
        }
    }

    static func reportListingDataToClients(_ data: Data) {
        iterateConnections { connection in
            if let client = connection.remoteObjectProxy as? BackupClientProtocol {
                client.reportListingData(data)
            }
        }
    }

}

private func checkForReplacedBinary() {
    let myCurrentPath = pathForPID(myPID)
    if  myCurrentPath != myInitialPath {
        os_log("terminating because app was moved from %{public}@ to %{public}@", myInitialPath, myCurrentPath)
        exit(0)
    }
}

private func pathForPID(_ pid: pid_t) -> String {
    let bufferLength = 4 * MAXPATHLEN
    var buffer = ContiguousArray<UInt8>(repeating: 0, count: Int(bufferLength))
    let length = buffer.withUnsafeMutableBufferPointer { bufferPointer in
        proc_pidpath(pid, bufferPointer.baseAddress, UInt32(bufferLength))
    }
    if length > 0 {
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    } else {
        return "error"
    }
}
