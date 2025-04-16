import Foundation
import SwiftUI
import Charts

@MainActor
class DashboardViewModel: ObservableObject {
    @Published var expenses: [Expense] = []
    @Published var cards: [Card] = []
    @Published var categories: [Category] = []
    @Published var bills: [Bill] = []
    @Published var isLoading = false
    @Published var error: Error?
    
    private let firebaseService = FirebaseService.shared
    
    // MARK: - Data Loading
    
    func loadDashboardData() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            async let expensesTask = loadExpenses()
            async let cardsTask = loadCards()
            async let categoriesTask = loadCategories()
            async let billsTask = loadBills()
            
            let (expenses, cards, categories, bills) = try await (expensesTask, cardsTask, categoriesTask, billsTask)
            
            self.expenses = expenses
            self.cards = cards
            self.categories = categories
            self.bills = bills
        } catch {
            self.error = error
        }
    }
    
    private func loadExpenses() async throws -> [Expense] {
        let cycle = BillingCycle.currentCycle()
        return try await firebaseService.getExpenses(for: cycle)
    }
    
    private func loadCards() async throws -> [Card] {
        return try await firebaseService.getCards()
    }
    
    private func loadCategories() async throws -> [Category] {
        return try await firebaseService.getCategories()
    }
    
    private func loadBills() async throws -> [Bill] {
        return try await firebaseService.getUpcomingBills()
    }
    
    // MARK: - Analytics
    
    var totalSpent: Double {
        expenses.reduce(0) { $0 + $1.amount }
    }
    
    var expensesByCard: [(Card, Double)] {
        cards.map { card in
            let amount = expenses
                .filter { $0.cardId == card.id }
                .reduce(0) { $0 + $1.amount }
            return (card, amount)
        }
        .sorted { $0.1 > $1.1 }
    }
    
    var expensesByCategory: [(Category, Double)] {
        categories.map { category in
            let amount = expenses
                .filter { $0.categoryId == category.id }
                .reduce(0) { $0 + $1.amount }
            return (category, amount)
        }
        .sorted { $0.1 > $1.1 }
    }
    
    var dailyExpenses: [(Date, Double)] {
        let calendar = Calendar.current
        let cycle = BillingCycle.currentCycle()
        
        var result: [Date: Double] = [:]
        var currentDate = cycle.start
        
        while currentDate <= cycle.end {
            result[currentDate] = 0
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        for expense in expenses {
            let date = calendar.startOfDay(for: expense.date)
            result[date, default: 0] += expense.amount
        }
        
        return result.sorted { $0.key < $1.key }
    }
    
    var weeklyExpenses: [(Date, Double)] {
        let calendar = Calendar.current
        let cycle = BillingCycle.currentCycle()
        
        var result: [Date: Double] = [:]
        var currentDate = cycle.start
        
        while currentDate <= cycle.end {
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: currentDate))!
            result[weekStart, default: 0] += expenses
                .filter { calendar.isDate($0.date, equalTo: currentDate, toGranularity: .day) }
                .reduce(0) { $0 + $1.amount }
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        return result.sorted { $0.key < $1.key }
    }
    
    var monthlyTrend: [(Date, Double)] {
        let calendar = Calendar.current
        let now = Date()
        var result: [(Date, Double)] = []
        
        for monthOffset in -5...0 {
            guard let date = calendar.date(byAdding: .month, value: monthOffset, to: now) else { continue }
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
            
            let amount = expenses
                .filter { $0.date >= monthStart && $0.date <= monthEnd }
                .reduce(0) { $0 + $1.amount }
            
            result.append((monthStart, amount))
        }
        
        return result.sorted { $0.0 < $1.0 }
    }
    
    // MARK: - Budget Analysis
    
    var budgetStatus: [(Category, Double, Double)] {
        // This would be enhanced with actual budget data
        categories.map { category in
            let spent = expenses
                .filter { $0.categoryId == category.id }
                .reduce(0) { $0 + $1.amount }
            let budget = 1000.0 // Example budget, would be user-defined
            return (category, spent, budget)
        }
    }
    
    var savingsRate: Double {
        // This would be enhanced with actual income data
        let income = 5000.0 // Example income, would be user-defined
        return ((income - totalSpent) / income) * 100
    }
    
    // MARK: - Bill Analysis
    
    var upcomingBillsTotal: Double {
        bills.reduce(0) { $0 + $1.amount }
    }
    
    var billsByDueDate: [(Bill, Int)] {
        bills.map { ($0, $0.daysUntilDue) }
            .sorted { $0.1 < $1.1 }
    }
    
    // MARK: - Spending Insights
    
    var topSpendingCategories: [(Category, Double)] {
        expensesByCategory.prefix(3).map { ($0.0, $0.1) }
    }
    
    var averageDailySpend: Double {
        let calendar = Calendar.current
        let cycle = BillingCycle.currentCycle()
        let days = calendar.dateComponents([.day], from: cycle.start, to: cycle.end).day ?? 1
        return totalSpent / Double(days)
    }
    
    var projectedMonthlySpend: Double {
        averageDailySpend * 30
    }
} 