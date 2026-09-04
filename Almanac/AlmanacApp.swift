import SwiftUI

@main
struct AlmanacApp: App {
    // Only here so CloudKit share invitations have somewhere to land.
    @UIApplicationDelegateAdaptor(AlmanacAppDelegate.self) private var appDelegate
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)

        }
    }
}
