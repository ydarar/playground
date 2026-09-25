# Goldie 🐠

A small goldfish that floats on your Mac desktop and tells you when a Cursor agent thread has become too expensive to keep going, so you start a fresh one.

**Why:** every agent turn re-sends the whole thread, so per-turn cost grows with context. A fresh thread plus a short handoff is often far cheaper than one more turn in a bloated thread. See [PRD.md](PRD.md).

> **Status: POC.** Cursor only. Apple Silicon, macOS 14+ (built for 26).

## How it works

```
Cursor hooks ──► goldiectl hook ──► ~/Library/Application Support/Goldie/cursor-hook-events.jsonl ─┐
Cursor state.vscdb (read-only) ────────────────────────────────────────────────────────────────────┤
                                                                                                    ▼
                           SnapshotCollector → Signals (per thread) → Brain (local LLM, rules fallback) → Judge (guardrails) → 🐠
```

**Two sensors.** If one misbehaves on your Cursor version, the other still works:

- **Hooks** (real-time). Cursor runs `goldiectl hook <event>` after agent replies, shell commands, file edits and MCP calls, and on `stop`. The hooks only observe; they can never block anything. They store metadata only: event, conversation id, model, command (truncated), file path.
- **Cursor's local DB** (`state.vscdb`, opened read-only). Holds each thread's messages. Used for context size and loop detection.

**Costs (real $).** Goldie reads your Cursor usage (per-request charges) with the Cursor app's own login token from its local DB. It is read-only, and the token is only ever sent to cursor.com, just like the Cursor app. Each charge is matched to the chat with agent activity closest in time. That gives each chat three numbers: **spent**, **last message** (all the steps one message triggered), and **per step**. The menu bar shows today's total. Turn it off with `"cursorUsageAPI": false`.

**Steps vs messages.** One message can trigger many *steps* (model calls: read a file, run a command, edit…), and **every step re-sends the whole chat**. That's why long chats get expensive fast.

**Signals per thread:**

| Signal | Meaning |
|---|---|
| context tokens | Reported by Cursor if available; else the last request's input tokens; else estimated from text (~4 bytes/token + system overhead). Estimated values show a `~`. |
| "a new chat would be ~N× cheaper" | `context / freshBaselineTokens` (default 15k, a fresh chat plus a handoff) |
| stuck / going in circles | Many steps since your last message, or the same command or file edit repeated |
| parallel | Threads active in the last 3 min (the small fry fish in the bowl) |

**Brain.** A small local model judges the numeric snapshot and decides mood, whether to speak, and what to say. It never sees transcripts. If the model isn't running, built-in rules take over. The **Judge** enforces the fixed rules either way:
- a speech budget (one bubble per thread per 15 min);
- snoozes;
- the LLM can't hide an alarm;
- a celebration when you start fresh after a nudge.

**Reading Goldie:**

| You see | It means |
|---|---|
| Water level | Monthly budget left (`monthlyBudgetUSD`, default $800). It drains as you spend |
| Cloudy / murky water | Your heaviest thread's context is growing |
| Goldie puffed up | The flagged thread costs a lot per turn |
| Tight frantic circles | Runaway loop, or too many agents at once |
| Small fry | Extra agents running in parallel |
| Orange number on the bowl | Goldie has suggestions. Click her → **Goldie's suggestions**, each with its own button |
| Goldie looks stressed but says nothing | No single chat is to blame, but the month is on pace to go over budget |
| Hover Goldie | Quick peek: mood and today's $ |
| Click Goldie (or her speech bubble) | Details: budget bar, chats sorted by what needs you, chats over the cap, setup checklist if something's missing. ⓘ in its header explains every number |
| Drag Goldie | Moves her. She remembers the spot. Menu bar → Size for Small / Medium / Large |
| Menu bar `🐠 $3.20 •` | Today's spend; the dot means Goldie has a suggestion. **Model scorecard** (cost per task that worked, by model and kind of work) is in this menu |

## Run it

```bash
cd projects/goldie
swift build -c release
swift run goldie-selftest                     # core logic tests (no Xcode needed)

# 1. Check that Goldie can read your Cursor data (structure only, no message text):
.build/release/goldiectl probe                # ← paste this output back to Claude
.build/release/goldiectl usage                # ← checks the Cursor cost connection; paste this too

# 2. Install the observe-only Cursor hooks (keeps any hooks you already have; backs up hooks.json):
.build/release/goldiectl install-cursor-hooks # then restart Cursor

# 3. Optional but recommended: the local brain (MLX on Apple Silicon; Meta Llama 3.2 3B, ~1.8 GB download on first run)
pip install mlx-lm
mlx_lm.server --model mlx-community/Llama-3.2-3B-Instruct-4bit --port 8080

# 4. Launch Goldie
.build/release/Goldie
```

**Build trouble with only the Command Line Tools?** If `swift build` crashes with a `BuildServerProtocol` symbol error, use Homebrew's Swift with the CLT SDK:
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk $(brew --prefix swift)/bin/swift build -c release`
(adjust the SDK version to what's in that folder). Installing Xcode also fixes it.

Full install and integration test plan (written for a local agent): [docs/integration-test-plan.md](docs/integration-test-plan.md).

Debug what Goldie sees without the UI: `.build/release/goldiectl snapshot`.

Remove the hooks: `.build/release/goldiectl uninstall-cursor-hooks`.

## Start fresh, suggestions and guards

**Copy handoff.** Goldie writes a handoff (goal, where things stand, files that matter, what not to redo) and copies it to your clipboard. That's all: no files written, no apps opened. Paste it into a new chat. **Copy redirect** works the same way for stuck chats.

**AI Token Budget.** One budget across tools, stacked by who's spending:
- **Cursor:** live, from Cursor's usage (charged amounts; matched the dashboard within 0.3%).
- **Claude:** from your LLM gateway's `/key/info`.
  - Set `sources.claudeGatewayURL` in the config.
  - Store the key once, pre-approving Goldie so macOS doesn't ask every time: `security add-generic-password -s goldie-llmg -a llmg -w '<key>' -T "$PWD/.build/release/Goldie"`. Or set env `GOLDIE_LLMG_KEY`.
  - If the key has a monthly budget period, that spend is used as-is. If it only reports lifetime spend, Goldie counts from the first reading it sees each month, and says so when you hover the icon.
- **Codex / OpenCode:** no API hookup yet. Set `sources.codexMonthUSD` / `sources.opencodeMonthUSD` to include them.

Hover a tool's icon for its status. The icons are stand-in symbols, not official logos.

**Guidance by situation, not just size.** A heavy chat isn't automatically "start fresh":
- **✨ Heavy and waiting for you (task boundary):** the right moment to start the *next* task fresh. Goldie nudges.
- **↩︎ Stuck (same command or edit repeated):** **Copy redirect** makes the agent stop, summarize and rethink. Usually better than a new chat. Goldie nudges.
- **⏳ Heavy but mid-task:** let it finish. A new chat would re-pay to rediscover everything. Shown, not nagged.
- **💤 Heavy but idle:** it costs nothing until you send another message. Shown, not nagged.

"Heavy" is measured against what a fresh chat really costs you. Goldie learns that from your chats' first messages (`baseline.json`) instead of assuming 15k tokens.

**Per-chat cap.** Any chat that costs more than `chatCapUSD` this month (default **$20**) is marked:
- a red **over $20** tag on the chat, with advice to start the next task fresh;
- an **Over the $20 cap this month** list in the card, including chats you've closed, with how much of the month they account for;
- one speech bubble when a live chat crosses the cap (not for chats already over when Goldie starts).

Sub-task chats count toward their parent. Why $20: it's 2.5% of an $800 month, about half a working day's share, so 40 such chats use the whole budget. `goldiectl usage` prints your chats' median and p90 spend to help pick your own number. Set it to 0 to turn the cap off.

**Hiding.** The 👁 button in the card (or right-click the bowl) hides her. To bring her back:
- the 🐠 menu bar item → Show Goldie (it's put back at every launch and every hide, even if it was ⌘-dragged out);
- **⌃⌥⌘G** anywhere (toggles her);
- `goldiectl show`, or just launch Goldie again: the running one comes back instead of a second copy starting.

Can't see the 🐠 in the menu bar? On a MacBook with a notch, a full menu bar hides items behind it; quit a few menu bar apps. On macOS 26, also check System Settings → Menu Bar.

**Suggestions.** The orange number on the bowl counts them:
- start fresh for heavy chats;
- turn on a guard when Goldie saw the problem happen;
- trim the rules and tool setup every chat starts with.


**Guards (opt-in, menu bar).** They use Cursor's before-shell and before-read hooks. Restart Cursor after turning one on.
- **Loop guard:** blocks the Nth identical command in a task (default 4) when no file was edited in between, and tells the agent to change approach.
- **Big-read guard:** refuses files over 256 KB once, telling the agent to search them. Asking again is allowed.
- **Fail-open:** when Goldie is not blocking (or has any problem), the hook replies with no opinion, so Cursor's own approval rules apply and nothing is blocked or auto-approved by accident.

## Config

`~/.config/goldie/config.json` (create with `goldiectl init-config`, or menu bar → Open config). Partial files are fine; anything missing uses the default.

```json
{
  "freshBaselineTokens": 15000,
  "heavyRatio": 4,
  "alarmedRatio": 8,
  "parallelAlarm": 4,
  "speechCooldownMinutes": 15,
  "chatCapUSD": 20,
  "llm": { "enabled": true, "endpoint": "http://127.0.0.1:8080/v1/chat/completions",
           "model": "mlx-community/Llama-3.2-3B-Instruct-4bit" },
  "inputPricePerMTok": {}
}
```

**Model policy: non-Chinese models only.** `blockedModelKeywords` (default: Qwen/QwQ, DeepSeek, GLM, Baichuan, InternLM, MiniMax, Kimi/Moonshot, Hunyuan, ERNIE, Yi, Doubao) stops Goldie's brain from running on a matching model. Any Cursor chat using one is flagged ⛔︎ in the details card. Non-Chinese alternatives for the brain include Google Gemma 3 and Microsoft Phi-4-mini (MLX builds on `mlx-community`).

`inputPricePerMTok` is optional. Add e.g. `{"grok": <$ per 1M input tokens>}` to see `$/turn` estimates.

## Known unknowns (POC)

- **Cursor's DB schema is undocumented** and changes between versions. `goldiectl probe` shows which fields exist. The context estimate falls back to text length when token fields are missing.
- **Hook payload fields** (conversation id, model) are inferred from Cursor's hooks docs. The probe prints the actual payload keys it received.
- `rowid` ordering is used as a fast "recently updated" index. The probe compares it against `lastUpdatedAt`.
- The Cursor usage endpoint (`/api/dashboard/get-filtered-usage-events`) is what cursor.com's dashboard uses. It's undocumented. `goldiectl usage` shows whether it works for your account.
- Per-chat $ is matched by time, so two chats running at the same second can swap a few cents.

## Layout

```
Sources/GoldieCore   sensors (CursorStore, HookTracker), Signals, Brain + Judge, LLMBrain, Handoff, probe
Sources/Goldie       SwiftUI app: floating panel, bowl + fish, details card, menu bar
Sources/goldiectl    CLI: hook sink, hook installer, probe, snapshot
Tests/               core logic tests
```
