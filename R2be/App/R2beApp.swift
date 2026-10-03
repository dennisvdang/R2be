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
    @State private var tab: AppTab = .library

    var body: some View {
        @Bindable var player = player
        Group {
            if library.isConfigured {
                TabView(selection: $tab) {
                    NavigationStack {
                        FolderView(prefix: "")
                            .navigationDestination(for: FolderRoute.self) { FolderView(prefix: $0.prefix) }
                    }
                        .id(library.activeBucket)
                        .miniPlayerInset()
                        .tabItem { Label("Library", systemImage: "play.rectangle.on.rectangle") }
                        .tag(AppTab.library)

                    FeedView(isActiveTab: tab == .feed)
                        .id(library.activeBucket)
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
            } else {
                NavigationStack { SetupView(isInitialSetup: true) }
            }
        }
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerView()
        }
    }
}
