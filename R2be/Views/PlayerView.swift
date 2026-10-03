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
        .onAppear { scheduleHide() }
        .onChange(of: player.isPlaying) { _, playing in if playing { scheduleHide() } else { showControls(autoHide: false) } }
    }

    // MARK: Video + overlay

    private func videoArea(landscape: Bool) -> some View {
        ZStack {
            VideoSurface(player: player.player, gravity: fill ? .resizeAspectFill : .resizeAspect)

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
        player.skip(forward ? PlayerController.skipInterval : -PlayerController.skipInterval)
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
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)],
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
            .padding(.vertical, landscape ? 16 : 8)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { player.isPresented = false } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 36, height: 36)
            }
            if landscape, let item = player.current {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.sourceTitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer()
            AirPlayButton().frame(width: 32, height: 32)
            Menu {
                Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0; onInteract() })) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { r in
                        Text(r == 1 ? "Normal" : String(format: "%gx", r)).tag(r)
                    }
                }
                Toggle("Loop queue", isOn: Binding(get: { player.loopQueue }, set: { player.loopQueue = $0 }))
            } label: {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title3).frame(width: 36, height: 36)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: landscape ? 48 : 26) {
            control("gobackward.30", size: 26) { player.skip(-PlayerController.skipInterval) }
            control("backward.end.fill", size: 24) { player.previous() }
            Button { player.togglePlay(); onInteract() } label: {
                ZStack {
                    if player.isBuffering { ProgressView().controlSize(.large).tint(.white) }
                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 38)) }
                }
                .frame(width: 72, height: 72)
                .background(.black.opacity(0.35), in: Circle())
            }
            control("forward.end.fill", size: 24) { player.next() }
                .disabled(!player.hasNext).opacity(player.hasNext ? 1 : 0.4)
            control("goforward.30", size: 26) { player.skip(PlayerController.skipInterval) }
        }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button { action(); onInteract() } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 48, height: 48)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text(Format.duration(player.isScrubbing ? scrubValue : player.currentTime))
                Text("/").foregroundStyle(.white.opacity(0.5))
                Text(Format.duration(player.duration)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                toggle("shuffle", on: player.shuffle) { player.shuffle.toggle() }
                toggle(player.autoplay ? "play.square.stack.fill" : "play.square.stack", on: player.autoplay) { player.autoplay.toggle() }
                toggle(fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", on: fill) {
                    withAnimation { fill.toggle() }
                }
                if !landscape {
                    toggle("rotate.right", on: false) { Orientation.request(.landscapeRight) }
                } else {
                    toggle("rotate.left", on: false) { Orientation.request(.portrait) }
                }
            }
            .font(.caption.monospacedDigit())

            Slider(value: Binding(get: { player.isScrubbing ? scrubValue : player.currentTime },
                                  set: { scrubValue = $0 }),
                   in: 0...max(player.duration, 1),
                   onEditingChanged: { editing in
                if editing { scrubValue = player.currentTime }
                player.isScrubbing = editing
                if !editing { player.seek(to: scrubValue) }
                onInteract()
            })
            .tint(.red)
        }
    }

    private func toggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); onInteract() } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on ? Color.red : Color.white)
                .frame(width: 36, height: 30)
        }
    }
}

// MARK: - Info + Up Next (portrait)

private struct PlayerInfoPanel: View {
    @Binding var pendingAdd: PendingPlaylistAdd?
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        List {
            if let item = player.current {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline).lineLimit(3)
                        Text([player.sourceTitle, item.folderDisplay, Format.bytes(item.size), Format.relative(item.lastModified)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.black)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip(player.shuffle ? "Shuffle on" : "Shuffle", "shuffle", on: player.shuffle) { player.shuffle.toggle() }
                            chip(player.autoplay ? "Autoplay on" : "Autoplay off", "play.square.stack", on: player.autoplay) { player.autoplay.toggle() }
                            chip("Save", "text.badge.plus", on: false) {
                                pendingAdd = PendingPlaylistAdd(entries: [.video(bucket: item.bucket, key: item.key)])
                            }
                            if let url = library.shareURL(for: item) {
                                ShareLink(item: url) { chipLabel("Share", "square.and.arrow.up", on: false) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.black)
                }
            }

            Section {
                ForEach(player.upNext) { v in
                    Button { player.jump(to: v) } label: {
                        HStack(spacing: 10) {
                            ThumbnailView(item: v).frame(width: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.title).font(.subheadline).lineLimit(2)
                                Text(v.folderDisplay).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.black)
                }
                .onDelete { player.removeFromUpNext(at: $0) }
            } header: {
                HStack {
                    Text("Up next · \(player.upNext.count)")
                    Spacer()
                    if player.shuffle {
                        Button { player.reshuffle() } label: { Label("Reshuffle", systemImage: "dice") }
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
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

// MARK: - Orientation helper

enum Orientation {
    @MainActor
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
