import AVFoundation
import PhotosUI
import SwiftUI

/// Only here to let the player lock orientation for fullscreen (see `Orientation`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.lock
    }
}

@main
struct R2beApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library: LibraryStore
    @State private var playlists = PlaylistStore()
    @State private var covers = FolderCoverStore()
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
                .environment(covers)
                .preferredColorScheme(.dark)
                .tint(.red)
        }
    }
}

enum AppTab: Hashable { case library, feed, playlists, settings }

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(FolderCoverStore.self) private var covers
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .library
    @State private var pickedCover: PhotosPickerItem?

    var body: some View {
        @Bindable var player = player
        Group {
            if library.isConfigured {
                TabView(selection: $tab) {
                    NavigationStack {
                        FolderView(prefix: "")
                            .navigationDestination(for: FolderRoute.self) { FolderView(prefix: $0.prefix) }
                    }
                        .miniPlayerInset(hidden: false)
                        .tabItem { Label("Library", systemImage: "play.rectangle.on.rectangle") }
                        .tag(AppTab.library)

                    FeedView(isActiveTab: tab == .feed)
                        .tabItem { Label("Feed", systemImage: "rectangle.stack.badge.play") }
                        .tag(AppTab.feed)

                    NavigationStack { PlaylistsView() }
                        .miniPlayerInset(hidden: false)
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
        // One photo picker for "Set Cover Image" on any folder (see FolderMenu).
        .photosPicker(isPresented: Binding(get: { covers.isPickerPresented }, set: { covers.isPickerPresented = $0 }),
                      selection: $pickedCover, matching: .images)
        .onChange(of: pickedCover) { _, item in
            guard let item, let target = covers.pickerTarget else { return }
            pickedCover = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    covers.setCover(data, for: target)
                }
            }
        }
    }
}
