import SwiftUI
import FirebaseCore

@main
struct SpendWiseApp: App {
    @StateObject private var authService = AuthenticationService.shared
    
    init() {
        FirebaseApp.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if authService.isAuthenticated {
                    MainTabView()
                } else {
                    AuthenticationView()
                }
            }
        }
    }
} 