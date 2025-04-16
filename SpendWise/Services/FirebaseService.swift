import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFirestoreSwift

class FirebaseService {
    static let shared = FirebaseService()
    private let db = Firestore.firestore()
    
    private init() {}
    
    // MARK: - Authentication
    
    func signIn(email: String, password: String) async throws -> User {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        return result.user
    }
    
    func signUp(email: String, password: String) async throws -> User {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        return result.user
    }
    
    func signOut() throws {
        try Auth.auth().signOut()
    }
    
    // MARK: - Expenses
    
    func addExpense(_ expense: Expense) async throws {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        var expense = expense
        expense.userId = userId
        try await db.collection("expenses").document(expense.id).setData(from: expense)
    }
    
    func updateExpense(_ expense: Expense) async throws {
        try await db.collection("expenses").document(expense.id).setData(from: expense)
    }
    
    func deleteExpense(_ expenseId: String) async throws {
        try await db.collection("expenses").document(expenseId).delete()
    }
    
    func getExpenses(for cycle: (start: Date, end: Date)) async throws -> [Expense] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }
        
        let snapshot = try await db.collection("expenses")
            .whereField("userId", isEqualTo: userId)
            .whereField("date", isGreaterThanOrEqualTo: cycle.start)
            .whereField("date", isLessThanOrEqualTo: cycle.end)
            .getDocuments()
        
        return try snapshot.documents.compactMap { try $0.data(as: Expense.self) }
    }
    
    // MARK: - Cards
    
    func addCard(_ card: Card) async throws {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        var card = card
        card.userId = userId
        try await db.collection("cards").document(card.id).setData(from: card)
    }
    
    func updateCard(_ card: Card) async throws {
        try await db.collection("cards").document(card.id).setData(from: card)
    }
    
    func deleteCard(_ cardId: String) async throws {
        try await db.collection("cards").document(cardId).delete()
    }
    
    func getCards() async throws -> [Card] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }
        
        let snapshot = try await db.collection("cards")
            .whereField("userId", isEqualTo: userId)
            .getDocuments()
        
        return try snapshot.documents.compactMap { try $0.data(as: Card.self) }
    }
    
    // MARK: - Categories
    
    func addCategory(_ category: Category) async throws {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        var category = category
        category.userId = userId
        try await db.collection("categories").document(category.id).setData(from: category)
    }
    
    func updateCategory(_ category: Category) async throws {
        try await db.collection("categories").document(category.id).setData(from: category)
    }
    
    func deleteCategory(_ categoryId: String) async throws {
        try await db.collection("categories").document(categoryId).delete()
    }
    
    func getCategories() async throws -> [Category] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }
        
        let snapshot = try await db.collection("categories")
            .whereField("userId", isEqualTo: userId)
            .getDocuments()
        
        return try snapshot.documents.compactMap { try $0.data(as: Category.self) }
    }
    
    // MARK: - Bills
    
    func addBill(_ bill: Bill) async throws {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        var bill = bill
        bill.userId = userId
        try await db.collection("bills").document(bill.id).setData(from: bill)
    }
    
    func updateBill(_ bill: Bill) async throws {
        try await db.collection("bills").document(bill.id).setData(from: bill)
    }
    
    func deleteBill(_ billId: String) async throws {
        try await db.collection("bills").document(billId).delete()
    }
    
    func getBills() async throws -> [Bill] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }
        
        let snapshot = try await db.collection("bills")
            .whereField("userId", isEqualTo: userId)
            .getDocuments()
        
        return try snapshot.documents.compactMap { try $0.data(as: Bill.self) }
    }
    
    func getUpcomingBills() async throws -> [Bill] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }
        let now = Date()
        
        let snapshot = try await db.collection("bills")
            .whereField("userId", isEqualTo: userId)
            .whereField("nextDueDate", isGreaterThan: now)
            .order(by: "nextDueDate")
            .getDocuments()
        
        return try snapshot.documents.compactMap { try $0.data(as: Bill.self) }
    }
} 