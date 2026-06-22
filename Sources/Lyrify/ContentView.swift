import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var vm: LyricsViewModel

    var body: some View {
        ZStack {
            VisualEffectView().ignoresSafeArea()

            VStack(spacing: 0) {
                // Clear zone for the traffic light buttons
                Color.clear.frame(height: 14)

                // Track info header
                if !vm.trackTitle.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.trackTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Text(vm.trackArtist)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                    Divider()
                        .background(Color.white.opacity(0.1))
                }

                if vm.lines.isEmpty {
                    // Scrollable: when there's no synced LRC we show the full plain lyrics
                    // here, which overflow a short window. Without the ScrollView the
                    // overflow was simply unreachable on the minimised window.
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(vm.statusMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    lyricsView
                }

                // Playback controls
                Divider().background(Color.white.opacity(0.1))
                HStack(spacing: 14) {
                    Spacer()
                    Button { SpotifyBridge.previousTrack() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(ControlButtonStyle(size: 13, idleOpacity: 0.55))

                    Button { SpotifyBridge.playPause() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(ControlButtonStyle(size: 17, idleOpacity: 0.95))

                    Button { SpotifyBridge.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(ControlButtonStyle(size: 13, idleOpacity: 0.55))
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var lyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.lines) { line in
                        if !line.text.isEmpty {
                            let isActive = line.id == vm.activeIndex
                            Text(line.text)
                                // Constant weight: animating bold↔medium crossfades two
                                // text bitmaps and flickers on fast lines. Emphasis comes
                                // from brightness + a subtle scale, which interpolate cleanly.
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(isActive ? 1 : 0.3))
                                .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .animation(.easeOut(duration: 0.2), value: isActive)
                                .contentShape(Rectangle())
                                .onTapGesture { vm.seek(to: line) }
                                .onHover { inside in
                                    if inside { NSCursor.pointingHand.push() }
                                    else { NSCursor.pop() }
                                }
                                .id(line.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 4)
            }
            .onChange(of: vm.activeIndex) { newIdx in
                guard newIdx > 2 else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newIdx - 2, anchor: .top)
                }
            }
        }
    }
}

/// Playback-control button: brightens, grows, and shows a circular highlight on
/// hover, presses inward on click, and swaps to a pointing-hand cursor.
private struct ControlButtonStyle: ButtonStyle {
    let size: CGFloat
    let idleOpacity: Double

    func makeBody(configuration: Configuration) -> some View {
        ControlButton(configuration: configuration, size: size, idleOpacity: idleOpacity)
    }

    private struct ControlButton: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let idleOpacity: Double
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : idleOpacity))
                .frame(width: size * 2.1, height: size * 2.1)
                .background(
                    Circle().fill(.white.opacity(pressed ? 0.22 : (hovering ? 0.1 : 0)))
                )
                .scaleEffect(pressed ? 0.85 : (hovering ? 1.13 : 1))
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hovering)
                .animation(.spring(response: 0.18, dampingFraction: 0.55), value: pressed)
                .contentShape(Circle())
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
        }
    }
}
