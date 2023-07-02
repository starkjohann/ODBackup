import Foundation
import os

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
