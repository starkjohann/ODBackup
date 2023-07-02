import Foundation
import os

enum CodeSignatureChecking {

    static let myTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code else {
            os_log("could not obtain code object for self")
            return nil
        }
        var rawSigningInfo: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &rawSigningInfo) == errSecSuccess else {
            os_log("could not obtain signing info from my own code object")
            return nil
        }
        guard let signingInfo = rawSigningInfo as? [String: Any] else {
            os_log("signing info has wrong type")
            return nil
        }
        let teamID = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
        os_log("my team identifier = %{public}@", teamID ?? "<nil>")
        return teamID
    }()

    static let requirement: SecRequirement = {
        // We don't check for code signing flags CS_HARD and CS_KILL because we know
        // that we compile with hardened runtime and there are no older versions available
        // without it. "Hardened Runtime" is active by default these days anyway.
        // Check at least the peer's TeamID
        guard let myTeamIdentifier else {
            fatalError("cannot infer team identifier for checking code signatures")
        }
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(myTeamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess else {
            fatalError("syntax error in requirement string")
        }
        return requirement!
    }()

    static func codeSignatureIsTrustedForBundle(at url: URL) -> Bool {
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(url as CFURL, [], &code) != errSecSuccess {
            os_log("bundle %{public}@ is not trusted because SecStaticCodeCreateWithPath() failed", url.path)
            return false
        }
        guard let code else {
            os_log("bundle %{public}@ is not trusted because SecStaticCodeCreateWithPath() returned a nil object", url.path)
            return false
        }
        if SecStaticCodeCheckValidityWithErrors(code, [], requirement, nil) != errSecSuccess {
            os_log("bundle %{public}@ does not satisfy requirement", url.path)
            return false
        }
        return true
    }

}
