import SwiftUI

struct CardManagementView: View {
    @StateObject private var viewModel = CardManagementViewModel()
    @State private var showingAddCard = false
    @State private var selectedCard: Card?
    
    var body: some View {
        List {
            Section {
                ForEach(viewModel.cards) { card in
                    CardRow(card: card)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedCard = card
                        }
                }
            } header: {
                Text("Your Cards")
            }
        }
        .navigationTitle("Cards")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingAddCard = true }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .sheet(isPresented: $showingAddCard) {
            AddCardView()
        }
        .sheet(item: $selectedCard) { card in
            CardDetailView(card: card)
        }
        .task {
            await viewModel.loadCards()
        }
    }
}

struct CardRow: View {
    let card: Card
    
    var body: some View {
        HStack {
            Image(systemName: card.type == .credit ? "creditcard.fill" : "creditcard")
                .foregroundColor(card.type == .credit ? .blue : .green)
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(card.name)
                    .font(.headline)
                
                HStack {
                    Text(card.type.rawValue.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let apr = card.apr {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.2f", apr))% APR")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            if let limit = card.creditLimit {
                Text(limit.formatted(.currency(code: "USD")))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddCardView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = AddCardViewModel()
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Card Name", text: $viewModel.name)
                        .autocapitalization(.words)
                    
                    Picker("Type", selection: $viewModel.type) {
                        ForEach(Card.CardType.allCases, id: \.self) { type in
                            Text(type.rawValue.capitalized)
                                .tag(type)
                        }
                    }
                } header: {
                    Text("Card Details")
                }
                
                if viewModel.type == .credit {
                    Section {
                        HStack {
                            TextField("APR", value: $viewModel.apr, format: .number)
                                .keyboardType(.decimalPad)
                            Text("%")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            TextField("Credit Limit", value: $viewModel.creditLimit, format: .currency(code: "USD"))
                                .keyboardType(.decimalPad)
                        }
                        
                        Stepper("Bill Due Day: \(viewModel.billDueDate)", value: $viewModel.billDueDate, in: 1...31)
                    } header: {
                        Text("Credit Card Details")
                    }
                }
            }
            .navigationTitle("Add Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        Task {
                            await viewModel.saveCard()
                            dismiss()
                        }
                    }
                    .disabled(!viewModel.isValid)
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
        }
    }
}

struct CardDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let card: Card
    @StateObject private var viewModel: CardDetailViewModel
    
    init(card: Card) {
        self.card = card
        _viewModel = StateObject(wrappedValue: CardDetailViewModel(card: card))
    }
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Image(systemName: card.type == .credit ? "creditcard.fill" : "creditcard")
                            .foregroundColor(card.type == .credit ? .blue : .green)
                            .font(.title)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name)
                                .font(.headline)
                            
                            Text(card.type.rawValue.capitalized)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                if card.type == .credit {
                    Section {
                        if let apr = card.apr {
                            HStack {
                                Text("APR")
                                Spacer()
                                Text("\(String(format: "%.2f", apr))%")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let limit = card.creditLimit {
                            HStack {
                                Text("Credit Limit")
                                Spacer()
                                Text(limit.formatted(.currency(code: "USD")))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let dueDate = card.billDueDate {
                            HStack {
                                Text("Bill Due Day")
                                Spacer()
                                Text("\(dueDate)")
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Credit Details")
                    }
                }
                
                Section {
                    ForEach(viewModel.recentExpenses) { expense in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(expense.store)
                                    .font(.headline)
                                
                                Text(expense.formattedDate)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(expense.formattedAmount)
                                .fontWeight(.semibold)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Recent Expenses")
                }
            }
            .navigationTitle("Card Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await viewModel.loadRecentExpenses()
            }
        }
    }
}

// MARK: - View Models

@MainActor
class CardManagementViewModel: ObservableObject {
    @Published var cards: [Card] = []
    private let firebaseService = FirebaseService.shared
    
    func loadCards() async {
        do {
            cards = try await firebaseService.getCards()
        } catch {
            print("Error loading cards: \(error)")
        }
    }
}

@MainActor
class AddCardViewModel: ObservableObject {
    @Published var name = ""
    @Published var type: Card.CardType = .credit
    @Published var apr: Double?
    @Published var creditLimit: Double?
    @Published var billDueDate = 1
    @Published var showError = false
    @Published var errorMessage = ""
    
    private let firebaseService = FirebaseService.shared
    
    var isValid: Bool {
        !name.isEmpty
    }
    
    func saveCard() async {
        do {
            let card = Card(
                name: name,
                type: type,
                apr: apr,
                billDueDate: billDueDate,
                creditLimit: creditLimit,
                userId: "",
                createdAt: Date(),
                updatedAt: Date()
            )
            
            try await firebaseService.addCard(card)
        } catch {
            showError = true
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
class CardDetailViewModel: ObservableObject {
    @Published var recentExpenses: [Expense] = []
    private let card: Card
    private let firebaseService = FirebaseService.shared
    
    init(card: Card) {
        self.card = card
    }
    
    func loadRecentExpenses() async {
        do {
            let cycle = BillingCycle.currentCycle()
            let expenses = try await firebaseService.getExpenses(for: cycle)
            recentExpenses = expenses
                .filter { $0.cardId == card.id }
                .sorted { $0.date > $1.date }
                .prefix(5)
                .map { $0 }
        } catch {
            print("Error loading expenses: \(error)")
        }
    }
}

#Preview {
    NavigationView {
        CardManagementView()
    }
} 