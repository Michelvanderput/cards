import SwiftUI
import CryptoKit
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platform image: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

/// Plaatjes-cache: geheugen (direct, zonder flikkeren) + schijf (blijft na herstarten, los van HTTP-cachekoppen).
actor ImageStore {
    static let shared = ImageStore()

    nonisolated(unsafe) private let memory: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 800
        return c
    }()
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]
    private var missing: Set<String> = []   // 404's, alleen deze sessie
    private let dir: URL

    init() {
        dir = URL.cachesDirectory.appending(path: "Images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Synchroon uit het geheugen, zodat een plaatje direct getoond wordt als het al geladen is.
    nonisolated func cached(_ url: URL) -> PlatformImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    func image(_ url: URL) async -> PlatformImage? {
        let key = url.absoluteString
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if missing.contains(key) { return nil }
        if let running = inflight[key] { return await running.value }

        let file = dir.appending(path: Self.fileName(key))
        let task = Task<PlatformImage?, Never> {
            if let data = try? Data(contentsOf: file), let img = PlatformImage(data: data) { return img }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200, let img = PlatformImage(data: data) else {
                return http.statusCode == 404 ? Self.notFound : nil
            }
            try? data.write(to: file, options: .atomic)
            return img
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result, result !== Self.notFound { memory.setObject(result, forKey: key as NSString) }
        else if result === Self.notFound { missing.insert(key) }
        return result === Self.notFound ? nil : result
    }

    /// Haalt plaatjes alvast op (6 tegelijk) en meldt de voortgang. Stopt als de taak geannuleerd wordt.
    func prefetch(_ urls: [URL], progress: @Sendable (Int) async -> Void) async {
        var done = 0
        var index = 0
        while index < urls.count, !Task.isCancelled {
            let batch = urls[index..<min(index + 6, urls.count)]
            await withTaskGroup(of: Void.self) { group in
                for url in batch { group.addTask { _ = await self.image(url) } }
            }
            index += batch.count
            done += batch.count
            await progress(done)
        }
    }

    func diskBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        memory.removeAllObjects()
        missing.removeAll()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Houdt de schijfcache onder een maximum door de oudste bestanden te verwijderen.
    func prune(maxBytes: Int64 = 800 << 20) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
            .compactMap { url -> (URL, Int64, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
            }
        var total = files.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        files.sort { $0.2 < $1.2 }
        for f in files where total > maxBytes * 3 / 4 {
            try? FileManager.default.removeItem(at: f.0)
            total -= f.1
        }
    }

    private static let notFound = PlatformImage()

    private static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Afbeelding uit de cache, met placeholder tijdens het laden en bij fouten.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder
    @State private var image: PlatformImage?
    @State private var failed = false

    init(url: URL?, @ViewBuilder placeholder: @escaping (_ failed: Bool) -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImageStore.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let image { Image(platform: image).resizable().scaledToFit() }
            else { placeholder(failed || url == nil) }
        }
        .task(id: url) {
            guard let url else { return }
            if let hit = ImageStore.shared.cached(url) { image = hit; return }
            failed = false
            image = await ImageStore.shared.image(url)
            failed = image == nil
        }
    }
}
