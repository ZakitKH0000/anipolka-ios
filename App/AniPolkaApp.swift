import SwiftUI

@main struct AniPolkaApp: App {
    @StateObject private var store = ShelfStore()
    @StateObject private var network = NetworkService()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(network)
                .preferredColorScheme(store.snapshot.preferences.theme == .system ? nil : (store.snapshot.preferences.theme == .dark ? .dark : .light))
                .onAppear { network.wifiOnly = store.snapshot.preferences.wifiOnly }
                .onChange(of: store.snapshot.preferences.wifiOnly) { _, value in network.wifiOnly = value }
        }
    }
}
