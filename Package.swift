// swift-tools-version: 5.9
// Lets Swift Playgrounds on iPad open this folder directly as an app project.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Ledger",
    platforms: [.iOS(.v17)],
    products: [
        .iOSApplication(
            name: "Ledger",
            targets: ["Ledger"],
            bundleIdentifier: "com.yourname.ledger",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            // No placeholder icon set: the exact PlaceholderIcon case names aren't
            // part of AppleProductTypes' public interface (only resolvable inside
            // Xcode/Swift Playgrounds' icon picker), so guessing one risked another
            // build break. Pick a real icon in Xcode's app icon editor once it's
            // available, or set an asset-based icon via iconAssetName.
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.phone, .pad],
            supportedInterfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight],
            capabilities: [
                .faceID(purposeString: "Unlocks your ledger and your saved card details."),
                .photoLibrary(purposeString: "Lets you attach a photo of a card, stored encrypted on this device only."),
                .camera(purposeString: "Scans receipts to fill in the amount, date and card for you.")
            ]
        )
    ],
    targets: [
        .executableTarget(name: "Ledger", path: "Ledger"),
        .testTarget(name: "LedgerTests", dependencies: ["Ledger"], path: "Tests")
    ]
)
