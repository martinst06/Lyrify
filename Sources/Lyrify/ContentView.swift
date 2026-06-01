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
                    Spacer()
                    Text(vm.statusMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                    Spacer()
                } else {
                    lyricsView
                }

                // Playback controls
                Divider().background(Color.white.opacity(0.1))
                HStack(spacing: 28) {
                    Spacer()
                    Button { DispatchQueue.global().async { SpotifyBridge.previousTrack() } } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Button { DispatchQueue.global().async { SpotifyBridge.playPause() } } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button { DispatchQueue.global().async { SpotifyBridge.nextTrack() } } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 10)
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
                                .font(.system(size: 15, weight: isActive ? .bold : .medium))
                                .foregroundStyle(
                                    isActive
                                        ? AnyShapeStyle(Color.white)
                                        : AnyShapeStyle(Color.white.opacity(0.3))
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .animation(.easeInOut(duration: 0.25), value: vm.activeIndex)
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
