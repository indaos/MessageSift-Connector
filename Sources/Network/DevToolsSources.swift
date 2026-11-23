import Foundation

/// GitHub, GitLab, Jira and Linear: review requests, assigned work and mentions, with tokens in the Keychain.
/// Handled items (closed, merged, done, todo marked done) simply stop coming back from the APIs.
enum DevTool: String, CaseIterable {
    case github, gitlab, jira, linear

    var source: MessageSource {
        switch self {
        case .github: return .github
        case .gitlab: return .gitlab
        case .jira: return .jira
        case .linear: return .linear
        }
    }

    var tokenKey: String { "\(rawValue)-token" }
    var token: String? { Keychain.get(tokenKey).flatMap { $0.isEmpty ? nil : $0 } }

    /// GitLab instance URL (default gitlab.com) or Jira site URL.
    var baseURL: String {
        get {
            let saved = DataLocation.defaults.string(forKey: "\(rawValue)-url") ?? ""
            if !saved.isEmpty { return saved.hasSuffix("/") ? String(saved.dropLast()) : saved }
            return self == .gitlab ? "https://gitlab.com" : ""
        }
        nonmutating set { DataLocation.defaults.set(newValue, forKey: "\(rawValue)-url") }
    }

    /// Jira account email (basic auth with an API token).
    var email: String {
        get { DataLocation.defaults.string(forKey: "\(rawValue)-email") ?? "" }
        nonmutating set { DataLocation.defaults.set(newValue, forKey: "\(rawValue)-email") }
    }

    /// Event types that count (Settings › Sources); all on by default.
    var enabledEvents: Set<WorkEventType> {
        get {
            guard let saved = DataLocation.defaults.stringArray(forKey: "\(rawValue)-events") else { return Set(WorkEventType.types(for: self)) }
            return Set(saved.compactMap(WorkEventType.init(rawValue:)))
        }
        nonmutating set { DataLocation.defaults.set(newValue.map(\.rawValue), forKey: "\(rawValue)-events") }
    }

    var isConfigured: Bool {
        guard token != nil else { return false }
        if self == .jira { return !baseURL.isEmpty && !email.isEmpty }
        return true
    }

    var tokenHelp: (text: String, url: String) {
        switch self {
        case .github: return ("Personal access token (classic: repo, notifications; or fine-grained with read access to issues, pull requests and notifications).",
                              "https://github.com/settings/tokens")
        case .gitlab: return ("Personal access token with the read_api scope.", "https://gitlab.com/-/user_settings/personal_access_tokens")
        case .jira: return ("API token for your Atlassian account, plus your site URL and email.",
                            "https://id.atlassian.com/manage-profile/security/api-tokens")
        case .linear: return ("Personal API key (Settings › Account › Security & access).", "https://linear.app/settings/account/security")
        }
    }
}

struct DevToolsClient {
    enum DevError: LocalizedError {
        case notConfigured, http(Int), unexpected
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Needs sign-in"
            case .http(let code): return code == 401 || code == 403 ? "Token rejected (HTTP \(code))" : "HTTP \(code)"
            case .unexpected: return "Unexpected response"
            }
        }
    }

    let tool: DevTool

    // MARK: Requests

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.httpBody = body
        let token = tool.token ?? ""
        switch tool {
        case .github:
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        case .gitlab:
            if OAuth.isOAuthToken(.gitlab) { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            else { r.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN") }
        case .jira:
            let basic = Data("\(tool.email):\(token)".utf8).base64EncodedString()
            r.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
        case .linear:
            r.setValue(OAuth.isOAuthToken(.linear) ? "Bearer \(token)" : token, forHTTPHeaderField: "Authorization")
        }
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func get(_ url: String, method: String = "GET", body: Data? = nil) async throws -> Any {
        guard let u = URL(string: url) else { throw DevError.unexpected }
        let (data, response) = try await URLSession.shared.data(for: request(u, method: method, body: body))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw DevError.http(http.statusCode) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// "Connected as …" for the Test connection button.
    func test() async throws -> String {
        guard tool.isConfigured else { throw DevError.notConfigured }
        switch tool {
        case .github:
            let me = try await get("https://api.github.com/user") as? [String: Any]
            return "Connected as \(me?["login"] as? String ?? "?")"
        case .gitlab:
            let me = try await get("\(tool.baseURL)/api/v4/user") as? [String: Any]
            return "Connected as \(me?["username"] as? String ?? "?")"
        case .jira:
            let me = try await get("\(tool.baseURL)/rest/api/3/myself") as? [String: Any]
            return "Connected as \(me?["displayName"] as? String ?? "?")"
        case .linear:
            let body = try JSONSerialization.data(withJSONObject: ["query": "{ viewer { name } }"])
            let r = try await get("https://api.linear.app/graphql", method: "POST", body: body) as? [String: Any]
            let name = ((r?["data"] as? [String: Any])?["viewer"] as? [String: Any])?["name"] as? String
            return "Connected as \(name ?? "?")"
        }
    }

    /// The items that need the user: events through the rules, then as messages for the AI judge.
    func fetch(since: Date) async throws -> [HubMessage] {
        let enabled = tool.enabledEvents
        return try await events(since: since).filter { WorkRules.dropReason($0, enabled: enabled) == nil }.map(WorkRules.message)
    }

    /// Every event the APIs return (deduplicated), before the rules.
    func events(since: Date) async throws -> [WorkEvent] {
        guard tool.isConfigured else { throw DevError.notConfigured }
        if tool == .gitlab { await OAuth.refreshIfNeeded(.gitlab) }
        if tool == .linear { await OAuth.refreshIfNeeded(.linear) }
        switch tool {
        case .github:
            let me = (try await get("https://api.github.com/user") as? [String: Any])?["login"] as? String ?? ""
            let review = try await get("https://api.github.com/search/issues?q=\(q("is:open is:pr user-review-requested:@me"))&per_page=50")
            let assigned = try await get("https://api.github.com/search/issues?q=\(q("is:open assignee:@me"))&per_page=50")
            let failing = (try? await get("https://api.github.com/search/issues?q=\(q("is:open is:pr author:@me status:failure"))&per_page=30")) ?? [:]
            var notifications = Self.parseGitHubNotifications((try? await get("https://api.github.com/notifications?participating=true&since=\(iso(since))")) ?? [], me: me)
            // Mentions: the comment and whether the item is still open (at most 10 lookups).
            for i in notifications.indices.prefix(10) {
                if notifications[i].note.isEmpty, let api = notifications[i].commentAPI,
                   let comment = try? await get(api) as? [String: Any] {
                    notifications[i].note = comment["body"] as? String ?? ""
                    let user = comment["user"] as? [String: Any]
                    notifications[i].actor = user?["login"] as? String ?? notifications[i].actor
                    notifications[i].actorIsBot = Self.githubIsBot(user)
                    notifications[i].actorIsMe = notifications[i].actor == me
                }
                if let api = notifications[i].api, let subject = try? await get(api) as? [String: Any] {
                    notifications[i].targetOpen = (subject["state"] as? String ?? "open") == "open"
                    notifications[i].targetAuthorIsMe = ((subject["user"] as? [String: Any])?["login"] as? String) == me
                }
            }
            return WorkRules.dedupe(Self.parseGitHubSearch(review, kind: .review, me: me)
                + Self.parseGitHubSearch(failing, kind: .pipeline, me: me)
                + notifications
                + Self.parseGitHubSearch(assigned, kind: .assigned, me: me))
        case .gitlab:
            let base = tool.baseURL
            let user = try await get("\(base)/api/v4/user") as? [String: Any]
            let myID = user?["id"] as? Int ?? -1
            let username = user?["username"] as? String ?? ""
            let todos = try await get("\(base)/api/v4/todos?state=pending&per_page=100")
            let reviews = (try? await get("\(base)/api/v4/merge_requests?state=opened&scope=all&reviewer_username=\(q(username))&per_page=50")) ?? []
            let assigned = (try? await get("\(base)/api/v4/issues?state=opened&scope=assigned_to_me&per_page=100")) ?? []
            var events = WorkRules.dedupe(Self.parseGitLabTodos(todos, myID: myID)
                + Self.parseGitLabMRs(reviews, myID: myID)
                + Self.parseGitLabIssues(assigned, myID: myID))
            // Approved already? One lookup per open MR waiting for a review or approval (at most 20).
            var approvals: [String: Bool] = [:]
            for i in events.indices where (events[i].kind == .review || events[i].kind == .approval) && events[i].targetOpen {
                guard let api = Self.gitlabApprovalsPath(events[i].url, base: base) else { continue }
                if approvals[api] == nil, approvals.count < 20 {
                    let json = (try? await get(api)) as? [String: Any]
                    approvals[api] = Self.approvedBy(json, myID: myID)
                }
                events[i].approvedByMe = approvals[api] ?? false
            }
            return events
        case .jira:
            let jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
            let fields = "summary,updated,created,status,priority,duedate,reporter"
            let result: Any
            do {
                result = try await get("\(tool.baseURL)/rest/api/3/search/jql?jql=\(q(jql))&fields=\(fields)&maxResults=50")
            } catch {
                result = try await get("\(tool.baseURL)/rest/api/3/search?jql=\(q(jql))&fields=\(fields)&maxResults=50")
            }
            return Self.parseJira(result, site: tool.baseURL)
        case .linear:
            let query = """
            { viewer { assignedIssues(first: 50, filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
                nodes { identifier title url createdAt updatedAt dueDate priority state { name } creator { name } } } }
              notifications(first: 50) { nodes { type readAt createdAt actor { name }
                ... on IssueNotification { comment { body } issue { identifier title url state { type } } } } } }
            """
            let body = try JSONSerialization.data(withJSONObject: ["query": query])
            return WorkRules.dedupe(Self.parseLinear(try await get("https://api.linear.app/graphql", method: "POST", body: body)))
        }
    }

    private func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? s }
    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    // MARK: Parsing (pure, tested)

    private static func date(_ s: Any?) -> Date {
        guard let s = s as? String else { return Date() }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
        // Jira: 2026-11-19T08:00:00.000+0100
        let j = DateFormatter()
        j.locale = Locale(identifier: "en_US_POSIX")
        j.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return j.date(from: s) ?? Date()
    }

    static func githubIsBot(_ user: [String: Any]?) -> Bool {
        guard let user else { return false }
        return user["type"] as? String == "Bot" || WorkRules.isBotUsername(user["login"] as? String ?? "")
    }

    static func parseGitHubSearch(_ json: Any, kind: WorkEvent.Kind, me: String) -> [WorkEvent] {
        ((json as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap { i in
            guard let url = i["html_url"] as? String, let title = i["title"] as? String else { return nil }
            let user = i["user"] as? [String: Any]
            let login = user?["login"] as? String ?? ""
            return WorkEvent(tool: .github, kind: kind, url: url, title: title,
                             project: (i["repository_url"] as? String)?.components(separatedBy: "/repos/").last ?? "",
                             actor: login, actorIsBot: githubIsBot(user), actorIsMe: login == me,
                             targetType: i["pull_request"] != nil ? "pull request" : "issue",
                             targetOpen: (i["state"] as? String ?? "open") == "open", targetAuthorIsMe: login == me,
                             date: date(i["updated_at"]), updated: date(i["updated_at"]))
        }
    }

    /// api.github.com/repos/o/r/pulls/12 → github.com/o/r/pull/12
    static func htmlURL(fromAPI api: String) -> String {
        api.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
    }

    /// Mentions only; review requests and assignments come from the searches.
    static func parseGitHubNotifications(_ json: Any, me: String) -> [WorkEvent] {
        (json as? [[String: Any]] ?? []).compactMap { n in
            guard let reason = n["reason"] as? String, reason == "mention" || reason == "team_mention",
                  let subject = n["subject"] as? [String: Any], let title = subject["title"] as? String,
                  let api = subject["url"] as? String else { return nil }
            let url = htmlURL(fromAPI: api)
            let repo = (n["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            return WorkEvent(tool: .github, kind: .mention, rawAction: reason, url: url, title: title, project: repo,
                             targetType: (subject["type"] as? String) == "PullRequest" ? "pull request" : "issue",
                             note: reason == "team_mention" ? "@team @all" : "", date: date(n["updated_at"]), fromNotification: true,
                             api: api, commentAPI: subject["latest_comment_url"] as? String)
        }
    }

    static func parseGitLabTodos(_ json: Any, myID: Int) -> [WorkEvent] {
        let kinds: [String: WorkEvent.Kind] = ["review_requested": .review, "approval_required": .approval, "mentioned": .mention,
                                               "directly_addressed": .addressed, "assigned": .assigned, "build_failed": .pipeline,
                                               "unmergeable": .unmergeable]
        return (json as? [[String: Any]] ?? []).compactMap { t in
            guard let url = t["target_url"] as? String else { return nil }
            let action = t["action_name"] as? String ?? ""
            let target = t["target"] as? [String: Any]
            let author = t["author"] as? [String: Any]
            let type = t["target_type"] as? String ?? ""
            let state = target?["state"] as? String
            return WorkEvent(tool: .gitlab, kind: kinds[action] ?? .other, rawAction: action, url: url,
                             title: target?["title"] as? String ?? "GitLab to-do",
                             project: (t["project"] as? [String: Any])?["name_with_namespace"] as? String ?? "",
                             actor: author?["name"] as? String ?? "", actorIsBot: gitlabIsBot(author),
                             actorIsMe: author?["id"] as? Int == myID,
                             targetType: type == "MergeRequest" ? "merge request" : type == "Issue" ? "issue" : type.lowercased(),
                             targetOpen: state == nil || state == "opened",
                             targetAuthorIsMe: (target?["author"] as? [String: Any])?["id"] as? Int == myID,
                             note: t["body"] as? String ?? "", date: date(t["created_at"]), updated: date(target?["updated_at"]),
                             due: (target?["due_date"] as? String).flatMap { ISO8601DateFormatter.flexible($0) }, fromNotification: true)
        }
    }

    static func gitlabIsBot(_ user: [String: Any]?) -> Bool {
        guard let user else { return false }
        return user["bot"] as? Bool == true || WorkRules.isBotUsername(user["username"] as? String ?? "")
    }

    static func parseGitLabMRs(_ json: Any, myID: Int) -> [WorkEvent] {
        (json as? [[String: Any]] ?? []).compactMap { i in
            guard let url = i["web_url"] as? String, let title = i["title"] as? String else { return nil }
            let author = i["author"] as? [String: Any]
            return WorkEvent(tool: .gitlab, kind: .review, url: url, title: title,
                             project: (i["references"] as? [String: Any])?["full"] as? String ?? "",
                             actor: author?["name"] as? String ?? "", actorIsBot: gitlabIsBot(author),
                             actorIsMe: author?["id"] as? Int == myID, targetType: "merge request",
                             targetOpen: (i["state"] as? String ?? "opened") == "opened", targetAuthorIsMe: author?["id"] as? Int == myID,
                             date: date(i["updated_at"]), updated: date(i["updated_at"]))
        }
    }

    static func parseGitLabIssues(_ json: Any, myID: Int) -> [WorkEvent] {
        (json as? [[String: Any]] ?? []).compactMap { i in
            guard let url = i["web_url"] as? String, let title = i["title"] as? String else { return nil }
            let author = i["author"] as? [String: Any]
            return WorkEvent(tool: .gitlab, kind: .assigned, url: url, title: title,
                             project: (i["references"] as? [String: Any])?["full"] as? String ?? "",
                             actor: author?["name"] as? String ?? "", actorIsBot: gitlabIsBot(author),
                             actorIsMe: author?["id"] as? Int == myID, targetType: "issue",
                             targetOpen: (i["state"] as? String ?? "opened") == "opened", targetAuthorIsMe: author?["id"] as? Int == myID,
                             date: date(i["updated_at"]), updated: date(i["updated_at"]),
                             due: (i["due_date"] as? String).flatMap { ISO8601DateFormatter.flexible($0) })
        }
    }

    /// https://gitlab.com/g/p/-/merge_requests/5 → /api/v4/projects/g%2Fp/merge_requests/5/approvals
    static func gitlabApprovalsPath(_ url: String, base: String) -> String? {
        guard url.hasPrefix(base), let range = url.range(of: "/-/merge_requests/") else { return nil }
        let project = String(url[url.index(url.startIndex, offsetBy: base.count + 1)..<range.lowerBound])
        let iid = url[range.upperBound...].prefix { $0.isNumber }
        guard !project.isEmpty, !iid.isEmpty,
              let encoded = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) else { return nil }
        return "\(base)/api/v4/projects/\(encoded)/merge_requests/\(iid)/approvals"
    }

    static func approvedBy(_ json: [String: Any]?, myID: Int) -> Bool {
        (json?["approved_by"] as? [[String: Any]] ?? []).contains { ($0["user"] as? [String: Any])?["id"] as? Int == myID }
    }

    static func parseJira(_ json: Any, site: String) -> [WorkEvent] {
        ((json as? [String: Any])?["issues"] as? [[String: Any]] ?? []).compactMap { i in
            guard let key = i["key"] as? String, let fields = i["fields"] as? [String: Any] else { return nil }
            let created = date(fields["created"])
            return WorkEvent(tool: .jira, kind: .assigned, url: "\(site)/browse/\(key)",
                             title: "\(key): \(fields["summary"] as? String ?? key)",
                             project: (fields["status"] as? [String: Any])?["name"] as? String ?? "",
                             actor: (fields["reporter"] as? [String: Any])?["displayName"] as? String ?? "",
                             date: fields["created"] == nil ? date(fields["updated"]) : created, updated: date(fields["updated"]),
                             due: (fields["duedate"] as? String).flatMap { ISO8601DateFormatter.flexible($0) },
                             // A recently created issue counts as recently assigned.
                             fromNotification: fields["created"] != nil)
        }
    }

    static func parseLinear(_ json: Any) -> [WorkEvent] {
        let data = (json as? [String: Any])?["data"] as? [String: Any]
        let viewer = data?["viewer"] as? [String: Any]
        let issues = ((viewer?["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { i -> WorkEvent? in
            guard let url = i["url"] as? String, let title = i["title"] as? String else { return nil }
            return WorkEvent(tool: .linear, kind: .assigned, url: url, title: "\(i["identifier"] as? String ?? ""): \(title)",
                             project: (i["state"] as? [String: Any])?["name"] as? String ?? "",
                             actor: (i["creator"] as? [String: Any])?["name"] as? String ?? "",
                             date: i["createdAt"] == nil ? date(i["updatedAt"]) : date(i["createdAt"]), updated: date(i["updatedAt"]),
                             due: (i["dueDate"] as? String).flatMap { ISO8601DateFormatter.flexible($0) },
                             fromNotification: i["createdAt"] != nil)
        }
        let notifications = ((data?["notifications"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { n -> WorkEvent? in
            guard n["readAt"] == nil || n["readAt"] is NSNull, let issue = n["issue"] as? [String: Any],
                  let url = issue["url"] as? String, let title = issue["title"] as? String else { return nil }
            let type = (n["type"] as? String ?? "").lowercased()
            let kind: WorkEvent.Kind = type.contains("mention") || type.contains("comment") ? .mention : type.contains("assign") ? .assigned : .other
            let stateType = ((issue["state"] as? [String: Any])?["type"] as? String) ?? ""
            return WorkEvent(tool: .linear, kind: kind, rawAction: type, url: url, title: "\(issue["identifier"] as? String ?? ""): \(title)",
                             actor: (n["actor"] as? [String: Any])?["name"] as? String ?? "",
                             targetOpen: !["completed", "canceled"].contains(stateType),
                             note: (n["comment"] as? [String: Any])?["body"] as? String ?? "", date: date(n["createdAt"]), fromNotification: true)
        }
        return notifications + issues
    }
}
