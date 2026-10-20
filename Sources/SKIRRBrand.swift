import SwiftUI
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
                   let url = Bundle.main.url(forResource: "SKIRR_Logo_animated_v5", withExtension: "svg"),
                   let svg = try? String(contentsOf: url, encoding: .utf8) {
                    SKIRRLogoAnimation(svg: svg)
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

/// Share the chosen appearance between settings, onboarding, and the popover.
struct SKIRRTheme: ViewModifier {
    @AppStorage("skirr.appearance") private var appearance = "system"
    func body(content: Content) -> some View {
        content.tint(SKIRRBrand.accent).accentColor(SKIRRBrand.accent)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}
