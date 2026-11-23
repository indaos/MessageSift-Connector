import Foundation

/// The event types the user can turn on or off per tool (Settings › Sources).
enum WorkEventType: String, CaseIterable, Identifiable {
    case reviews, approvals, assigned, mentions, pipelines
    var id: String { rawValue }

    var title: String {
        switch self {
        case .reviews: return "Review requests"
        case .approvals: return "Approvals needed"
        case .assigned: return "Assigned"
        case .mentions: return "Mentions"
        case .pipelines: return "Failed pipelines on my MRs"
        }
    }

    static func types(for tool: DevTool) -> [WorkEventType] {
        switch tool {
        case .gitlab: return allCases
        case .github: return [.reviews, .assigned, .mentions, .pipelines]
        case .jira, .linear: return [.assigned, .mentions]
        }
    }
}

/// One GitHub/GitLab/Jira/Linear event, before the rules decide whether it needs the user.
struct WorkEvent: Equatable {
    enum Kind: String {
        case review, approval, mention, addressed, assigned, pipeline, unmergeable, other

        var type: WorkEventType? {
            switch self {
            case .review: return .reviews
            case .approval: return .approvals
            case .mention, .addressed: return .mentions
            case .assigned: return .assigned
            case .pipeline, .unmergeable: return .pipelines
            case .other: return nil
            }
        }

        /// The label shown as the reason (and used for the category).
        var label: String {
            switch self {
            case .review: return "Review requested"
            case .approval: return "Approval required"
            case .mention: return "You were mentioned"
            case .addressed: return "Addressed to you"
            case .assigned: return "Assigned to you"
            case .pipeline: return "Pipeline failed"
            case .unmergeable: return "Merge conflict"
            case .other: return "Notification"
            }
        }
    }

    var tool: DevTool
    var kind: Kind
    /// The tool's own name for the event, e.g. GitLab's action_name.
    var rawAction = ""
    var url: String
    var title: String
    var project = ""
    var actor = ""
    var actorIsBot = false
    var actorIsMe = false
    /// "merge request", "issue", "pull request".
    var targetType = "issue"
    var targetOpen = true
    var targetAuthorIsMe = false
    var approvedByMe = false
    /// The comment that triggered a mention.
    var note = ""
    var date: Date
    var updated: Date? = nil
    var due: Date? = nil
    /// From a to-do or notification (an event that happened to the user), not from a list query.
    var fromNotification = false
    /// GitHub API links for the item and the latest comment (looked up after parsing).
    var api: String? = nil
    var commentAPI: String? = nil
}

/// Which work events need the user (pure, tested). The AI judge then decides on everything kept.
enum WorkRules {
    /// Project/group bots, Renovate, Dependabot, GitLab's own bots, the "ghost" user and GitHub "[bot]" accounts.
    static func isBotUsername(_ username: String) -> Bool {
        let u = username.lowercased()
        if ["ghost", "gitlab-bot", "renovate", "renovate-bot", "dependabot", "github-actions", "alert-bot", "support-bot"].contains(u) { return true }
        if u.hasSuffix("[bot]") || u.hasSuffix("-bot") || u.hasSuffix("_bot") || u.hasPrefix("renovate") || u.hasPrefix("dependabot") { return true }
        return u.range(of: #"^(project|group)_\d+_bot"#, options: .regularExpression) != nil
    }

    /// @all, @here, @channel, or a comment that pings many people at once.
    static func isGroupPing(_ note: String) -> Bool {
        let lower = note.lowercased()
        if lower.range(of: #"@(all|here|channel|everyone)\b"#, options: .regularExpression) != nil { return true }
        let handles = (try? NSRegularExpression(pattern: #"(^|\s)@[\w.\-/]+"#))?.numberOfMatches(in: note, range: NSRange(note.startIndex..., in: note)) ?? 0
        return handles >= 4
    }

    /// nil when the event is kept (then judged), else why it is dropped.
    static func dropReason(_ e: WorkEvent, enabled: Set<WorkEventType>, now: Date = Date()) -> String? {
        guard let type = e.kind.type else { return "not an action (\(e.rawAction.isEmpty ? "other" : e.rawAction))" }
        if !enabled.contains(type) { return "event type off" }
        if !e.targetOpen { return "merged or closed" }
        if e.actorIsBot { return "bot" }
        // GitLab authors build_failed/unmergeable to-dos as the user; those still need them.
        if e.actorIsMe && e.fromNotification && e.kind != .pipeline && e.kind != .unmergeable { return "your own action" }
        if (e.kind == .review || e.kind == .approval) && e.approvedByMe { return "already approved" }
        if (e.kind == .pipeline || e.kind == .unmergeable) && !e.targetAuthorIsMe { return "not your merge request" }
        if (e.kind == .mention || e.kind == .addressed) && !UrgencyEngine.asksSomething(e.note) && !e.note.isEmpty {
            return "mention without a question or request"
        }
        if e.kind == .assigned {
            let day: TimeInterval = 86_400
            let recentlyAssigned = e.fromNotification && now.timeIntervalSince(e.date) < 7 * day
            // Due within 7 days, or overdue by at most 7 days (older due dates are stale).
            let dueSoon = e.due.map { $0.timeIntervalSince(now) < 7 * day && now.timeIntervalSince($0) < 7 * day } ?? false
            // GitLab reports others' activity as to-dos (mentions, comments); Jira and Linear only have the update time.
            let recentActivity = e.tool != .gitlab && (e.updated ?? e.date).timeIntervalSince(now) > -2 * day
            if !(recentlyAssigned || dueSoon || recentActivity) { return "stale assignment" }
        }
        return nil
    }

    /// One event per item: to-dos and notifications win over list results, and the most specific kind wins.
    static func dedupe(_ events: [WorkEvent]) -> [WorkEvent] {
        let rank: [WorkEvent.Kind: Int] = [.approval: 0, .review: 1, .pipeline: 2, .unmergeable: 3, .addressed: 4, .mention: 5, .assigned: 6, .other: 7]
        var best: [String: WorkEvent] = [:]
        var order: [String] = []
        for e in events {
            guard let current = best[e.url] else { best[e.url] = e; order.append(e.url); continue }
            if (rank[e.kind] ?? 9, e.fromNotification ? 0 : 1) < (rank[current.kind] ?? 9, current.fromNotification ? 0 : 1) {
                var merged = e
                merged.approvedByMe = merged.approvedByMe || current.approvedByMe
                best[e.url] = merged
            }
        }
        return order.compactMap { best[$0] }
    }

    static let groupPingNote = "This is a group ping to many people, not only to the user."

    /// The kept event as a message. The body is what the AI judge reads.
    static func message(_ e: WorkEvent) -> HubMessage {
        let group = (e.kind == .mention || e.kind == .addressed) && isGroupPing(e.note)
        let role: String = {
            switch e.kind {
            case .review, .approval: return "reviewer"
            case .assigned: return "assignee"
            case .pipeline, .unmergeable: return "author"
            default: return e.targetAuthorIsMe ? "author" : "mentioned"
            }
        }()
        var lines = [
            "Event: \(e.kind.label.lowercased()) on a \(e.targetType)\(e.project.isEmpty ? "" : " in \(e.project)").",
            "State: \(e.targetOpen ? "open" : "closed").",
            "Acted by: \(e.actor.isEmpty ? "unknown" : e.actor).",
            "The user's role: \(role).",
        ]
        if let due = e.due { lines.append("Due: \(due.formatted(.iso8601.year().month().day())).") }
        if group { lines.append(groupPingNote) }
        if !e.note.isEmpty { lines.append("Comment: \(String(e.note.prefix(1200)))") }
        return HubMessage(
            id: "\(e.tool.rawValue):\(e.url)", source: e.tool.source, sender: e.actor.isEmpty ? e.tool.source.displayName : e.actor,
            senderHandle: e.actor, title: e.title, body: lines.joined(separator: "\n"), date: e.date, isUnread: true,
            isDirect: !(e.kind == .mention || group),
            conversationID: "\(e.tool.rawValue):\(e.url)", context: e.kind.label, link: URL(string: e.url), dueDate: e.due)
    }
}
