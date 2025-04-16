import Foundation
import FirebaseFirestoreSwift

struct Category: Identifiable, Codable {
    @DocumentID var id: String?
    let name: String
    let icon: String
    let color: String
    let userId: String
    let isDefault: Bool
    let createdAt: Date
    let updatedAt: Date
    
    var subcategories: [Subcategory]?
}

struct Subcategory: Identifiable, Codable {
    @DocumentID var id: String?
    let name: String
    let categoryId: String
    let userId: String
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - Default Categories
extension Category {
    static let defaultCategories: [Category] = [
        Category(
            id: "food",
            name: "Food & Dining",
            icon: "fork.knife",
            color: "#FF6B6B",
            userId: "",
            isDefault: true,
            createdAt: Date(),
            updatedAt: Date()
        ),
        Category(
            id: "transport",
            name: "Transportation",
            icon: "car.fill",
            color: "#4ECDC4",
            userId: "",
            isDefault: true,
            createdAt: Date(),
            updatedAt: Date()
        ),
        Category(
            id: "utilities",
            name: "Utilities",
            icon: "bolt.fill",
            color: "#45B7D1",
            userId: "",
            isDefault: true,
            createdAt: Date(),
            updatedAt: Date()
        )
    ]
}

// MARK: - Firestore Extensions
extension Category {
    static func from(_ document: DocumentSnapshot) -> Category? {
        try? document.data(as: Category.self)
    }
    
    func toDictionary() -> [String: Any] {
        [
            "name": name,
            "icon": icon,
            "color": color,
            "userId": userId,
            "isDefault": isDefault,
            "createdAt": createdAt,
            "updatedAt": updatedAt
        ]
    }
}

extension Subcategory {
    static func from(_ document: DocumentSnapshot) -> Subcategory? {
        try? document.data(as: Subcategory.self)
    }
    
    func toDictionary() -> [String: Any] {
        [
            "name": name,
            "categoryId": categoryId,
            "userId": userId,
            "createdAt": createdAt,
            "updatedAt": updatedAt
        ]
    }
} 