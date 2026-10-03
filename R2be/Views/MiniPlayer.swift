import SwiftUI

/// In-app Picture in Picture: when you leave the full player while something is playing, the video
/// keeps going in this small floating window. Drag it anywhere; let go and it tucks against the
/// nearest side. Tap to reopen the full player, ▶︎/❚❚ to pause, ✕ to stop. It floats above the
/// keyboard and tab bar rather than being pushed around by them. When you leave the app, the
/// system Picture in Picture window takes over from it.
struct FloatingPlayer: View {
    let bounds: CGSize
    let insets: EdgeInsets
    @Environment(PlayerController.self) private var player
    @State private var center: CGPoint?
    @GestureState private var drag: CGSize = .zero

    private var width: CGFloat { min(max(bounds.width * 0.48, 170), 280) }
    private var height: CGFloat { width * 9 / 16 }
    private let margin: CGFloat = 10
    private let tabBarHeight: CGFloat = 49

    var body: some View {
        if player.current != nil {
            let c = center ?? defaultCenter
            ZStack {
                VideoSurface(player: player.player, gravity: .resizeAspectFill, pip: player.pip)
                    .allowsHitTesting(false)
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    HStack {
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 44, height: 40)
                        }
                        Spacer()
                        Button { player.stop() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 40)
                        }
                    }
                    Spacer()
                    GeometryReader { g in
                        Rectangle().fill(.red)
                            .frame(width: player.duration > 0 ? g.size.width * min(player.currentTime / player.duration, 1) : 0)
                    }
                    .frame(height: 3)
                    .background(Color.white.opacity(0.25))
                }
                .foregroundStyle(.white)
                .shadow(radius: 3)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { player.isPresented = true }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { v, state, _ in state = v.translation }
                    .onEnded { v in
                        let dropped = CGPoint(x: c.x + v.translation.width + v.predictedEndTranslation.width * 0.2,
                                              y: c.y + v.translation.height + v.predictedEndTranslation.height * 0.2)
                        withAnimation(.spring(duration: 0.35)) { center = snapped(dropped) }
                    })
            .position(x: c.x + drag.width, y: c.y + drag.height)
            .onChange(of: bounds) { _, _ in if let cur = center { center = snapped(cur) } }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private var minX: CGFloat { insets.leading + margin + width / 2 }
    private var maxX: CGFloat { bounds.width - insets.trailing - margin - width / 2 }
    private var minY: CGFloat { insets.top + margin + height / 2 }
    private var maxY: CGFloat { bounds.height - insets.bottom - tabBarHeight - margin - height / 2 }

    private var defaultCenter: CGPoint { CGPoint(x: maxX, y: maxY) }

    /// Keeps the window on screen and against the nearer left/right side; the height you drop it at stays.
    private func snapped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x < bounds.width / 2 ? minX : maxX,
                y: min(max(p.y, minY), max(maxY, minY)))
    }
}
