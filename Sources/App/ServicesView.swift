import AppKit
import SwiftUI

/// The services the Connector reads over the network with your keys. Keys stay in the Connector's Keychain items;
/// MessageSift only gets the items.
enum Service: String, CaseIterable, Identifiable {
    case slack, github, gitlab, jira, linear, microsoft
    var id: String { rawValue }

    var title: String {
        switch self {
        case .slack: return "Slack"
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .jira: return "Jira"
        case .linear: return "Linear"
        case .microsoft: return "Teams and Outlook"
        }
    }

    var tool: DevTool? { DevTool(rawValue: rawValue) }

    var sources: [MessageSource] {
        switch self {
        case .slack: return [.slack]
        case .microsoft: return [.teams, .outlook]
        default: return tool.map { [$0.source] } ?? []
        }
    }

    var isConfigured: Bool { sources.allSatisfy(NetworkSources.configured.contains) }

    /// messagesift-connector://service/gitlab (MessageSift uses teams and outlook too).
    init?(link: URL) {
        guard link.host == "service", let name = link.pathComponents.dropFirst().first else { return nil }
        switch name {
        case "teams", "outlook": self = .microsoft
        default:
            guard let s = Service(rawValue: name) else { return nil }
            self = s
        }
    }
}

/// One window for all services; opened from the menu or by MessageSift on one service.
@MainActor
enum ServicesWindow {
    private static var window: NSWindow?
    private static let selection = ServiceSelection()

    static func show(_ service: Service? = nil) {
        if let service { selection.service = service }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Services"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ServicesView().environmentObject(selection)
                .environmentObject(NetworkSources.shared))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class ServiceSelection: ObservableObject {
    @Published var service: Service = .slack
}

struct ServicesView: View {
    @EnvironmentObject private var selection: ServiceSelection
    @EnvironmentObject private var network: NetworkSources

    var body: some View {
        HSplitView {
            List(Service.allCases, selection: Binding(get: { selection.service }, set: { if let s = $0 { selection.service = s } })) { s in
                HStack {
                    Text(s.title)
                    Spacer()
                    if let e = s.sources.compactMap({ network.errors[$0] }).first {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
                    } else if s.isConfigured {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .tag(s)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            ScrollView {
                ServiceDetail(service: selection.service).id(selection.service).padding(20)
            }
            .frame(minWidth: 400)
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

/// Server, email and key fields; "Check and Save" keeps a key only when the service accepts it.
struct ServiceDetail: View {
    let service: Service
    @EnvironmentObject private var network: NetworkSources
    @State private var key = ""
    @State private var server = ""
    @State private var email = ""
    @State private var clientID = ""
    @State private var tenant = ""
    @State private var result: String?
    @State private var failed = false
    @State private var working = false
    @State private var code: MSGraph.DeviceCode?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(service.title).font(.title2.weight(.semibold))
            Text(intro).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if service == .microsoft { microsoft } else { keyFields }
            if let result { Text(result).font(.callout).foregroundStyle(failed ? Color.red : Color.green) }
            if let e = service.sources.compactMap({ network.errors[$0] }).first, result == nil {
                Text("Last read: \(e)").font(.callout).foregroundStyle(.orange)
            }
            if let last = network.lastRead, service.isConfigured {
                Text("Read \(last.formatted(date: .omitted, time: .shortened)), \(count) items.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
    }

    private var count: Int { network.items.filter { service.sources.contains($0.source) }.count }

    private var intro: String {
        switch service {
        case .slack: return "A Slack user token (xoxp-) reads your direct messages, mentions and thread replies."
        case .microsoft: return "Your own Azure app (client ID) and one Microsoft sign-in read Teams chats and Outlook mail."
        default: return service.tool?.tokenHelp.text ?? ""
        }
    }

    @ViewBuilder private var keyFields: some View {
        if service == .gitlab { TextField("Server", text: $server, prompt: Text("https://gitlab.com")) }
        if service == .jira {
            TextField("Site URL", text: $server, prompt: Text("https://yourcompany.atlassian.net"))
            TextField("Email", text: $email, prompt: Text("you@company.com"))
        }
        SecureField(service == .linear ? "API key" : service == .slack ? "xoxp-…" : "Token", text: $key)
        HStack {
            Button(working ? "Checking…" : "Check and Save") { checkAndSave() }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || working)
            Link("How to get a key…", destination: keyPage)
            Spacer()
            if service.isConfigured { Button("Remove Key", role: .destructive) { removeKey() } }
        }
    }

    @ViewBuilder private var microsoft: some View {
        TextField("Application (client) ID", text: $clientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
        TextField("Tenant", text: $tenant, prompt: Text("organizations"))
        HStack {
            if MSGraph.isSignedIn {
                Text("Signed in as \(MSGraph.accountName ?? "?")").font(.callout)
                Button("Sign Out") { Task { await MSGraph.shared.signOut(); result = "Signed out"; failed = false; Connector.shared.servicesChanged() } }
            } else {
                Button(working ? "Waiting for sign-in…" : "Sign In…") { signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            Link("Set up the Azure app…", destination: URL(string: "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
        }
        if let code {
            HStack(spacing: 10) {
                Text(code.userCode).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                Button("Copy Code and Open Page") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    NSWorkspace.shared.open(code.verificationURL)
                }
            }
        }
        Text("Azure app: public client flows on; Microsoft Graph delegated permissions User.Read, Mail.Read, Chat.Read, offline_access.")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// GitLab: the token page of the server typed above.
    private var keyPage: URL {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if service == .gitlab, !s.isEmpty, let u = URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s) {
            return u.appendingPathComponent("-/user_settings/personal_access_tokens")
        }
        if service == .slack { return URL(string: "https://api.slack.com/apps")! }
        return URL(string: service.tool?.tokenHelp.url ?? "https://example.com")!
    }

    private func load() {
        if let tool = service.tool {
            server = tool == .gitlab && tool.baseURL == "https://gitlab.com" ? "" : tool.baseURL
            email = tool.email
        }
        clientID = MSGraph.clientID
        tenant = DataLocation.defaults.string(forKey: "msgraph-tenant") ?? ""
    }

    private func checkAndSave() {
        let newKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true
        result = nil
        Task {
            defer { working = false }
            if service == .slack {
                do {
                    result = "Connected as \(try await SlackSource.test(token: newKey))"
                    Keychain.set(newKey, for: "slack-token")
                    failed = false
                } catch { result = "Not accepted: \(error.localizedDescription)"; failed = true }
            } else if let tool = service.tool {
                let previous = (Keychain.get(tool.tokenKey), tool.baseURL, tool.email)
                Keychain.set(newKey, for: tool.tokenKey)
                if tool == .gitlab || tool == .jira { tool.baseURL = server.trimmingCharacters(in: .whitespacesAndNewlines) }
                if tool == .jira { tool.email = email.trimmingCharacters(in: .whitespacesAndNewlines) }
                do {
                    result = try await DevToolsClient(tool: tool).test()
                    failed = false
                } catch {
                    Keychain.set(previous.0, for: tool.tokenKey)
                    tool.baseURL = previous.1
                    tool.email = previous.2
                    result = "Not accepted: \(error.localizedDescription)"
                    failed = true
                }
            }
            if !failed { key = ""; Connector.shared.servicesChanged() }
        }
    }

    private func removeKey() {
        if service == .slack { Keychain.set(nil, for: "slack-token") }
        if let tool = service.tool { Keychain.set(nil, for: tool.tokenKey) }
        result = "Key removed"
        failed = false
        Connector.shared.servicesChanged()
    }

    private func signIn() {
        MSGraph.clientID = clientID
        MSGraph.tenant = tenant
        working = true
        result = nil
        Task {
            defer { working = false; code = nil }
            do {
                let c = try await MSGraph.shared.startDeviceCode()
                code = c
                let name = try await MSGraph.shared.completeSignIn(c)
                result = "Signed in as \(name)"
                failed = false
                Connector.shared.servicesChanged()
            } catch { result = error.localizedDescription; failed = true }
        }
    }
}
