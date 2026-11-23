# MessageSift Connector

A small, free, open-source (MIT) helper for **MessageSift from the Mac App Store**.

App Store apps run in a sandbox, so MessageSift can't open macOS's Notification Center database or WhatsApp's
chat store. The Connector can, with Full Disk Access. It copies recent items into one file that MessageSift reads.
It runs as a menu bar app with a small status window.

- **Read-only:** it never writes to the databases it reads.
- **Network off by default:** WhatsApp and Mac notifications need no network, and the Connector makes no network
  connections until you allow one. When you add a service in **Services**, it asks "Allow the Connector to connect to
  …?" and names the host(s). Only allowed hosts are ever contacted (one gate checks every request). Turn it off per
  service in Services. MessageSift itself has no network access at all.
- **No AI**, no analytics, no updates, no accounts.

## Install

1. Download **MessageSift Connector.dmg** from the [latest release](https://github.com/indaos/MessageSift-Connector/releases/latest).
2. Open it and drag **MessageSift Connector** onto **Applications**.
3. Open MessageSift Connector from Applications. It is signed with Developer ID and notarized by Apple.
4. Give it Full Disk Access (steps below). It then shares in the background; turn on **Open at login** to keep it running.

## What it reads (read-only)

| Data | Path | What is used |
| --- | --- | --- |
| Notification Center database | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` | Notifications of Slack, WhatsApp and the chat apps you choose (default: Signal, Discord, Telegram, Teams): title, subtitle, text, time. Other apps' notifications are skipped. |
| WhatsApp desktop store | `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite` | 1:1 chats, group messages that mention you, and your own messages (so MessageSift knows what you answered). |
| WhatsApp preferences | `…/group.net.whatsapp.WhatsApp.shared/Library/Preferences/group.net.whatsapp.WhatsApp.shared.plist` | Only your own phone number and LID, to find mentions of you in groups. |

Databases are opened with `SQLITE_OPEN_READONLY`. Only the last 30 days are read.

## Services (network, optional)

Menu bar icon › **Services…** (MessageSift opens it on one service when you turn that source on).

| Service | What you enter | What is read |
| --- | --- | --- |
| Slack | User token (`xoxp-`) | Direct messages, mentions, thread replies |
| GitHub | Personal access token | Review requests, failed checks on your pull requests, mentions, assigned issues |
| GitLab | Server (default gitlab.com) and personal access token (`read_api`) | Review and approval requests, mentions, failed pipelines, assigned issues |
| Jira | Site URL, email, API token | Assigned open issues that are new, due soon or recently updated |
| Linear | Personal API key | Assigned issues, unread mentions and comments |
| Teams and Outlook | Your own Azure app (client ID) and a Microsoft sign-in | Teams chats, Outlook inbox |

- Before the first check of a service, the Connector asks to allow its host(s): `slack.com`, `api.github.com`, your
  GitLab server, your Jira site, `api.linear.app`, or `login.microsoftonline.com` and `graph.microsoft.com`.
- **Check and Save** keeps a key only when the service accepts it.
- Keys are kept in the Connector's own Keychain items (`com.dmikaya.MessageHub.Connector`). MessageSift never gets them.
- Read every 10 minutes, last 14 days. Items go into the same shared file, with their service as the source.
- A second small file, `connector-status.json`, tells MessageSift which services have a key and the last error
  (no keys, no content).

## What it writes

One file, in MessageSift's App Group folder:

`~/Library/Group Containers/5PMP974V72.com.dmikaya.MessageHub.store/connector-messages.json`

- The last 30 days, at most 3,000 items, newest first.
- Per item: id, source (`slack`, `whatsapp`, `otherApps`, `github`, `gitlab`, `jira`, `linear`, `teams`, `outlook`), sender, sender handle, title, text, date, read/answered/direct
  flags, conversation id, context (app name) and an app link (`whatsapp://`, `sgnl://`, …).
- Written atomically (MessageSift never sees half a file), every 3 minutes and a few seconds after the databases change.

Its own settings (Pause, chosen apps) are kept in its UserDefaults. It keeps no other copy of your data.

## Network: how to check

- All network code is in `Sources/Network/` (copied from MessageSift's readers). Every request goes through
  `NetworkGate` (`Sources/Network/NetworkGate.swift`), which refuses any host you have not allowed; a unit test checks
  that nothing goes out without consent.
- Without an allowed service, nothing in `Sources/Network/` sends anything. A firewall such as LuLu or Little Snitch, or `nettop`,
  shows no connections. With keys, it shows only the services you added.
- The app is not sandboxed (Full Disk Access needs that), so there is no network entitlement to look for. Its only
  entitlement is the App Group shared with MessageSift (`Sources/App/Connector.entitlements`).

## Full Disk Access

1. Open the Connector (menu bar icon › Open Window) and click **Open System Settings**.
2. In Privacy & Security › Full Disk Access, turn on **MessageSift Connector**.
3. Apps that never asked are not listed: click **+** below the list and choose MessageSift Connector in Applications,
   or drag it from the Finder window into the list.
4. Click **Restart Connector** when the window offers it.

The Connector checks access by really opening and reading the Notification Center database.

## Controls

- **Pause sharing:** no new writes; MessageSift keeps what was shared before.
- **Delete Shared Data:** removes `connector-messages.json` and pauses.
- **Other chat apps to share:** choose which apps' notifications are shared.
- **Open at login** (`SMAppService`).
- `"/Applications/MessageSift Connector.app/Contents/MacOS/MessageSift Connector" --status` prints Full Disk Access and the
  shared file's time and counts per source (no content).

## Build

Requires Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project MessageSiftConnector.xcodeproj -scheme MessageSiftConnector test
xcodebuild -project MessageSiftConnector.xcodeproj -scheme MessageSiftConnector -configuration Release -derivedDataPath build build
ditto "build/Build/Products/Release/MessageSift Connector.app" "/Applications/MessageSift Connector.app"
```

To build with your own Apple developer team, set `DEVELOPMENT_TEAM` in `project.yml` and run `xcodegen generate`.
The shared App Group (`5PMP974V72.com.dmikaya.MessageHub.store`) belongs to MessageSift's team: a build signed by
another team runs and can be audited, but macOS won't let it write into MessageSift's folder.

Tests use synthetic fixtures only (no real messages).

Releases: export the archive for Developer ID (Xcode › Organizer › Distribute App › Direct Distribution › Export),
then `Scripts/make_dmg.sh "/path/to/MessageSift Connector.app"`, notarize and staple the DMG (commands in the script),
and attach it to a GitHub release. `swift Scripts/make_icon.swift` redraws the app icon.

## Code

| File | Purpose |
| --- | --- |
| `Sources/Core/Readers.swift` | Paths, the Full Disk Access check (open + read one byte), read-only SQLite queries |
| `Sources/Core/NotificationParser.swift` | Notification plist → item |
| `Sources/Core/WhatsAppParser.swift` | WhatsApp rows → items |
| `Sources/Core/SharedMessage.swift` | The shared JSON format and the atomic write |
| `Sources/App/` | Menu bar and window UI, timer, file watching, Pause, Delete, open at login |

## Privacy

Everything stays on your Mac. The shared file is in MessageSift's App Group folder, which only apps of MessageSift's
developer team with that App Group can open. To remove everything: use Delete Shared Data, quit the Connector and move
it to the Trash.

## License

MIT, see [LICENSE](LICENSE).
