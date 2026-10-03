import AVFoundation
import SwiftUI

@main
struct R2beApp: App {
    @State private var library: LibraryStore
    @State private var playlists = PlaylistStore()
    @State private var player: PlayerController

    init() {
        let lib = LibraryStore()
        let p = PlayerController()
        p.library = lib
        _library = State(initialValue: lib)
        _player = State(initialValue: p)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(playlists)
                .environment(player)
                .preferredColorScheme(.dark)
                .tint(.red)
        }
    }
}

enum AppTab: Hashable { case library, feed, playlists, settings }

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var indexingTask: UIBackgroundTaskIdentifier = .invalid
    @State private var tab: AppTab = .library

    var body: some View {
        @Bindable var player = player
        Group {
            if library.isConfigured {
                TabView(selection: $tab) {
                    NavigationStack {
                        FolderView(prefix: library.rootPrefix)
                            .navigationDestination(for: FolderRoute.self) { FolderView(prefix: $0.prefix) }
                    }
                        .id(library.activeBucket + "/" + library.rootPrefix)
                        .miniPlayerInset()
                        .tabItem { Label("Library", systemImage: "play.rectangle.on.rectangle") }
                        .tag(AppTab.library)

                    FeedView(isActiveTab: tab == .feed)
                        .id(library.activeBucket + "/" + library.rootPrefix)
                        .tabItem { Label("Feed", systemImage: "rectangle.stack.badge.play") }
                        .tag(AppTab.feed)

                    NavigationStack { PlaylistsView() }
                        .miniPlayerInset()
                        .tabItem { Label("Playlists", systemImage: "music.note.list") }
                        .tag(AppTab.playlists)

                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppTab.settings)
                }
                .onAppear { library.refreshIfStale() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { library.refreshIfStale() } }

                // Auto-lock suspends the app and cuts the listing off, so stay awake while indexing.
                // Leaving the app buys ~30 s of background time; the listing resumes on return after that.
                .onChange(of: library.isIndexing) { _, indexing in
                    UIApplication.shared.isIdleTimerDisabled = indexing
                    if indexing {
                        indexingTask = UIApplication.shared.beginBackgroundTask { endIndexingTask() }
                    } else {
                        endIndexingTask()
                    }
                }
            } else {
                NavigationStack { SetupView(isInitialSetup: true) }
            }
        }
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerView()
        }

        // Any scroll closes the keyboard, so a search field never stays stuck open.
        .scrollDismissesKeyboard(.immediately)
    }

    private func endIndexingTask() {
        guard indexingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(indexingTask)
        indexingTask = .invalid
    }
}
