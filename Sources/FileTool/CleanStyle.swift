import SwiftUI
import AppKit

// Vzhled okna Úklid: barvy podle zvoleného barevného profilu (stejně jako hlavní okno).
// Tmavé profily = tmavá navigace a světlý text, světlé profily (Arctic Light, Sandstone) = světlá plocha
// a tmavý text. Úvodní panel a hlavní tlačítka používají přechod profilu, moduly mají plastické dlaždice
// s vlastním odstínem sladěným s profilem. Síla efektů podle stylu rozhraní (Výrazný / Jemný).

enum C {
    nonisolated(unsafe) static var module: CleanModule = .smart
    private static var t: Theme { ThemeStore.ui }
    static var dark: Bool { t.isDark }

    static var text: SwiftUI.Color { UI.text }
    static var text2: SwiftUI.Color { UI.textSecondary }
    static var text3: SwiftUI.Color { UI.textTertiary }
    static var card: SwiftUI.Color { dark ? .white.opacity(0.07) : .white.opacity(0.62) }
    static var cardStrong: SwiftUI.Color { dark ? .white.opacity(0.13) : .white.opacity(0.88) }
    static var border: SwiftUI.Color { dark ? .white.opacity(0.13) : .black.opacity(0.09) }
    static var hover: SwiftUI.Color { dark ? .white.opacity(0.10) : Modern.gradA.opacity(0.10) }
    static var selected: SwiftUI.Color { dark ? .white.opacity(0.15) : Modern.gradA.opacity(0.16) }
    static var rail: SwiftUI.Color {
        Modern.blend(t.sidebarBackground, Modern.brand.nav, Brand.vivid ? 0.85 : 0.4).opacity(dark ? 0.92 : 0.8)
    }
    static var clear: SwiftUI.Color { .clear }
    static var accent: SwiftUI.Color { UI.accent }

    static func hex(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }
}

extension CleanModule {
    /// Odstín dlaždice modulu (sladí se s profilem v TileIcon).
    var hue: String {
        switch self {
        case .smart:       return "#C34FD0"
        case .junk:        return "#2F9BEA"
        case .large:       return "#F08A2C"
        case .old:         return "#3AA6C9"
        case .uninstall:   return "#3E7CF2"
        case .performance: return "#EE6236"
        case .lens:        return "#2FB98A"
        case .dupes:       return "#8A5CF0"
        }
    }
    /// (horní, dolní barva pozadí okna, odstín modulu) – pozadí je stejné pro všechny moduly, podle profilu.
    var palette: (top: SwiftUI.Color, bottom: SwiftUI.Color, accent: SwiftUI.Color) {
        let t = ThemeStore.ui, b = Modern.brand, v = Brand.vivid
        if t.isDark {
            return (Modern.blend(b.nav, b.a, v ? 0.34 : 0.14), Modern.blend(t.appBackground, b.b, v ? 0.26 : 0.10), C.hex(hue))
        }
        return (Modern.blend(t.appBackground, b.a, v ? 0.14 : 0.06), Modern.blend(t.appBackground, b.b, v ? 0.20 : 0.08), C.hex(hue))
    }
    var gradient: LinearGradient {
        LinearGradient(colors: [palette.top, palette.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Tlačítko Úklidu: výrazné (přechod profilu), běžné (sklo) nebo pro mazání. Velikost beze změny.
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
            .background {
                if prominent {
                    Capsule().fill(Modern.accentGradient)
                        .shadow(color: Modern.gradB.opacity(Brand.vivid ? 0.45 : 0), radius: 6, y: 2)
                } else {
                    Capsule().fill(danger ? SwiftUI.Color.red.opacity(0.6) : C.cardStrong)
                }
            }
            .overlay(Capsule().stroke(prominent ? SwiftUI.Color.white.opacity(Brand.vivid ? 0.22 : 0) : C.border, lineWidth: 1))
            .foregroundStyle(prominent ? Modern.onGrad : danger ? SwiftUI.Color.white : C.text)
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
