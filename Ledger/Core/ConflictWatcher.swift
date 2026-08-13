import Foundation
import CoreData

// Statement-edit collision detection.
//
// Per SECURITY-ARCHITECTURE.md §5: most writes are appends (new expenses) —
// low collision risk, the default merge policy is fine there. Statement
// edits (marking paid, adjusting carry-forward) are the real risk, because
// two people can genuinely edit the same statement within the same minute.
// The working agreement is explicit: "nothing logged silently when
// uncertain" — so a real collision gets flagged `needsReview` rather than
// letting NSMergeByPropertyObjectTrumpMergePolicy silently pick a winner.
//
// This follows Apple's documented pattern for consuming persistent history
// (NSPersistentHistoryChangeRequest / NSPersistentHistoryTransaction) to
// distinguish a genuinely remote, CloudKit-driven change from this device's
// own save echoing back. What it cannot do from here is prove itself
// against real concurrent edits — that needs the two-device test called out
// in SECURITY-ARCHITECTURE.md §4 ("have Dev and Subha edit the same
// statement from two devices within the same minute").

final class ConflictWatcher {
    static let shared = ConflictWatcher()
    static let transactionAuthor = "LedgerApp"

    private let lastTokenKey = "conflictWatcher.lastHistoryToken"
    private var observer: NSObjectProtocol?
    private weak var container: NSPersistentCloudKitContainer?

    private init() {}

    func start(container: NSPersistentCloudKitContainer) {
        guard observer == nil else { return }
        self.container = container
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            self?.processRemoteChanges()
        }
    }

    private func lastToken() -> NSPersistentHistoryToken? {
        guard let data = UserDefaults.standard.data(forKey: lastTokenKey),
              let token = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSPersistentHistoryToken.self, from: data)
        else { return nil }
        return token
    }

    private func save(token: NSPersistentHistoryToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: lastTokenKey)
    }

    private func processRemoteChanges() {
        guard let container else { return }
        let ctx = container.viewContext
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: lastToken())
        guard let result = try? ctx.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction]
        else { return }

        for transaction in transactions {
            // Transactions this device authored are our own save echoing
            // back through the store; only a transaction from elsewhere
            // (Subha's device, relayed through CloudKit) is a candidate.
            guard transaction.author != Self.transactionAuthor else { continue }
            for change in transaction.changes ?? []
            where change.changedObjectID.entity.name == "CDStatement" {
                flagIfCollides(objectID: change.changedObjectID, context: ctx)
            }
            save(token: transaction.token)
        }

        if ctx.hasChanges { try? ctx.save() }
    }

    /// A local edit landing in the same short window as the incoming
    /// remote change is the signature of a genuine two-device collision —
    /// not just this device's own earlier change being relayed back.
    private func flagIfCollides(objectID: NSManagedObjectID, context: NSManagedObjectContext) {
        guard let statement = try? context.existingObject(with: objectID) as? CDStatement
        else { return }
        guard let localUpdated = statement.updatedAt else { return }
        let window: TimeInterval = 90
        if abs(localUpdated.timeIntervalSinceNow) < window,
           context.updatedObjects.contains(statement) {
            statement.needsReview = true
        }
    }
}
