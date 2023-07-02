import Foundation

enum StaticConfiguration {

    static let sshKeyFileBaseName = "id_ODBackup"   // key file base name in /var/root/.ssh/
    static let rootHomeDirectoryURL = URL(fileURLWithPath: "/var/root")
    static let sshPrivateKeyFileURL = rootHomeDirectoryURL.appending(components: ".ssh", sshKeyFileBaseName)
    static let sshPublicKeyFileURL = rootHomeDirectoryURL.appending(components: ".ssh", sshKeyFileBaseName + ".pub")

    static let rootOwnedResourcesURL = URL(fileURLWithPath: "/Library/Application Support/Objective Development/ODBackup")

    static let logDirectoryURL = URL(fileURLWithPath: "/var/log/ODBackup")

    static let dataVolumeURL = URL(fileURLWithPath: "/System/Volumes/Data")

    static let destinationNameForSkipBackup = "SKIP"
    static let destinationNameForDeferBackup = "DEFER"

}
