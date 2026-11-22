import SwiftUI
import AppKit

/// Centrální stav motivu (stejné barevné profily jako SSHTool). Nastavuje FTSettings.applyTheme().
enum ThemeStore {
    nonisolated(unsafe) static var ui: Theme = .midnight
    static let changed = Notification.Name("FileToolThemeChanged")

    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    /// appearance: "dark" | "light" | "system"
    static func resolve(themeID: String, appearance: String) -> Theme {
        let chosen = Theme.byID(themeID)
        let dark = chosen.isDark ? chosen : .midnight
        switch appearance {
        case "light": return chosen.isDark ? .arctic : chosen
        case "system": return systemIsDark ? dark : (chosen.isDark ? .arctic : chosen)
        default: return chosen.isDark ? chosen : dark
        }
    }
}

struct RGBColor {
    let r, g, b: UInt8
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = UInt8(v >> 16 & 0xFF); g = UInt8(v >> 8 & 0xFF); b = UInt8(v & 0xFF)
    }
}

extension Color {
    init?(hex: String) {
        guard let c = RGBColor(hex: hex) else { return nil }
        self.init(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

extension NSColor {
    static func hex(_ h: String) -> NSColor {
        guard let c = RGBColor(hex: h) else { return .gray }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}

/// Barvy rozhraní podle aktivního profilu (stejné role jako v SSHTool).
enum UI {
    static func hex(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }
    private static var t: Theme { ThemeStore.ui }

    static var app: SwiftUI.Color           { hex(t.appBackground) }
    static var list: SwiftUI.Color          { hex(t.background) }          // seznam souborů = „terminálová“ plocha
    static var sidebar: SwiftUI.Color       { hex(t.sidebarBackground) }
    static var chrome: SwiftUI.Color        { hex(t.toolbarBackground) }
    static var card: SwiftUI.Color          { hex(t.tabInactiveBackground) }
    static var cardSelected: SwiftUI.Color  { hex(t.tabActiveBackground) }
    static var hover: SwiftUI.Color         { hex(t.itemHoverBackground) }
    static var rowSelected: SwiftUI.Color   { hex(t.itemSelectedBackground) }
    static var border: SwiftUI.Color        { hex(t.borderColor) }
    static var text: SwiftUI.Color          { hex(t.textPrimary) }
    static var textSecondary: SwiftUI.Color { hex(t.textSecondary) }
    static var textTertiary: SwiftUI.Color  { hex(t.textTertiary) }
    static var accent: SwiftUI.Color        { hex(t.accentColor) }
    static var ok: SwiftUI.Color            { hex(t.statusConnected) }
    static var warn: SwiftUI.Color          { hex(t.statusConnecting) }
    static var error: SwiftUI.Color         { hex(t.statusError) }

    // AppKit varianty pro tabulku souborů
    enum NS {
        private static var t: Theme { ThemeStore.ui }
        static var list: NSColor        { .hex(t.background) }
        static var text: NSColor        { .hex(t.foreground) }
        static var textDim: NSColor     { .hex(t.textSecondary) }
        static var dir: NSColor         { .hex(t.ansiBright[4]) }           // složky (modrá z palety)
        static var marked: NSColor      { .hex(t.ansiBright[1]) }           // označené (červená jako v TC)
        static var cursor: NSColor      { .hex(t.itemSelectedBackground) }
        static var cursorInactive: NSColor { .hex(t.itemHoverBackground) }
        static var accent: NSColor      { .hex(t.accentColor) }
        static var header: NSColor      { .hex(t.toolbarBackground) }
        static var grid: NSColor        { .hex(t.borderColor) }
        static var hidden: NSColor      { .hex(t.textTertiary) }
        static var exec: NSColor        { .hex(t.ansiBright[2]) }           // spustitelné (zelená)
        static var archive: NSColor     { .hex(t.ansiBright[5]) }           // archivy (fialová)
    }
}

/// Malé tlačítko v liště (ikona, aktivní stav).
struct ChromeIcon: View {
    let symbol: String
    var active = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .frame(width: 24, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? UI.cardSelected : SwiftUI.Color.clear))
            .foregroundStyle(active ? UI.text : UI.textSecondary)
            .contentShape(Rectangle())
    }
}

/// Hover bez @State (SDK z Command Line Tools nemá SwiftUI makra).
final class HoverModel: ObservableObject { @Published var on = false }
