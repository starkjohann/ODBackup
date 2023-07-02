import Foundation
import Security

@objc
class ConfigurationModel: NSObject {

    static var shared = ConfigurationModel()

    var isEmpty: Bool {
        backupPaths.isEmpty || destinations.isEmpty
    }

    @objc var userDefaults: UserDefaults { UserDefaults.standard }    // wrapper for KVO dependencies

    @objc class var keyPathsForValuesAffectingBackupPaths: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.backupPaths.rawValue] }
    @objc dynamic var backupPaths: [String] {
        get {
            userDefaults.object(forKey: DefaultsKeys.backupPaths.rawValue) as? [String] ?? []
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.backupPaths.rawValue)
        }
    }

    // Excludes we want to have hardcoded:
    //  .fseventsd
    //  .Spotlight-V100
    //  .HFS+ Private Directory Data*
    //  .DocumentRevisions-V100
    //  private/var/vm
    //  private/tmp
    //  private/var/db/fpsd/dvp
    //  Volumes
    // Bring hardcoded excludes from script here:
    //  private/var/folders
    //  Library/Caches
    //  System/Library/Caches
    //  Users/*/Library/Caches
    //  Users/*/Library/Containers/*/Data/Library/Caches
    //  .TemporaryItems
    //  **/.TemporaryItems
    //  .Trashes
    //  **/.Trashes
    //  **/.Trash
    // add more suggestions like:
    //  Users/*/Library/Developer/...
    //  Applications/Xcode*.app
    //  Users/*/Library/Metadata/CoreSpotlight
    //  Users/*/Library/Biome/streams/restricted/ProactiveHarvesting/*
    //  private/var/db/Spotlight-V100
    //  private/var/db/diagnostics (system log!)
    //  private/var/db/uuidtext (system log!)
    //  Users/cs/Library/Mail/V10/MailData/Envelope Index (439MB of 2GB changed!)
    @objc class var keyPathsForValuesAffectingExcludePatterns: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.excludePatterns.rawValue] }
    @objc dynamic var excludePatterns: [String] {
        get {
            userDefaults.object(forKey: DefaultsKeys.excludePatterns.rawValue) as? [String] ?? []
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.excludePatterns.rawValue)
        }
    }

    @objc class var keyPathsForValuesAffectingDestinations: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.backupDestinations.rawValue] }
    @objc dynamic var destinations: [BackupDestination] {
        get {
            let rawArray = userDefaults.object(forKey: DefaultsKeys.backupDestinations.rawValue) as? [[String: String]] ?? []
            return rawArray.map { BackupDestination(dictionary: $0) }
        }
        set {
            userDefaults.set(newValue.map { $0.dictionaryRepresentation }, forKey: DefaultsKeys.backupDestinations.rawValue)
        }
    }

    @objc class var keyPathsForValuesAffectingDestinationSelectionScript: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.destinationSelectionScript.rawValue] }
    @objc dynamic var destinationSelectionScript: String {
        get {
            userDefaults.object(forKey: DefaultsKeys.destinationSelectionScript.rawValue) as? String ?? "# echo backup destination name to standard output\n# echo \"SKIP\" to skip this backup\n# echo \"DEFER\" to defer one minute.\n# You have \"$WIFI_SSID\" and \"$SCHEDULED_DATTIME\" (in format YYYY-MM-DD hh:mm:ss) available for your descision.\n\necho SKIP\necho \"Not yet configured\" >&2"
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.destinationSelectionScript.rawValue)
        }
    }

    @objc class var keyPathsForValuesAffectingBackupTimes: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.backupTimes.rawValue] }
    @objc dynamic var backupTimes: String {
        get {
            userDefaults.object(forKey: DefaultsKeys.backupTimes.rawValue) as? String ?? "2:00, 12:00, 14:30, 19:00"
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.backupTimes.rawValue)
        }
    }

    @objc class var keyPathsForValuesAffectingPruneKeepHourly: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.pruneKeepHourly.rawValue] }
    @objc dynamic var pruneKeepHourly: Int {
        get {
            userDefaults.object(forKey: DefaultsKeys.pruneKeepHourly.rawValue) as? Int ?? 24
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.pruneKeepHourly.rawValue)
        }
    }

    @objc class var keyPathsForValuesAffectingPruneKeepDaily: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.pruneKeepDaily.rawValue] }
    @objc dynamic var pruneKeepDaily: Int {
        get {
            userDefaults.object(forKey: DefaultsKeys.pruneKeepDaily.rawValue) as? Int ?? 7
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.pruneKeepDaily.rawValue)
        }
    }

    @objc class var keyPathsForValuesAffectingPruneKeepWeekly: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.pruneKeepWeekly.rawValue] }
    @objc dynamic var pruneKeepWeekly: Int {
        get {
            userDefaults.object(forKey: DefaultsKeys.pruneKeepWeekly.rawValue) as? Int ?? 4
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.pruneKeepWeekly.rawValue)
        }
    }

    @objc class var keyPathsForValuesAffectingPruneKeepMonthly: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.pruneKeepMonthly.rawValue] }
    @objc dynamic var pruneKeepMonthly: Int {
        get {
            userDefaults.object(forKey: DefaultsKeys.pruneKeepMonthly.rawValue) as? Int ?? 12
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.pruneKeepMonthly.rawValue)
        }
    }

    @objc class var keyPathsForValuesAffectingRshCommand: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.rshCommand.rawValue] }
    @objc dynamic var rshCommand: String {
        get {
            userDefaults.object(forKey: DefaultsKeys.rshCommand.rawValue) as? String ?? ""
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.rshCommand.rawValue)
        }
    }

    var effectiveRSHCommand: String {
        let rshCommand = rshCommand
        return (rshCommand.isEmpty ? "ssh" : rshCommand) + " -o StrictHostKeyChecking=accept-new -i " + StaticConfiguration.sshPrivateKeyFileURL.path
    }

    @objc class var keyPathsForValuesAffectingRateLimitKBytesPerSecond: Set<String> { [#keyPath(userDefaults) + "." + DefaultsKeys.rateLimitKBytesPerSecond.rawValue] }
    @objc dynamic var rateLimitKBytesPerSecond: Int {
        get {
            userDefaults.object(forKey: DefaultsKeys.rateLimitKBytesPerSecond.rawValue) as? Int ?? 0
        }
        set {
            userDefaults.set(newValue, forKey: DefaultsKeys.rateLimitKBytesPerSecond.rawValue)
        }
    }

    private var lastUpdateOfSSHPublicKey = Date.distantPast
    private var _sshPublicKey = ""

    @objc dynamic var sshPublicKey: String {
        // If asking for the ssh public key and it turns out that the last update
        // is quite a while ago, trigger a new update. This will update our UI
        // through the KVO binding mechanism.
        let now = Date()
        if now.timeIntervalSince(lastUpdateOfSSHPublicKey) > 10 {
            Task {
                await updatePublicKey()
            }
        }
        return _sshPublicKey
    }

    override init() {
        super.init()
        if !isEmpty {
            Task {
                await updatePublicKey()
            }
        }
    }

    private func setSSHPublicKey(_ key: String) {
        lastUpdateOfSSHPublicKey = Date()
        willChangeValue(for: \.sshPublicKey)
        _sshPublicKey = key
        didChangeValue(for: \.sshPublicKey)
    }

    @MainActor
    func updatePublicKey() async {
        setSSHPublicKey(await DaemonProxy.shared.sshPublicKey() ?? "<no key found>")
    }

    @MainActor
    func loadKeysFromFile(_ fileURL: URL) async throws {
        let privateKeyURL: URL
        let publicKeyURL: URL
        if fileURL.pathExtension == "pub" {
            publicKeyURL = fileURL
            privateKeyURL = fileURL.deletingPathExtension()
        } else {
            publicKeyURL = fileURL.appendingPathExtension("pub")
            privateKeyURL = fileURL
        }
        let publicKey = try String(contentsOf: publicKeyURL)
        let privateKey = try String(contentsOf: privateKeyURL)
        if let error = await DaemonProxy.shared.setSSHKeys(public: publicKey, private: privateKey) {
            throw error as Error
        }
        await updatePublicKey()
    }

    @MainActor
    func generateNewKey() async -> String? {
        if let stderrString = await DaemonProxy.shared.generateNewSSHKeys() {
            return stderrString
        }
        await updatePublicKey()
        return nil
    }

}

@objc
class BackupDestination: NSObject {
    let uuid: UUID
    @objc dynamic var name = "Location Name"
    @objc dynamic var repository = "user@ssh-server:directory"
    @objc dynamic var passPhrase = "" {
        didSet {
            _ = Keychain.store(serviceLabel: "ODBackup Password for \(name)", account: uuid.uuidString, password: passPhrase, comment: "Location: \(name)\nrepository URL: \(repository)")
            _ = Keychain.store(serviceLabel: "ODBackup Password for \(name)", account: uuid.uuidString, password: passPhrase, comment: "Location: \(name)\nrepository URL: \(repository)")
        }
    }

    var dictionaryRepresentation: [String: String] {
        ["name": name, "repository": repository, "uuid": uuid.uuidString]
    }

    init(dictionary: [String: String]) {
        uuid = UUID(uuidString: dictionary["uuid"] ?? "") ?? UUID()
        name = dictionary["name"] ?? ""
        repository = dictionary["repository"] ?? ""
        passPhrase = Keychain.load(account: uuid.uuidString) ?? ""
    }

    required override init() {
        uuid = UUID()
    }

}

extension BackupDestination: StringRepresentable {

    private static let tabCharacterSet = CharacterSet(charactersIn: "\t")

    var stringRepresentation: String {
        "\(name)\t\(repository)\t**********"
    }

    static func make(representedString: String) -> Self? {
        let fields = representedString.components(separatedBy: tabCharacterSet)
        guard fields.count >= 2 else {
            return nil
        }
        let result = Self()
        result.name = fields[0]
        result.repository = fields[1]
        return result
    }
}

private enum DefaultsKeys: String {

    case backupPaths = "BackupPaths"
    case excludePatterns = "ExcludePatterns"
    case backupDestinations = "BackupDestinations"
    case destinationSelectionScript = "DestinationSelectionScript"
    case backupTimes = "BackupTimes"
    case pruneKeepHourly = "PruneKeepHourly"
    case pruneKeepDaily = "PruneKeepDaily"
    case pruneKeepWeekly = "PruneKeepWeekly"
    case pruneKeepMonthly = "PruneKeepMonthly"
    case rshCommand = "RSHCommand"
    case rateLimitKBytesPerSecond = "RateLimitKBytesPerSecond"
}

private enum Keychain {

    static func store(serviceLabel: String, account: String, password: String, comment: String) -> OSStatus {
        let searchQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]

        // Delete the existing item before adding the new one
        SecItemDelete(searchQuery as CFDictionary)

        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrLabel: serviceLabel,
            kSecValueData: password.data(using: .utf8)!,
            kSecAttrComment: comment
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let passwordData = result as? Data else {
            return nil
        }
        return String(data: passwordData, encoding: .utf8)
    }
}
