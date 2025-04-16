import Foundation
import FirebaseFirestoreSwift

struct Bill: Identifiable, Codable {
    @DocumentID var id: String?
    var name: String
    var amount: Double
    var dueDate: Int // Day of the month
    var categoryId: String
    var subCategoryId: String?
    var cardId: String?
    var isRecurring: Bool
    var frequency: BillFrequency
    var reminderDays: Int // Days before due date to remind
    var isPaid: Bool
    var lastPaidDate: Date?
    var nextDueDate: Date
    var userId: String
    var createdAt: Date
    var updatedAt: Date
    
    enum BillFrequency: String, Codable {
        case monthly
        case quarterly
        case yearly
    }
}

// MARK: - Computed Properties
extension Bill {
    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: amount)) ?? "$0.00"
    }
    
    var formattedNextDueDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: nextDueDate)
    }
    
    var daysUntilDue: Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: Date(), to: nextDueDate).day ?? 0
    }
    
    var isOverdue: Bool {
        return daysUntilDue < 0
    }
    
    var reminderDate: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -reminderDays, to: nextDueDate) ?? nextDueDate
    }
} 