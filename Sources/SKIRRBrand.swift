import SwiftUI
import AVFoundation
import AppKit

enum SKIRRBrand {
    static let navy = Color(red: 11/255, green: 44/255, blue: 103/255)
    static let secondary = Color(red: 131/255, green: 145/255, blue: 174/255)
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(red: 111/255, green: 163/255, blue: 230/255, alpha: 1)
                    : NSColor(red: 47/255, green: 106/255, blue: 173/255, alpha: 1)
    })
}

struct SKIRRHeader: View {
    let animate: Bool
    let version: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Image("SKIRRLogo").resizable().scaledToFit()
                if animate && !reduceMotion && !isSnapshot,
                   let url = Bundle.main.url(forResource: "SKIRR_LogoAnimation_v4", withExtension: "mp4") {
                    SKIRRLogoPlayer(url: url)
                }
            }
            .frame(width: 112, height: 112).clipShape(.circle)
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                Text("OKM").foregroundStyle(.primary)
                Text("SKÍRR").foregroundStyle(SKIRRBrand.secondary)
            }.font(.system(size: 25, weight: .semibold)).tracking(4)
                .accessibilityElement(children: .ignore).accessibilityLabel("OKM SKÍRR")
            Text("版本 \(version)").font(.callout).foregroundStyle(.secondary)
            Text("Copyright © 2026 OKMaster Inc.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 22))
    }
}

/// A local, muted, one-shot logo. The last video frame remains visible until the window closes.
struct SKIRRLogoPlayer: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> LogoVideoView { LogoVideoView(url: url) }
    func updateNSView(_ nsView: LogoVideoView, context: Context) {}
    static func dismantleNSView(_ nsView: LogoVideoView, coordinator: ()) { nsView.stop() }
}

final class LogoVideoView: NSView {
    private let player: AVPlayer
    private let videoLayer = AVPlayerLayer()
    private var started = false
    init(url: URL) {
        player = AVPlayer(url: url)
        super.init(frame: .zero)
        wantsLayer = true
        player.isMuted = true
        player.actionAtItemEnd = .pause
        videoLayer.player = player
        videoLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); videoLayer.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                                  name: NSWindow.willCloseNotification, object: window)
        }
        if window != nil && !started { started = true; player.play() }
        else if window == nil { player.pause() }
    }
    @objc private func windowWillClose() { player.pause() }
    func stop() { NotificationCenter.default.removeObserver(self); player.pause(); videoLayer.player = nil; player.replaceCurrentItem(with: nil) }
}

/// Share the chosen appearance between settings, onboarding, and the popover.
struct SKIRRTheme: ViewModifier {
    @AppStorage("skirr.appearance") private var appearance = "system"
    func body(content: Content) -> some View {
        content.tint(SKIRRBrand.accent).accentColor(SKIRRBrand.accent)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}
