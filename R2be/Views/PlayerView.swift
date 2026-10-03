import AVFoundation
import SwiftUI

/// Full-screen in-app player. Portrait: 16:9 video on top with info + Up Next below (YouTube-like).
/// Landscape: edge-to-edge video. Swipe down to minimise into the mini player.
struct PlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dragOffset: CGFloat = 0
    @State private var flash: Bool? = nil          // true = forward, false = back
    @State private var flashTask: Task<Void, Never>?
    @State private var scrubValue: Double = 0
    @State private var fill = false
    @State private var pendingAdd: PendingPlaylistAdd?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if landscape {
                    videoArea(landscape: true)
                        .ignoresSafeArea()
                } else if fill {

                    // Portrait fill: the video takes the whole screen and the info panel hides.
                    videoArea(landscape: false)
                } else {
                    VStack(spacing: 0) {
                        videoArea(landscape: false)
                            .aspectRatio(16 / 9, contentMode: .fit)
                        PlayerInfoPanel(pendingAdd: $pendingAdd)
                    }
                }
            }
            .offset(y: max(dragOffset, 0))
            .statusBarHidden(landscape)
        }
        .persistentSystemOverlays(.hidden)
        .sheet(item: $pendingAdd) { AddToPlaylistSheet(pending: $0) }
        .onAppear {
            scheduleHide()
            if player.startFullscreen {
                player.startFullscreen = false
                Orientation.enterFullscreen()
            }
        }
        .onDisappear { if Orientation.isFullscreen { Orientation.exitFullscreen() } }
        .onChange(of: player.isPlaying) { _, playing in if playing { scheduleHide() } else { showControls(autoHide: false) } }
    }

    // MARK: Video + overlay

    private func videoArea(landscape: Bool) -> some View {
        ZStack {
            VideoSurface(player: player.player, gravity: fill ? .resizeAspectFill : .resizeAspect, pip: player.pip)
                .ignoresSafeArea(edges: fill ? .all : [])

            // Gesture layer: single tap toggles controls, double tap left/right skips 30 s.
            HStack(spacing: 0) {
                tapZone(forward: false)
                tapZone(forward: true)
            }

            if let flash {
                HStack {
                    if flash { Spacer() }
                    SeekFlash(forward: flash).padding(.horizontal, 40)
                    if !flash { Spacer() }
                }
                .allowsHitTesting(false)
            }

            if player.isBuffering && !controlsVisible {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if controlsVisible {
                ControlsOverlay(landscape: landscape, fill: $fill, scrubValue: $scrubValue,
                                onInteract: { scheduleHide() })
                    .transition(.opacity)
            }

            if let err = player.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(err).font(.footnote).multilineTextAlignment(.center).padding(.horizontal, 30)
                    if player.hasNext { Button("Skip to next") { player.next() }.buttonStyle(.borderedProminent) }
                }
                .padding()
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .contentShape(Rectangle())
        .pinchToFill($fill)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in if v.translation.height > 0 && abs(v.translation.height) > abs(v.translation.width) { dragOffset = v.translation.height } }
                .onEnded { v in
                    if v.translation.height > 120 { player.isPresented = false }
                    else if v.translation.width < -80 && abs(v.translation.width) > abs(v.translation.height) { player.next() }
                    else if v.translation.width > 80 && abs(v.translation.width) > abs(v.translation.height) { player.previous() }
                    withAnimation(.spring) { dragOffset = 0 }
                })
    }

    private func tapZone(forward: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTap(forward: forward) }
            .onTapGesture {
                if controlsVisible { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false } }
                else { showControls(autoHide: true) }
            }
    }

    private func doubleTap(forward: Bool) {
        forward ? player.skipForward() : player.skipBackward()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(duration: 0.25)) { flash = forward }
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            if !Task.isCancelled { withAnimation(.easeOut) { flash = nil } }
        }
    }

    private func showControls(autoHide: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled, player.isPlaying, !player.isScrubbing {
                withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
            }
        }
    }
}

// MARK: - Controls

private struct ControlsOverlay: View {
    let landscape: Bool
    @Binding var fill: Bool
    @Binding var scrubValue: Double
    let onInteract: () -> Void
    @Environment(PlayerController.self) private var player

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                transport
                Spacer()
                bottomBar
            }
            .padding(.horizontal, landscape ? 44 : 12)
            .padding(.top, landscape ? 16 : 8)
        }
        .foregroundStyle(.white)
    }

    // Top: minimise on the left; autoplay switch, shuffle, AirPlay and settings on the right.
    private var topBar: some View {
        HStack(spacing: 14) {
            Button { player.isPresented = false } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Minimise")
            if landscape, let item = player.current {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.sourceTitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer()
            AutoplaySwitch(isOn: player.autoplay) { player.autoplay.toggle(); onInteract() }
            Button { player.shuffle.toggle(); onInteract() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(player.shuffle ? Color.red : Color.white)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(player.shuffle ? "Shuffle on" : "Shuffle off")
            AirPlayButton().frame(width: 32, height: 32)
            PlayerSettingsMenu(landscape: landscape, fill: $fill, onInteract: onInteract) {
                Image(systemName: "gearshape").font(.system(size: 20, weight: .semibold)).frame(width: 36, height: 36)
            }
        }
    }

    // Middle: previous / play-pause / next in round buttons, ±30 s on the outside.
    private var transport: some View {
        HStack(spacing: landscape ? 40 : 18) {
            plain(player.skipSymbol(forward: false), size: 22) { player.skipBackward() }
            round("backward.end.fill", size: 22, diameter: 52) { player.previous() }
            Button { player.togglePlay(); onInteract() } label: {
                ZStack {
                    if player.isBuffering { ProgressView().controlSize(.large).tint(.white) }
                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34)) }
                }
                .frame(width: 70, height: 70)
                .background(.black.opacity(0.4), in: Circle())
            }
            round("forward.end.fill", size: 22, diameter: 52) { player.next() }
                .disabled(!player.hasNext).opacity(player.hasNext ? 1 : 0.4)
            plain(player.skipSymbol(forward: true), size: 22) { player.skipForward() }
        }
    }

    private func round(_ symbol: String, size: CGFloat, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button { action(); onInteract() } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .background(.black.opacity(0.4), in: Circle())
        }
    }

    private func plain(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button { action(); onInteract() } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 44, height: 44)
        }
    }

    // Bottom: time pill on the left, fullscreen alone on the right, scrubber along the bottom edge.
    private var bottomBar: some View {
        VStack(spacing: 2) {
            HStack(alignment: .bottom) {
                HStack(spacing: 4) {
                    Text(Format.duration(player.isScrubbing ? scrubValue : player.currentTime))
                    Text("/").foregroundStyle(.white.opacity(0.6))
                    Text(Format.duration(player.duration)).foregroundStyle(.white.opacity(0.8))
                }
                .font(.subheadline.monospacedDigit().weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                Spacer()
                Button {
                    if landscape { Orientation.exitFullscreen() } else { Orientation.enterFullscreen() }
                    onInteract()
                } label: {
                    Image(systemName: landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel(landscape ? "Exit full screen" : "Full screen")
            }

            // The drag owns the value from its first change; on release the seek holds the
            // handle at the drop point until the player catches up.
            Slider(value: Binding(get: { player.isScrubbing ? scrubValue : player.currentTime },
                                  set: { scrubValue = $0; player.isScrubbing = true }),
                   in: 0...max(player.duration, 1),
                   onEditingChanged: { editing in
                if !editing {
                    player.seek(to: scrubValue)
                    player.isScrubbing = false
                }
                onInteract()
            })
            .tint(.red)
            .padding(.horizontal, landscape ? -28 : -6)   // run the scrubber nearly edge to edge
        }
    }
}

/// YouTube-style autoplay switch: a pill with a ▶︎ knob on the right when on, ❚❚ on the left when off.
private struct AutoplaySwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(.white.opacity(isOn ? 0.55 : 0.3)).frame(width: 46, height: 22)
                Circle().fill(.white).frame(width: 28, height: 28)
                    .overlay(Image(systemName: isOn ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.black))
                    .shadow(radius: 2)
            }
            .frame(width: 50, height: 36)
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Autoplay on" : "Autoplay off")
    }
}

/// The cog menu: speed, loop, sleep timer, picture fit, Picture in Picture and media source.
private struct PlayerSettingsMenu<MenuLabel: View>: View {
    let landscape: Bool
    @Binding var fill: Bool
    let onInteract: () -> Void
    @ViewBuilder let label: () -> MenuLabel
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var downloads = DownloadStore.shared

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { player.rate }, set: { player.rate = $0; onInteract() })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { r in
                    Text(r == 1 ? "Normal" : String(format: "%gx", r)).tag(r)
                }
            } label: {
                Label("Playback speed", systemImage: "gauge.with.dots.needle.33percent")
            }
            .pickerStyle(.menu)
            Toggle(isOn: Binding(get: { player.loopQueue }, set: { player.loopQueue = $0 })) {
                Label("Loop queue", systemImage: "repeat")
            }
            Menu {
                SleepTimerItems()
            } label: {
                Label(player.sleepTimer == .off ? "Sleep timer" : "Sleep timer (on)", systemImage: "moon.zzz")
            }
            if landscape {
                Toggle(isOn: $fill) { Label("Zoom to fill", systemImage: "aspectratio") }
            }
            if PiPManager.isSupported {
                Button { player.pip.toggle() } label: {
                    Label(player.pip.isActive ? "Stop Picture in Picture" : "Picture in Picture", systemImage: "pip.enter")
                }
                .disabled(!player.pip.isPossible && !player.pip.isActive)
            }
            if let item = player.current {
                Section("Media source") {
                    Label(downloads.isDownloaded(item) ? "Playing downloaded copy" : "Streaming from R2",
                          systemImage: downloads.isDownloaded(item) ? "iphone" : "cloud")
                    DownloadMenuItems(items: [item])
                }
            }
        } label: {
            label()
        }
    }
}

// MARK: - Info + Up Next (portrait)

private struct PlayerInfoPanel: View {
    @Binding var pendingAdd: PendingPlaylistAdd?
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @AppStorage("disableShare") private var disableShare = true
    @State private var downloads = DownloadStore.shared

    enum ListTab { case upNext, related }
    @State private var tab: ListTab = .upNext

    var body: some View {
        List {
            if let item = player.current {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline).lineLimit(3)
                        Text([player.duration > 0 ? Format.duration(player.duration) : "", Format.relative(item.lastModified)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.black)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip(player.shuffle ? "Shuffle on" : "Shuffle", "shuffle", on: player.shuffle) { player.shuffle.toggle() }
                            chip(player.autoplay ? "Autoplay on" : "Autoplay off", "play.square.stack", on: player.autoplay) { player.autoplay.toggle() }
                            SleepTimerMenu { sleepChipLabel }
                            chip("Save", "text.badge.plus", on: false) {
                                pendingAdd = PendingPlaylistAdd(entries: [.video(bucket: item.bucket, key: item.key)])
                            }
                            if downloads.isDownloaded(item) {
                                chipLabel("Downloaded", "arrow.down.circle.fill", on: false)
                            } else if let p = downloads.progress[item.id] {
                                chip("Downloading \(Int(p * 100))%", "arrow.down.circle", on: false) { downloads.cancel(item) }
                            } else {
                                chip("Download", "arrow.down.circle", on: false) { library.download([item]) }
                            }
                            if !disableShare, let url = library.shareURL(for: item) {
                                ShareLink(item: url) { chipLabel("Share", "square.and.arrow.up", on: false) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.black)
                }
            }

            let related = player.current.map { library.related(to: $0) } ?? []
            Section {
                switch tab {
                case .upNext:
                    ForEach(player.upNext) { v in
                        Button { player.jump(to: v) } label: { videoRow(v) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.black)
                    }
                    .onDelete { player.removeFromUpNext(at: $0) }
                case .related:
                    if related.isEmpty {
                        Text("No other parts found. Related lists videos with the same name ending in -pt1, pt 2, part 3, ep 4, (5) and so on.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .listRowBackground(Color.black)
                    }
                    ForEach(related) { v in
                        let isCurrent = v == player.current
                        Button { player.playNow(v) } label: { videoRow(v, nowPlaying: isCurrent) }
                            .buttonStyle(.plain)
                            .disabled(isCurrent)
                            .listRowBackground(Color.black)
                    }
                }
            } header: {
                HStack(spacing: 16) {
                    tabButton("Up next · \(player.upNext.count)", .upNext)
                    tabButton("Related · \(max(related.count - 1, 0))", .related)
                    Spacer()
                    if tab == .upNext, player.shuffle {
                        Button { player.reshuffle() } label: { Label("Reshuffle", systemImage: "dice") }
                            .font(.caption)
                    } else if tab == .related, let first = related.first {
                        Button {
                            player.play(related, startAt: first, shuffle: false,
                                        title: "Related", present: false, keepGivenOrder: true)
                        } label: { Label("Play all parts", systemImage: "play.fill") }
                            .font(.caption)
                    }
                }
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }

    private func tabButton(_ title: String, _ value: ListTab) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { tab = value } } label: {
            Text(title)
                .font(.subheadline.weight(tab == value ? .semibold : .regular))
                .foregroundStyle(tab == value ? Color.white : Color.secondary)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    if tab == value { Rectangle().fill(Color.red).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
    }

    private func videoRow(_ v: VideoItem, nowPlaying: Bool = false) -> some View {
        HStack(spacing: 10) {
            ThumbnailView(item: v).frame(width: 120).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(v.title).font(.subheadline).lineLimit(2)
                Text(nowPlaying ? "Now playing" : v.folderDisplay)
                    .font(.caption).foregroundStyle(nowPlaying ? Color.red : Color.secondary).lineLimit(1)
            }
        }
    }

    /// "Sleep" chip; shows the countdown while a timer is running.
    private var sleepChipLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let title: String = {
                switch player.sleepTimer {
                case .off: return "Sleep timer"
                case .endOfVideo: return "Sleep: end of video"
                case .at(let end): return "Sleep " + Format.duration(max(end.timeIntervalSince(context.date), 0))
                }
            }()
            chipLabel(title, "moon.zzz", on: player.sleepTimer != .off)
        }
    }

    private func chip(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, symbol, on: on) }.buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, _ symbol: String, on: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(on ? Color.red.opacity(0.85) : Color(white: 0.18), in: Capsule())
    }
}

// MARK: - Sleep timer

/// Menu for setting the sleep timer: pauses playback after a set time or when the video ends.
struct SleepTimerMenu<MenuLabel: View>: View {
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu { SleepTimerItems() } label: { label() }
    }
}

/// The sleep timer choices, shared by the chip menu and the player's cog menu.
struct SleepTimerItems: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        Group {
            if player.sleepTimer != .off {
                Button("Turn off sleep timer", systemImage: "xmark", role: .destructive) { player.cancelSleepTimer() }
            }
            Button("End of current video", systemImage: "film") { player.setSleepAtEndOfVideo() }
            ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { m in
                Button(m < 60 ? "\(m) minutes" : (m == 60 ? "1 hour" : String(format: "%g hours", Double(m) / 60))) {
                    player.setSleepTimer(minutes: m)
                }
            }
        }
    }
}

// MARK: - Orientation / fullscreen

/// Fullscreen for the player. Entering locks the app to landscape even while the phone is still
/// upright, so you can tap Expand and then turn the phone (like YouTube). Leaving locks portrait
/// until the phone is actually held upright again, then normal auto-rotation resumes.
@MainActor
enum Orientation {
    /// Read by AppDelegate.supportedInterfaceOrientationsFor.
    private(set) static var lock: UIInterfaceOrientationMask = .allButUpsideDown
    static var isFullscreen: Bool { lock == .landscape }
    private static var uprightObserver: NSObjectProtocol?

    static func enterFullscreen() {
        stopWaitingForUpright()
        apply(.landscape)
    }

    static func exitFullscreen() {
        apply(.portrait)
        let device = UIDevice.current.orientation
        if device == .portrait || !device.isValidInterfaceOrientation {
            release()
            return
        }
        // Phone is still sideways: stay portrait until it's turned upright, or it would flip straight back.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        stopWaitingForUpright()
        uprightObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if UIDevice.current.orientation == .portrait { Orientation.release() }
            }
        }
    }

    private static func release() {
        stopWaitingForUpright()
        lock = .allButUpsideDown
        refreshSupportedOrientations()
    }

    private static func stopWaitingForUpright() {
        if let uprightObserver { NotificationCenter.default.removeObserver(uprightObserver) }
        uprightObserver = nil
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        lock = mask
        refreshSupportedOrientations()
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    /// Every controller in the presentation chain (the player is a full-screen cover) must re-query.
    private static func refreshSupportedOrientations() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) {
            var vc = window.rootViewController
            while let current = vc {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = current.presentedViewController
            }
        }
    }
}
