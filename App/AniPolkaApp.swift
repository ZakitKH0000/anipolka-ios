import SwiftUI
import UserNotifications

@main @MainActor struct AniPolkaApp: App {
    @StateObject private var store: ShelfStore
    @StateObject private var network: NetworkService
    @StateObject private var assistant: ShelfAssistant
    @StateObject private var lock: AppLock
    @Environment(\.scenePhase) private var phase
    init() {
        // Set before launch finishes so a notification action works when iOS starts the app in the background.
        UNUserNotificationCenter.current().delegate = NotificationBridge.shared
        NotificationBridge.shared.registerCategories()
        let store = ShelfStore.shared, network = NetworkService()
        _store = StateObject(wrappedValue:store); _network = StateObject(wrappedValue:network)
        _assistant = StateObject(wrappedValue:ShelfAssistant(store:store,network:network))
        _lock = StateObject(wrappedValue:AppLock(enabled:store.snapshot.preferences.appLock && !store.demo))
    }
    private var coverSignature: String { store.snapshot.entries.map { "\($0.id)\($0.title)\($0.coverURL)\($0.coverData != nil)\($0.coverLookupDisabled == true)" }.joined() }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(network).environmentObject(assistant).environmentObject(lock)
                // Also hides the collection in the app switcher while the lock is on.
                .overlay { if store.snapshot.preferences.appLock && (lock.locked || phase != .active) { LockScreen(lock:lock) } }
                .preferredColorScheme(store.snapshot.preferences.theme == .system ? nil : (store.snapshot.preferences.theme == .dark ? .dark : .light))
                .onAppear { network.wifiOnly = store.snapshot.preferences.wifiOnly; assistant.queueCovers(); assistant.scheduleBackground(); if lock.locked { Task { await lock.authenticate() } } }
                .onChange(of: store.snapshot.preferences.wifiOnly) { _, value in network.wifiOnly = value }
                .onChange(of: network.revision) { _, _ in assistant.queueCovers() }
                .onChange(of: coverSignature) { _, _ in assistant.queueCovers() }
                .onChange(of: store.snapshot.preferences.automaticCovers) { _, value in if value { assistant.queueCovers(force:true) } }
                .onChange(of: phase) { _, value in
                    if value == .background { assistant.scheduleBackground(); if store.snapshot.preferences.appLock { lock.lock() } }
                    if value == .active {
                        if lock.locked && store.snapshot.preferences.appLock { Task { await lock.authenticate() } }
                        assistant.queueCovers()
                        let hasDue = store.snapshot.entries.contains { ($0.subscriptions ?? []).contains { $0.enabled && ($0.lastCheckedAt ?? .distantPast).timeIntervalSinceNow < -3600 } }
                        if hasDue { Task { await assistant.checkReleases(background:true) } }
                    }
                }
        }
        .backgroundTask(.appRefresh(ShelfAssistant.refreshID)) { await assistant.checkReleases(background:true) }
    }
}
