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
            MenuBarIconView()
        }
        .menuBarExtraStyle(.window)
    }
}
