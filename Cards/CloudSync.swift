import Foundation
import Observation

/// Houdt je collectie, watchlist, binders en prijsgeschiedenis gelijk tussen je apparaten via je iCloud Drive-container.
/// Elk bestand wordt lokaal bijgehouden en gespiegeld naar iCloud; bij een conflict (beide kanten gewijzigd)
/// worden de versies samengevoegd in plaats van overschreven.
@MainActor
@Observable
final class CloudSync {
    enum Status: Equatable {
        case off, unavailable, syncing, upToDate(Date), failed(String)
    }

    static let shared = CloudSync()
    nonisolated static let containerID = "iCloud.nl.michelvanderput.cards"
    static let files = ["collection.json", "watchlist.json", "binders.json", "history.json"]

    private(set) var status: Status = .off
    /// Wordt aangeroepen als een bestand door een ander apparaat is bijgewerkt; de stores laden dan opnieuw.
    var onRemoteChange: ((String) -> Void)?

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "iCloudSync")
            Task { isEnabled ? await start() : stop() }
        }
    }

    private let localDir = URL.applicationSupportDirectory.appending(path: "Cards", directoryHint: .isDirectory)
    private var remoteDir: URL?
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var debounce: [String: Task<Void, Never>] = [:]
    private var running = false

    init() { isEnabled = UserDefaults.standard.object(forKey: "iCloudSync") as? Bool ?? true }

    func start() async {
        guard isEnabled else { status = .off; return }
        guard !running else { return }
        running = true
        status = .syncing
        let dir = await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID)?
                .appending(path: "Documents", directoryHint: .isDirectory)
        }.value
        guard let dir else { status = .unavailable; running = false; return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        remoteDir = dir
        await syncAll()
        startQuery()
    }

    func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        running = false
        status = .off
    }

    func syncAll() async {
        guard remoteDir != nil else { return }
        status = .syncing
        for f in Self.files { await sync(f) }
        if case .syncing = status { status = .upToDate(Date()) }
    }

    /// Een store heeft lokaal iets opgeslagen: even wachten en dan synchroniseren.
    func localChanged(_ file: String) {
        guard isEnabled, remoteDir != nil else { return }
        debounce[file]?.cancel()
        debounce[file] = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await sync(file) }
        }
    }

    // MARK: - Eén bestand afstemmen

    private func sync(_ file: String) async {
        guard let remoteDir else { return }
        let local = localDir.appending(path: file)
        let remote = remoteDir.appending(path: file)
        let key = "cloud.\(file)"
        let lastLocal = UserDefaults.standard.double(forKey: key + ".local")
        let lastRemote = UserDefaults.standard.double(forKey: key + ".remote")

        let outcome: Result<(Action, Data?), Error> = await Task.detached {
            do {
                let fm = FileManager.default
                let localDate = (try? local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970
                let remoteExists = Self.coordinatedExists(remote)
                let remoteDate = remoteExists ? (try? remote.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 : nil
                let action = SyncMerge.decide(
                    localExists: fm.fileExists(atPath: local.path), remoteExists: remoteExists,
                    localChanged: localDate.map { abs($0 - lastLocal) > 0.5 } ?? false,
                    remoteChanged: remoteDate.map { abs($0 - lastRemote) > 0.5 } ?? false)
                switch action {
                case .none: return .success((.none, nil))
                case .push:
                    let data = try Data(contentsOf: local)
                    try Self.coordinatedWrite(data, to: remote)
                    return .success((.push, nil))
                case .pull:
                    let data = try Self.coordinatedRead(remote)
                    try data.write(to: local, options: .atomic)
                    return .success((.pull, data))
                case .merge:
                    let l = try Data(contentsOf: local), r = try Self.coordinatedRead(remote)
                    guard let merged = SyncMerge.merge(file: file, local: l, remote: r) else { return .success((.pull, r)) }
                    try merged.write(to: local, options: .atomic)
                    try Self.coordinatedWrite(merged, to: remote)
                    return .success((.merge, merged))
                }
            } catch { return .failure(error) }
        }.value

        switch outcome {
        case .failure(let error):
            status = .failed(error.localizedDescription)
        case .success(let (action, _)):
            guard action != .none else { return }
            // Onthoud de datums na afstemmen, zodat we onze eigen wijziging niet opnieuw oppakken.
            let ld = (try? local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            let rd = (try? remote.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            UserDefaults.standard.set(ld, forKey: key + ".local")
            UserDefaults.standard.set(rd, forKey: key + ".remote")
            if action == .pull || action == .merge { onRemoteChange?(file) }
            status = .upToDate(Date())
        }
    }

    private typealias Action = SyncMerge.Action

    // MARK: - Wijzigingen van andere apparaten

    private func startQuery() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.syncAll() }
            })
        }
        q.start()
        query = q
    }

    // MARK: - Gecoördineerd bestandsgebruik (nodig voor iCloud)

    nonisolated private static func coordinatedExists(_ url: URL) -> Bool {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return FileManager.default.fileExists(atPath: url.path)
            || ((try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus != nil)
    }

    nonisolated private static func coordinatedRead(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    nonisolated private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            result = Result { try data.write(to: writeURL, options: .atomic) }
        }
        if let coordError { throw coordError }
        try result.get()
    }
}
