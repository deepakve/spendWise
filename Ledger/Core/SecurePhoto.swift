import Foundation
import CryptoKit
import UIKit

// Card photos.
//
// A photo of a card is the most sensitive artefact in the app — it contains
// the number, the expiry, the name, and usually the CVV, all in plaintext
// pixels. So it gets stronger handling than the text fields, not weaker:
//
//   • Encrypted with AES-GCM using a 256-bit key generated on this device.
//   • The key lives in the Keychain as `ThisDeviceOnly`, so the photo cannot be
//     decrypted anywhere else even if the ciphertext file is copied.
//   • The ciphertext is written with `.completeFileProtection`, so it isn't
//     readable while the phone is locked.
//   • It is NOT written to the photo library, so it never reaches iCloud
//     Photos, Shared Albums, or any photo-scanning service.
//
// The trade, stated plainly in the UI: reinstalling the app or replacing the
// phone loses these images. They are a convenience copy, not a backup.

enum SecurePhoto {
    private static let keyService = "com.ledger.photokey"

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("CardPhotos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
        }
        return dir
    }

    /// Fetch the device key, creating it on first use.
    private static func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: "photo-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return SymmetricKey(data: data)
        }

        let fresh = SymmetricKey(size: .bits256)
        let bytes = fresh.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: "photo-key",
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(add as CFDictionary, nil)
        return fresh
    }

    static func save(_ image: UIImage, ref: String) throws {
        // Downscale before encrypting: a 12MP original is far larger than
        // needed to read a card, and smaller ciphertext is less to protect.
        let resized = image.scaled(maxDimension: 1600)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
        let sealed = try AES.GCM.seal(jpeg, using: key())
        guard let combined = sealed.combined else { return }
        let url = try directory().appendingPathComponent("\(ref).bin")
        try combined.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func load(ref: String) throws -> UIImage? {
        let url = try directory().appendingPathComponent("\(ref).bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key())
        return UIImage(data: plain)
    }

    static func exists(ref: String) -> Bool {
        guard let url = try? directory().appendingPathComponent("\(ref).bin") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    static func delete(ref: String) -> Bool {
        guard let url = try? directory().appendingPathComponent("\(ref).bin") else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

extension UIImage {
    func scaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
