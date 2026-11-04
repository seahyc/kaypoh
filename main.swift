// agent-notify: one notification layer for every agent tool on this Mac.
//
//   agent-notify post  --source TOOL --title "what happened" --message TEXT
//                      [--key KEY] [--urgency low|normal|urgent] [--sound]
//                      [--if-new] [--open https://... | --run /abs/exe args...] [--activate BUNDLE_ID]
//   agent-notify clear --source TOOL --key KEY          withdraw a notice once it is resolved
//   agent-notify run   --source TOOL --title WHAT -- /cmd args...   run it, then report the result
//   agent-notify hook  claude|codex                      harness hooks (JSON on stdin / last arg)
//   agent-notify list  [--json]                          recent history
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
struct Kind { let sound: String?; let titles: [String] }
let kinds: [String: Kind] = [
    "claude-waiting":    Kind(sound: "Pop", titles: ["👋 Claude is waiting for you{p}", "👋 Claude finished{p} and it's your turn",
                                                     "☕️ Claude is ready for your next message{p}"]),
    "claude-permission": Kind(sound: "Hero", titles: ["🙋 Claude needs your OK to continue{p}", "🙋 Claude is asking permission{p}",
                                                      "✋ Claude is paused{p} until you approve something"]),
    "codex-done":        Kind(sound: "Glass", titles: ["🎉 Codex finished its turn{p}", "✅ Codex is done{p} and waiting for you",
                                                       "🎉 Codex wrapped up{p}, over to you"]),
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
        if t.contains("finished") || t.contains("landed") { return "run-ok" }
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
    var sent: [String: [Double]] = [:]      // source -> times of counted notices in the window
    var folded: [String: Int] = [:]         // source -> notices folded into "N more"
    var active: [String: Double] = [:]      // identifier -> time posted (for replace-not-count)
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

func content(for n: Notice) -> UNMutableNotificationContent {
    let kind = n.kind ?? inferKind(n)
    let c = UNMutableNotificationContent()
    let startsWithEmoji = n.title.unicodeScalars.first.map { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF } ?? false
    c.title = startsWithEmoji ? n.title : "\(sourceEmoji[n.source] ?? "✨") \(n.title)"
    c.subtitle = [n.display, n.subtitle].compactMap { $0 }.joined(separator: " · ")
    c.body = n.message
    c.threadIdentifier = n.source
    var info = n.action
    info["kind"] = kind
    c.userInfo = info
    c.attachments = badgeAttachment(kind)
    if n.action["iterm"] != nil && kind == "claude-waiting" { c.categoryIdentifier = "reply" }
    else if n.action.isEmpty { c.categoryIdentifier = "notice" }
    else { c.categoryIdentifier = "actionable" }
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
            let summary = Notice(source: n.source, title: "📚 \(count) more from \(n.display) while you were away",
                                 message: "The latest one: \(n.title). \(n.message)", key: "__more", urgency: "low", kind: "pile")
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
            print(outcome)
            done(0)
        }
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
        n.title = pickTitle(n.kind!, project: project.isEmpty ? nil : project, "Claude is waiting for you")
        n.urgency = permission ? "urgent" : "normal"
        let hint = n.action["iterm"] == nil ? "Click to switch to it."
            : permission ? "Click to jump to its iTerm tab and decide." : "Click to jump to its iTerm tab, or reply right here."
        n.message = "\(message.hasSuffix(".") ? message : message + ".") \(hint)"
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
        n.message += n.action["open"] != nil ? " Click to open the conversation in Codex." : " Click to jump to its iTerm tab."
        n.kind = "codex-done"
        n.title = pickTitle("codex-done", project: project, "Codex finished its turn")
        let said = last.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        n.message = "It said: “\(said.count > 220 ? said.prefix(220) + "…" : Substring(said))”"
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
    n.title = code == 0 ? "🚀 \(what) finished" : "💥 \(what) failed"
    n.message = code == 0 ? "All good. It took \(took) and exited cleanly. 😎"
                          : "It stopped with exit code \(code) after \(took). Click to see the output in your terminal. 🔍"
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
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.agents.notify")!)
        }
        exit(s.alertStyle == .alert ? 0 : 1)
    }
}

// MARK: - App

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let icon = { (name: String) in UNNotificationActionIcon(systemImageName: name) }
        let open = UNNotificationAction(identifier: "open", title: "👉 Take me there", options: [.foreground], icon: icon("arrow.up.forward.app"))
        let snooze = UNNotificationAction(identifier: "snooze", title: "😴 Remind me in 10 min", options: [], icon: icon("moon.zzz"))
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "💬 Reply", options: [], icon: icon("text.bubble"),
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message Claude…")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "actionable", actions: [open, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "reply", actions: [reply, open, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "notice", actions: [snooze], intentIdentifiers: []),
        ])
        var args = Array(CommandLine.arguments.dropFirst())
        let finish: (Int32) -> Void = { code in exit(code) }
        guard let command = args.first else {
            // Relaunched by a click: the response arrives through the delegate.
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
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, "open":
            runAction(request.content.userInfo)
            forget(id)
            entry("clicked")
        case "snooze":
            // Hand it back to macOS with a 10-minute timer; it comes back even though this app exits.
            let c = request.content.mutableCopy() as! UNMutableNotificationContent
            if !c.title.hasPrefix("⏰") { c.title = "⏰ Reminder: " + c.title }
            c.attachments = badgeAttachment(request.content.userInfo["kind"] as? String ?? "bell")
            let again = UNNotificationRequest(identifier: id, content: c,
                                              trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
            entry("snoozed")
            center.add(again) { _ in done(); exit(0) }
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
        exit(0)
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
