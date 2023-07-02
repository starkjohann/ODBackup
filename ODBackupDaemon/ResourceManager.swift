import Foundation
import os

/*
# The purpose of this module
The `SMAppService` framework allows us to start a process as root and takes care
of security implications involved when the executable binary is under the user's
control, but it does not manage resources of that process. If the process is in
a bundle and accesses bundle resources, these resources may have been modified
maliciously.

We therefore copy the entire daemon bundle to a location which is only writable
by root, perform a code signature check on the entire bundle there, and then make
it available to the daemon executable.
*/

class ResourceManager {

    private static let userWritableBundleURL = Bundle.main.bundleURL
    private static let bundleName = userWritableBundleURL.lastPathComponent

    private static let stagingDirectoryURL = StaticConfiguration.rootOwnedResourcesURL.appending(path: "staging")

    private static let copiedBundleURL = StaticConfiguration.rootOwnedResourcesURL.appending(path: bundleName)
    private static let stagedBundleURL = stagingDirectoryURL.appending(path: bundleName)

    static let shared = ResourceManager()

    let resourceBundle: Bundle

    private static func bundlesAreSameVersion(_ a: URL, _ b: URL) -> Bool {
        // compare only relevant files, we need this check in order to find out
        // whether this is the same version or not
        let paths = [
            "Contents/Info.plist",
            "Contents/Resources/borg/borg.exe",
            "Contents/Resources/odbackup.sh",
            "Contents/MacOS/ODBackupDaemon"
        ]
        for path in paths {
            do {
                let contentA = try Data(contentsOf: a.appending(path: path))
                let contentB = try Data(contentsOf: b.appending(path: path))
                if contentA != contentB {
                    os_log("must install new version because %{public}@ does not match", path)
                    return false
                }
            } catch {
                os_log("must install new version because reading of %{public}@ failed", path)
                return false
            }
        }
        return true
    }

    private static func chownRecursively(on url: URL) throws {
        let fileManager = FileManager.default
        let path = url.path
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard var permissions = attributes[.posixPermissions] as? UInt16 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        permissions &= ~UInt16(0o022)  // Remove write access for group and others
        let newAttributes: [FileAttributeKey: Any] = [
            .ownerAccountID: 0,
            .groupOwnerAccountID: 0,
            .posixPermissions: permissions
        ]
        try fileManager.setAttributes(newAttributes, ofItemAtPath: path)
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue {
            for childURL in (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isWritableKey])) ?? [] {
                try chownRecursively(on: childURL)
            }
        }
    }

    private init() {
        if let copiedBundle = Bundle(url: Self.copiedBundleURL), Self.bundlesAreSameVersion(Self.copiedBundleURL, Self.userWritableBundleURL) {
            resourceBundle = copiedBundle
        } else {
            do {
                let fileManager = FileManager.default
                try? fileManager.removeItem(at: Self.copiedBundleURL)       // may not exist
                try? fileManager.removeItem(at: Self.stagingDirectoryURL)   // may not exist
                try fileManager.createDirectory(at: Self.stagingDirectoryURL, withIntermediateDirectories: true)
                try fileManager.copyItem(at: Self.userWritableBundleURL, to: Self.stagedBundleURL)
                try Self.chownRecursively(on: Self.stagedBundleURL)
                if !CodeSignatureChecking.codeSignatureIsTrustedForBundle(at: Self.stagedBundleURL) {
                    try? fileManager.removeItem(at: Self.stagingDirectoryURL)
                    fatalError("Code signature of bundle is invalid")
                }
                try fileManager.moveItem(at: Self.stagedBundleURL, to: Self.copiedBundleURL)
                try? fileManager.removeItem(at: Self.stagingDirectoryURL)
                resourceBundle = Bundle(url: Self.copiedBundleURL)!
            } catch {
                fatalError("Cannot copy resources: \(error)")
            }
        }

    }

}
