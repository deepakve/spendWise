import Foundation
import Security
import LocalAuthentication

// Card vault.
//
// You asked to store full card details, and you're right that the Keychain is
// the correct place — it's the same mechanism Apple's own Passwords app and
// Safari AutoFill use. Three protections are applied here:
//
//   1. kSecAttrAccessibleWhenUnlockedThisDeviceOnly
//      Never leaves this device. Not in iCloud, not in encrypted backups.
//      Consequence: lose the phone, lose the numbers. Keep the physical cards.
//
//   2. SecAccessControl with .biometryCurrentSet
//      Face ID or the device passcode is required on every single read. Adding
//      a new fingerprint or face re-enrols invalidates the item, which is what
//      you want — someone who coerces a new biometric enrolment still can't read it.
//
//   3. Nothing here is ever written to Core Data, so it never reaches CloudKit
//      and is never included in a share with anyone, including your wife.
//
// One recommendation I'd make strongly, and then leave to you: store the card
// number if it's useful, but consider leaving CVV empty. The card number alone
// is low-risk — it's printed on every receipt stub and can be re-issued. Number
// + expiry + CVV together is a complete card-not-present transaction. That
// combination is the reason PCI DSS forbids even merchants from storing CVV.
// The field exists because it's your device and your call, but the app never
// requires it, and everything you actually asked to track — due date, APR,
// cycle date, limit — lives in the ordinary database where it's searchable.

struct CardSecret: Codable {
    var number: String = ""
    var expiry: String = ""        // "07/31"
    var cvv: String = ""           // recommended: leave empty
    var pin: String = ""
    var loginHint: String = ""     // e.g. which email the account uses
    var supportPhone: String = ""
    var freeform: String = ""
}

enum CardVault {
    private static let service = "com.ledger.cardvault"

    enum VaultError: LocalizedError {
        case biometricsUnavailable, authFailed, notFound, saveFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .biometricsUnavailable: "Face ID or a device passcode must be set up first."
            case .authFailed:            "Authentication failed."
            case .notFound:              "No details saved for this card yet."
            case .saveFailed(let s):     "Could not save (code \(s))."
            }
        }
    }

    static var isAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthentication, error: &err)
    }

    static func save(_ secret: CardSecret, ref: String) throws {
        guard isAvailable else { throw VaultError.biometricsUnavailable }
        let data = try JSONEncoder().encode(secret)

        var acError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &acError) else {
            throw VaultError.saveFailed(errSecParam)
        }

        delete(ref: ref)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.saveFailed(status) }
    }

    /// Prompts for Face ID / passcode. `reason` is shown in the system dialog.
    static func load(ref: String, reason: String) async throws -> CardSecret {
        let ctx = LAContext()
        ctx.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: ctx,
            kSecUseOperationPrompt as String: reason
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let secret = try? JSONDecoder().decode(CardSecret.self, from: data) else {
                throw VaultError.notFound
            }
            return secret
        case errSecItemNotFound: throw VaultError.notFound
        default:                 throw VaultError.authFailed
        }
    }

    /// Whether anything is stored, without triggering a biometric prompt.
    static func exists(ref: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
            kSecReturnData as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    @discardableResult
    static func delete(ref: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Masked display form: •••• •••• •••• 1234
    static func masked(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 4 else { return "••••" }
        return "•••• •••• •••• " + String(digits.suffix(4))
    }
}
