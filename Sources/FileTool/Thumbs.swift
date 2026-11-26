import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Zobrazení „Náhledy“ (velké ikony / náhledy obrázků) místo seznamu. Klávesnici dál obsluhuje
// skrytá tabulka panelu (F-klávesy, mezerník, Enter…); šipky v mřížce posouvají po řádcích/sloupcích.

enum ThumbSupport {
    /// Složka jen s obrázky (podsložky nevadí) → automaticky náhledy.
    static func onlyImages(_ items: [FileItem]) -> Bool {
        let files = items.filter { !$0.isParent && !$0.isDir }
        guard !files.isEmpty else { return false }
        return files.allSatisfy { isImage($0) }
    }
    static func isImage(_ i: FileItem) -> Bool {
        guard !i.isDir, let t = UTType(filenameExtension: i.ext.lowercased()) else { return false }
        return t.conforms(to: .image)
    }
}

/// Mezipaměť náhledů (Quick Look).
@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 2000 }
    func get(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func set(_ key: String, _ img: NSImage) { cache.setObject(img, forKey: key as NSString) }
}

@MainActor
final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?

    func load(_ item: FileItem, size: CGFloat) async {
        let px = size <= 96 ? 128 : size <= 160 ? 256 : 512                 // pár velikostí = lepší využití mezipaměti
        let key = item.url.path + "#\(px)#\(item.modified.timeIntervalSince1970)"
        if let c = ThumbCache.shared.get(key) { image = c; return }
        // v archivu / na serveru soubor na disku není → ikona podle typu
        if item.archiveInner != nil || item.remotePath != nil || item.isParent {
            image = item.isDir || item.isParent ? NSWorkspace.shared.icon(for: .folder)
                : NSWorkspace.shared.icon(for: UTType(filenameExtension: item.ext) ?? .data)
            return
        }
        image = NSWorkspace.shared.icon(forFile: item.url.path)              // hned ikona, pak náhled
        guard !item.isDir || item.isPackage else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: px, height: px),
                                               scale: scale, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            ThumbCache.shared.set(key, rep.nsImage)
            image = rep.nsImage
        }
    }
}

struct ThumbCell: View {
    let item: FileItem
    let size: CGFloat
    let marked: Bool
    let cursor: Bool
    let active: Bool
    @StateObject private var loader = ThumbLoader()

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let img = loader.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(ThumbSupport.isImage(item) ? 0.35 : 0), radius: 3, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: size, height: size)
            Text(item.isParent ? ".." : item.name)
                .font(.system(size: 11, weight: marked ? .semibold : .regular))
                .foregroundStyle(marked ? Color(nsColor: UI.NS.marked) : item.isDir || item.isParent ? Color(nsColor: UI.NS.dir) : UI.listText)
                .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .help(item.isParent ? "" : item.name)
                .frame(width: size, height: 28, alignment: .top)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(cursor ? Color(nsColor: active ? UI.NS.cursor : UI.NS.cursorInactive) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(marked ? Color(nsColor: UI.NS.marked) : cursor && active ? UI.accent : Color.clear,
                                                         lineWidth: marked ? 2 : 1.5))
        .contentShape(Rectangle())
        .task(id: item.url.path + "\(Int(size))") { await loader.load(item, size: size) }
    }
}

struct ThumbGrid: View {
    @ObservedObject var tab: PanelTab
    let side: Side
    @ObservedObject var commander: Commander
    @ObservedObject var settings: FTSettings

    private let spacing: CGFloat = 10

    var body: some View {
        let size = CGFloat(settings.thumbSize)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(UI.textTertiary)
                Slider(value: $settings.thumbSize, in: 64...320).controlSize(.mini).frame(width: 140)
                    .tip("Velikost náhledů")
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(UI.textTertiary)
                Spacer()
                Button { tab.thumbOverride = false; commander.focus(side) } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.plain).foregroundStyle(UI.textSecondary).tip("Zpět na seznam (⌥⌘T)")
            }
            .padding(.horizontal, 10).frame(height: 24).background(UI.chrome)
            GeometryReader { g in
                let cols = max(1, Int((g.size.width - 16 + spacing) / (size + 12 + spacing)))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(size + 12), spacing: spacing), count: cols),
                                  alignment: .leading, spacing: spacing) {
                            ForEach(Array(tab.items.enumerated()), id: \.element.id) { i, item in
                                ThumbCell(item: item, size: size, marked: tab.marked.contains(item.url),
                                          cursor: i == tab.cursor, active: commander.activeSide == side)
                                    .id(i)
                                    .onTapGesture(count: 2) { tab.cursor = i; commander.focus(side); tab.open(item) }
                                    .onTapGesture {
                                        tab.cursor = i
                                        if NSEvent.modifierFlags.contains(.command) { tab.toggleMark(i) }
                                        commander.focus(side)
                                    }
                                    .onDrag {
                                        guard item.archiveInner == nil, item.remotePath == nil, !item.isParent else { return NSItemProvider() }
                                        return NSItemProvider(object: item.url as NSURL)
                                    }
                                    .contextMenu {
                                        Button("Otevřít") { tab.cursor = i; tab.open(item) }
                                        Button("Zobrazit (F3)") { tab.cursor = i; commander.focus(side); commander.view() }
                                        Button(tab.marked.contains(item.url) ? "Odznačit" : "Označit") { tab.toggleMark(i) }
                                        Divider()
                                        Button("Zobrazit ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                            .disabled(item.archiveInner != nil || item.remotePath != nil)
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: tab.cursor) { c in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(c) } }
                    .onAppear { tab.gridColumns = cols; proxy.scrollTo(tab.cursor) }
                    .onChange(of: cols) { tab.gridColumns = $0 }
                }
            }
            .background(UI.list)
        }
    }
}
