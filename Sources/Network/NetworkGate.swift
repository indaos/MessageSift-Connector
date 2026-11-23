import Foundation

/// The one place the Connector reaches the network. Off by default: WhatsApp and Mac notifications need no network.
/// A host is contacted only after the person allowed it for a service in Services (stored per host).
enum NetworkGate {
    enum GateError: LocalizedError {
        case notAllowed(String)
        var errorDescription: String? {
            switch self {
            case .notAllowed(let host): return "Network is off for \(host). Allow it in Services."
            }
        }
    }

    private static let key = "allowedHosts"

    static var allowedHosts: Set<String> {
        Set(DataLocation.defaults.stringArray(forKey: key) ?? [])
    }

    static func allow(_ hosts: [String]) {
        DataLocation.defaults.set(Array(allowedHosts.union(hosts.map { $0.lowercased() })).sorted(), forKey: key)
    }

    static func revoke(_ hosts: [String]) {
        DataLocation.defaults.set(Array(allowedHosts.subtracting(hosts.map { $0.lowercased() })).sorted(), forKey: key)
    }

    static func isAllowed(_ hosts: [String]) -> Bool {
        !hosts.isEmpty && Set(hosts.map { $0.lowercased() }).isSubset(of: allowedHosts)
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    /// The hosts one service contacts (GitLab and Jira: the server or site typed in Services).
    static func hosts(for service: Service, server: String? = nil) -> [String] {
        switch service {
        case .slack: return ["slack.com"]
        case .github: return ["api.github.com"]
        case .linear: return ["api.linear.app"]
        case .microsoft: return ["login.microsoftonline.com", "graph.microsoft.com"]
        case .gitlab, .jira:
            let address = server ?? service.tool?.baseURL ?? ""
            return URL(string: address)?.host.map { [$0.lowercased()] } ?? []
        }
    }

    /// Sends one allowed request. Replaceable in tests, which never reach the network.
    nonisolated(unsafe) static var transport: (URLRequest) async throws -> (Data, URLResponse) = {
        try await Foundation.URLSession.shared.data(for: $0)
    }

    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, isAllowed(url) else { throw GateError.notAllowed(request.url?.host ?? "?") }
        return try await transport(request)
    }
}

/// Inside the Connector, `URLSession.shared` is this gate (the readers copied from MessageSift stay unchanged),
/// so no request can go out without passing `NetworkGate`.
enum URLSession {
    static let shared = GatedSession()
}

struct GatedSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await NetworkGate.send(request)
    }
}
