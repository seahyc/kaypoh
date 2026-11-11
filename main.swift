// agent-notify: one notification layer for every coding agent on this Mac.
//
//   agent-notify post   --source TOOL --title "what happened" --message TEXT [options]
//   agent-notify clear  --source TOOL --key KEY          withdraw a notice once it is resolved
//   agent-notify run    --source TOOL --title WHAT -- /cmd args...   run it, then report the result
//   agent-notify hook   claude|codex                     harness hooks (JSON on stdin / last arg)
//   agent-notify install [--claude] [--codex] [--dry-run] / uninstall   wire the hooks in
//   agent-notify voice  [NAME]                           list persona packs, or pick one
//   agent-notify demo   [KIND...]                        post sample notices in the current voice
//   agent-notify list   [--json]                         recent history
//   agent-notify status [--open-settings]                permission, banner style, hooks
//
// One design: every notice says who and what, carries its own click target (open a URL, focus an
// iTerm2 pane or tmux pane, run one program by absolute path, then bring an app forward), and the
// target travels inside the notice, so a click works after this process exits: macOS relaunches
// the app and hands it the click. Nothing else in a notice is ever executed.
//
// Anti-spam: a notice with the same --key replaces the earlier one instead of stacking; clear
// withdraws it; each tool gets at most 3 non-urgent notices per 10 minutes and the rest fold into
// one "N more" notice; urgent notices always show; agent turns shorter than 20 s don't notify.
//
// The copy (titles, buttons, summary lines) comes from a persona pack: personas/*.json in the
// app, or ~/.config/agent-notify/personas/NAME.json.

import Cocoa
import UserNotifications

let appName = "agent-notify"
let appDisplayName = "Agent Notify"
let bundleId = "com.seahyc.agent-notify"
let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

let env = ProcessInfo.processInfo.environment
let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
let stateDir = (home as NSString).appendingPathComponent(".local/state/\(appName)")
let configDir = env["XDG_CONFIG_HOME"].map { ($0 as NSString).appendingPathComponent(appName) }
    ?? (home as NSString).appendingPathComponent(".config/\(appName)")
let dryRun = env["AGENT_NOTIFY_DRY_RUN"] == "1" || CommandLine.arguments.contains("--dry-run")

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(("\(appName): " + message + "\n").data(using: .utf8)!)
    exit(code)
}

// MARK: - Config: ~/.config/agent-notify/config.json, overridden by AGENT_NOTIFY_* variables

func readJSON(_ path: String) -> Any? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

func writeJSON(_ object: Any, to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    try (data + "\n".data(using: .utf8)!).write(to: URL(fileURLWithPath: path), options: .atomic)
}

let configPath = configDir + "/config.json"
let config = (readJSON(configPath) as? [String: Any]) ?? [:]
func setting(_ envName: String, _ key: String) -> String? {
    if let v = env[envName], !v.isEmpty { return v }
    if let v = config[key] { return "\(v)" }
    return nil
}

let window: TimeInterval = 600
let perWindow = 3
// Notices tidy themselves away after this long; 0 keeps them until dismissed.
let defaultExpire = TimeInterval(setting("AGENT_NOTIFY_EXPIRE", "expire") ?? "") ?? 60
// An agent turn shorter than this doesn't notify: you were probably still watching.
let minTurnSeconds = TimeInterval(setting("AGENT_NOTIFY_MIN_SECONDS", "minSeconds") ?? "") ?? 20

// MARK: - Tools, kinds and badges

// Tools agent-notify knows by name: what to call them, and the emoji that starts their titles.
let tools: [String: (display: String, agent: String, emoji: String)] = [
    "claude": ("Claude Code", "Claude", "🧡"), "codex": ("Codex", "Codex", "🤖"),
    "cursor": ("Cursor", "Cursor", "🖱️"), "gemini": ("Gemini", "Gemini", "♊️"),
    "antigravity": ("Antigravity", "Antigravity", "🪐"), "opencode": ("OpenCode", "OpenCode", "🟩"),
    "copilot": ("Copilot", "Copilot", "🛩️"), "aider": ("Aider", "Aider", "🧑‍💻"),
    "windsurf": ("Windsurf", "Windsurf", "🏄"), "scripts": ("Scripts", "Your script", "⚙️"),
    "browserctrl": ("browserctrl", "browserctrl", "🌐"), "agent-vault": ("agent-vault", "agent-vault", "🗝️"),
]
func toolDisplay(_ source: String) -> String { tools[source]?.display ?? source }
func agentName(_ source: String) -> String { tools[source]?.agent ?? source.prefix(1).uppercased() + source.dropFirst() }

// Each kind has a badge (drawn by badges.swift) and a system sound.
let kindSounds: [String: String?] = [
    "done": "Glass", "waiting": "Pop", "permission": "Hero", "handoff": "Submarine", "signin": "Submarine",
    "approval": "Purr", "run-ok": "Ping", "run-failed": "Basso", "pile": nil, "bell": "Tink",
]
// Names from before v1, still accepted.
let kindAliases = ["claude-waiting": "waiting", "claude-permission": "permission", "codex-done": "done",
                   "browser-handoff": "handoff", "browser-signin": "signin", "browser-debug": "handoff",
                   "vault-approval": "approval"]
func canonicalKind(_ k: String) -> String? {
    let kind = kindAliases[k] ?? k
    return kindSounds[kind] != nil ? kind : nil
}

// The kind of a notice, when its sender didn't say: guessed from the tool and the title.
func inferKind(_ n: Notice) -> String {
    let t = n.title.lowercased()
    switch n.source {
    case "browserctrl":
        return t.contains("sign") || t.contains("log in") || t.contains("login") ? "signin" : "handoff"
    case "agent-vault": return "approval"
    case "scripts":
        return t.contains("fail") || t.contains("flop") ? "run-failed" : t.contains("finish") ? "run-ok" : "bell"
    default:
        if t.contains("permission") || n.urgency == "urgent" { return "permission" }
        if t.contains("failed") || t.contains("flopped") { return "run-failed" }
        return tools[n.source] != nil ? (n.source == "codex" ? "done" : "waiting") : "bell"
    }
}

// MARK: - Persona packs

// The voice: AGENT_NOTIFY_VOICE, or "voice" in config.json, or Gen Z. Missing lines fall back to plain.
let voice = setting("AGENT_NOTIFY_VOICE", "voice") ?? "genz"

func packPaths() -> [String: String] {
    var found: [String: String] = [:]
    var dirs: [String] = []
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("personas").path { dirs.append(bundled) }
    dirs.append(configDir + "/personas")   // the user's own packs win
    for dir in dirs {
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".json") {
            found[String(file.dropLast(5))] = dir + "/" + file
        }
    }
    return found
}

let builtinPlain: [String: Any] = [
    "titles": ["done": ["🎉 {agent} finished, your turn"], "waiting": ["👋 {agent} is waiting for you"],
               "permission": ["🙋 {agent} needs your OK"], "handoff": ["🧩 {agent} needs you to step in"],
               "signin": ["🚪 {agent} needs you to sign in"], "approval": ["🔐 {agent} is asking for access"],
               "run-ok": ["🚀 {what} finished"], "run-failed": ["💥 {what} failed"],
               "pile": ["📚 {count} more from {tool}"]],
    "messages": ["run-ok": ["All good. It took {took} and exited cleanly."],
                 "run-failed": ["It stopped with exit code {code} after {took}. Click to see the output."],
                 "pile": ["The latest one: {title}. {message}"]],
    "buttons": ["go": "👉 Take me there", "go-done": "👀 Review it", "go-permission": "👀 Review it",
                "go-chat": "💬 Open conversation", "go-tab": "🧭 Open the tab", "go-approval": "🔐 Review request",
                "go-failed": "🔍 Show me", "reply": "💬 Reply to {agent}", "snooze": "😴 Remind me in 10 min"],
    "snoozed": "⏰ Reminder: ",
]
let packs = packPaths()
let plainPack = packs["plain"].flatMap { readJSON($0) as? [String: Any] } ?? builtinPlain
let pack: [String: Any] = packs[voice].flatMap { readJSON($0) as? [String: Any] } ?? plainPack

func fill(_ template: String, _ vars: [String: String]) -> String {
    vars.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
}

// A random line for a kind from the pack (titles or messages), falling back to plain.
func line(_ section: String, _ kind: String, _ vars: [String: String]) -> String? {
    for p in [pack, plainPack, builtinPlain] {
        if let lines = (p[section] as? [String: Any])?[kind] as? [String], let pick = lines.randomElement() {
            return fill(pick, vars)
        }
    }
    return nil
}

func label(_ key: String, agent: String = "your agent") -> String {
    for p in [pack, plainPack, builtinPlain] {
        if let l = (p["buttons"] as? [String: Any])?[key] as? String { return fill(l, ["agent": agent]) }
    }
    return "👉 Take me there"
}

let snoozedPrefix = (pack["snoozed"] as? String) ?? (plainPack["snoozed"] as? String) ?? "⏰ Reminder: "

// MARK: - Text

// Agents write markdown; Notification Center shows it raw. Flatten it to one plain line.
func plainText(_ s: String, limit: Int) -> String {
    var t = s
    let rules: [(String, String)] = [
        ("```[\\s\\S]*?```", " "),                       // code blocks
        ("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),           // links and images: keep the text
        ("(?m)^\\s{0,3}#{1,6}\\s+", ""),                 // headings
        ("(?m)^\\s*(?:[-*+]|\\d+[.)])\\s+", ""),         // list markers
        ("(?m)^\\s*>\\s?", ""),                          // quotes
        ("\\*\\*|__|~~|`", ""),                          // bold, strike, code
        ("(?<![\\w*])\\*(?!\\s)([^*\\n]+?)\\*(?![\\w*])", "$1"),   // *italic*
        ("\\s+", " "),
    ]
    for (pattern, template) in rules {
        t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.count > limit ? String(t.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : t
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
    var unbudgeted = false                 // demos you asked for don't count against the 3-per-10-min budget
    var identifier: String { "\(source):\(key ?? UUID().uuidString)" }
}

func validSource(_ s: String) -> Bool { s.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil }

// ITERM_SESSION_ID looks like "w0t4p0:9053558D-36ED-4F77-94C8-AD5C6AB3BEC7"; AppleScript knows the UUID.
func itermSessionUUID(_ id: String) -> String { String(id.split(separator: ":").last ?? "") }
func validItermSession(_ id: String) -> Bool {
    itermSessionUUID(id).range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil
}

// Schemes a click may open: web pages, the Codex app's threads, and editor windows.
let openSchemes: Set<String> = ["https", "http", "codex", "vscode", "vscode-insiders", "cursor", "windsurf"]

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
            guard let kind = canonicalKind(k) else { fail("--kind is one of: \(kindSounds.keys.sorted().joined(separator: ", "))") }
            n.kind = kind
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
        case "--dry-run": break
        case "--activate": n.action["activate"] = value()
        case "--iterm-session":
            let id = value()
            guard validItermSession(id) else { fail("--iterm-session takes an iTerm2 session id (ITERM_SESSION_ID)") }
            n.action["iterm"] = itermSessionUUID(id)
        case "--tmux-pane":
            let pane = value()
            guard let target = tmuxTarget(pane: pane, tmuxEnv: env["TMUX"]) else { fail("--tmux-pane takes a pane id like %3, from inside tmux") }
            n.action["tmux"] = target
        case "--open":
            let url = value()
            guard let u = URL(string: url), openSchemes.contains(u.scheme ?? "") else {
                fail("--open takes an http(s), codex://, vscode://, cursor:// or windsurf:// URL")
            }
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
        n.subtitle = subtitle.map { plainText($0, limit: 80) }
    }
    guard validSource(n.source) else { fail("--source is lowercase letters, digits and dashes, up to 32") }
    guard !n.title.isEmpty, !n.message.isEmpty else { fail("--title and --message are required") }
    if let key = n.key, key.count > 120 { fail("--key is at most 120 characters") }
    n.title = plainText(n.title, limit: 80)
    n.message = plainText(n.message, limit: 400)
    return n
}

// MARK: - State (anti-spam, turn timing) and history, under one file lock

struct State: Codable {
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = try c.decodeIfPresent([String: [Double]].self, forKey: .sent) ?? [:]
        folded = try c.decodeIfPresent([String: Int].self, forKey: .folded) ?? [:]
        active = try c.decodeIfPresent([String: Double].self, forKey: .active) ?? [:]
        expiry = try c.decodeIfPresent([String: String].self, forKey: .expiry) ?? [:]
        turns = try c.decodeIfPresent([String: Double].self, forKey: .turns) ?? [:]
    }
    var sent: [String: [Double]] = [:]      // source -> times of counted notices in the window
    var folded: [String: Int] = [:]         // source -> notices folded into "N more"
    var active: [String: Double] = [:]      // identifier -> time posted (for replace-not-count)
    var expiry: [String: String] = [:]      // identifier -> stamp of the timer allowed to remove it
    var turns: [String: Double] = [:]       // agent session -> when its current turn started
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
    if !dryRun, let data = try? JSONEncoder().encode(state) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o600)
    }
    return result
}

func record(_ entry: [String: Any]) {
    guard !dryRun else { return }
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
        if n.urgency == "urgent" || n.unbudgeted || state.sent[n.source]!.count < perWindow {
            if !n.unbudgeted { state.sent[n.source]!.append(now) }
            if let id = id { state.active[id] = now }
            return .show
        }
        let count = (state.folded[n.source] ?? 0) + 1
        state.folded[n.source] = count
        return .fold(count)
    }
}

func forget(_ identifier: String) {
    withState { state in _ = state.active.removeValue(forKey: identifier) }
}

// MARK: - Buttons
//
// A button is {type, label, target?}. Types: go (the notice's own click target), snooze (back in
// 10 min), reply (type into the notice's iTerm2 or tmux pane), open (a URL), run (a program).
//   --button go | snooze | reply            a preset with the voice's label
//   --button "go=👀 Review the diff"         a preset with your own label
//   --button "🚀 Open MR=https://…"          a labelled URL
//   --button "🔁 Rerun=/abs/script arg"      a labelled program (absolute path, space-separated args)
// macOS shows the first button on hover and the rest under Options.

func parseButton(_ spec: String) -> [String: Any] {
    let parts = spec.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
    if ["go", "snooze", "reply"].contains(parts[0]) {
        var b: [String: Any] = ["type": parts[0]]
        if parts.count > 1, !parts[1].isEmpty { b["label"] = String(parts[1].prefix(40)) }
        return b
    }
    guard parts.count == 2, !parts[0].isEmpty else { fail("--button is go|snooze|reply[=Label] or \"Label=URL\" or \"Label=/abs/program args\"") }
    let label = String(parts[0].prefix(40)), target = parts[1]
    if target.hasPrefix("/") {
        return ["type": "run", "label": label, "target": target.split(separator: " ").map(String.init)]
    }
    guard let u = URL(string: target), openSchemes.contains(u.scheme ?? "") else { fail("--button target must be a URL agent-notify can open or an absolute program path") }
    return ["type": "open", "label": label, "target": target]
}

func canReply(_ n: Notice) -> Bool { n.action["iterm"] != nil || n.action["tmux"] != nil }

// What a notice gets when its sender doesn't choose: the click target under a label that says
// where it goes, a reply box when the agent sits in an iTerm2 or tmux pane, and a 10-minute reminder.
func defaultButtons(_ n: Notice, kind: String) -> [[String: Any]] {
    guard !n.action.isEmpty else { return [] }
    let opensChat = ((n.action["open"] as? String)?.hasPrefix("codex:") ?? false)
    let go: String
    switch kind {
    case "done", "waiting": go = opensChat ? "go-chat" : "go-done"
    case "permission": go = "go-permission"
    case "handoff", "signin": go = "go-tab"
    case "approval": go = "go-approval"
    case "run-failed": go = "go-failed"
    default: go = "go"
    }
    var list: [[String: Any]] = []
    if ["done", "waiting"].contains(kind) && canReply(n) { list.append(["type": "reply"]) }
    list.append(["type": "go", "labelKey": go])
    list.append(["type": "snooze"])
    return list
}

// Fill in each button's label from the voice, and drop buttons that need something the notice lacks.
func resolveButtons(_ n: Notice, kind: String) -> [[String: Any]] {
    let agent = agentName(n.source)
    return (n.buttons ?? defaultButtons(n, kind: kind)).compactMap { b in
        var b = b
        let type = b["type"] as? String ?? "go"
        if type == "reply" && !canReply(n) { return nil }
        if type == "go" && n.action.isEmpty { return nil }
        if b["label"] == nil { b["label"] = label(b["labelKey"] as? String ?? type, agent: agent) }
        b.removeValue(forKey: "labelKey")
        return b
    }
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
    var known = (readJSON(path) as? [[String: Any]]) ?? []
    var id: String?
    if let buttons = buttons, !buttons.isEmpty {
        let cid = categoryId(buttons)
        id = cid
        let shape = buttons.map { ["type": $0["type"] ?? "", "label": $0["label"] ?? ""] }
        known.removeAll { ($0["id"] as? String) == cid }
        known.append(["id": cid, "buttons": shape])
        known = Array(known.suffix(64))
        if !dryRun, let data = try? JSONSerialization.data(withJSONObject: known) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
    guard !dryRun else { return id }
    let icons = ["go": "arrow.up.forward.app", "snooze": "moon.zzz", "reply": "text.bubble", "open": "link", "run": "play.circle"]
    var categories: Set<UNNotificationCategory> = [UNNotificationCategory(identifier: "notice", actions: [], intentIdentifiers: [])]
    for entry in known {
        guard let cid = entry["id"] as? String, let list = entry["buttons"] as? [[String: Any]] else { continue }
        let actions: [UNNotificationAction] = list.enumerated().map { i, b in
            let type = b["type"] as? String ?? "go", title = b["label"] as? String ?? "Open"
            let icon = UNNotificationActionIcon(systemImageName: icons[type] ?? "circle")
            if type == "reply" {
                return UNTextInputNotificationAction(identifier: "btn\(i)", title: title, options: [], icon: icon,
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "Type your reply…")
            }
            return UNNotificationAction(identifier: "btn\(i)", title: title, options: type == "snooze" ? [] : [.foreground], icon: icon)
        }
        categories.insert(UNNotificationCategory(identifier: cid, actions: actions, intentIdentifiers: []))
    }
    UNUserNotificationCenter.current().setNotificationCategories(categories)
    return id
}

// MARK: - Posting

// The badge for a kind, copied out of the app (macOS moves an attachment into its own store).
func badgeAttachment(_ kind: String) -> [UNNotificationAttachment] {
    guard !dryRun, let src = Bundle.main.url(forResource: kind, withExtension: "png", subdirectory: "badges") else { return [] }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(appName)-\(UUID().uuidString).png")
    guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil,
          let a = try? UNNotificationAttachment(identifier: "badge", url: tmp, options: nil) else { return [] }
    return [a]
}

func startsWithEmoji(_ s: String) -> Bool {
    s.unicodeScalars.first.map { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF } ?? false
}

func content(for n: Notice) -> UNMutableNotificationContent {
    let kind = n.kind ?? inferKind(n)
    let c = UNMutableNotificationContent()
    c.title = startsWithEmoji(n.title) ? n.title : "\(tools[n.source]?.emoji ?? "✨") \(n.title)"
    if let subtitle = n.subtitle { c.subtitle = subtitle }   // real context only (the project)
    c.body = n.message
    // One group per session/thread/event, not per tool: macOS stacks a group, and the first click
    // on a stack only expands it, so per-tool groups made clicks look like they did nothing.
    c.threadIdentifier = n.key.map { "\(n.source):\($0)" } ?? n.source
    let buttons = resolveButtons(n, kind: kind)
    var info = n.action
    info["kind"] = kind
    info["buttons"] = buttons
    c.userInfo = info
    c.attachments = badgeAttachment(kind)
    c.categoryIdentifier = registerCategories(adding: buttons) ?? "notice"
    let sound = (kindSounds[kind] ?? nil).map { UNNotificationSound(named: UNNotificationSoundName("\($0).aiff")) }
    switch n.urgency {
    case "low": c.interruptionLevel = .passive
    case "urgent": c.interruptionLevel = .active; c.sound = sound ?? .default; c.relevanceScore = 1
    default: c.interruptionLevel = .active; c.sound = sound; c.relevanceScore = 0.5
    }
    if n.sound && c.sound == nil { c.sound = .default }
    return c
}

// --dry-run: print what would be shown, without posting or touching state.
func describe(_ n: Notice) -> [String: Any] {
    let c = content(for: n)
    var out: [String: Any] = ["source": n.source, "title": c.title, "body": c.body, "kind": c.userInfo["kind"] ?? "",
                              "urgency": n.urgency, "voice": voice,
                              "buttons": ((c.userInfo["buttons"] as? [[String: Any]]) ?? []).map { $0["label"] ?? "" }]
    if !c.subtitle.isEmpty { out["subtitle"] = c.subtitle }
    if let key = n.key { out["key"] = key }
    if n.ifNew { out["ifNew"] = true }
    if !n.action.isEmpty { out["action"] = n.action }
    return out
}

func printJSON(_ object: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) {
        print(String(decoding: data, as: UTF8.self))
    }
}

func post(_ n: Notice, done: @escaping (Int32) -> Void) {
    if dryRun { printJSON(describe(n)); done(0); return }
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { fail("notifications are not allowed for \(appDisplayName) (System Settings > Notifications)", 3) }
        let decision = decide(n)
        var request: UNNotificationRequest
        var outcome: String
        switch decision {
        case .skip:
            print("skipped")
            done(0)
            return
        case .fold(let count):
            let vars = ["count": "\(count)", "tool": toolDisplay(n.source), "title": n.title, "message": n.message]
            let summary = Notice(source: n.source, title: line("titles", "pile", vars) ?? "📚 \(count) more",
                                 message: plainText(line("messages", "pile", vars) ?? n.message, limit: 400),
                                 key: "__more", urgency: "low", kind: "pile", action: n.action)
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
    withState { state in state.expiry[id] = stamp }
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

func clear(source: String, key: String, quiet: Bool = false, done: @escaping (Int32) -> Void) {
    let id = "\(source):\(key)"
    if dryRun { if !quiet { printJSON(["cleared": id]) }; done(0); return }
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [id])
    center.removePendingNotificationRequests(withIdentifiers: [id])
    forget(id)
    record(["source": source, "key": key, "outcome": "cleared"])
    // Removal is asynchronous inside Notification Center; give it a moment before exiting.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !quiet { print("cleared") }; done(0) }
}

// MARK: - Click targets: iTerm2 panes, tmux panes, editor windows

func runAction(_ info: [AnyHashable: Any]) {
    if let url = info["open"] as? String, let u = URL(string: url), openSchemes.contains(u.scheme ?? "") {
        NSWorkspace.shared.open(u)
    }
    if let session = info["iterm"] as? String, validItermSession(session) {
        focusItermSession(session)
    }
    if let target = info["tmux"] as? [String: String] {
        tmux(target, ["select-window", "-t", target["pane"] ?? ""])
        tmux(target, ["select-pane", "-t", target["pane"] ?? ""])
        tmux(target, ["switch-client", "-t", target["pane"] ?? ""])
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

func iterm(_ uuid: String, _ body: String) -> String {
    """
    tell application id "com.googlecode.iterm2"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if unique id of s is "\(uuid)" then
              \(body)
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell
    """
}

func runAppleScript(_ source: String, failure: String) {
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error = error { record(["outcome": failure, "source": "iterm", "key": "\(error[NSAppleScript.errorNumber] ?? "")"]) }
}

// Bring the iTerm2 window, tab and split pane that hold this session to the front. The first
// time, macOS asks once whether Agent Notify may control iTerm2.
func focusItermSession(_ uuid: String) {
    runAppleScript(iterm(uuid, "tell w to select\n tell t to select\n tell s to select\n activate"), failure: "focus-failed")
}

func escapeAppleScript(_ text: String) -> String {
    text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

// tmux: the pane (%3) and the server's socket, from $TMUX ("socket,pid,session") and $TMUX_PANE.
func tmuxTarget(pane: String?, tmuxEnv: String?) -> [String: String]? {
    guard let pane = pane, pane.range(of: "^%[0-9]{1,6}$", options: .regularExpression) != nil,
          let socket = tmuxEnv?.split(separator: ",").first.map(String.init), socket.hasPrefix("/"),
          let exe = findExecutable("tmux") else { return nil }
    return ["pane": pane, "socket": socket, "tmux": exe]
}

@discardableResult
func tmux(_ target: [String: String], _ args: [String]) -> Bool {
    guard let exe = target["tmux"], exe.hasPrefix("/"), let socket = target["socket"] else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["-S", socket] + args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// Quick reply: type the text into the agent's pane and press Return, as if typed there.
func reply(_ info: [AnyHashable: Any], _ text: String) -> Bool {
    let line = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    if let session = info["iterm"] as? String, validItermSession(session) {
        runAppleScript(iterm(session, "tell s to write text \"\(escapeAppleScript(line))\""), failure: "reply-failed")
        return true
    }
    if let target = info["tmux"] as? [String: String], let pane = target["pane"] {
        return tmux(target, ["send-keys", "-t", pane, "-l", line]) && tmux(target, ["send-keys", "-t", pane, "Enter"])
    }
    return false
}

func findExecutable(_ name: String) -> String? {
    let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    return dirs.map { ($0 as NSString).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

// MARK: - Harness hooks

// Terminals and editors an agent may run in, by TERM_PROGRAM (the app's bundle id wins when set).
let terminalBundles = ["iTerm.app": "com.googlecode.iterm2", "Apple_Terminal": "com.apple.Terminal",
                       "WarpTerminal": "dev.warp.Warp-Stable", "ghostty": "com.mitchellh.ghostty",
                       "WezTerm": "com.github.wez.wezterm", "kitty": "net.kovidgoyal.kitty",
                       "vscode": "com.microsoft.VSCode"]
// Editors whose URL scheme opens (and so focuses) the window for a folder.
let editorSchemes = ["com.microsoft.VSCode": "vscode", "com.microsoft.VSCodeInsiders": "vscode-insiders",
                     "com.todesktop.230313mzl4w4u92": "cursor", "com.exafunction.windsurf": "windsurf"]

func terminalBundle() -> String? {
    if let b = env["__CFBundleIdentifier"], !b.isEmpty, b != bundleId { return b }
    return env["TERM_PROGRAM"].flatMap { terminalBundles[$0] }
}

// The folder an editor window is most likely open on: the repository root above cwd, else cwd.
func workspaceRoot(_ cwd: String) -> String {
    var dir = cwd
    while dir != "/" && !dir.isEmpty {
        if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return cwd
}

// Where a click on an agent's notice should land, from the hook's environment.
func clickTarget(cwd: String?) -> [String: Any] {
    var action: [String: Any] = [:]
    let bundle = terminalBundle()
    if let bundle = bundle { action["activate"] = bundle }
    if let session = env["ITERM_SESSION_ID"], validItermSession(session) { action["iterm"] = itermSessionUUID(session) }
    if let target = tmuxTarget(pane: env["TMUX_PANE"], tmuxEnv: env["TMUX"]) { action["tmux"] = target }
    if action["iterm"] == nil, action["tmux"] == nil, let bundle = bundle, let scheme = editorSchemes[bundle],
       let cwd = cwd, cwd.hasPrefix("/"),
       let path = workspaceRoot(cwd).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
        action["open"] = "\(scheme)://file\(path)"
    }
    return action
}

// The last text an agent wrote, from the end of a Claude Code transcript (JSONL).
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
        if let text = parts.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
    }
    return nil
}

func quote(_ text: String) -> String { "“\(plainText(text, limit: 220))”" }

enum HookResult { case notice(Notice), clear(source: String, key: String), nothing(String) }

func claudeHook(_ json: [String: Any]) -> HookResult {
    let event = json["hook_event_name"] as? String ?? "Notification"
    let cwd = json["cwd"] as? String
    let project = (cwd as NSString?)?.lastPathComponent
    let session = json["session_id"] as? String
    let key = session.map { "session-\($0)" }
    var n = Notice()
    n.source = "claude"
    n.key = key
    n.subtitle = project.flatMap { $0.isEmpty ? nil : "in \($0)" }
    n.action = clickTarget(cwd: cwd)
    let vars = ["agent": "Claude"]
    switch event {
    case "UserPromptSubmit":
        // You're back at the prompt: start timing the turn, and the old notice is stale.
        if let session = session { withState { $0.turns[session] = Date().timeIntervalSince1970 } }
        return key.map { .clear(source: "claude", key: $0) } ?? .nothing("no session")
    case "Stop", "SubagentStop":
        if event == "SubagentStop" { return .nothing("subagent") }
        if json["stop_hook_active"] as? Bool == true { return .nothing("stop hook active") }
        let started = session.flatMap { s in withState { $0.turns.removeValue(forKey: s) } }
        if let started = started, Date().timeIntervalSince1970 - started < minTurnSeconds {
            return .nothing("short turn")
        }
        n.kind = "done"
        n.title = line("titles", "done", vars) ?? "Claude finished"
        let said = (json["last_assistant_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (json["transcript_path"] as? String).flatMap(lastClaudeText)
        n.message = said.map(quote) ?? "Your turn."
    default:   // Notification
        let message = (json["message"] as? String) ?? "Claude Code is waiting for you"
        let type = json["notification_type"] as? String
            ?? (message.lowercased().contains("permission") ? "permission_prompt" : "idle_prompt")
        switch type {
        case "permission_prompt":
            n.kind = "permission"
            n.urgency = "urgent"
            n.title = line("titles", "permission", vars) ?? "Claude needs your OK"
            n.message = plainText(message, limit: 300)
        case "idle_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog":
            n.kind = "waiting"
            n.title = line("titles", "waiting", vars) ?? "Claude is waiting for you"
            // An idle nudge after a "done" notice that is still showing adds nothing.
            n.ifNew = type == "idle_prompt"
            let said = type == "idle_prompt" ? (json["transcript_path"] as? String).flatMap(lastClaudeText) : nil
            n.message = said.map(quote) ?? plainText(message, limit: 300)
        default:
            return .nothing("notification \(type)")
        }
    }
    return .notice(n)
}

func codexHook(_ args: [String]) -> HookResult {
    // Codex `notify`: the JSON payload is the last argument. An earlier notify program that
    // `install` chained in comes as --previous-notify '["/path", "args"]' and runs first.
    if let i = args.firstIndex(of: "--previous-notify"), i + 1 < args.count, !dryRun,
       let previous = (try? JSONSerialization.jsonObject(with: Data(args[i + 1].utf8))) as? [String],
       let exe = previous.first, exe.hasPrefix("/"), let payload = args.last {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(previous.dropFirst()) + [payload]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
    let json = (args.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] ?? [:]
    guard (json["type"] as? String) == "agent-turn-complete" else { return .nothing("not a finished turn") }
    let cwd = json["cwd"] as? String
    var n = Notice()
    n.source = "codex"
    let thread = json["thread-id"] as? String
    n.key = thread.map { "thread-\($0)" } ?? "turn"
    n.action = clickTarget(cwd: cwd)
    // The Codex app (or a CLI run outside a pane we can focus): a click opens that conversation.
    let inApp = env["__CFBundleIdentifier"] == "com.openai.codex" || env["BROWSER_USE_CODEX_APP_VERSION"] != nil
    if let thread = thread, thread.range(of: "^[0-9A-Za-z-]{1,80}$", options: .regularExpression) != nil,
       inApp || (n.action["iterm"] == nil && n.action["tmux"] == nil) {
        n.action = ["open": "codex://threads/\(thread)", "activate": "com.openai.codex"]
    }
    n.kind = "done"
    n.title = line("titles", "done", ["agent": "Codex"]) ?? "Codex finished"
    n.subtitle = cwd.map { "in \(($0 as NSString).lastPathComponent)" }
    n.message = (json["last-assistant-message"] as? String).map(quote) ?? "Your turn."
    return .notice(n)
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
    let vars = ["what": what, "took": took, "code": "\(code)"]
    n.title = line("titles", n.kind!, vars) ?? what
    n.message = line("messages", n.kind!, vars) ?? "Took \(took)."
    if code != 0 { n.sound = true }
    if n.action["activate"] == nil, let bundle = terminalBundle() { n.action["activate"] = bundle }
    return (n, code)
}

// MARK: - install: wire the hooks into Claude Code and Codex

// The command hooks should run: agent-notify on PATH if it is there, else this app's binary.
func selfCommand() -> String {
    if let shim = env["AGENT_NOTIFY_SHIM"], shim.hasPrefix("/") { return shim }
    if let found = findExecutable(appName) { return found }
    return Bundle.main.executablePath ?? appName
}

func shellQuote(_ s: String) -> String {
    s.range(of: "^[A-Za-z0-9_./~-]+$", options: .regularExpression) != nil ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

let claudeDir = env["CLAUDE_CONFIG_DIR"] ?? (home as NSString).appendingPathComponent(".claude")
let codexDir = env["CODEX_HOME"] ?? (home as NSString).appendingPathComponent(".codex")

func isOurClaudeHook(_ h: [String: Any]) -> Bool {
    let cmd = h["command"] as? String ?? ""
    return cmd.contains(appName) && cmd.contains("hook claude")
}

// Remove our hook handlers everywhere, keeping everyone else's (and dropping groups we emptied).
func withoutOurHooks(_ hooks: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (event, value) in hooks {
        guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
        let kept: [[String: Any]] = groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let rest = handlers.filter { !isOurClaudeHook($0) }
            if rest.isEmpty { return nil }
            var g = group
            g["hooks"] = rest
            return g
        }
        if !kept.isEmpty { out[event] = kept }
    }
    return out
}

func claudeSettings(install: Bool) -> (path: String, before: [String: Any], after: [String: Any]) {
    let path = claudeDir + "/settings.json"
    let before = (readJSON(path) as? [String: Any]) ?? [:]
    var after = before
    var hooks = withoutOurHooks((before["hooks"] as? [String: Any]) ?? [:])
    if install {
        let handler: [String: Any] = ["type": "command", "command": "\(shellQuote(selfCommand())) hook claude >/dev/null 2>&1 || true",
                                      "timeout": 10, "async": true]
        let groups: [(String, String?)] = [("Stop", nil), ("UserPromptSubmit", nil),
                                           ("Notification", "permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input")]
        for (event, matcher) in groups {
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher = matcher { group["matcher"] = matcher }
            hooks[event] = ((hooks[event] as? [[String: Any]]) ?? []) + [group]
        }
    }
    if hooks.isEmpty { after.removeValue(forKey: "hooks") } else { after["hooks"] = hooks }
    return (path, before, after)
}

// Codex keeps one `notify` program in config.toml. Ours goes first; one that was there before is
// chained (--previous-notify) so it keeps working.
func codexConfig(install: Bool) -> (path: String, before: String, after: String, note: String?) {
    let path = codexDir + "/config.toml"
    let before = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    var lines = before.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    let notifyIndex = lines.firstIndex { $0.range(of: "^\\s*notify\\s*=", options: .regularExpression) != nil }
    let current = notifyIndex.map { lines[$0] }
    func array(_ line: String) -> [String]? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String]
    }
    func toml(_ argv: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: argv, options: [.withoutEscapingSlashes])
        return "notify = " + String(decoding: data, as: UTF8.self)
    }
    let ours = current.map { $0.contains(appName) } ?? false
    if install {
        if ours { return (path, before, before, "Codex already notifies through \(appName)") }
        var argv = [selfCommand(), "hook", "codex"]
        if let current = current {
            guard let previous = array(current) else {
                return (path, before, before, "Codex's notify line isn't a one-line list; add \(toml(argv)) by hand")
            }
            argv += ["--previous-notify", String(decoding: try! JSONSerialization.data(withJSONObject: previous, options: [.withoutEscapingSlashes]), as: UTF8.self)]
            lines[notifyIndex!] = toml(argv)
        } else {
            // A top-level key must come before the first [table].
            let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            lines.insert(toml(argv), at: firstTable)
        }
    } else {
        guard ours, let i = notifyIndex else { return (path, before, before, nil) }
        if let argv = array(lines[i]), let p = argv.firstIndex(of: "--previous-notify"), p + 1 < argv.count,
           argv[0].contains(appName),
           let previous = (try? JSONSerialization.jsonObject(with: Data(argv[p + 1].utf8))) as? [String] {
            lines[i] = toml(previous)
        } else if array(lines[i])?.first?.contains(appName) == true {
            lines.remove(at: i)
        } else {
            return (path, before, before, "Codex's notify chains \(appName) inside another program; edit \(path) by hand")
        }
    }
    return (path, before, lines.joined(separator: "\n") + "\n", nil)
}

func installHooks(_ args: [String], install: Bool) {
    let only = Set(args.filter { ["--claude", "--codex"].contains($0) })
    let doClaude = only.isEmpty || only.contains("--claude"), doCodex = only.isEmpty || only.contains("--codex")
    let verb = install ? "wired" : "removed"
    var changed = false
    if doClaude {
        let hasClaude = FileManager.default.fileExists(atPath: claudeDir)
        if !hasClaude && only.isEmpty {
            print("Claude Code: not found (\(claudeDir)), skipped")
        } else {
            let (path, before, after) = claudeSettings(install: install)
            if NSDictionary(dictionary: before).isEqual(to: after) {
                print("Claude Code: nothing to change")
            } else if dryRun {
                printJSON(["file": path, "hooks": after["hooks"] ?? [:]])
            } else {
                if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path + ".agent-notify.bak"); try? FileManager.default.copyItem(atPath: path, toPath: path + ".agent-notify.bak") }
                do { try writeJSON(after, to: path) } catch { fail("can't write \(path): \(error.localizedDescription)", 1) }
                print("Claude Code: \(verb) Stop, Notification and UserPromptSubmit hooks in \(path)\(install ? " (backup: settings.json.agent-notify.bak)" : "")")
                changed = true
            }
        }
    }
    if doCodex {
        let hasCodex = FileManager.default.fileExists(atPath: codexDir)
        if !hasCodex && only.isEmpty {
            print("Codex: not found (\(codexDir)), skipped")
        } else {
            let (path, before, after, note) = codexConfig(install: install)
            if let note = note { print("Codex: \(note)") }
            if before == after {
                if note == nil { print("Codex: nothing to change") }
            } else if dryRun {
                print("\(path):\n" + after.components(separatedBy: "\n").filter { $0.hasPrefix("notify") }.joined(separator: "\n"))
            } else {
                if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path + ".agent-notify.bak"); try? FileManager.default.copyItem(atPath: path, toPath: path + ".agent-notify.bak") }
                do {
                    try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
                    try after.write(toFile: path, atomically: true, encoding: .utf8)
                } catch { fail("can't write \(path): \(error.localizedDescription)", 1) }
                print("Codex: \(verb) notify in \(path)")
                changed = true
            }
        }
    }
    if install && changed { print("Restart running agent sessions to pick up the hooks.") }
}

// MARK: - voice and demo

func voices() {
    for (name, path) in packPaths().sorted(by: { $0.key < $1.key }) {
        let p = readJSON(path) as? [String: Any] ?? [:]
        let mark = name == voice ? "*" : " "
        let sample = ((p["titles"] as? [String: Any])?["done"] as? [String])?.first.map { fill($0, ["agent": "Claude"]) } ?? ""
        print("\(mark) \(name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(sample)")
    }
    print("\nPick one: \(appName) voice NAME   (or AGENT_NOTIFY_VOICE=NAME). Your own packs: \(configDir)/personas/")
}

func setVoice(_ name: String) {
    guard packPaths()[name] != nil else { fail("no persona pack named \(name); see \(appName) voice") }
    var c = config
    c["voice"] = name
    do { try writeJSON(c, to: configPath) } catch { fail("can't write \(configPath): \(error.localizedDescription)", 1) }
    print("voice: \(name)")
    if let v = env["AGENT_NOTIFY_VOICE"], !v.isEmpty, v != name { print("(AGENT_NOTIFY_VOICE=\(v) is set and still wins in this shell)") }
}

func demoNotices(_ kinds: [String]) -> [Notice] {
    let all = kinds.isEmpty ? ["done", "permission", "run-failed"] : kinds
    return all.compactMap { k in
        guard let kind = canonicalKind(k) else { fail("demo takes kinds: \(kindSounds.keys.sorted().joined(separator: ", "))") }
        var n = Notice()
        n.source = ["run-ok", "run-failed"].contains(kind) ? "scripts" : "claude"
        n.key = "demo-\(kind)"
        n.kind = kind
        n.unbudgeted = true
        n.subtitle = "in my-app"
        n.action = ["activate": terminalBundle() ?? "com.apple.Terminal"]
        let vars = ["agent": "Claude", "what": "npm test", "took": "2m 14s", "code": "1", "count": "4",
                    "tool": "Claude Code", "title": "Tests pass", "message": "Ready for review."]
        n.title = line("titles", kind, vars) ?? kind
        switch kind {
        case "done", "waiting": n.message = quote("Fixed the flaky login test and added a retry. All 214 tests pass. Want me to open the PR?")
        case "permission": n.urgency = "urgent"; n.message = "Claude needs your permission to use Bash: git push origin main"
        case "run-ok", "run-failed", "pile": n.message = line("messages", kind, vars) ?? ""
        case "handoff": n.urgency = "urgent"; n.message = "A captcha is blocking the checkout page."
        case "signin": n.urgency = "urgent"; n.message = "GitHub wants you to sign in again."
        case "approval": n.urgency = "urgent"; n.message = "Read access to the staging database password."
        default: n.message = "Something happened."
        }
        return n
    }
}

// MARK: - list and status

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

let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)")!

func hooksSummary() -> String {
    let claude = (claudeSettings(install: false).before["hooks"] as? [String: Any]).map { hooks in
        hooks.values.contains { ($0 as? [[String: Any]])?.contains { (($0["hooks"] as? [[String: Any]]) ?? []).contains(where: isOurClaudeHook) } ?? false }
    } ?? false
    let codex = codexConfig(install: false).before.components(separatedBy: "\n").contains { $0.hasPrefix("notify") && $0.contains(appName) }
    return "hooks: Claude Code \(claude ? "wired" : "not wired"), Codex \(codex ? "wired" : "not wired")"
}

func status(openSettings: Bool) {
    UNUserNotificationCenter.current().getNotificationSettings { s in
        let auth = [UNAuthorizationStatus.notDetermined: "not asked yet", .denied: "denied",
                    .authorized: "allowed", .provisional: "provisional"][s.authorizationStatus] ?? "other"
        let style = [UNAlertStyle.none: "none (Notification Center only)", .banner: "temporary banners (hide after ~5s)",
                     .alert: "persistent (stay until dismissed)"][s.alertStyle] ?? "unknown"
        print("\(appName) \(appVersion)\nnotifications: \(auth)\nstyle: \(style)\nvoice: \(voice)\n\(hooksSummary())")
        if s.alertStyle != .alert {
            print("To keep notices on screen: System Settings > Notifications > \(appDisplayName) > Persistent.")
        }
        if openSettings { NSWorkspace.shared.open(settingsURL) }
        exit(s.alertStyle == .alert ? 0 : 1)
    }
}

// After install: ask for permission, show a sample in the voice, and offer persistent banners.
func welcome() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else {
            print("Notifications are off for \(appDisplayName). Turn them on in System Settings > Notifications.")
            NSWorkspace.shared.open(settingsURL)
            exit(3)
        }
        center.getNotificationSettings { s in
            if s.alertStyle != .alert {
                print("Tip: notices hide after ~5 s. For ones that stay until you act, set \(appDisplayName) to Persistent in the pane that just opened.")
                NSWorkspace.shared.open(settingsURL)
            }
            var n = demoNotices(["done"])[0]
            n.key = "welcome"
            n.message = "This is how your agents will reach you. Change the voice with: \(appName) voice"
            post(n) { _ in exit(0) }
        }
    }
}

// MARK: - App

let usage = """
usage: \(appName) <command>
  install [--claude] [--codex] [--dry-run]   wire notifications into Claude Code and Codex
  uninstall [--claude] [--codex]             take them out again
  voice [NAME]                               list persona packs, or pick one
  demo [KIND...]                             post sample notices (done, waiting, permission, run-failed, ...)
  post --source TOOL --title T --message M   post your own (see README for options)
  run --source TOOL --title WHAT -- cmd...   run a command, then report how it went
  clear --source TOOL --key KEY              withdraw a notice
  status [--open-settings] | list [--json] | version
Every command takes --dry-run to print the notice instead of posting it.
"""

// A click relaunches the app with no arguments; only then does handling it end the process.
var launchedForClick = false

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // The click that launched the app is delivered right at launch: listen before it finishes.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var args = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--dry-run" }
        let finish: (Int32) -> Void = { code in exit(code) }
        guard let command = args.first else {
            // Relaunched by a click: the response arrives through the delegate.
            _ = registerCategories()
            launchedForClick = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
            return
        }
        args.removeFirst()
        switch command {
        case "post":
            post(parseNotice(args, legacy: false), done: finish)
        case "clear":
            let n = parseNotice(args + ["--title", "-", "--message", "-"], legacy: false)
            guard let key = n.key else { fail("clear needs --key") }
            clear(source: n.source, key: key, done: finish)
        case "run":
            let (n, code) = runCommand(args)
            post(n) { _ in exit(code) }
        case "hook":
            guard let harness = args.first else { fail("hook takes claude or codex") }
            let result: HookResult
            switch harness {
            case "claude":
                let data = FileHandle.standardInput.readDataToEndOfFile()
                result = claudeHook((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            case "codex": result = codexHook(Array(args.dropFirst()))
            default: fail("hook takes claude or codex")
            }
            switch result {
            case .notice(let n): post(n) { _ in exit(0) }
            case .clear(let source, let key):
                // Only touch Notification Center when a notice for this session is showing.
                let showing = withState { $0.active["\(source):\(key)"] != nil }
                if showing || dryRun { clear(source: source, key: key, quiet: !dryRun) { _ in exit(0) } } else { exit(0) }
            case .nothing(let why):
                if dryRun { printJSON(["skipped": why]) }
                exit(0)
            }
        case "install", "uninstall":
            installHooks(args, install: command == "install")
            if command == "install" && !dryRun && !args.contains("--no-welcome") { welcome() } else { exit(0) }
        case "voice", "voices", "persona":
            if let name = args.first { setVoice(name) } else { voices() }
            exit(0)
        case "demo":
            let notices = demoNotices(args)
            var remaining = notices.count
            for (i, n) in notices.enumerated() {
                // A beat apart, so they arrive in order and each one gets its moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + (dryRun ? 0 : Double(i) * 1.5)) {
                    post(n) { _ in remaining -= 1; if remaining == 0 { exit(0) } }
                }
            }
        case "list":
            list(json: args.contains("--json"))
            exit(0)
        case "expire":
            guard args.count == 3, let secs = TimeInterval(args[2]) else { exit(2) }
            expire(args[0], stamp: args[1], after: secs)
        case "status":
            status(openSettings: args.contains("--open-settings"))
        case "version", "--version", "-v":
            print("\(appName) \(appVersion)")
            exit(0)
        case "--help", "-h", "help":
            print(usage)
            exit(0)
        default:
            guard args.contains("--title") else { fail("unknown command \(command)\n\(usage)") }
            post(parseNotice([command] + args, legacy: true), done: finish)
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
            runAction(info)
            forget(id)
            entry("clicked")
        case "snooze":
            // Hand it back to macOS with a 10-minute timer; it comes back even though this app exits.
            let c = request.content.mutableCopy() as! UNMutableNotificationContent
            if !c.title.hasPrefix("⏰") { c.title = snoozedPrefix + c.title }
            c.attachments = badgeAttachment(info["kind"] as? String ?? "bell")
            let again = UNNotificationRequest(identifier: id, content: c,
                                              trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
            entry("snoozed")
            center.add(again) { _ in done(); if launchedForClick { exit(0) } }
            return
        case "reply":
            if let text = (response as? UNTextInputNotificationResponse)?.userText, reply(info, text) {
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
