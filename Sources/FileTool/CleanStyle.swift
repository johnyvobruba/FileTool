import SwiftUI
import AppKit

// Vzhled okna Úklid ve stylu CleanMyMac: každý modul má vlastní barevný přechod,
// obsah je na „skleněných“ kartách, text světlý (okno je vždy v tmavém režimu).

enum C {
    nonisolated(unsafe) static var module: CleanModule = .smart

    static var text: SwiftUI.Color { .white }
    static var text2: SwiftUI.Color { .white.opacity(0.74) }
    static var text3: SwiftUI.Color { .white.opacity(0.5) }
    static var card: SwiftUI.Color { .white.opacity(0.08) }
    static var cardStrong: SwiftUI.Color { .white.opacity(0.14) }
    static var border: SwiftUI.Color { .white.opacity(0.14) }
    static var hover: SwiftUI.Color { .white.opacity(0.12) }
    static var selected: SwiftUI.Color { .white.opacity(0.18) }
    static var rail: SwiftUI.Color { .black.opacity(0.22) }
    static var clear: SwiftUI.Color { .clear }
    static var accent: SwiftUI.Color { module.palette.accent }

    static func hex(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }
}

extension CleanModule {
    /// (horní, dolní barva přechodu, zvýraznění)
    var palette: (top: SwiftUI.Color, bottom: SwiftUI.Color, accent: SwiftUI.Color) {
        switch self {
        case .smart:       return (C.hex("#4A2675"), C.hex("#8E2F6C"), C.hex("#F06BC0"))
        case .junk:        return (C.hex("#173F27"), C.hex("#3C6B26"), C.hex("#9BE27A"))
        case .large:       return (C.hex("#143E4A"), C.hex("#246A6B"), C.hex("#6FE3D6"))
        case .old:         return (C.hex("#1E3550"), C.hex("#2E6178"), C.hex("#7CC8F2"))
        case .uninstall:   return (C.hex("#1B2E5E"), C.hex("#2F539A"), C.hex("#7FA7FF"))
        case .performance: return (C.hex("#5A220E"), C.hex("#A84A18"), C.hex("#FFB066"))
        case .lens:        return (C.hex("#2C1760"), C.hex("#6A2A86"), C.hex("#E07BFF"))
        case .dupes:       return (C.hex("#173B4D"), C.hex("#2C6E80"), C.hex("#74D8F0"))
        }
    }
    var gradient: LinearGradient {
        LinearGradient(colors: [palette.top, palette.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Tlačítko na barevném pozadí: průhledné (sklo), výrazné (bílé) nebo pro mazání.
struct GlassButton: ButtonStyle {
    var prominent = false
    var danger = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(prominent ? SwiftUI.Color.white : danger ? SwiftUI.Color.red.opacity(0.55) : C.cardStrong))
            .overlay(Capsule().stroke(prominent ? SwiftUI.Color.clear : C.border, lineWidth: 1))
            .foregroundStyle(prominent ? C.module.palette.top : SwiftUI.Color.white)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Skleněná karta (CMM): zaoblená, průsvitná, jemný okraj.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    let content: Content
    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) { self.padding = padding; self.content = content() }
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18).fill(C.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(C.border, lineWidth: 1))
    }
}

/// Průsvitné pozadí macOS (vibrancy) – pro jemně modernější hlavní okno.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
