import AppKit
import CoreServices
import Foundation
import ServiceManagement

/// Reads, shares and reports. No network, no AI: it only copies recent items into MessageSift's App Group folder.
@MainActor
final class Connector: ObservableObject {
    static let shared = Connector()
    static let days = 30

    @Published private(set) var hasAccess = Sources.hasFullDiskAccess
    /// Access arrived while running: offer a restart (the file watchers start fresh).
    @Published private(set) var accessArrived = false
    @Published private(set) var counts: [SharedMessage.Source: Int] = [:]
    @Published private(set) var lastShared: Date?
    @Published private(set) var problem: String?
    @Published private(set) var notifyingApps: [(app: String, count: Int)] = []
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused"); if !paused { share() } } }
    @Published var otherApps: Set<String> { didSet { defaults.set(Array(otherApps), forKey: "otherApps"); share() } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var accessTimer: Timer?
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init() {
        paused = defaults.bool(forKey: "paused")
        otherApps = Set(defaults.stringArray(forKey: "otherApps") ?? NotificationParser.defaultApps)
    }

    /// Unit tests run inside this app; they must never read real data or write the shared file.
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    func start() {
        guard timer == nil, !Self.isRunningTests else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in Task { @MainActor in Connector.shared.tick() } }
        watch()
        tick()
        // Without Full Disk Access: check every 2 seconds, and share at once when it arrives.
        accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let c = Connector.shared
                if Sources.hasFullDiskAccess && !c.hasAccess { c.tick() }
            }
        }
    }

    /// Every 3 minutes and after a database change: check access, then share.
    func tick() {
        let now = Sources.hasFullDiskAccess
        if now && !hasAccess { accessArrived = true }
        hasAccess = now
        if hasAccess { notifyingApps = Sources.notifyingApps() }
        share()
    }

    func share() {
        guard hasAccess, !paused else { return }
        guard let folder = SharedFile.folder else { problem = "MessageSift's shared folder is not available."; return }
        let since = Date().addingTimeInterval(-Double(Self.days) * 86_400)
        let apps = otherApps
        Task.detached(priority: .utility) {
            var items: [SharedMessage] = []
            let rows = Sources.whatsAppRows(since: since)
            if let rows { items += WhatsAppParser.messages(rows, me: Sources.whatsAppIdentity()) }
            let names = Dictionary(uniqueKeysWithValues: apps.map { ($0, Connector.appName($0)) })
            items += Sources.notificationRecords(since: since).compactMap { r -> SharedMessage? in
                guard let m = NotificationParser.message(r, otherApps: apps, appName: { names[$0] ?? $0 }) else { return nil }
                // The WhatsApp store is complete; its notifications would only repeat it.
                return rows != nil && m.source == .whatsapp ? nil : m
            }
            let result = Result { try SharedFile.write(items, to: folder) }
            let counts = Dictionary(grouping: items, by: \.source).mapValues(\.count)
            await MainActor.run {
                switch result {
                case .success: self.counts = counts; self.lastShared = Date(); self.problem = nil
                case .failure(let e): self.problem = "Can't write to MessageSift's shared folder: \(e.localizedDescription)"
                }
            }
        }
    }

    func deleteSharedData() {
        paused = true
        guard let folder = SharedFile.folder else { return }
        do { try SharedFile.delete(in: folder); counts = [:]; lastShared = nil } catch { problem = error.localizedDescription }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { problem = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    nonisolated static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    nonisolated static func statusReport() -> String {
        var lines = ["fullDiskAccess: \(Sources.hasFullDiskAccess)", "whatsAppStore: \(Sources.probe(Sources.whatsAppStore))"]
        guard let folder = SharedFile.folder else { return (lines + ["sharedFolder: unavailable"]).joined(separator: "\n") }
        let url = folder.appendingPathComponent(SharedFile.fileName)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lines.append("sharedFile: \(modified.map { "written \(ISO8601DateFormatter().string(from: $0))" } ?? "none")")
        struct Item: Decodable { let source: String; let date: String }
        if let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([Item].self, from: data) {
            for (source, list) in Dictionary(grouping: items, by: \.source).sorted(by: { $0.key < $1.key }) {
                let dates = list.map(\.date).sorted()
                lines.append("  \(source): \(list.count) (\(dates.first ?? "") … \(dates.last ?? ""))")
            }
        }
        lines.append("paused: \(UserDefaults.standard.bool(forKey: "paused"))")
        return lines.joined(separator: "\n")
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    static func openFullDiskAccessPane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: Watching (FSEvents on the two folders; a change shares again after 5 seconds)

    private func watch() {
        let paths = (Sources.notificationDatabases.map { $0.deletingLastPathComponent() } + [Sources.whatsAppFolder]).map(\.path)
        var context = FSEventStreamContext()
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in Task { @MainActor in Connector.shared.changed() } }
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          2, UInt32(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in Connector.shared.share() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
