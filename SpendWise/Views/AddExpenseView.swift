import SwiftUI

struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = AddExpenseViewModel()
    
    var body: some View {
        NavigationView {
            Form {
                // Amount Section
                Section {
                    HStack {
                        Text("$")
                            .foregroundColor(.secondary)
                        
                        TextField("0.00", value: $viewModel.amount, format: .number)
                            .keyboardType(.decimalPad)
                            .font(.title2)
                    }
                } header: {
                    Text("Amount")
                }
                
                // Store Section
                Section {
                    TextField("Store Name", text: $viewModel.store)
                        .autocapitalization(.words)
                } header: {
                    Text("Store")
                }
                
                // Date Section
                Section {
                    DatePicker("Date", selection: $viewModel.date, displayedComponents: [.date])
                        .datePickerStyle(.compact)
                } header: {
                    Text("Date")
                }
                
                // Card Section
                Section {
                    Picker("Card", selection: $viewModel.selectedCardId) {
                        ForEach(viewModel.cards) { card in
                            HStack {
                                Image(systemName: card.type == .credit ? "creditcard.fill" : "creditcard")
                                    .foregroundColor(card.type == .credit ? .blue : .green)
                                Text(card.name)
                            }
                            .tag(card.id ?? "")
                        }
                    }
                } header: {
                    Text("Card")
                }
                
                // Category Section
                Section {
                    Picker("Category", selection: $viewModel.selectedCategoryId) {
                        ForEach(viewModel.categories) { category in
                            HStack {
                                Image(systemName: category.icon)
                                    .foregroundColor(Color(hex: category.color))
                                Text(category.name)
                            }
                            .tag(category.id ?? "")
                        }
                    }
                    
                    if let subCategories = viewModel.selectedCategory?.subCategories, !subCategories.isEmpty {
                        Picker("Subcategory", selection: $viewModel.selectedSubCategoryId) {
                            Text("None").tag("")
                            ForEach(subCategories) { subCategory in
                                HStack {
                                    if let icon = subCategory.icon {
                                        Image(systemName: icon)
                                            .foregroundColor(Color(hex: subCategory.color ?? "#000000"))
                                    }
                                    Text(subCategory.name)
                                }
                                .tag(subCategory.id)
                            }
                        }
                    }
                } header: {
                    Text("Category")
                }
                
                // Recurring Section
                Section {
                    Toggle("Recurring Expense", isOn: $viewModel.isRecurring)
                    
                    if viewModel.isRecurring {
                        Picker("Frequency", selection: $viewModel.recurringFrequency) {
                            ForEach(Expense.RecurringFrequency.allCases, id: \.self) { frequency in
                                Text(frequency.rawValue.capitalized)
                                    .tag(frequency as Expense.RecurringFrequency?)
                            }
                        }
                    }
                } header: {
                    Text("Recurring")
                }
                
                // Notes Section
                Section {
                    TextEditor(text: $viewModel.notes)
                        .frame(minHeight: 100)
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle("Add Expense")
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
                            await viewModel.saveExpense()
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
            .task {
                await viewModel.loadData()
            }
        }
    }
}

// MARK: - View Model

@MainActor
class AddExpenseViewModel: ObservableObject {
    @Published var amount: Double = 0
    @Published var store: String = ""
    @Published var date: Date = Date()
    @Published var selectedCardId: String = ""
    @Published var selectedCategoryId: String = ""
    @Published var selectedSubCategoryId: String = ""
    @Published var isRecurring: Bool = false
    @Published var recurringFrequency: Expense.RecurringFrequency?
    @Published var notes: String = ""
    
    @Published var cards: [Card] = []
    @Published var categories: [Category] = []
    @Published var showError = false
    @Published var errorMessage = ""
    
    private let firebaseService = FirebaseService.shared
    
    var selectedCategory: Category? {
        categories.first { $0.id == selectedCategoryId }
    }
    
    var isValid: Bool {
        amount > 0 && !store.isEmpty && !selectedCardId.isEmpty && !selectedCategoryId.isEmpty
    }
    
    func loadData() async {
        do {
            async let cardsTask = firebaseService.getCards()
            async let categoriesTask = firebaseService.getCategories()
            
            let (cards, categories) = try await (cardsTask, categoriesTask)
            
            self.cards = cards
            self.categories = categories
            
            if let firstCard = cards.first {
                selectedCardId = firstCard.id ?? ""
            }
            
            if let firstCategory = categories.first {
                selectedCategoryId = firstCategory.id ?? ""
            }
        } catch {
            showError = true
            errorMessage = error.localizedDescription
        }
    }
    
    func saveExpense() async {
        do {
            let expense = Expense(
                amount: amount,
                store: store,
                date: date,
                cardId: selectedCardId,
                categoryId: selectedCategoryId,
                subCategoryId: selectedSubCategoryId.isEmpty ? nil : selectedSubCategoryId,
                isRecurring: isRecurring,
                recurringFrequency: recurringFrequency,
                notes: notes.isEmpty ? nil : notes,
                userId: "",
                createdAt: Date(),
                updatedAt: Date()
            )
            
            try await firebaseService.addExpense(expense)
        } catch {
            showError = true
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview {
    AddExpenseView()
} 