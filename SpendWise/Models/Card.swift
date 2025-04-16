import Foundation
import FirebaseFirestoreSwift

struct Card: Identifiable, Codable {
    @DocumentID var id: String?
    let name: String
    let lastFourDigits: String
    let type: CardType
    let color: String
    let userId: String
    let isDefault: Bool
    let createdAt: Date
    let updatedAt: Date
    
    enum CardType: String, Codable {
        case credit
        case debit
        case prepaid
    }
    
    var formattedLastFourDigits: String {
        "•••• \(lastFourDigits)"
    }
}

// MARK: - Firestore Extensions
extension Card {
    static func from(_ document: DocumentSnapshot) -> Card? {
        try? document.data(as: Card.self)
    }
    
    func toDictionary() -> [String: Any] {
        [
            "name": name,
            "lastFourDigits": lastFourDigits,
            "type": type.rawValue,
            "color": color,
            "userId": userId,
            "isDefault": isDefault,
            "createdAt": createdAt,
            "updatedAt": updatedAt
        ]
    }
}

// MARK: - Computed Properties
extension Card {
    var formattedAPR: String {
        guard let apr = apr else { return "N/A" }
        return String(format: "%.2f%%", apr)
    }
    
    var formattedCreditLimit: String {
        guard let limit = creditLimit else { return "N/A" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: limit)) ?? "$0.00"
    }
} 