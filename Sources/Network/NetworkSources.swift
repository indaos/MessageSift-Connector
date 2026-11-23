import Foundation

extension SharedMessage {
    /// A network item in the shared file's shape (the source names are MessageSift's).
    init?(_ m: HubMessage) {
        guard let source = Source(rawValue: m.source.rawValue) else { return nil }
        self.init(id: m.id, source: source, sender: m.sender, senderHandle: m.senderHandle, title: m.title, body: m.body, date: m.date,
                  isUnread: m.isUnread, isFlagged: m.isFlagged, isFromMe: m.isFromMe, isAnswered: m.isAnswered, isDirect: m.isDirect,
                  conversationID: m.conversationID, context: m.context, link: m.link, dueDate: m.dueDate,
                  slackTeam: m.slackTeam, slackChannel: m.slackChannel, slackTs: m.slackTs, slackThreadTs: m.slackThreadTs)
    }
}

/// Slack, GitHub, GitLab, Jira, Linear, Teams and Outlook, read with the keys saved in the Connector.
/// Read every 10 minutes and right after a key changes; the items go into the shared file with the others.
@MainActor
final class NetworkSources: ObservableObject {
    static let shared = NetworkSources()
    static let refreshEvery: TimeInterval = 10 * 60
    static let days = 14

    @Published private(set) var items: [HubMessage] = []
    @Published private(set) var errors: [MessageSource: String] = [:]
    @Published private(set) var lastRead: Date?
    @Published private(set) var reading = false

    /// Services with a key (or Microsoft sign-in) here and network allowed for their host.
    nonisolated static var configured: [MessageSource] {
        func allowed(_ s: Service) -> Bool { NetworkGate.isAllowed(NetworkGate.hosts(for: s)) }
        var out = DevTool.allCases.filter { $0.isConfigured && allowed(Service(rawValue: $0.rawValue)!) }.map(\.source)
        if !(Keychain.get("slack-token") ?? "").isEmpty, allowed(.slack) { out.append(.slack) }
        if MSGraph.isSignedIn, allowed(.microsoft) { out += [.teams, .outlook] }
        return out
    }

    var status: ConnectorStatus {
        ConnectorStatus(configured: Self.configured.map(\.rawValue).sorted(),
                        errors: Dictionary(uniqueKeysWithValues: errors.map { ($0.key.rawValue, $0.value) }))
    }

    /// Returns true when it read (so the shared file should be written again).
    @discardableResult
    func readIfDue(force: Bool = false) async -> Bool {
        guard !reading, !DataLocation.isRunningTests else { return false }
        if !force, let lastRead, Date().timeIntervalSince(lastRead) < Self.refreshEvery { return false }
        let configured = Self.configured
        guard !configured.isEmpty else {
            let changed = !items.isEmpty || !errors.isEmpty
            items = []; errors = [:]
            return changed
        }
        reading = true
        defer { reading = false }
        let since = Date().addingTimeInterval(-Double(Self.days) * 86_400)
        var all: [HubMessage] = []
        var errs: [MessageSource: String] = [:]
        for tool in DevTool.allCases where configured.contains(tool.source) {
            do { all += try await DevToolsClient(tool: tool).fetch(since: since) } catch { errs[tool.source] = error.localizedDescription }
        }
        if configured.contains(.slack), let token = Keychain.get("slack-token") {
            do { all += try await SlackSource(token: token).fetch(since: since) } catch { errs[.slack] = error.localizedDescription }
        }
        if configured.contains(.teams) {
            let client = MSGraphClient()
            do {
                let me = try await client.me()
                do { all += try await client.teams(since: since, me: me) } catch { errs[.teams] = error.localizedDescription }
                do { all += try await client.outlook(since: since, knownMessageIDs: []) } catch { errs[.outlook] = error.localizedDescription }
            } catch {
                errs[.teams] = error.localizedDescription
                errs[.outlook] = error.localizedDescription
            }
        }
        items = all
        errors = errs
        lastRead = Date()
        return true
    }
}
