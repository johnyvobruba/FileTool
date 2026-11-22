import AppKit

/// Ikona aplikace kreslená vektorově v barvách profilu: dva panely se seznamem souborů,
/// aktivní panel s pruhem v barvě zvýraznění (jako v Total Commanderu). Dock se přebarví podle profilu.
@MainActor
enum AppIcon {
    static func apply() {
        NSApp.applicationIconImage = FTSettings.shared.themedIcon ? render(ThemeStore.ui) : nil
    }

    static func writePNG(_ t: Theme, to path: String) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        render(t).draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    static func render(_ t: Theme) -> NSImage {
        func c(_ h: String) -> NSColor { .hex(h) }
        let accent = c(t.accentColor)
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { _ in
            guard let g = NSGraphicsContext.current?.cgContext else { return false }
            // podklad
            let base = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
            NSGraphicsContext.saveGraphicsState()
            g.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            c(t.appBackground).setFill(); base.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: c(t.sidebarBackground).blended(withFraction: 0.12, of: .white) ?? c(t.sidebarBackground),
                       ending: c(t.appBackground))?.draw(in: base, angle: 90)
            c(t.borderColor).withAlphaComponent(0.8).setStroke(); base.lineWidth = 3; base.stroke()

            // okno se dvěma panely
            let win = NSRect(x: 200, y: 250, width: 624, height: 520)
            let wp = NSBezierPath(roundedRect: win, xRadius: 40, yRadius: 40)
            c(t.background).setFill(); wp.fill()
            NSGraphicsContext.saveGraphicsState()
            wp.addClip()
            c(t.toolbarBackground).setFill(); NSRect(x: win.minX, y: win.minY, width: win.width, height: 84).fill()
            for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
                c(hex).setFill(); NSBezierPath(ovalIn: NSRect(x: 240 + CGFloat(i) * 56, y: 272, width: 36, height: 36)).fill()
            }
            // dělicí čára mezi panely
            c(t.borderColor).setFill(); NSRect(x: 510, y: win.minY + 84, width: 4, height: win.height - 84).fill()
            // pruh s cestou: levý panel aktivní (barva zvýraznění), pravý tlumený
            accent.setFill(); NSRect(x: win.minX, y: 334, width: 310, height: 40).fill()
            c(t.tabInactiveBackground).setFill(); NSRect(x: 514, y: 334, width: 310, height: 40).fill()
            // řádky souborů: složky modře, kurzor, označený soubor červeně
            let dir = c(t.ansiBright[4]), file = c(t.foreground), mark = c(t.ansiBright[1])
            for side in 0..<2 {
                let x0: CGFloat = side == 0 ? 236 : 550
                for r in 0..<6 {
                    let y = 404 + CGFloat(r) * 56
                    if side == 0 && r == 2 {
                        c(t.itemSelectedBackground).setFill()
                        NSRect(x: win.minX, y: y - 12, width: 310, height: 48).fill()
                    }
                    let color = r < 2 ? dir : (side == 1 && r == 4 ? mark : file)
                    color.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x0, y: y, width: 26, height: 22), xRadius: 4, yRadius: 4).fill()
                    let w: CGFloat = [190, 150, 210, 170, 200, 130][(r + side * 2) % 6]
                    NSBezierPath(roundedRect: NSRect(x: x0 + 42, y: y + 3, width: w, height: 16), xRadius: 8, yRadius: 8).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            c(t.textTertiary).withAlphaComponent(0.7).setStroke(); wp.lineWidth = 7; wp.stroke()
            return true
        }
    }
}
