import Foundation
import FirebaseFirestoreSwift

struct User: Identifiable, Codable {
    @DocumentID var id: String?
    let email: String
    let displayName: String
    let createdAt: Date
    let updatedAt: Date
    var settings: UserSettings
    
    struct UserSettings: Codable {
        var currency: String
        var theme: Theme
        var notificationsEnabled: Bool
        
        enum Theme: String, Codable {
            case light
            case dark
            case system
        }
        
        static let `default` = UserSettings(
            currency: "USD",
            theme: .system,
            notificationsEnabled: true
        )
    }
}

// MARK: - Firestore Extensions
extension User {
    static func from(_ document: DocumentSnapshot) -> User? {
        try? document.data(as: User.self)
    }
    
    func toDictionary() -> [String: Any] {
        [
            "email": email,
            "displayName": displayName,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "settings": [
                "currency": settings.currency,
                "theme": settings.theme.rawValue,
                "notificationsEnabled": settings.notificationsEnabled
            ]
        ]
    }
} 