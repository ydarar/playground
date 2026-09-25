import Foundation
import GoldieCore

let usage = """
goldiectl: Goldie's command-line helper

  goldiectl probe                   Print the structure of your Cursor data (no message text). Paste it back to Claude.
  goldiectl usage                   Check that Goldie can read your Cursor costs (no secrets printed).
  goldiectl snapshot [--no-costs]   Print what Goldie currently sees (with costs and billed models), as JSON.
  goldiectl install-cursor-hooks    Add Goldie's observe-only hooks to ~/.cursor/hooks.json (keeps yours).
  goldiectl uninstall-cursor-hooks  Remove them.
  goldiectl init-config             Write ~/.config/goldie/config.json with defaults.
  goldiectl show                    Bring back a hidden Goldie (and her menu bar item).
  goldiectl hook <event>            (Called by Cursor.) Record one hook event.
"""

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

switch command {
case "hook":
    // Must be fast and must never fail loudly: Cursor waits on this process.
    // Guard events get an allow/deny answer; everything else gets "{}".
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let reply = HookRecorder.handle(stdin: input, eventArg: args.first)
    FileHandle.standardOutput.write(Data((reply + "\n").utf8))

case "install-cursor-hooks":
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    let guards = GoldieConfig.load().guards
    do { print(try CursorHooksInstaller.install(executable: exe, guards: guards.loopGuard || guards.readGuard)) }
    catch { print("error: \(error)"); exit(1) }

case "uninstall-cursor-hooks":
    do { print(try CursorHooksInstaller.uninstall()) } catch { print("error: \(error)"); exit(1) }

case "probe":
    print(CursorProbe.report())

case "usage":
    print(await UsageDiagnostics.report())

case "snapshot":
    // Same view as the app, including real costs and billed models (skip with --no-costs).
    let config = GoldieConfig.load()
    var snap = SnapshotCollector(config: config).collect()
    if config.cursorUsageAPI, !args.contains("--no-costs") {
        let now = Date()
        if let result = try? await CursorUsageClient().fetchAll(since: UsageLedger.monthStart(now), until: now) {
            var ledger = UsageLedger()
            ledger.merge(result.events, now: now)
            snap = CostModel.enrich(snap, ledger: ledger, config: config, now: now)
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(snap) { print(String(decoding: data, as: UTF8.self)) }

case "show":
    DistributedNotificationCenter.default().postNotificationName(GoldieIPC.show, object: nil, userInfo: nil, deliverImmediately: true)
    print("asked Goldie to show herself (if she isn't running, start .build/release/Goldie)")

case "init-config":
    print("config: \(GoldieConfig.writeDefaultIfMissing().path)")

default:
    print(usage)
}
