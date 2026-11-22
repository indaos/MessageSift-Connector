import AppKit
import SwiftUI

@main
struct ConnectorApp: App {
    @StateObject private var connector = Connector.shared

    init() {
        // `--status`: Full Disk Access and what the shared file holds (counts and time only), then quit.
        if CommandLine.arguments.contains("--status") {
            print(Connector.statusReport())
            exit(0)
        }
    }

    var body: some Scene {
        Window("MessageSift Connector", id: "main") {
            StatusView().environmentObject(connector).frame(width: 460).padding(20)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("MessageSift Connector", systemImage: connector.paused ? "powerplug" : "powerplug.fill") {
            StatusView().environmentObject(connector).frame(width: 420).padding(16)
        }
        .menuBarExtraStyle(.window)
    }
}

struct StatusView: View {
    @EnvironmentObject private var c: Connector
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text("MessageSift Connector").font(.headline)
                    Text("Shares Mac notifications and WhatsApp with MessageSift from the App Store. Nothing leaves this Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if c.accessArrived {
                HStack {
                    Text("Access works. Restart the Connector so it reads with it.").font(.callout)
                    Button("Restart Connector") { Connector.relaunch() }
                }
            } else if !c.hasAccess {
                FullDiskAccessGuide()
            } else {
                shared
            }
            if let p = c.problem { Text(p).font(.caption).foregroundStyle(.red) }
            Divider()
            Toggle("Open at login", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
            HStack {
                Button("Open Window") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .onAppear { c.start() }
    }

    private var shared: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pause sharing", isOn: $c.paused)
            Text(c.paused ? "Paused. MessageSift keeps what was shared before." :
                    c.lastShared.map { "Shared \($0.formatted(date: .omitted, time: .shortened)), last \(Connector.days) days:" } ?? "Reading…")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, verticalSpacing: 4) {
                GridRow { Text("Slack notifications"); Text("\(c.counts[.slack] ?? 0)").monospacedDigit() }
                GridRow { Text("WhatsApp"); Text("\(c.counts[.whatsapp] ?? 0)").monospacedDigit() }
                GridRow { Text("Other chat apps"); Text("\(c.counts[.otherApps] ?? 0)").monospacedDigit() }
            }
            .font(.callout)
            DisclosureGroup("Other chat apps to share") {
                ForEach(c.notifyingApps, id: \.app) { item in
                    Toggle(Connector.appName(item.app), isOn: Binding(
                        get: { c.otherApps.contains(item.app) },
                        set: { on in if on { c.otherApps.insert(item.app) } else { c.otherApps.remove(item.app) } }))
                }
                if c.notifyingApps.isEmpty { Text("No other apps with notifications.").font(.caption).foregroundStyle(.secondary) }
            }
            .font(.callout)
            Button("Delete Shared Data", role: .destructive) { c.deleteSharedData() }
                .help("Removes the shared file from MessageSift's folder and pauses sharing.")
        }
    }
}

/// Full Disk Access: why, Open System Settings, Show in Finder, the drag steps, checked every 2 seconds.
struct FullDiskAccessGuide: View {
    @EnvironmentObject private var c: Connector
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Full Disk Access needed", systemImage: "lock.shield").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text("macOS keeps Notification Center and WhatsApp data behind Full Disk Access. The Connector only reads it.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") { Connector.openFullDiskAccessPane() }.buttonStyle(.borderedProminent)
                Button("Show Connector in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
            Text("In System Settings › Privacy & Security › Full Disk Access, turn on MessageSift Connector. If it is not in the list, click + below the list and choose MessageSift Connector in Applications, or drag it from the Finder window into the list.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(timer) { _ in c.tick() }
    }
}
