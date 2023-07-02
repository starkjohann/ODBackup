import Foundation

public let machServiceName = "at.obdev.odbackup.daemon"

@objc
protocol BackupDaemonProtocol {

    /// Used to check for proper version numbers on both ends
    func bundleVersion(clientBundleversion: String, with reply: @escaping (String) -> Void)

    func getSSHPublicKey(with reply: @escaping (String?) -> Void)

    func setSSHKeys(public: String, private: String, with reply: @escaping (NSError?) -> Void)

    // returns stderr string on failure, nil on success
    func generateNewSSHKeys(with reply: @escaping (String?) -> Void)

    func checkFullDiskAccess(with reply: @escaping (Int32, String) -> Void)

    func initializeRepository(_ repository: String, passPhrase: String, rshCommand: String, with reply: @escaping (Int32, String) -> Void)

    func performBackup(backupRoots: [String], excludePatterns: [String], repository: String, repositoryName: String, passPhrase: String, rateLimitKBytes: Int, rshCommand: String, pruneKeepHourly: Int, pruneKeepDaily: Int, pruneKeepWeekly: Int, pruneKeepMonthly: Int, with reply: @escaping (Int32, String) -> Void)

    func listArchives(repository: String, repositoryName: String, passPhrase: String, rshCommand: String, with reply: @escaping (Int32, _ stdout: String, _ stderr: String) -> Void)

    func listFiles(repository: String, repositoryName: String, archive: String, passPhrase: String, rshCommand: String, with reply: @escaping (Int32, String) -> Void)

    func extractFiles(repository: String, repositoryName: String, archive: String, path: String?, passPhrase: String, rshCommand: String, with reply: @escaping (Int32, String) -> Void)

    func logToBackupLog(repositoryName: String, exitStatus: Int32, logMessage: String, with reply: @escaping (Int32, String) -> Void)


    func abortBackups()
    func abortListings()
    func abortExtractions()

    func terminate()

    func scheduleWake(date: Date)

}
