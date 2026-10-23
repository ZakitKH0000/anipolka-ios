import SwiftUI

@main @MainActor struct AniPolkaApp: App {
    @StateObject private var store: ShelfStore
    @StateObject private var network: NetworkService
    @StateObject private var assistant: ShelfAssistant
    @Environment(\.scenePhase) private var phase
    init() {
        let store = ShelfStore(), network = NetworkService()
        _store = StateObject(wrappedValue:store); _network = StateObject(wrappedValue:network)
        _assistant = StateObject(wrappedValue:ShelfAssistant(store:store,network:network))
    }
    private var coverSignature: String { store.snapshot.entries.map { "\($0.id)\($0.title)\($0.coverURL)\($0.coverData != nil)\($0.coverLookupDisabled == true)" }.joined() }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(network).environmentObject(assistant)
                .preferredColorScheme(store.snapshot.preferences.theme == .system ? nil : (store.snapshot.preferences.theme == .dark ? .dark : .light))
                .onAppear { network.wifiOnly = store.snapshot.preferences.wifiOnly; assistant.queueCovers(); assistant.scheduleBackground() }
                .onChange(of: store.snapshot.preferences.wifiOnly) { _, value in network.wifiOnly = value }
                .onChange(of: network.revision) { _, _ in assistant.queueCovers() }
                .onChange(of: coverSignature) { _, _ in assistant.queueCovers() }
                .onChange(of: store.snapshot.preferences.automaticCovers) { _, value in if value { assistant.queueCovers(force:true) } }
                .onChange(of: phase) { _, value in
                    if value == .background { assistant.scheduleBackground() }
                    if value == .active {
                        assistant.queueCovers()
                        let hasDue = store.snapshot.entries.contains { ($0.subscriptions ?? []).contains { $0.enabled && ($0.lastCheckedAt ?? .distantPast).timeIntervalSinceNow < -3600 } }
                        if hasDue { Task { await assistant.checkReleases(background:true) } }
                    }
                }
        }
        .backgroundTask(.appRefresh(ShelfAssistant.refreshID)) { await assistant.checkReleases(background:true) }
    }
}
