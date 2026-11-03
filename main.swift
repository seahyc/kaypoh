// agent-notify: one notification layer for every agent tool on this Mac.
//
//   agent-notify post  --source TOOL --title "what happened" --message TEXT
//                      [--key KEY] [--urgency low|normal|urgent] [--sound]
//                      [--open https://... | --run /abs/exe args...] [--activate BUNDLE_ID]
//   agent-notify clear --source TOOL --key KEY          withdraw a notice once it is resolved
//   agent-notify run   --source TOOL --title WHAT -- /cmd args...   run it, then report the result
//   agent-notify hook  claude|codex                      harness hooks (JSON on stdin / last arg)
//   agent-notify list  [--json]                          recent history
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
        case "--key": n.key = value()
        case "--urgency":
            n.urgency = value()
            guard ["low", "normal", "urgent"].contains(n.urgency) else { fail("--urgency is low, normal or urgent") }
        case "--sound": n.sound = true
        case "--activate": n.action["activate"] = value()
        case "--open":
            let url = value()
            guard let u = URL(string: url), ["https", "http"].contains(u.scheme ?? "") else { fail("--open takes an http(s) URL") }
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

enum Decision { case show, replace, fold(Int) }

func decide(_ n: Notice) -> Decision {
    let now = Date().timeIntervalSince1970
    return withState { state in
        state.sent[n.source] = (state.sent[n.source] ?? []).filter { now - $0 < window }
        state.active = state.active.filter { now - $0.value < 86400 }
        if state.sent[n.source]!.isEmpty { state.folded[n.source] = 0 }
        let id = n.key.map { "\(n.source):\($0)" }
        if let id = id, state.active[id] != nil {
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

func content(for n: Notice) -> UNMutableNotificationContent {
    let c = UNMutableNotificationContent()
    c.title = "\(n.display) · \(n.title)"
    c.body = n.message
    c.threadIdentifier = n.source
    c.userInfo = n.action
    c.categoryIdentifier = n.action.isEmpty ? "notice" : "actionable"
    switch n.urgency {
    case "low": c.interruptionLevel = .passive
    case "urgent": c.interruptionLevel = .active; c.sound = .default; c.relevanceScore = 1
    default: c.interruptionLevel = .active; c.relevanceScore = 0.5
    }
    if n.sound { c.sound = .default }
    return c
}

func post(_ n: Notice, done: @escaping (Int32) -> Void) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { fail("notifications are not allowed for Agent Notify (System Settings > Notifications)", 3) }
        let decision = decide(n)
        var request: UNNotificationRequest
        var outcome: String
        switch decision {
        case .fold(let count):
            let summary = Notice(source: n.source, title: "\(count) more notice\(count == 1 ? "" : "s")",
                                 message: "Latest: \(n.title). \(n.message)", key: "__more", urgency: "low")
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
            record(["source": n.source, "key": n.key ?? "", "title": n.title, "urgency": n.urgency, "outcome": outcome])
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
    if let url = info["open"] as? String, let u = URL(string: url), ["https", "http"].contains(u.scheme ?? "") {
        NSWorkspace.shared.open(u)
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

// MARK: - Harness hooks

func terminalBundle(_ env: [String: String]) -> String? {
    if let b = env["__CFBundleIdentifier"], !b.isEmpty { return b }
    return env["TERM_PROGRAM"].flatMap { terminalBundles[$0] }
}

func hookNotice(_ harness: String, _ args: [String]) -> Notice {
    let env = ProcessInfo.processInfo.environment
    var n = Notice()
    if let bundle = terminalBundle(env) { n.action["activate"] = bundle }
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
        n.title = permission ? "Needs permission" : "Waiting for you"
        n.urgency = permission ? "urgent" : "normal"
        n.message = project.isEmpty ? message : "\(project): \(message)"
    case "codex":
        // Codex notify: the JSON payload is the last argument.
        let json = (args.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] ?? [:]
        guard (json["type"] as? String) == "agent-turn-complete" else { exit(0) }
        let last = (json["last-assistant-message"] as? String) ?? "Turn finished"
        let project = ((json["cwd"] as? String) as NSString?)?.lastPathComponent
        n.source = "codex"
        n.key = (json["thread-id"] as? String).map { "thread-\($0)" } ?? "turn"
        n.title = "Turn finished"
        n.message = (project.map { "\($0): " } ?? "") + last.replacingOccurrences(of: "\n", with: " ")
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
    n.title = code == 0 ? "\(what) finished" : "\(what) failed"
    n.message = code == 0 ? "Finished in \(took)." : "Exited with status \(code) after \(took)."
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

// MARK: - App

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "actionable", actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "notice", actions: [], intentIdentifiers: []),
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
        case "--help", "-h", "help":
            print("usage: agent-notify post|clear|run|hook|list ... (see ~/.agents/lib/agent-notify/README.md)")
            exit(0)
        default:
            guard args.contains("--title") else { fail("unknown command \(command)") }
            post(parseNotice(args, legacy: true), done: finish)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if [UNNotificationDefaultActionIdentifier, "open"].contains(response.actionIdentifier) {
            runAction(response.notification.request.content.userInfo)
            let id = response.notification.request.identifier
            forget(id)
            record(["source": String(id.split(separator: ":").first ?? ""), "key": String(id.split(separator: ":", maxSplits: 1).last ?? ""), "outcome": "clicked"])
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
