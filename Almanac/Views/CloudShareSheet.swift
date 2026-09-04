import SwiftUI
import CloudKit
import UIKit

/// Apple's own sharing sheet. Rolling your own invitation flow means handling
/// email, iMessage, links, permissions and revocation — this is the same screen
/// Notes and Reminders use, and participants get the standard accept experience.
struct CloudShareSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func itemTitle(for controller: UICloudSharingController) -> String? { "Almanac" }

        func cloudSharingControllerDidSaveShare(_ controller: UICloudSharingController) {
            onFinish()
        }

        func cloudSharingControllerDidStopSharing(_ controller: UICloudSharingController) {
            onFinish()
        }

        func cloudSharingController(
            _ controller: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            onFinish()
        }
    }
}

/// Handles someone tapping an invitation.
///
/// SwiftUI has no hook for this — accepting a CloudKit share arrives through the
/// window scene delegate, so the app needs one even though nothing else does.
final class ShareAcceptanceDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            await CloudSync.shared.accept(metadata)
        }
    }
}

final class AlmanacAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = ShareAcceptanceDelegate.self
        return configuration
    }
}
