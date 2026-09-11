import Foundation
import Security

public enum NativeCodeSigning {
    /// Pin messages to the actual signed bundled build, not another installed
    /// app with the same team/identifier serving the registered Mach name.
    public static func pin(_ base: String, to bundle: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(base as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let hash = (information as NSDictionary?)?[kSecCodeInfoUnique] as? Data, hash.count == 20 else {
            throw NativeCodeSigningError.invalidIdentity
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return base + " and cdhash H\"" + hex + "\""
    }

}
enum NativeCodeSigningError: Error { case invalidIdentity }
