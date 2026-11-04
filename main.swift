// agent-notify: one notification layer for every agent tool on this Mac.
//
//   agent-notify post  --source TOOL --title "what happened" --message TEXT
//                      [--key KEY] [--urgency low|normal|urgent] [--sound]
//                      [--if-new] [--open https://... | --run /abs/exe args...] [--activate BUNDLE_ID]
//   agent-notify clear --source TOOL --key KEY          withdraw a notice once it is resolved
//   agent-notify run   --source TOOL --title WHAT -- /cmd args...   run it, then report the result
//   agent-notify hook  claude|codex                      harness hooks (JSON on stdin / last arg)
//   agent-notify list  [--json]                          recent history
//   (post takes --expire SECONDS: notices remove themselves after 5 min by default; 0 = never)
//   agent-notify status [--open-settings]                permission and banner style (persistent?)
//
// One design: every notice is titled "<Tool> · <what happened>", grouped per tool, with at most
// one action (open an http(s) URL, or run one program by absolute path, then optionally bring an
// app forward). The action travels inside the notice, so a click works after this process exits:
// macOS relaunches the app and hands it the click. Nothing else in a notice is ever executed.
//
// Anti-spam (balanced): a notice with the same --key replaces the earlier one instead of
// stacking; clear withdraws it; each tool gets at most 3 non-urgent notices per 10 minutes and
// the rest fold into one "N more" notice; urgent notices always show.
//
// The older form (--title T --message M [--subtitle S] [--open|--run] [--activate]) still works:
// the first word of the title is taken as the tool.

import Cocoa
import UserNotifications

let window: TimeInterval = 600
// Notices stay on screen (persistent alerts) but tidy themselves away after this long.
// --expire SECONDS per notice, AGENT_NOTIFY_EXPIRE for everything; 0 keeps them until dismissed.
let defaultExpire = TimeInterval(ProcessInfo.processInfo.environment["AGENT_NOTIFY_EXPIRE"] ?? "") ?? 300
let perWindow = 3
let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/agent-notify")
let displayNames = ["claude": "Claude Code", "codex": "Codex", "agent-vault": "agent-vault",
                    "browserctrl": "browserctrl", "scripts": "Scripts"]
let terminalBundles = ["iTerm.app": "com.googlecode.iterm2", "Apple_Terminal": "com.apple.Terminal",
                       "WarpTerminal": "dev.warp.Warp-Stable", "ghostty": "com.mitchellh.ghostty",
                       "vscode": "com.microsoft.VSCode"]

// Schemes a click may open: web pages, and the Codex app's thread links (codex://threads/<id>).
let openSchemes: Set<String> = ["https", "http", "codex"]

// ITERM_SESSION_ID looks like "w0t4p0:9053558D-36ED-4F77-94C8-AD5C6AB3BEC7"; AppleScript knows the UUID.
func itermSessionUUID(_ id: String) -> String { String(id.split(separator: ":").last ?? "") }
func validItermSession(_ id: String) -> Bool {
    itermSessionUUID(id).range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil
}

// Every kind of notice has its own badge (drawn by badges.swift), its own system sound and a
// handful of title lines, picked at random so the same event doesn't read the same way twice.
// The voice: Gen Z internet slang by default (still readable at a glance), or plain with
// AGENT_NOTIFY_VOICE=plain. `say(slang, plain)` picks.
let plainVoice = ProcessInfo.processInfo.environment["AGENT_NOTIFY_VOICE"] == "plain"
func say<T>(_ slang: T, _ plain: T) -> T { plainVoice ? plain : slang }

struct Kind { let sound: String?; let titles: [String] }
let kinds: [String: Kind] = [
    "claude-waiting":    Kind(sound: "Pop", titles: say(
        ["👋 Claude's done, ur turn bestie", "👀 Claude is waiting on u fr", "☕️ Claude finished, ball's in ur court ngl",
         "🫵 ur move, Claude is just sitting there"],
        ["👋 Claude is waiting for you", "👋 Claude finished and it's your turn", "☕️ Claude is ready for you"])),
    "claude-permission": Kind(sound: "Hero", titles: say(
        ["🙋 Claude needs ur OK, no cap", "🙏 Claude won't move without ur blessing", "✋ Claude is asking permission rn",
         "🥺 Claude needs a yes from u fr"],
        ["🙋 Claude needs your OK to continue", "🙋 Claude is asking permission", "✋ Claude is paused for your OK"])),
    "codex-done":        Kind(sound: "Glass", titles: say(
        ["🎉 Codex ate that turn", "💅 Codex is done, it's giving shipped", "✅ Codex finished, ur move bestie",
         "🔥 Codex cooked, come look"],
        ["🎉 Codex finished its turn", "✅ Codex is done, your turn", "🎉 Codex wrapped up, over to you"])),
    "browser-handoff":   Kind(sound: "Submarine", titles: []),
    "browser-signin":    Kind(sound: "Submarine", titles: []),
    "browser-debug":     Kind(sound: "Submarine", titles: []),
    "vault-approval":    Kind(sound: "Purr", titles: []),
    "run-ok":            Kind(sound: "Ping", titles: []),
    "run-failed":        Kind(sound: "Basso", titles: []),
    "pile":              Kind(sound: nil, titles: []),
    "bell":              Kind(sound: "Tink", titles: []),
]
let sourceEmoji = ["claude": "🧡", "codex": "🤖", "browserctrl": "🌐", "agent-vault": "🗝️", "scripts": "⚙️"]

func pickTitle(_ kind: String, project: String?, _ fallback: String) -> String {
    let template = kinds[kind]?.titles.randomElement() ?? fallback
    return template.replacingOccurrences(of: "{p}", with: project.map { " in \($0)" } ?? "")
}

// The kind of a notice, when its sender didn't say: guessed from the tool and the title.
func inferKind(_ n: Notice) -> String {
    let t = n.title.lowercased()
    switch n.source {
    case "claude": return t.contains("permission") || n.urgency == "urgent" ? "claude-permission" : "claude-waiting"
    case "codex": return "codex-done"
    case "browserctrl":
        if t.contains("debugging") || t.contains("allow") { return "browser-debug" }
        if t.contains("sign") || t.contains("log in") || t.contains("login") { return "browser-signin" }
        return "browser-handoff"
    case "agent-vault": return "vault-approval"
    default:
        if t.contains("failed") { return "run-failed" }
        if t.contains("flopped") || t.contains("took an l") { return "run-failed" }
        if t.contains("finished") || t.contains("slay") || t.contains("took the w") { return "run-ok" }
        return "bell"
    }
}

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(("agent-notify: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

// MARK: - Requests

struct Notice {
    var source = "agent"
    var title = ""
    var message = ""
    var key: String?
    var urgency = "normal"
    var sound = false
    var ifNew = false
    var kind: String?
    var subtitle: String?
    var expire: TimeInterval = defaultExpire
    var buttons: [[String: Any]]?          // nil = the kind's defaults; [] = no buttons
    var action: [String: Any] = [:]
    var identifier: String { "\(source):\(key ?? UUID().uuidString)" }
    var display: String { displayNames[source] ?? source }
}

func validSource(_ s: String) -> Bool { s.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil }

func parseNotice(_ args: [String], legacy: Bool) -> Notice {
    var n = Notice()
    var subtitle: String?
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--source": n.source = value()
        case "--title": n.title = value()
        case "--message": n.message = value()
        case "--subtitle": subtitle = value()
        case "--kind":
            let k = value()
            guard kinds[k] != nil else { fail("--kind is one of: \(kinds.keys.sorted().joined(separator: ", "))") }
            n.kind = k
        case "--key": n.key = value()
        case "--urgency":
            n.urgency = value()
            guard ["low", "normal", "urgent"].contains(n.urgency) else { fail("--urgency is low, normal or urgent") }
        case "--sound": n.sound = true
        case "--button":
            if n.buttons == nil { n.buttons = [] }
            n.buttons!.append(parseButton(value()))
            guard n.buttons!.count <= 3 else { fail("at most 3 --button") }
        case "--no-buttons": n.buttons = []
        case "--expire":
            guard let secs = TimeInterval(value()), secs >= 0 else { fail("--expire takes seconds (0 = never)") }
            n.expire = secs
        case "--if-new": n.ifNew = true
        case "--activate": n.action["activate"] = value()
        case "--iterm-session":
            let id = value()
            guard validItermSession(id) else { fail("--iterm-session takes an iTerm2 session id (ITERM_SESSION_ID)") }
            n.action["iterm"] = itermSessionUUID(id)
        case "--open":
            let url = value()
            guard let u = URL(string: url), openSchemes.contains(u.scheme ?? "") else { fail("--open takes an http(s) or codex:// URL") }
            n.action["open"] = url
        case "--run":
            let argv = Array(args[(i + 1)...])
            guard let exe = argv.first, exe.hasPrefix("/") else { fail("--run takes an absolute program path") }
            n.action["run"] = argv
            i = args.count
            continue
        default: fail("unknown argument \(args[i])")
        }
        i += 1
    }
    if legacy {
        // "agent-vault approval" -> tool agent-vault, "Approval"; the subtitle was the detail line.
        let words = n.title.split(separator: " ", maxSplits: 1).map(String.init)
        if let first = words.first, validSource(first.lowercased()) { n.source = first.lowercased() }
        n.title = words.count > 1 ? words[1].prefix(1).uppercased() + words[1].dropFirst() : "Notice"
        if let subtitle = subtitle { n.message = subtitle + " — " + n.message }
        if n.sound { n.urgency = "urgent" }
    } else {
        n.subtitle = subtitle.map { String($0.prefix(80)) }
    }
    guard validSource(n.source) else { fail("--source is lowercase letters, digits and dashes, up to 32") }
    guard !n.title.isEmpty, !n.message.isEmpty else { fail("--title and --message are required") }
    if let key = n.key, key.count > 120 { fail("--key is at most 120 characters") }
    n.title = String(n.title.prefix(80))
    n.message = String(n.message.prefix(400))
    return n
}

// MARK: - State (anti-spam) and history, under one file lock

struct State: Codable {
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = try c.decodeIfPresent([String: [Double]].self, forKey: .sent) ?? [:]
        folded = try c.decodeIfPresent([String: Int].self, forKey: .folded) ?? [:]
        active = try c.decodeIfPresent([String: Double].self, forKey: .active) ?? [:]
        expiry = try c.decodeIfPresent([String: String].self, forKey: .expiry) ?? [:]
    }
    var sent: [String: [Double]] = [:]      // source -> times of counted notices in the window
    var folded: [String: Int] = [:]         // source -> notices folded into "N more"
    var active: [String: Double] = [:]      // identifier -> time posted (for replace-not-count)
    var expiry: [String: String] = [:]      // identifier -> stamp of the timer allowed to remove it
}

func withState<T>(_ body: (inout State) -> T) -> T {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let lockFd = open(stateDir + "/state.lock", O_RDWR | O_CREAT, 0o600)
    if lockFd >= 0 { flock(lockFd, LOCK_EX) }
    defer { if lockFd >= 0 { flock(lockFd, LOCK_UN); close(lockFd) } }
    let path = stateDir + "/state.json"
    var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: path)))) ?? State()
    let result = body(&state)
    if let data = try? JSONEncoder().encode(state) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o600)
    }
    return result
}

func record(_ entry: [String: Any]) {
    let path = stateDir + "/history.jsonl"
    var line = entry
    let stamp = ISO8601DateFormatter()
    stamp.timeZone = .current
    line["at"] = stamp.string(from: Date())
    guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 1 << 20 {
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data + "\n".data(using: .utf8)!)
        handle.closeFile()
    }
}

enum Decision { case show, replace, fold(Int), skip }

func decide(_ n: Notice) -> Decision {
    let now = Date().timeIntervalSince1970
    return withState { state in
        state.sent[n.source] = (state.sent[n.source] ?? []).filter { now - $0 < window }
        state.active = state.active.filter { now - $0.value < 86400 }
        if state.sent[n.source]!.isEmpty { state.folded[n.source] = 0 }
        let id = n.key.map { "\(n.source):\($0)" }
        if let id = id, state.active[id] != nil {
            if n.ifNew { return .skip }   // already showing: don't alert again
            state.active[id] = now
            return .replace   // the same event again: replace, don't count
        }
        if n.urgency == "urgent" || state.sent[n.source]!.count < perWindow {
            state.sent[n.source]!.append(now)
            if let id = id { state.active[id] = now }
            return .show
        }
        let count = (state.folded[n.source] ?? 0) + 1
        state.folded[n.source] = count
        return .fold(count)
    }
}

func forget(_ identifier: String) {
    _ = withState { state in state.active.removeValue(forKey: identifier) }
}

// MARK: - Posting

// The badge for a kind, copied out of the app (macOS moves an attachment into its own store).
func badgeAttachment(_ kind: String) -> [UNNotificationAttachment] {
    guard let src = Bundle.main.url(forResource: kind, withExtension: "png", subdirectory: "badges") else { return [] }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-notify-\(UUID().uuidString).png")
    guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil,
          let a = try? UNNotificationAttachment(identifier: "badge", url: tmp, options: nil) else { return [] }
    return [a]
}

// MARK: - Buttons
//
// A button is {type, label, target?}. Types: go (the notice's own click target), snooze (back in
// 10 min), reply (type into the notice's iTerm pane), open (a URL), run (a program by absolute path).
//   --button go | snooze | reply            a preset with its default label
//   --button "go=👀 Review the diff"         a preset with your own label
//   --button "🚀 Open MR=https://…"          a labelled URL (http, https, codex)
//   --button "🔁 Rerun=/abs/script arg"      a labelled program (absolute path, space-separated args)
// macOS shows the first button on hover and the rest under Options.

let presetLabels = say(["go": "👉 Take me there", "snooze": "😴 Remind me in 10", "reply": "💬 Reply"],
                       ["go": "👉 Take me there", "snooze": "😴 Remind me in 10 min", "reply": "💬 Reply"])

func parseButton(_ spec: String) -> [String: Any] {
    let parts = spec.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
    if let label = presetLabels[parts[0]] {
        return ["type": parts[0], "label": parts.count > 1 && !parts[1].isEmpty ? String(parts[1].prefix(40)) : label]
    }
    guard parts.count == 2, !parts[0].isEmpty else { fail("--button is go|snooze|reply[=Label] or \"Label=URL\" or \"Label=/abs/program args\"") }
    let label = String(parts[0].prefix(40)), target = parts[1]
    if target.hasPrefix("/") {
        return ["type": "run", "label": label, "target": target.split(separator: " ").map(String.init)]
    }
    guard let u = URL(string: target), openSchemes.contains(u.scheme ?? "") else { fail("--button target must be an http(s)/codex URL or an absolute program path") }
    return ["type": "open", "label": label, "target": target]
}

// What a notice gets when its sender doesn't choose: the click target under a label that says
// where it goes, a reply box for a waiting Claude in iTerm2, and a 10-minute reminder.
func defaultButtons(_ n: Notice, kind: String) -> [[String: Any]] {
    guard !n.action.isEmpty else { return [] }
    let opensCodex = (n.action["open"] as? String)?.hasPrefix("codex:") ?? false
    let go: String
    switch kind {
    case "claude-permission": go = say("👀 Lemme see", "👀 Review it")
    case "codex-done": go = opensCodex ? say("💬 Open the chat", "💬 Open conversation") : "👉 Take me there"
    case "browser-handoff", "browser-signin", "browser-debug": go = "🧭 Open the tab"
    case "vault-approval": go = say("🔐 Check the request", "🔐 Review request")
    case "run-failed": go = say("🔍 Show me what broke", "🔍 Show me")
    default: go = "👉 Take me there"
    }
    var list: [[String: Any]] = []
    if kind == "claude-waiting" && n.action["iterm"] != nil { list.append(["type": "reply", "label": say("💬 Slide into Claude's replies", "💬 Reply to Claude")]) }
    list.append(["type": "go", "label": go])
    list.append(["type": "snooze", "label": presetLabels["snooze"]!])
    return list
}

// macOS needs every set of buttons registered as a category before a notice can use it, and
// registering replaces the whole list, so the sets seen so far are kept (newest 64) and
// re-registered together.
func categoryId(_ buttons: [[String: Any]]) -> String {
    var h: UInt64 = 5381
    for b in buttons { for ch in "\(b["type"] ?? ""):\(b["label"] ?? "")|".utf8 { h = (h &* 33) ^ UInt64(ch) } }
    return "b-\(String(h, radix: 36))"
}

func registerCategories(adding buttons: [[String: Any]]? = nil) -> String? {
    let path = stateDir + "/categories.json"
    var known = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [[String: Any]]) ?? []
    var id: String?
    if let buttons = buttons, !buttons.isEmpty {
        let cid = categoryId(buttons)
        id = cid
        let shape = buttons.map { ["type": $0["type"] ?? "", "label": $0["label"] ?? ""] }
        known.removeAll { ($0["id"] as? String) == cid }
        known.append(["id": cid, "buttons": shape])
        known = Array(known.suffix(64))
        if let data = try? JSONSerialization.data(withJSONObject: known) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
    let icons = ["go": "arrow.up.forward.app", "snooze": "moon.zzz", "reply": "text.bubble", "open": "link", "run": "play.circle"]
    var categories: Set<UNNotificationCategory> = [UNNotificationCategory(identifier: "notice", actions: [], intentIdentifiers: [])]
    for entry in known {
        guard let cid = entry["id"] as? String, let list = entry["buttons"] as? [[String: Any]] else { continue }
        let actions: [UNNotificationAction] = list.enumerated().map { i, b in
            let type = b["type"] as? String ?? "go", label = b["label"] as? String ?? "Open"
            let icon = UNNotificationActionIcon(systemImageName: icons[type] ?? "circle")
            if type == "reply" {
                return UNTextInputNotificationAction(identifier: "btn\(i)", title: label, options: [], icon: icon,
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "Type your reply…")
            }
            return UNNotificationAction(identifier: "btn\(i)", title: label, options: type == "snooze" ? [] : [.foreground], icon: icon)
        }
        categories.insert(UNNotificationCategory(identifier: cid, actions: actions, intentIdentifiers: []))
    }
    UNUserNotificationCenter.current().setNotificationCategories(categories)
    return id
}

func content(for n: Notice) -> UNMutableNotificationContent {
    let kind = n.kind ?? inferKind(n)
    let c = UNMutableNotificationContent()
    let startsWithEmoji = n.title.unicodeScalars.first.map { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF } ?? false
    c.title = startsWithEmoji ? n.title : "\(sourceEmoji[n.source] ?? "✨") \(n.title)"
    if let subtitle = n.subtitle { c.subtitle = subtitle }   // real context only (the project); the emoji says which tool
    c.body = n.message
    // One group per session/thread/event, not per tool: macOS stacks a group, and the first click
    // on a stack only expands it, so per-tool groups made clicks look like they did nothing.
    c.threadIdentifier = n.key.map { "\(n.source):\($0)" } ?? n.source
    // Buttons that need something the notice lacks are dropped (reply without an iTerm pane).
    let buttons = (n.buttons ?? defaultButtons(n, kind: kind)).filter { b in
        switch b["type"] as? String {
        case "reply": return n.action["iterm"] != nil
        case "go": return !n.action.isEmpty
        default: return true
        }
    }
    var info = n.action
    info["kind"] = kind
    info["buttons"] = buttons
    c.userInfo = info
    c.attachments = badgeAttachment(kind)
    c.categoryIdentifier = registerCategories(adding: buttons) ?? "notice"
    let sound = kinds[kind]?.sound.map { UNNotificationSound(named: UNNotificationSoundName("\($0).aiff")) }
    switch n.urgency {
    case "low": c.interruptionLevel = .passive
    case "urgent": c.interruptionLevel = .active; c.sound = sound ?? .default; c.relevanceScore = 1
    default: c.interruptionLevel = .active; c.sound = sound; c.relevanceScore = 0.5
    }
    if n.sound && c.sound == nil { c.sound = .default }
    return c
}

func post(_ n: Notice, done: @escaping (Int32) -> Void) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { fail("notifications are not allowed for Agent Notify (System Settings > Notifications)", 3) }
        let decision = decide(n)
        var request: UNNotificationRequest
        var outcome: String
        if case .skip = decision {
            print("skipped")
            done(0)
            return
        }
        switch decision {
        case .skip: return
        case .fold(let count):
            let summary = Notice(source: n.source, title: say("📚 \(count) more from \(n.display), u were busy fr", "📚 \(count) more from \(n.display) while you were away"),
                                 message: say("Latest drop: \(n.title). \(n.message)", "The latest one: \(n.title). \(n.message)"), key: "__more", urgency: "low", kind: "pile",
                                 action: n.action)
            request = UNNotificationRequest(identifier: "\(n.source):__more", content: content(for: summary), trigger: nil)
            outcome = "folded"
        case .replace:
            request = UNNotificationRequest(identifier: n.identifier, content: content(for: n), trigger: nil)
            outcome = "replaced"
        case .show:
            request = UNNotificationRequest(identifier: n.identifier, content: content(for: n), trigger: nil)
            outcome = "posted"
        }
        center.add(request) { error in
            if let error = error { fail("\(error)", 4) }
            record(["source": n.source, "key": n.key ?? "", "title": n.title, "urgency": n.urgency, "outcome": outcome,
                    "action": n.action])
            if n.expire > 0 { scheduleExpiry(request.identifier, after: n.expire) }
            print(outcome)
            done(0)
        }
    }
}

// A small detached helper waits, then removes the notice, unless it was re-posted meanwhile
// (a newer post of the same key gets its own timer).
func scheduleExpiry(_ id: String, after seconds: TimeInterval) {
    let stamp = String(Date().timeIntervalSince1970)
    _ = withState { state in state.expiry[id] = stamp }
    guard let exe = Bundle.main.executableURL else { return }
    let p = Process()
    p.executableURL = exe
    p.arguments = ["expire", id, stamp, String(seconds)]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

func expire(_ id: String, stamp: String, after seconds: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        let current = withState { state -> Bool in
            guard state.expiry[id] == stamp else { return false }
            state.expiry.removeValue(forKey: id)
            state.active.removeValue(forKey: id)
            return true
        }
        guard current else { exit(0) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        record(["source": String(id.split(separator: ":").first ?? ""),
                "key": String(id.split(separator: ":", maxSplits: 1).last ?? ""), "outcome": "expired"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}

func clear(source: String, key: String, done: @escaping (Int32) -> Void) {
    let id = "\(source):\(key)"
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [id])
    center.removePendingNotificationRequests(withIdentifiers: [id])
    forget(id)
    record(["source": source, "key": key, "outcome": "cleared"])
    // Removal is asynchronous inside Notification Center; give it a moment before exiting.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("cleared"); done(0) }
}

// MARK: - Click handling

func runAction(_ info: [AnyHashable: Any]) {
    if let url = info["open"] as? String, let u = URL(string: url), openSchemes.contains(u.scheme ?? "") {
        NSWorkspace.shared.open(u)
    }
    if let session = info["iterm"] as? String, validItermSession(session) {
        focusItermSession(session)
    }
    if let argv = info["run"] as? [String], let exe = argv.first, exe.hasPrefix("/") {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = Array(argv.dropFirst())
        if (try? process.run()) != nil { process.waitUntilExit() }
    }
    if let bundle = info["activate"] as? String,
       let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }
}

// Bring the iTerm2 window, tab and split pane that hold this session to the front. The first
// time, macOS asks once whether Agent Notify may control iTerm2.
func focusItermSession(_ uuid: String) {
    let source = """
    tell application id "com.googlecode.iterm2"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if unique id of s is "\(uuid)" then
              tell w to select
              tell t to select
              tell s to select
              activate
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell
    """
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error = error { record(["outcome": "focus-failed", "source": "iterm", "key": "\(error[NSAppleScript.errorNumber] ?? "")"]) }
}

// Quick reply: type the text into that iTerm2 session and press Return, as if typed there.
func typeIntoItermSession(_ uuid: String, _ text: String) {
    let line = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let source = """
    tell application id "com.googlecode.iterm2"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if unique id of s is "\(uuid)" then
              tell s to write text "\(line)"
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell
    """
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error = error { record(["outcome": "reply-failed", "source": "iterm", "key": "\(error[NSAppleScript.errorNumber] ?? "")"]) }
}

// MARK: - Harness hooks

func terminalBundle(_ env: [String: String]) -> String? {
    if let b = env["__CFBundleIdentifier"], !b.isEmpty { return b }
    return env["TERM_PROGRAM"].flatMap { terminalBundles[$0] }
}

// The last text Claude wrote in a session, from the end of its transcript (JSONL), on one line.
func lastClaudeText(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 400_000 ? size - 400_000 : 0)
    let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    for line in tail.split(separator: "\n").reversed() {
        guard line.contains("\"assistant\""),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let parts = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        if let text = parts.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
            let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
            guard !flat.isEmpty else { continue }
            return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
        }
    }
    return nil
}

func hookNotice(_ harness: String, _ args: [String]) -> Notice {
    let env = ProcessInfo.processInfo.environment
    var n = Notice()
    if let bundle = terminalBundle(env) { n.action["activate"] = bundle }
    // A harness running in iTerm2: a click lands on its exact tab and pane.
    if let session = env["ITERM_SESSION_ID"], validItermSession(session) { n.action["iterm"] = itermSessionUUID(session) }
    switch harness {
    case "claude":
        // Claude Code's Notification hook: {"session_id", "cwd", "message", ...} on stdin.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = (json["message"] as? String) ?? "Claude Code is waiting"
        let project = ((json["cwd"] as? String) as NSString?)?.lastPathComponent ?? ""
        n.source = "claude"
        n.key = (json["session_id"] as? String).map { "session-\($0)" }
        let permission = message.lowercased().contains("permission")
        n.kind = permission ? "claude-permission" : "claude-waiting"
        n.title = pickTitle(n.kind!, project: nil, "Claude is waiting for you")
        n.subtitle = project.isEmpty ? nil : "in \(project)"
        n.urgency = permission ? "urgent" : "normal"
        let hint = n.action["iterm"] == nil ? say("Tap in to switch to it.", "Click to switch to it.")
            : permission ? say("Tap in to jump to its iTerm tab and decide.", "Click to jump to its iTerm tab and decide.")
            : say("Tap in to jump to its iTerm tab, or reply right here.", "Click to jump to its iTerm tab, or reply right here.")
        // Quote what Claude actually last said, not Claude Code's generic "waiting for your input".
        if !permission, let said = (json["transcript_path"] as? String).flatMap(lastClaudeText) {
            n.message = "“\(said)”"   // the quote speaks for itself; the buttons say where a click goes
        } else {
            n.message = "\(message.hasSuffix(".") ? message : message + ".") \(hint)"
        }
    case "codex":
        // Codex notify: the JSON payload is the last argument.
        let json = (args.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] ?? [:]
        guard (json["type"] as? String) == "agent-turn-complete" else { exit(0) }
        let last = (json["last-assistant-message"] as? String) ?? "Turn finished"
        let project = ((json["cwd"] as? String) as NSString?)?.lastPathComponent
        n.source = "codex"
        let thread = json["thread-id"] as? String
        n.key = thread.map { "thread-\($0)" } ?? "turn"
        // The Codex app (or a CLI run outside iTerm2): a click opens that conversation in the app.
        let inApp = env["__CFBundleIdentifier"] == "com.openai.codex" || env["BROWSER_USE_CODEX_APP_VERSION"] != nil
        if let thread = thread, thread.range(of: "^[0-9A-Za-z-]{1,80}$", options: .regularExpression) != nil,
           inApp || n.action["iterm"] == nil {
            n.action = ["open": "codex://threads/\(thread)", "activate": "com.openai.codex"]
        }
        // (no click hint after the quote: the buttons say where it goes)
        n.kind = "codex-done"
        n.title = pickTitle("codex-done", project: nil, "Codex finished its turn")
        n.subtitle = project.map { "in \($0)" }
        let said = last.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        n.message = "“\(said.count > 220 ? said.prefix(220) + "…" : Substring(said))”"
    default: fail("hook takes claude or codex")
    }
    n.message = String(n.message.prefix(400))
    return n
}

// MARK: - run: report a long-running command

func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

func runCommand(_ args: [String]) -> (Notice, Int32) {
    guard let split = args.firstIndex(of: "--") else { fail("run needs -- before the command") }
    var n = parseNotice(Array(args[..<split]) + ["--message", "-"], legacy: false)
    let command = Array(args[(split + 1)...])
    guard let exe = command.first else { fail("run needs a command after --") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe.hasPrefix("/") ? exe : "/usr/bin/env")
    process.arguments = exe.hasPrefix("/") ? Array(command.dropFirst()) : command
    let started = Date()
    do { try process.run() } catch { fail("cannot run \(exe): \(error.localizedDescription)", 127) }
    process.waitUntilExit()
    let took = duration(Date().timeIntervalSince(started))
    let code = process.terminationStatus
    let what = n.title
    n.key = n.key ?? "run-\(what)"
    n.kind = code == 0 ? "run-ok" : "run-failed"
    n.title = code == 0 ? say("🚀 \(what) finished, slay", "🚀 \(what) finished") : say("💥 \(what) flopped 💀", "💥 \(what) failed")
    n.message = code == 0 ? say("Took \(took), clean exit. Big W 😎", "All good. It took \(took) and exited cleanly. 😎")
                          : say("Exit code \(code) after \(took). Not the vibe 😬 Click to see what broke 🔍",
                                "It stopped with exit code \(code) after \(took). Click to see the output in your terminal. 🔍")
    if code != 0 { n.sound = true }
    if n.action["activate"] == nil, let bundle = terminalBundle(ProcessInfo.processInfo.environment) { n.action["activate"] = bundle }
    return (n, code)
}

// MARK: - list

func list(json: Bool) {
    let path = stateDir + "/history.jsonl"
    let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").suffix(30)
    for line in lines {
        if json { print(line); continue }
        guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        let at = (entry["at"] as? String ?? "").replacingOccurrences(of: "T", with: " ").prefix(19)
        print("\(at)  \(entry["outcome"] ?? "")  \(entry["source"] ?? ""): \(entry["title"] ?? entry["key"] ?? "")")
    }
}

// MARK: - status: is Agent Notify allowed, and do its notices stay on screen?

func status(openSettings: Bool) {
    UNUserNotificationCenter.current().getNotificationSettings { s in
        let auth = [UNAuthorizationStatus.notDetermined: "not asked yet", .denied: "denied",
                    .authorized: "allowed", .provisional: "provisional"][s.authorizationStatus] ?? "other"
        let style = [UNAlertStyle.none: "none (Notification Center only)", .banner: "temporary banners (hide after ~5s)",
                     .alert: "persistent (stay until dismissed)"][s.alertStyle] ?? "unknown"
        print("notifications: \(auth)\nstyle: \(style)")
        if s.alertStyle != .alert {
            print("To keep notices on screen: System Settings > Notifications > Agent Notify > set style to Persistent (Alerts).")
        }
        if openSettings {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.seahyc.agent-notify")!)
        }
        exit(s.alertStyle == .alert ? 0 : 1)
    }
}

// MARK: - App

// A click relaunches the app with no arguments; only then does handling it end the process.
var launchedForClick = false

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // The click that launched the app is delivered right at launch: listen before it finishes.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        _ = center
        _ = registerCategories()
        var args = Array(CommandLine.arguments.dropFirst())
        let finish: (Int32) -> Void = { code in exit(code) }
        guard let command = args.first else {
            // Relaunched by a click: the response arrives through the delegate.
            launchedForClick = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
            return
        }
        switch command {
        case "post":
            args.removeFirst()
            post(parseNotice(args, legacy: false), done: finish)
        case "clear":
            args.removeFirst()
            let n = parseNotice(args + ["--title", "-", "--message", "-"], legacy: false)
            guard let key = n.key else { fail("clear needs --key") }
            clear(source: n.source, key: key, done: finish)
        case "run":
            args.removeFirst()
            let (n, code) = runCommand(args)
            post(n) { _ in exit(code) }
        case "hook":
            args.removeFirst()
            guard let harness = args.first else { fail("hook takes claude or codex") }
            post(hookNotice(harness, args)) { _ in exit(0) }
        case "list":
            list(json: args.contains("--json"))
            exit(0)
        case "expire":
            guard args.count == 4, let secs = TimeInterval(args[3]) else { exit(2) }
            expire(args[1], stamp: args[2], after: secs)
        case "status":
            status(openSettings: args.contains("--open-settings"))
        case "--help", "-h", "help":
            print("usage: agent-notify post|clear|run|hook|list|status ... (see ~/Code/agent-notify/README.md)")
            exit(0)
        default:
            guard args.contains("--title") else { fail("unknown command \(command)") }
            post(parseNotice(args, legacy: true), done: finish)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let request = response.notification.request
        let id = request.identifier
        let entry = { (outcome: String) in
            record(["source": String(id.split(separator: ":").first ?? ""),
                    "key": String(id.split(separator: ":", maxSplits: 1).last ?? ""), "outcome": outcome])
        }
        let info = request.content.userInfo
        var action = response.actionIdentifier
        var button: [String: Any] = [:]
        if action.hasPrefix("btn"), let i = Int(action.dropFirst(3)), let list = info["buttons"] as? [[String: Any]], i < list.count {
            button = list[i]
            action = button["type"] as? String ?? "go"
        }
        switch action {
        case "open" where button["target"] != nil:
            if let url = button["target"] as? String, let u = URL(string: url), openSchemes.contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
            forget(id)
            entry("clicked: \(button["label"] ?? "")")
        case "run":
            if let argv = button["target"] as? [String], let exe = argv.first, exe.hasPrefix("/") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = Array(argv.dropFirst())
                try? p.run()
            }
            forget(id)
            entry("clicked: \(button["label"] ?? "")")
        case UNNotificationDefaultActionIdentifier, "open", "go":
            runAction(request.content.userInfo)
            forget(id)
            entry("clicked")
        case "snooze":
            // Hand it back to macOS with a 10-minute timer; it comes back even though this app exits.
            let c = request.content.mutableCopy() as! UNMutableNotificationContent
            if !c.title.hasPrefix("⏰") { c.title = say("⏰ Back again: ", "⏰ Reminder: ") + c.title }
            c.attachments = badgeAttachment(request.content.userInfo["kind"] as? String ?? "bell")
            let again = UNNotificationRequest(identifier: id, content: c,
                                              trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
            entry("snoozed")
            center.add(again) { _ in done(); if launchedForClick { exit(0) } }
            return
        case "reply":
            if let text = (response as? UNTextInputNotificationResponse)?.userText,
               let session = request.content.userInfo["iterm"] as? String, validItermSession(session) {
                typeIntoItermSession(session, text)
                forget(id)
                entry("replied")
            }
        default: break
        }
        done()
        if launchedForClick { exit(0) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
