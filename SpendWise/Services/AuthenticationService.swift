import Foundation
import FirebaseAuth
import FirebaseFirestore

@MainActor
class AuthenticationService: ObservableObject {
    static let shared = AuthenticationService()
    
    @Published var currentUser: User?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var error: AuthError?
    
    private let auth = Auth.auth()
    private let db = Firestore.firestore()
    
    enum AuthError: LocalizedError {
        case signInFailed
        case signUpFailed
        case signOutFailed
        case userNotFound
        case invalidEmail
        case weakPassword
        case emailAlreadyInUse
        case unknown
        
        var errorDescription: String? {
            switch self {
            case .signInFailed:
                return "Failed to sign in. Please check your credentials."
            case .signUpFailed:
                return "Failed to create account. Please try again."
            case .signOutFailed:
                return "Failed to sign out. Please try again."
            case .userNotFound:
                return "No account found with this email."
            case .invalidEmail:
                return "Please enter a valid email address."
            case .weakPassword:
                return "Password should be at least 6 characters."
            case .emailAlreadyInUse:
                return "An account with this email already exists."
            case .unknown:
                return "An unknown error occurred. Please try again."
            }
        }
    }
    
    private init() {
        setupAuthStateListener()
    }
    
    private func setupAuthStateListener() {
        auth.addStateDidChangeListener { [weak self] _, user in
            Task {
                if let user = user {
                    await self?.fetchUser(userId: user.uid)
                } else {
                    self?.currentUser = nil
                    self?.isAuthenticated = false
                }
            }
        }
    }
    
    func signIn(email: String, password: String) async {
        isLoading = true
        error = nil
        
        do {
            let result = try await auth.signIn(withEmail: email, password: password)
            await fetchUser(userId: result.user.uid)
        } catch {
            self.error = mapError(error)
        }
        
        isLoading = false
    }
    
    func signUp(email: String, password: String, displayName: String) async {
        isLoading = true
        error = nil
        
        do {
            let result = try await auth.createUser(withEmail: email, password: password)
            let user = User(
                email: email,
                displayName: displayName,
                createdAt: Date(),
                updatedAt: Date(),
                settings: .default
            )
            
            try await db.collection("users").document(result.user.uid).setData(user.toDictionary())
            await fetchUser(userId: result.user.uid)
        } catch {
            self.error = mapError(error)
        }
        
        isLoading = false
    }
    
    func signOut() async {
        isLoading = true
        error = nil
        
        do {
            try auth.signOut()
            currentUser = nil
            isAuthenticated = false
        } catch {
            self.error = .signOutFailed
        }
        
        isLoading = false
    }
    
    private func fetchUser(userId: String) async {
        do {
            let document = try await db.collection("users").document(userId).getDocument()
            if let user = User.from(document) {
                currentUser = user
                isAuthenticated = true
            } else {
                error = .userNotFound
            }
        } catch {
            self.error = .unknown
        }
    }
    
    private func mapError(_ error: Error) -> AuthError {
        if let errorCode = AuthErrorCode.Code(rawValue: (error as NSError).code) {
            switch errorCode {
            case .userNotFound:
                return .userNotFound
            case .invalidEmail:
                return .invalidEmail
            case .weakPassword:
                return .weakPassword
            case .emailAlreadyInUse:
                return .emailAlreadyInUse
            default:
                return .unknown
            }
        }
        return .unknown
    }
} 