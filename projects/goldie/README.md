# Goldie 🐠

A small goldfish that floats on your Mac desktop and tells you when a Cursor agent thread has become too expensive to keep going, so you start a fresh one.

**Why:** every agent turn re-sends the whole thread, so per-turn cost grows with context. A fresh thread plus a short handoff is often far cheaper than one more turn in a bloated thread. See [PRD.md](PRD.md).

> **Status: POC.** Cursor only. No spend meters yet. Apple Silicon, macOS 14+ (built for 26).

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

**Signals per thread:**

| Signal | Meaning |
|---|---|
| context tokens | Reported by Cursor if available; else the last request's input tokens; else estimated from text (~4 bytes/token + system overhead). Estimated values show a `~`. |
| context ratio | `context / freshBaselineTokens` (default 15k). "One more turn costs ≈ N fresh starts." |
| loop score | Tool calls since you last spoke, plus the same command or file edit repeated |
| parallel | Threads active in the last 3 min (the small fry fish in the bowl) |

**Brain.** A small local model judges the numeric snapshot and decides mood, whether to speak, and what to say. It never sees transcripts. If the model isn't running, built-in rules take over. The **Judge** enforces the fixed rules either way:
- a speech budget (one bubble per thread per 15 min);
- snoozes;
- the LLM can't hide an alarm;
- a celebration when you start fresh after a nudge.

**Reading Goldie:**

| You see | It means |
|---|---|
| Cloudy / murky water | Your heaviest thread's context is growing |
| Goldie puffed up | The flagged thread costs a lot per turn |
| Tight frantic circles | Runaway loop, or too many agents at once |
| Small fry | Extra agents running in parallel |
| A fresh bowl appears: *"fresh water?"* | Click it to copy a handoff prompt, then paste it into a new chat |
| Click Goldie | Details: every live thread, the brain's reasoning, handoff / snooze / not-helpful buttons |
| Drag Goldie | Moves her |

## Run it

```bash
cd projects/goldie
swift build -c release
swift test                                    # core logic tests

# 1. Check that Goldie can read your Cursor data (structure only, no message text):
.build/release/goldiectl probe                # ← paste this output back to Claude

# 2. Install the observe-only Cursor hooks (keeps any hooks you already have; backs up hooks.json):
.build/release/goldiectl install-cursor-hooks # then restart Cursor

# 3. Optional but recommended: the local brain (MLX on Apple Silicon, ~2.5 GB download on first run)
pip install mlx-lm
mlx_lm.server --model mlx-community/Qwen3-4B-Instruct-2507-4bit --port 8080

# 4. Launch Goldie
.build/release/Goldie
```

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
           "model": "mlx-community/Qwen3-4B-Instruct-2507-4bit" },
  "inputPricePerMTok": {}
}
```

`inputPricePerMTok` is optional. Add e.g. `{"grok": <$ per 1M input tokens>}` to see `$/turn` estimates.

## Known unknowns (POC)

- **Cursor's DB schema is undocumented** and changes between versions. `goldiectl probe` shows which fields exist. The context estimate falls back to text length when token fields are missing.
- **Hook payload fields** (conversation id, model) are inferred from Cursor's hooks docs. The probe prints the actual payload keys it received.
- `rowid` ordering is used as a fast "recently updated" index. The probe compares it against `lastUpdatedAt`.
- Water level (monthly budget) is always full until the spend meters land.

## Layout

```
Sources/GoldieCore   sensors (CursorStore, HookTracker), Signals, Brain + Judge, LLMBrain, Handoff, probe
Sources/Goldie       SwiftUI app: floating panel, bowl + fish, details card, menu bar
Sources/goldiectl    CLI: hook sink, hook installer, probe, snapshot
Tests/               core logic tests
```
