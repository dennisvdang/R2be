import SwiftUI

struct MiniPlayerBar: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        if let item = player.current {
            VStack(spacing: 0) {
                GeometryReader { g in
                    Rectangle().fill(.red)
                        .frame(width: player.duration > 0 ? g.size.width * min(player.currentTime / player.duration, 1) : 0)
                }
                .frame(height: 2)
                .background(Color.white.opacity(0.15))

                HStack(spacing: 10) {
                    VideoSurface(player: player.player, gravity: .resizeAspectFill, pip: player.pip)
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(player.sourceTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 44)
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.end.fill").font(.body).frame(width: 36, height: 44)
                    }
                    .disabled(!player.hasNext)
                    Button { player.stop() } label: {
                        Image(systemName: "xmark").font(.body).frame(width: 32, height: 44)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .foregroundStyle(.white)
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture { player.isPresented = true }
            .gesture(DragGesture(minimumDistance: 15).onEnded { v in
                if v.translation.height < -30 { player.isPresented = true }
                else if v.translation.width < -60 { player.next() }
            })
        }
    }
}

extension View {
    /// Pins the mini player above the tab bar while something is playing and the full player is closed.
    func miniPlayerInset(hidden: Bool) -> some View {
        modifier(MiniPlayerInset(hidden: hidden))
    }
}

private struct MiniPlayerInset: ViewModifier {
    let hidden: Bool
    @Environment(PlayerController.self) private var player

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if !hidden, !player.isPresented, player.current != nil {
                MiniPlayerBar().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
