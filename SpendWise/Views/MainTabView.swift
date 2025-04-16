import SwiftUI

struct MainTabView: View {
    @StateObject private var authService = AuthenticationService.shared
    
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.bar.fill")
                }
            
            CardManagementView()
                .tabItem {
                    Label("Cards", systemImage: "creditcard.fill")
                }
            
            AddExpenseView()
                .tabItem {
                    Label("Add", systemImage: "plus.circle.fill")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .overlay(alignment: .top) {
            if authService.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.2))
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var authService = AuthenticationService.shared
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    if let user = authService.currentUser {
                        Text(user.displayName)
                            .font(.headline)
                        Text(user.email)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section {
                    Button(role: .destructive) {
                        Task {
                            await authService.signOut()
                        }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    MainTabView()
} 