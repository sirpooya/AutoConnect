import MacAuthCore
import SwiftUI

@main
struct MacAuthApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(state)
        } label: {
            // Filled when at least one account exists, so the icon reflects whether the app
            // has anything to offer.
            Image(systemName: state.accounts.isEmpty ? "lock.rotation" : "lock.rotation.open")
        }
        .menuBarExtraStyle(.window)
    }
}
