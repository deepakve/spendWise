import Foundation
import FirebaseFirestoreSwift

struct Expense: Identifiable, Codable {
    @DocumentID var id: String?
    let amount: Double
    let store: String
    let date: Date
    let cardId: String
    let categoryId: String
    let subcategoryId: String?
    let isRecurring: Bool
    let recurringFrequency: RecurringFrequency?
    let notes: String?
    let userId: String
    
    enum RecurringFrequency: String, Codable {
        case daily
        case weekly
        case monthly
        case yearly
    }
    
    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Firestore Extensions
extension Expense {
    static func from(_ document: DocumentSnapshot) -> Expense? {
        try? document.data(as: Expense.self)
    }
    
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "amount": amount,
            "store": store,
            "date": date,
            "cardId": cardId,
            "categoryId": categoryId,
            "isRecurring": isRecurring,
            "userId": userId
        ]
        
        if let subcategoryId = subcategoryId {
            dict["subcategoryId"] = subcategoryId
        }
        
        if let recurringFrequency = recurringFrequency {
            dict["recurringFrequency"] = recurringFrequency.rawValue
        }
        
        if let notes = notes {
            dict["notes"] = notes
        }
        
        return dict
    }
} 