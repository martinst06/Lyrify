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
    @State private var plainScrollSpeed = 1.0
    @State private var showScrollSpeed = false

    /// Identity of the currently displayed song. When it changes, the content crossfades.
    private var songKey: String { vm.trackKey }
    private var hasPlainLyrics: Bool { vm.lines.isEmpty && !vm.plainLyricLines.isEmpty }

    var body: some View {
        ZStack {
            VisualEffectView().ignoresSafeArea()

            VStack(spacing: 0) {
                // Clear zone for the traffic light buttons
                Color.clear.frame(height: 14)

                // Per-song content — crossfades on each song change instead of snapping.
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
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

                        if !vm.lines.isEmpty {
                            lyricsView
                        } else if hasPlainLyrics {
                            // Unsynced lyrics: auto-scroll at an estimated pace (see PlainLyricsView).
                            PlainLyricsView(vm: vm, speed: plainScrollSpeed)
                        } else {
                            // Status text only ("Loading…", "Waiting…", "No lyrics found.").
                            ScrollView(.vertical, showsIndicators: false) {
                                Text(vm.statusMessage)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(24)
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .id(songKey)
                    .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.3), value: songKey)

                // Playback controls
                Divider().background(Color.white.opacity(0.1))
                HStack(spacing: 14) {
                    Spacer()
                    Button { SpotifyBridge.previousTrack() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(ControlButtonStyle(size: 13, idleOpacity: 0.55))

                    Button {
                        // Explicit play/pause so resume works even from Spotify's stopped state.
                        if vm.isPlaying { SpotifyBridge.pause() } else { SpotifyBridge.play() }
                    } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(ControlButtonStyle(size: 17, idleOpacity: 0.95))

                    Button { SpotifyBridge.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(ControlButtonStyle(size: 13, idleOpacity: 0.55))

                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    if hasPlainLyrics {
                        Button { showScrollSpeed.toggle() } label: {
                            Image(systemName: "speedometer")
                        }
                        .buttonStyle(ControlButtonStyle(size: 13, idleOpacity: 0.55))
                        .help("Plain lyrics scroll speed")
                        .padding(.trailing, 2)
                        .popover(isPresented: $showScrollSpeed, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Scroll speed: \(Int((plainScrollSpeed * 100).rounded()))%")
                                    .font(.system(size: 12, weight: .semibold))
                                Slider(value: $plainScrollSpeed, in: 0.75...1.25, step: 0.05)
                                    .accessibilityLabel("Plain lyrics scroll speed")
                                HStack {
                                    Text("Slower")
                                    Spacer()
                                    Text("Faster")
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(width: 220)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: songKey) { _ in
            plainScrollSpeed = 1
            showScrollSpeed = false
        }
        .onChange(of: hasPlainLyrics) { hasLyrics in
            if !hasLyrics { showScrollSpeed = false }
        }
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

/// Unsynced lyrics view. LRCLIB-plain and Genius text carry no timestamps, so instead of
/// staying static this drifts down at an estimated pace: `vm.plainProgress` (playback
/// fraction) maps onto the line count. The estimate is deliberately rough — no highlight,
/// no click-to-seek — but it keeps the words moving with the song. If you scroll by hand it
/// backs off for a few seconds so you can read ahead, then re-syncs.
private struct PlainLyricsView: View {
    @ObservedObject var vm: LyricsViewModel
    let speed: Double

    /// How long auto-scroll stays out of the way after a manual scroll.
    private static let manualPause: TimeInterval = 4

    @State private var lastOffset: CGFloat? = nil
    // Offset changes we cause ourselves (the programmatic scroll animation) must not be
    // mistaken for the user scrolling; ignore offset reports until this moment.
    @State private var programmaticUntil = Date.distantPast
    // Auto-scroll is suppressed until here after the user scrolls by hand.
    @State private var resumeAt = Date.distantPast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(vm.plainLyricLines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(idx)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: PlainScrollOffsetKey.self,
                            value: geo.frame(in: .named("plainScroll")).minY)
                    }
                )
            }
            .coordinateSpace(name: "plainScroll")
            .onPreferenceChange(PlainScrollOffsetKey.self) { offset in
                handleOffset(offset)
            }
            .onChange(of: vm.plainProgress) { _ in
                autoScroll(proxy, animated: true)
            }
            .onChange(of: speed) { _ in
                autoScroll(proxy, animated: true)
            }
            .onAppear {
                // A song already mid-play: jump to its estimated spot without animating.
                // Deferred so the scroll view has laid out its rows before we target one.
                DispatchQueue.main.async { autoScroll(proxy, animated: false) }
            }
        }
    }

    private func autoScroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard Date() >= resumeAt else { return }   // user is reading — leave the scroll alone
        let target = PlainScroll.targetLine(progress: vm.plainProgress,
                                            lineCount: vm.plainLyricLines.count, speed: speed)
        // Suppress the self-inflicted offset changes this scroll produces (window > animation).
        programmaticUntil = Date().addingTimeInterval(0.7)
        let anchor = UnitPoint(x: 0.5, y: 0.4)
        if animated {
            withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(target, anchor: anchor) }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }

    private func handleOffset(_ offset: CGFloat) {
        defer { lastOffset = offset }
        guard let last = lastOffset else { return }        // first sample: just record the baseline
        guard Date() >= programmaticUntil else { return }  // our own scroll, not the user's
        if abs(offset - last) > 1 {
            resumeAt = Date().addingTimeInterval(Self.manualPause)
        }
    }
}

/// Reports the plain-lyrics scroll offset (content top's y in the scroll coordinate space)
/// so `PlainLyricsView` can tell a manual scroll from its own programmatic one.
private struct PlainScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
