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
| A fresh bowl appears: *"fresh water?"* | Click it to copy a handoff prompt, then paste it into a new chat |
| Goldie looks stressed but says nothing | No single chat is to blame, but the month is on pace to go over budget |
| Hover Goldie | Quick peek: mood and today's $ |
| Click Goldie (or her speech bubble) | Details: budget bar, Goldie's verdict with **Start fresh**, chats sorted by what needs you, setup checklist if something's missing |
| Drag Goldie | Moves her. She remembers the spot. Menu bar → Size for Small / Medium / Large |
| Menu bar `🐠 $3.20 •` | Today's spend; the dot means Goldie has a suggestion |

## Run it

```bash
cd projects/goldie
swift build -c release
swift test                                    # core logic tests

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

Full install and integration test plan (written for a local agent): [docs/integration-test-plan.md](docs/integration-test-plan.md).

Debug what Goldie sees without the UI: `.build/release/goldiectl snapshot`.

Remove the hooks: `.build/release/goldiectl uninstall-cursor-hooks`.

## Config

`~/.config/goldie/config.json` (create with `goldiectl init-config`, or menu bar → Open config). Partial files are fine; anything missing uses the default.

```json
{
  "freshBaselineTokens": 15000,
  "heavyRatio": 4,
  "alarmedRatio": 8,
  "parallelAlarm": 4,
  "speechCooldownMinutes": 15,
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
