# MessageSift Connector

A small, free, open-source (MIT) helper for **MessageSift from the Mac App Store**.

App Store apps run in a sandbox, so MessageSift can't open macOS's Notification Center database or WhatsApp's
chat store. The Connector can, with Full Disk Access. It copies recent items into one file that MessageSift reads.
It runs as a menu bar app with a small status window.

- **Read-only:** it never writes to the databases it reads.
- **No network:** it makes no network connections of any kind.
- **No AI**, no analytics, no updates, no accounts.

## What it reads (read-only)

| Data | Path | What is used |
| --- | --- | --- |
| Notification Center database | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` | Notifications of Slack, WhatsApp and the chat apps you choose (default: Signal, Discord, Telegram, Teams): title, subtitle, text, time. Other apps' notifications are skipped. |
| WhatsApp desktop store | `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite` | 1:1 chats, group messages that mention you, and your own messages (so MessageSift knows what you answered). |
| WhatsApp preferences | `…/group.net.whatsapp.WhatsApp.shared/Library/Preferences/group.net.whatsapp.WhatsApp.shared.plist` | Only your own phone number and LID, to find mentions of you in groups. |

Databases are opened with `SQLITE_OPEN_READONLY`. Only the last 30 days are read.

## What it writes

One file, in MessageSift's App Group folder:

`~/Library/Group Containers/5PMP974V72.com.dmikaya.MessageHub.store/connector-messages.json`

- The last 30 days, at most 3,000 items, newest first.
- Per item: id, source (`slack`, `whatsapp`, `otherApps`), sender, sender handle, title, text, date, read/answered/direct
  flags, conversation id, context (app name) and an app link (`whatsapp://`, `sgnl://`, …).
- Written atomically (MessageSift never sees half a file), every 3 minutes and a few seconds after the databases change.

Its own settings (Pause, chosen apps) are kept in its UserDefaults. It keeps no other copy of your data.

## No network: how to check

- The code has no networking: `grep -rnE "URLSession|NWConnection|CFStream|socket\(|https?://" --include='*.swift' Sources`
  finds nothing.
- The app is not sandboxed (Full Disk Access needs that), so there is no network entitlement to look for. Its only
  entitlement is the App Group shared with MessageSift (`Sources/App/Connector.entitlements`).
- At run time, a firewall such as LuLu or Little Snitch, or `nettop`, shows no connections.

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
