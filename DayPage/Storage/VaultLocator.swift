import Foundation

// MARK: - VaultLocator

/// Abstracts the storage backend so the vault path can be swapped at runtime
/// without touching individual call sites.
protocol VaultLocator {
    var vaultURL: URL { get }
    var isUsingiCloud: Bool { get }
}

// MARK: - LocalVaultLocator

/// Default implementation: stores vault under the app's local Documents directory.
/// Behavior is identical to the previous hard-coded VaultInitializer.vaultURL.
struct LocalVaultLocator: VaultLocator {
    var vaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vault", isDirectory: true)
    }

    var isUsingiCloud: Bool { false }
}

// MARK: - iCloudVaultLocator

/// iCloud Drive implementation: stores vault under the app's ubiquity container.
/// Falls back gracefully when iCloud is unavailable (e.g., Simulator without account).
struct iCloudVaultLocator: VaultLocator {
    let containerID = "iCloud.com.daypage.app"

    var vaultURL: URL {
        FileManager.default
            .url(forUbiquityContainerIdentifier: containerID)?
            .appendingPathComponent("Documents/vault", isDirectory: true)
            ?? LocalVaultLocator().vaultURL
    }

    var isUsingiCloud: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID) != nil
    }
}
