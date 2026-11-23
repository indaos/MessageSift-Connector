import Foundation

/// Reads Slack DMs, group DMs and @mentions with a user token (xoxp-…).
/// Token scopes: im:history, mpim:history, im:read, mpim:read, users:read, search:read.
final class SlackSource {
    enum SlackError: LocalizedError {
        case api(String)
        var errorDescription: String? {
            switch self { case .api(let e): return "Slack: \(e)" }
        }
    }

    /// Counts for diagnostics; never message text.
    struct Stats {
        var dmConversations = 0, groupDMConversations = 0
        var dmMessages = 0, groupDMMessages = 0, mentions = 0
        var historyCalls = 0, conversationsCovered = 0, conversationsTotal = 0
        /// Conversations whose history does not reach back to the window yet (read a page at a time on later refreshes).
        var olderToLoad = 0
        var errors: [String: Int] = [:]
    }

    private let token: String
    private var myUserID = ""
    private var workspaceURL = ""
    private var teamID = ""
    private(set) var stats = Stats()
    /// Your Slack handle, real name and display name, for the mention filter.
    private(set) var myNames: [String] = []
    /// Diagnostics read with another window and must not change the cache the app uses.
    var persistCache = true

    /// users.info results, kept across refreshes so each person is looked up once.
    private static var userNameCache: [String: String] = [:]
    private static let recentPerRefresh = 20
    private static let rotatingPerRefresh = 40
    private static let maxHistoryCalls = 80
    private static let lightPerRefresh = 10
    private static let parallelCalls = 6

    /// Runs the jobs at most `parallelCalls` at a time; results in the jobs' order.
    private static func inParallel<T: Sendable>(_ jobs: [@Sendable () async -> T]) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { group in
            var next = 0
            var out = [T?](repeating: nil, count: jobs.count)
            func add() { if next < jobs.count { let i = next, job = jobs[i]; next += 1; group.addTask { (i, await job()) } } }
            for _ in 0..<parallelCalls { add() }
            while let (i, value) = await group.next() { out[i] = value; add() }
            return out.compactMap { $0 }
        }
    }

    /// One Web API call without shared state (safe in parallel); waits and retries when rate limited.
    private static func get(_ token: String, _ method: String, _ params: [String: String]) async -> Result<[String: Any], SlackError> {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for attempt in 0..<3 {
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .failure(.api("network")) }
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                let wait = min(30, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)
                if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); continue }
                return .failure(.api("ratelimited"))
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.api("unexpected_response")) }
            guard json["ok"] as? Bool == true else { return .failure(.api(json["error"] as? String ?? "unknown_error")) }
            return .success(json)
        }
        return .failure(.api("ratelimited"))
    }

    init(token: String) { self.token = token }

    /// `light`: between full reads, only the most recently updated conversations, page 1 of mentions, fewer thread checks.
    func fetch(since: Date, light: Bool = false) async throws -> [HubMessage] {
        let auth = try await call("auth.test")
        myUserID = auth["user_id"] as? String ?? ""
        workspaceURL = auth["url"] as? String ?? ""
        teamID = auth["team_id"] as? String ?? ""
        let oldest = String(format: "%.6f", since.timeIntervalSince1970)
        if !light { myNames = await ownNames(handle: auth["user"] as? String) }

        var result: [HubMessage] = []

        // 1. Direct and group DMs. Each refresh reads the 20 most recently updated conversations plus
        //    the next 40 of the rest from a rotating cursor, so every conversation is read every few refreshes
        //    at the same API cost. Results are cached per conversation and merged.
        var channels: [[String: Any]] = []
        var cursor = ""
        repeat {
            var params = ["types": "im,mpim", "exclude_archived": "true", "limit": "200"]
            if !cursor.isEmpty { params["cursor"] = cursor }
            let page = try await call("conversations.list", params)
            channels += page["channels"] as? [[String: Any]] ?? []
            cursor = (page["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
        } while !cursor.isEmpty && channels.count < 1000
        channels.sort { ($0["updated"] as? Double ?? 0) > ($1["updated"] as? Double ?? 0) }

        var cache = SlackHistoryCache.load()
        cache.notFound = cache.notFound.filter { Date().timeIntervalSince($0.value) < 86_400 }
        channels.removeAll { cache.notFound[$0["id"] as? String ?? ""] != nil }
        for channel in channels {
            if channel["is_im"] as? Bool ?? false { stats.dmConversations += 1 } else { stats.groupDMConversations += 1 }
        }
        // Light: the most recently updated conversations, plus up to 10 whose history does not reach back to the window yet.
        let windowStartTS = since.timeIntervalSince1970
        let incomplete = channels.indices.filter { i in
            guard i >= Self.lightPerRefresh, let id = channels[i]["id"] as? String else { return false }
            guard let e = cache.conversations[id], let covered = e.coveredFrom else { return true }
            return covered > windowStartTS + 1
        }
        let selected = light ? Array(0..<min(Self.lightPerRefresh, channels.count)) + incomplete.prefix(Self.lightPerRefresh)
            : SlackHistoryCache.select(count: channels.count, recent: Self.recentPerRefresh, rotating: Self.rotatingPerRefresh, cursor: &cache.cursor)
        // Plan the reads per conversation, fetch them in parallel, then merge in order.
        struct Plan { let channelID: String; let title: String; var entry: SlackHistoryCache.Entry; let reads: [[String: String]] }
        var plans: [Plan] = []
        var planned = 0
        for index in selected {
            let channel = channels[index]
            guard let channelID = channel["id"] as? String else { continue }
            let isIM = channel["is_im"] as? Bool ?? false
            var entry = cache.conversations[channelID] ?? SlackHistoryCache.Entry()
            let windowStart = since.timeIntervalSince1970
            var title = channel["name"] as? String ?? "Group DM"
            if isIM, let other = channel["user"] as? String { title = await name(of: other) }
            if !isIM, title.hasPrefix("mpdm-") {
                // "mpdm-anna--ben--carl-1" → "anna, ben, carl"
                title = title.dropFirst(5).replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
                    .components(separatedBy: "--").joined(separator: ", ")
            }
            // Read newer messages (incremental), then, if the window grew, one page of older history.
            var reads: [[String: String]] = []
            if let newest = entry.newestTS, let n = Double(newest), n > windowStart, entry.coveredFrom != nil {
                reads.append(["oldest": newest])
            } else {
                reads.append(["oldest": oldest])
                entry.coveredFrom = nil
            }
            if let covered = entry.coveredFrom, covered > windowStart + 1 {
                reads.append(["oldest": oldest, "latest": String(format: "%.6f", covered)])
            }
            let allowed = Array(reads.prefix(max(0, Self.maxHistoryCalls - planned)))
            planned += allowed.count
            plans.append(Plan(channelID: channelID, title: title, entry: entry, reads: allowed))
        }
        let token = self.token
        let fetched = await Self.inParallel(plans.map { plan in
            { () async -> [Result<[String: Any], SlackError>] in
                var out: [Result<[String: Any], SlackError>] = []
                for range in plan.reads {
                    let r = await Self.get(token, "conversations.history", range.merging(["channel": plan.channelID, "limit": "200"]) { a, _ in a })
                    out.append(r)
                    if case .failure = r { break }
                }
                return out
            }
        })
        for (plan, pages) in zip(plans, fetched) {
            var entry = plan.entry
            let channelID = plan.channelID
            let windowStart = since.timeIntervalSince1970
            var notFound = false
            for (n, (range, result)) in zip(plan.reads, pages).enumerated() {
                stats.historyCalls += 1
                let page: [String: Any]
                switch result {
                case .success(let p): page = p
                case .failure(.api(let code)):
                    stats.errors[code, default: 0] += 1
                    if code == "channel_not_found" { notFound = true }
                    page = [:]
                }
                guard case .success = result else { break }
                let items = page["messages"] as? [[String: Any]] ?? []
                let hasMore = page["has_more"] as? Bool ?? false
                for item in items {
                    guard let m = await message(from: item, channelID: channelID, channelTitle: plan.title, isDirect: true, permalink: nil),
                          !entry.messages.contains(where: { $0.id == m.id }) else { continue }
                    entry.messages.append(m)
                }
                let stamps = items.compactMap { ($0["ts"] as? String).flatMap(Double.init) }
                entry.newestTS = ([entry.newestTS].compactMap { $0 } + items.compactMap { $0["ts"] as? String })
                    .max { (Double($0) ?? 0) < (Double($1) ?? 0) }
                // The first full read or a backfill page defines how far back this conversation is covered.
                if n == 0, range["latest"] == nil, entry.coveredFrom == nil {
                    entry.coveredFrom = hasMore ? (stamps.min() ?? windowStart) : windowStart
                } else if range["latest"] != nil {
                    entry.coveredFrom = hasMore ? (stamps.min() ?? windowStart) : windowStart
                }
            }
            if notFound {
                cache.notFound[channelID] = Date()
                cache.conversations[channelID] = nil
                continue
            }
            entry.lastRead = Date()
            cache.conversations[channelID] = entry
        }

        // Merge every cached conversation that still exists, also the ones not read this round.
        let liveIDs = Set(channels.compactMap { $0["id"] as? String })
        cache.conversations = cache.conversations.filter { liveIDs.contains($0.key) }
        for (channelID, var entry) in cache.conversations {
            entry.messages = entry.messages.filter { $0.date > since }
            if let covered = entry.coveredFrom { entry.coveredFrom = max(covered, since.timeIntervalSince1970) }
            cache.conversations[channelID] = entry
            var batch = entry.messages.sorted { $0.date < $1.date }
            let lastMine = batch.filter(\.isFromMe).map(\.date).max() ?? .distantPast
            for i in batch.indices { batch[i].isAnswered = !batch[i].isFromMe && batch[i].date < lastMine }
            let isGroup = channels.first { $0["id"] as? String == channelID }?["is_mpim"] as? Bool ?? false
            if isGroup { stats.groupDMMessages += batch.count } else { stats.dmMessages += batch.count }
            result += batch
        }
        stats.conversationsCovered = cache.conversations.values.filter { $0.lastRead != nil }.count
        stats.olderToLoad = channels.filter { c in
            guard let id = c["id"] as? String else { return false }
            guard let e = cache.conversations[id], let covered = e.coveredFrom else { return true }
            return covered > since.timeIntervalSince1970 + 1
        }.count
        stats.conversationsTotal = channels.count
        if persistCache { cache.save() }

        // 2. Messages that mention you directly (search:read). @here/@channel don't match "<@you>".
        //    Page 1 every refresh for new mentions, plus one older page per refresh until the window is covered.
        if !myUserID.isEmpty {
            var mentionCache = SlackHistoryCache.load()
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            let query = "<@\(myUserID)> after:\(day.string(from: since.addingTimeInterval(-86_400)))"
            if mentionCache.mentionsQuery != query { mentionCache.mentionsQuery = query; mentionCache.mentionsNextPage = 2 }
            var pages = [1]
            if !light, mentionCache.mentionsNextPage > 1 { pages.append(mentionCache.mentionsNextPage) }
            for page in pages {
                guard let search = try? await call("search.messages", ["query": query, "sort": "timestamp", "count": "100", "page": "\(page)"]),
                      let messages = search["messages"] as? [String: Any] else { break }
                let total = (messages["paging"] as? [String: Any])?["pages"] as? Int ?? 1
                if page > 1 { mentionCache.mentionsNextPage = page < total ? page + 1 : 0 }
                else if total <= 1 { mentionCache.mentionsNextPage = 0 }
                for item in messages["matches"] as? [[String: Any]] ?? [] {
                    let channel = item["channel"] as? [String: Any] ?? [:]
                    let channelID = channel["id"] as? String ?? ""
                    let isPrivateDM = (channel["is_im"] as? Bool ?? false) || (channel["is_mpim"] as? Bool ?? false)
                    let channelName = isPrivateDM ? (channel["name"] as? String ?? "DM") : "#" + (channel["name"] as? String ?? "channel")
                    guard let m = await message(from: item, channelID: channelID, channelTitle: channelName,
                                                isDirect: isPrivateDM, permalink: item["permalink"] as? String), !m.isFromMe else { continue }
                    mentionCache.mentions[m.id] = m
                }
            }
            mentionCache.mentions = mentionCache.mentions.filter { $0.value.date > since }

            // Thread mentions you already replied to are handled (conversations.replies, cached 10 minutes).
            var replyCalls = 0
            for (id, var m) in mentionCache.mentions {
                guard let channel = m.slackChannel, let ts = m.slackTs else { continue }
                let key = "\(channel):\(m.slackThreadTs ?? ts)"
                var check = mentionCache.threadChecks[key]
                if check == nil || Date().timeIntervalSince(check!.checkedAt) > 600, replyCalls < (light ? 5 : 20) {
                    replyCalls += 1
                    if let replies = try? await call("conversations.replies", ["channel": channel, "ts": m.slackThreadTs ?? ts, "limit": "200"]) {
                        let mine = (replies["messages"] as? [[String: Any]] ?? [])
                            .filter { $0["user"] as? String == myUserID }
                            .compactMap { $0["ts"] as? String }
                            .max { (Double($0) ?? 0) < (Double($1) ?? 0) }
                        check = SlackHistoryCache.ThreadCheck(checkedAt: Date(), myLastReplyTS: mine)
                        mentionCache.threadChecks[key] = check
                    }
                }
                if let mine = check?.myLastReplyTS, let a = Double(mine), let b = Double(ts), a > b {
                    m.resolvedReason = "replied in thread"
                } else {
                    m.resolvedReason = nil
                }
                mentionCache.mentions[id] = m
            }
            mentionCache.threadChecks = mentionCache.threadChecks.filter { Date().timeIntervalSince($0.value.checkedAt) < 7 * 86_400 }
            // Keep the DM cache written above and add the mention state.
            var merged = SlackHistoryCache.load()
            merged.mentions = mentionCache.mentions
            merged.mentionsQuery = mentionCache.mentionsQuery
            merged.mentionsNextPage = mentionCache.mentionsNextPage
            merged.threadChecks = mentionCache.threadChecks
            if persistCache { merged.save() }
            for m in mentionCache.mentions.values where !result.contains(where: { $0.id == m.id }) {
                stats.mentions += 1
                result.append(m)
            }
        }
        return result
    }

    /// Finds the API message behind a notification: search.messages for a quoted snippet on that day,
    /// taking a match within ±5 minutes. Call after `fetch`, which sets the team. Returns nil if not found.
    func findMessage(text: String, date: Date, channelName: String? = nil) async -> (team: String, channel: String, ts: String, thread: String?)? {
        // Notifications write mentions as "@Name" while the API text has "<@U…>", so skip mention words.
        let stripped = text.replacingOccurrences(of: #"^[^:\n]{2,60}: "#, with: "", options: .regularExpression)
        let tokens = stripped.replacingOccurrences(of: #"[\"“”*_~`<>()\[\]]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var words: [String] = []
        var skipNext = false
        for t in tokens {
            if t.hasPrefix("@") { skipNext = true; continue }
            if skipNext, t.first?.isUppercase == true { skipNext = false; continue }
            skipNext = false
            if t.hasPrefix(":") || t.hasPrefix("http") { continue }
            words.append(t)
        }
        let phrase = words.prefix(6).joined(separator: " ")
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        var queryList: [String] = []
        if words.count >= 3 { queryList += ["\"\(phrase)\" on:\(day.string(from: date))", "\"\(phrase)\""] }
        // Notification text often differs from the stored text (bots, blocks); the channel and time still match.
        if let channelName, !channelName.isEmpty {
            let name = channelName.hasPrefix("#") ? String(channelName.dropFirst()) : channelName
            // A ±1 day window avoids local/UTC date boundaries.
            let before = day.string(from: date.addingTimeInterval(86_400))
            let after = day.string(from: date.addingTimeInterval(-86_400))
            queryList.append("in:#\(name) after:\(after) before:\(before)")
        }
        guard !queryList.isEmpty else { return nil }
        var matches: [[String: Any]] = []
        for query in queryList where !matches.contains(where: { abs((($0["ts"] as? String).flatMap(Double.init) ?? 0) - date.timeIntervalSince1970) < 300 }) {
            if let search = try? await call("search.messages", ["query": query, "count": "100", "sort": "timestamp"]) {
                matches = (search["messages"] as? [String: Any])?["matches"] as? [[String: Any]] ?? []
            }
        }
        // Closest in time first.
        matches.sort {
            abs((($0["ts"] as? String).flatMap(Double.init) ?? 0) - date.timeIntervalSince1970)
                < abs((($1["ts"] as? String).flatMap(Double.init) ?? 0) - date.timeIntervalSince1970)
        }
        for item in matches {
            guard let ts = item["ts"] as? String, let seconds = Double(ts), abs(seconds - date.timeIntervalSince1970) < 300,
                  let channel = (item["channel"] as? [String: Any])?["id"] as? String else { continue }
            let thread = (item["permalink"] as? String).flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "thread_ts" }?.value }
            return (teamID, channel, ts, thread == ts ? nil : thread)
        }
        return nil
    }

    private func ownNames(handle: String?) async -> [String] {
        var names = [handle].compactMap { $0 }
        if let info = try? await call("users.info", ["user": myUserID]),
           let user = info["user"] as? [String: Any] {
            let profile = user["profile"] as? [String: Any]
            names += [user["real_name"] as? String, profile?["display_name"] as? String, profile?["real_name"] as? String]
                .compactMap { $0 }
        }
        return names.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private func message(from item: [String: Any], channelID: String, channelTitle: String,
                         isDirect: Bool, permalink: String?) async -> HubMessage? {
        guard let ts = item["ts"] as? String, let seconds = Double(ts) else { return nil }
        if let subtype = item["subtype"] as? String, ["channel_join", "channel_leave", "bot_add"].contains(subtype) { return nil }
        let userID = item["user"] as? String ?? ""
        let fromMe = userID == myUserID
        let sender: String
        if fromMe {
            sender = "Me"
        } else if userID.isEmpty {
            sender = item["username"] as? String ?? "Slack"
        } else {
            sender = await name(of: userID)
        }
        let text = await clean(item["text"] as? String ?? "")

        // The permalink (with thread_ts for replies) is opened with the Slack app, which scrolls to the message.
        let link = permalink.flatMap(URL.init(string:))
            ?? DeepLinks.slack(workspaceURL: workspaceURL, channelID: channelID, ts: ts, threadTS: item["thread_ts"] as? String)

        return HubMessage(
            id: "slack:\(channelID):\(ts)",
            source: .slack,
            sender: sender,
            senderHandle: userID,
            title: channelTitle,
            body: text,
            date: Date(timeIntervalSince1970: seconds),
            isFromMe: fromMe,
            isDirect: isDirect,
            conversationID: "slack:\(channelID)",
            context: "Slack",
            link: link,
            slackTeam: teamID.isEmpty ? nil : teamID,
            slackChannel: channelID,
            slackTs: ts,
            slackThreadTs: (item["thread_ts"] as? String).flatMap { $0 == ts ? nil : $0 }
                ?? permalink.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "thread_ts" }?.value })
    }

    /// "<@U123>" → "@Anna", "<https://x|label>" → "label".
    private func clean(_ text: String) async -> String {
        var out = text
        let mention = try! NSRegularExpression(pattern: "<@([A-Z0-9]+)(\\|[^>]*)?>")
        let ns = out as NSString
        let ids = mention.matches(in: out, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        for id in Set(ids) {
            let n = await name(of: id)
            out = out.replacingOccurrences(of: "<@\(id)>", with: "@\(n)")
        }
        out = out.replacingOccurrences(of: "<@([A-Z0-9]+)\\|([^>]*)>", with: "@$2", options: .regularExpression)
        out = out.replacingOccurrences(of: "<([^|>]+)\\|([^>]+)>", with: "$2", options: .regularExpression)
        out = out.replacingOccurrences(of: "<(https?://[^>]+)>", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return out
    }

    private func name(of userID: String) async -> String {
        if let cached = Self.userNameCache[userID] { return cached }
        let info = try? await call("users.info", ["user": userID])
        let user = info?["user"] as? [String: Any]
        let profile = user?["profile"] as? [String: Any]
        let n = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (profile?["real_name"] as? String)
            ?? (user?["name"] as? String)
            ?? userID
        if info != nil { Self.userNameCache[userID] = n }
        return n
    }

    private func call(_ method: String, _ params: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            // Rate limited: wait as long as Slack asks (Retry-After), at most 30 s, then try again.
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                stats.errors["ratelimited", default: 0] += 1
                let wait = min(30, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)
                if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); continue }
                throw SlackError.api("ratelimited")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                stats.errors["unexpected_response", default: 0] += 1
                throw SlackError.api("unexpected response")
            }
            guard json["ok"] as? Bool == true else {
                let code = json["error"] as? String ?? "unknown_error"
                stats.errors[code, default: 0] += 1
                throw SlackError.api(code)
            }
            return json
        }
        throw SlackError.api("ratelimited")
    }

    /// Checks a token and returns "user @ workspace".
    static func test(token: String) async throws -> String {
        let source = SlackSource(token: token)
        let auth = try await source.call("auth.test")
        return "\(auth["user"] as? String ?? "?") @ \(auth["team"] as? String ?? "?")"
    }
}

/// Per-conversation Slack history between refreshes, plus the rotation cursor.
struct SlackHistoryCache: Codable {
    struct Entry: Codable {
        var newestTS: String?
        var lastRead: Date?
        /// How far back (epoch seconds) this conversation's history has been read.
        var coveredFrom: Double?
        var messages: [HubMessage] = []
    }

    struct ThreadCheck: Codable {
        var checkedAt: Date
        var myLastReplyTS: String?
    }

    /// Bumped when the cached message format changes; an old cache is dropped.
    static let currentVersion = 4
    var version = SlackHistoryCache.currentVersion
    var cursor = 0
    var conversations: [String: Entry] = [:]
    /// Conversations that returned channel_not_found, skipped for a day.
    var notFound: [String: Date] = [:]
    var mentions: [String: HubMessage] = [:]
    var mentionsQuery = ""
    /// Next older search page to read (0 = done).
    var mentionsNextPage = 2
    var threadChecks: [String: ThreadCheck] = [:]

    private static var url: URL {
        DataLocation.applicationSupport
            .appendingPathComponent("MessageHub/slack-api-cache.json")
    }

    static func load() -> SlackHistoryCache {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let cache = try? decoder.decode(SlackHistoryCache.self, from: data),
              cache.version == currentVersion else {
            return SlackHistoryCache()
        }
        return cache
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    /// Indexes to read this refresh: the first `recent` (most recently updated), then `rotating`
    /// from the rest starting at `cursor`, wrapping around. Advances the cursor.
    static func select(count: Int, recent: Int, rotating: Int, cursor: inout Int) -> [Int] {
        let head = Array(0..<min(recent, count))
        let rest = count - head.count
        guard rest > 0 else { cursor = 0; return head }
        let start = cursor % rest
        let tail = (0..<min(rotating, rest)).map { head.count + (start + $0) % rest }
        cursor = (start + min(rotating, rest)) % rest
        return head + tail
    }
}
