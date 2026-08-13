import CoreData
import CloudKit
import SwiftUI

// Persistence with CloudKit *sharing*.
//
// This is why the app uses Core Data rather than SwiftData: as of iOS 18,
// SwiftData has no CKShare support. Sharing a ledger with a second Apple ID
// requires two store descriptions — one for your own private database, one
// for records shared with you — and NSPersistentCloudKitContainer only
// exposes that through Core Data.
//
// Both stores are backed by the same model and appear as one dataset to the
// UI. Records you create live in .private; records your wife creates and
// shares with you arrive in .shared. Neither of you needs the other's
// password, and either can revoke at any time.

final class Persistence: ObservableObject {
    static let shared = Persistence()

    /// Replace with your own container ID after adding the iCloud capability.
    static let containerID = "iCloud.com.yourname.ledger"

    let container: NSPersistentCloudKitContainer

    @Published var syncError: String?
    @Published var lastSync: Date?

    private init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Ledger",
                                                  managedObjectModel: LedgerModel.make())

        guard let privateDesc = container.persistentStoreDescriptions.first else {
            fatalError("Missing store description")
        }

        if inMemory {
            privateDesc.url = URL(fileURLWithPath: "/dev/null")
        } else {
            let base = NSPersistentContainer.defaultDirectoryURL()
            privateDesc.url = base.appendingPathComponent("private.sqlite")

            // --- private database ---
            let privateOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: Self.containerID)
            privateOptions.databaseScope = .private
            privateDesc.cloudKitContainerOptions = privateOptions
            privateDesc.setOption(true as NSNumber,
                                  forKey: NSPersistentHistoryTrackingKey)
            privateDesc.setOption(true as NSNumber,
                                  forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            // --- shared database (what your wife shares with you) ---
            let sharedDesc = privateDesc.copy() as! NSPersistentStoreDescription
            sharedDesc.url = base.appendingPathComponent("shared.sqlite")
            let sharedOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: Self.containerID)
            sharedOptions.databaseScope = .shared
            sharedDesc.cloudKitContainerOptions = sharedOptions

            container.persistentStoreDescriptions = [privateDesc, sharedDesc]
        }

        container.loadPersistentStores { [weak self] desc, error in
            if let error {
                // Never crash on a sync failure — the local store still works.
                // A banner in Settings tells the user sync is degraded.
                DispatchQueue.main.async {
                    self?.syncError = error.localizedDescription
                }
                print("Store load failed for \(desc.url?.lastPathComponent ?? "?"): \(error)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try? container.viewContext.setQueryGenerationFrom(.current)
    }

    var context: NSManagedObjectContext { container.viewContext }

    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
            // Widgets read a small pre-computed blob rather than opening their
            // own Core Data stack, so it has to be refreshed here.
            Task { @MainActor in SnapshotPublisher.refresh(context: context) }
        } catch { syncError = error.localizedDescription }
    }

    // MARK: - Sharing

    /// True when the object lives in the shared database (i.e. someone else owns it).
    func isShared(_ object: NSManagedObject) -> Bool {
        guard let store = object.objectID.persistentStore else { return false }
        return store == sharedStore
    }

    var privateStore: NSPersistentStore? {
        container.persistentStoreCoordinator.persistentStores.first {
            $0.url?.lastPathComponent == "private.sqlite"
        }
    }

    var sharedStore: NSPersistentStore? {
        container.persistentStoreCoordinator.persistentStores.first {
            $0.url?.lastPathComponent == "shared.sqlite"
        }
    }

    /// Existing share for the whole ledger, if one has been created.
    func existingShare() -> CKShare? {
        guard let store = privateStore else { return nil }
        // A zone-wide share covers every record in the zone, so one share
        // gives your wife the entire ledger rather than per-record grants.
        return try? container.fetchShares(in: store).first
    }
}

// MARK: - Share sheet
//
// Presents Apple's standard sharing UI. Your wife taps the link, accepts, and
// her app starts reading and writing the same ledger from her own Apple ID.

struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.modalPresentationStyle = .formSheet
        return controller
    }

    func updateUIViewController(_ vc: UICloudSharingController, context: Context) {}
}
