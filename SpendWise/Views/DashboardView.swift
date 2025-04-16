import SwiftUI
import Charts

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @State private var selectedTimeRange: TimeRange = .month
    @State private var showingAddExpense = false
    
    enum TimeRange: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    headerSection
                    
                    // Quick Stats
                    quickStatsSection
                    
                    // Spending Trends
                    spendingTrendsSection
                    
                    // Category Breakdown
                    categoryBreakdownSection
                    
                    // Card Usage
                    cardUsageSection
                    
                    // Upcoming Bills
                    upcomingBillsSection
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddExpense = true }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .sheet(isPresented: $showingAddExpense) {
                // AddExpenseView will be implemented later
                Text("Add Expense")
            }
            .task {
                await viewModel.loadDashboardData()
            }
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Billing Cycle")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text(BillingCycle.formatCycle(BillingCycle.currentCycle()))
                .font(.title2)
                .fontWeight(.bold)
            
            HStack {
                Text("Total Spent")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(viewModel.totalSpent.formatted(.currency(code: "USD")))
                    .font(.title3)
                    .fontWeight(.semibold)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    // MARK: - Quick Stats Section
    
    private var quickStatsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            StatCard(
                title: "Daily Average",
                value: viewModel.averageDailySpend.formatted(.currency(code: "USD")),
                icon: "chart.line.uptrend.xyaxis",
                color: .blue
            )
            
            StatCard(
                title: "Savings Rate",
                value: String(format: "%.1f%%", viewModel.savingsRate),
                icon: "percent",
                color: .green
            )
            
            StatCard(
                title: "Projected Monthly",
                value: viewModel.projectedMonthlySpend.formatted(.currency(code: "USD")),
                icon: "chart.bar.fill",
                color: .orange
            )
            
            StatCard(
                title: "Upcoming Bills",
                value: viewModel.upcomingBillsTotal.formatted(.currency(code: "USD")),
                icon: "calendar.badge.clock",
                color: .red
            )
        }
    }
    
    // MARK: - Spending Trends Section
    
    private var spendingTrendsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spending Trends")
                .font(.headline)
            
            Picker("Time Range", selection: $selectedTimeRange) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            
            Chart {
                ForEach(viewModel.monthlyTrend, id: \.0) { date, amount in
                    LineMark(
                        x: .value("Date", date),
                        y: .value("Amount", amount)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    
                    AreaMark(
                        x: .value("Date", date),
                        y: .value("Amount", amount)
                    )
                    .foregroundStyle(Color.blue.opacity(0.1))
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    // MARK: - Category Breakdown Section
    
    private var categoryBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Category Breakdown")
                .font(.headline)
            
            Chart {
                ForEach(viewModel.expensesByCategory.prefix(5), id: \.0.id) { category, amount in
                    SectorMark(
                        angle: .value("Amount", amount),
                        innerRadius: .ratio(0.618),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Category", category.name))
                }
            }
            .frame(height: 200)
            
            ForEach(viewModel.expensesByCategory.prefix(5), id: \.0.id) { category, amount in
                HStack {
                    Image(systemName: category.icon)
                        .foregroundColor(Color(hex: category.color))
                    
                    Text(category.name)
                    
                    Spacer()
                    
                    Text(amount.formatted(.currency(code: "USD")))
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    // MARK: - Card Usage Section
    
    private var cardUsageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Card Usage")
                .font(.headline)
            
            ForEach(viewModel.expensesByCard, id: \.0.id) { card, amount in
                HStack {
                    VStack(alignment: .leading) {
                        Text(card.name)
                            .fontWeight(.medium)
                        
                        Text(card.type.rawValue.capitalized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(amount.formatted(.currency(code: "USD")))
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    // MARK: - Upcoming Bills Section
    
    private var upcomingBillsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upcoming Bills")
                .font(.headline)
            
            ForEach(viewModel.billsByDueDate.prefix(3), id: \.0.id) { bill, daysUntilDue in
                HStack {
                    VStack(alignment: .leading) {
                        Text(bill.name)
                            .fontWeight(.medium)
                        
                        Text("Due in \(daysUntilDue) days")
                            .font(.caption)
                            .foregroundColor(daysUntilDue <= 3 ? .red : .secondary)
                    }
                    
                    Spacer()
                    
                    Text(bill.amount.formatted(.currency(code: "USD")))
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview {
    DashboardView()
} 