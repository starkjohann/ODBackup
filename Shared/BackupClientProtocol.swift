import Foundation

@objc
protocol BackupClientProtocol {

    /// Send progress report to client
    func reportProgress(_ info: String)

    func reportListingData(_ data: Data)

}
