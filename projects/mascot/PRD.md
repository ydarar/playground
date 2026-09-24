# PRD — AI Spend Mascot (working title)

> Status: draft v0.1 · Owner: Yasin · Folder will be renamed once we pick a name.

## 1. Problem

My enterprise AI allowance is **$800/month**, measured in API cost through our Bedrock LLM gateway. I currently spend **~$20,000/month**, so I need a **25× reduction**.

The single biggest leak is **long-running agent threads**. LLMs are stateless, so every turn re-sends the full context: system prompt, files read, tool output and all earlier turns. The cost of turn *n* is roughly `context_n × input price`, and context only grows, so **the total cost of a thread grows roughly with the square of its length**. Prompt caching helps (cached re-reads are cheap), but it doesn't remove this. A fresh task with a tight handoff is often far cheaper than one more turn in a bloated thread.

Nothing in Cursor, Claude Code or Codex tells me this in the moment. I only find out at the end of the month.

## 2. Goal

A small, mostly-silent **desktop mascot** for Apple Silicon Macs that:

1. Knows what every running agent thread costs **per next turn**, across harnesses.
2. Uses **local AI judgment** (not a hard-coded rule set) to decide when a thread should be abandoned for a fresh one, and says so.
3. Helps me **hand off** to the fresh task (generates a handoff prompt).
4. Keeps the **monthly $ vs $800** reality visible at a glance.

### Success metrics
- Monthly gateway spend trends toward $800. First milestone: under $5k within 2 months.
- Median context size per turn drops (tracked per harness).
- Nudge acceptance rate is at least 50%. If it's lower, the brain is too noisy.
- The mascot's own cost is **$0 marginal**, because inference runs on-device.

### Non-goals (v1)
- Blocking, killing or throttling agents. It advises; it doesn't enforce.
- Team or org dashboards, sharing, signing or notarization. It's a personal tool.
- Intel Macs, macOS < 26, Windows or Linux.
- Replacing the gateway as the source of truth for billing.

## 3. Users & context
- **Just me.** I run agents in Cursor (primary, v1), Claude Code and Codex (v2), and Claude/ChatGPT desktop apps (best-effort, v3+).
- macOS 26 (Tahoe) or later, Apple Silicon only.
- Config is a file (`~/.config/<name>/config.toml`). A settings UI is optional.

## 4. Experience

### The mascot
- A **floating desktop pet**: an always-on-top, draggable panel that stays on every Space and never steals focus. It has a menu bar icon for settings and quit.
- Style: **Funko-Pop-esque "pop-funk" vinyl figure**. The character is TBD (see §10).
- Personality: **mostly silent**. Mood shows through animation. It speaks (a small speech bubble) only when it matters, or when clicked.

### Moods (the animation set)
The *decision* of which mood to show comes from the AI brain (see §6). The *set* of moods is finite so we can animate them:

| Mood | Meaning |
|---|---|
| Sleeping | No agents active |
| Working | Agents running, costs healthy |
| Heavy | A thread is getting expensive per turn |
| Alarmed | Runaway loop, huge marginal turn, or too many parallel agents burning |
| Stressed | Monthly pace projects well over $800 |
| Celebrating | I started fresh after a nudge, or today is under pace |

### Interactions
- **Hover** shows a mini card: today's $, month-to-date vs $800, projected month-end, and the most expensive live thread's next-turn cost.
- **Click** shows the "why" panel. It lists every live thread (harness, model, context size, $/next turn, turns, loop score) and the brain's reasoning in one line.
- **Nudge actions:** `Copy handoff` · `Snooze this thread` · `Not helpful`. Snooze and not-helpful feed back into the brain's prompt as recent feedback.
- A macOS notification only for *Alarmed*, in case the pet is hidden.

## 5. What it watches (signals)

All signals are computed **deterministically and locally**. They're cheap, testable and free.

| Signal | Definition |
|---|---|
| `context_tokens` | Current context size of the thread (last turn's total input) |
| `next_turn_cost` | Estimated $ of one more turn: uncached input + cache reads + cache writes + typical output, × model price |
| `fresh_start_cost` | Estimated $ of the first turn of a fresh thread with a handoff (base system prompt + ~2k handoff) |
| `cost_ratio` | `next_turn_cost / fresh_start_cost`, the core "start fresh" signal |
| `thread_cost` | Cumulative $ of this thread |
| `loop_score` | Autonomous tool calls since the last user message, plus repetition (same file edited or same test run N times, same error text) |
| `model_tier` | Premium model or Max Mode vs standard |
| `parallel_agents` | Threads active in the last N minutes, and their combined $/min |
| `month_to_date` / `projected` | From the gateway (ground truth), with a linear or workday projection vs $800 |
| `daily_allowance` | `(800 − MTD) / remaining workdays` |

Model prices live in `config.toml` (from our gateway/Bedrock pricing). They aren't hard-coded.

## 6. The brain (AI judgment)

**Why not a rule set:** "Should I start fresh?" depends on more than one number. Is the thread converging or circling? Is it 5 minutes from done? Is the month already blown? Did I just dismiss the same nudge? An LLM weighs that better than a pile of thresholds.

**How:**
- **Runtime:** a local open model via **MLX** on the Mac's GPU, through `mlx-swift`. Start with a ~3–4B instruct model at 4-bit (~2–3 GB). Unload it after it's been idle for a while.
- **Input:** a compact JSON snapshot of the signals above for all live threads, plus the last few nudges and my feedback. For judgment calls it **never gets transcripts**.
- **Output (schema-constrained JSON):** `{ mood, speak: bool, target_thread?, message?, reason, suggested_action }`.
- **When it runs (event-driven, not polling):** a new turn finishes, a thread crosses a signal band, a loop is detected, a gateway refresh lands, or at most every ~5 min while agents run.
- **Guardrails** (the only hard-coded logic):
  - A speech budget: at most one bubble per thread per ~15 min unless Alarmed.
  - If the model fails or times out, fall back to a simple deterministic mood.
  - The brain can't hide Alarmed-level signals.

**Handoff generation** is the only time the model reads thread content. It reads locally, and nothing leaves the machine. Input: the first user message (the goal), files touched, the last few turns, and open errors. Output: a ≤300-word handoff prompt with goal, current state, files that matter, next step, and what *not* to redo. It's copied to the clipboard.

## 7. Data sources (adapters)

The app is harness-agnostic: each harness gets an adapter that emits normalized `TurnEvent`s:
`{harness, thread_id, workspace, model, ts, input_tokens, cache_read, cache_write, output_tokens, tool_calls[], user_initiated}`.

| Source | Mechanism | Phase |
|---|---|---|
| **Bedrock gateway** | Your existing alias commands (**details pending from Yasin**). Ground truth for MTD spend. | v1 |
| **Cursor** | (a) Cursor agent hooks (`~/.cursor/hooks.json`) call our tiny `…-hook` CLI for real-time turn/stop events. (b) Read Cursor's local state DB (`state.vscdb`, composer/bubble records) for token counts and model. **Needs a spike to confirm the fields.** | v1 |
| **Claude Code** | Tail `~/.claude/projects/**/*.jsonl` (per-message `usage`) plus Claude Code hooks (`Stop`, `UserPromptSubmit`) | v2 |
| **Codex** | Tail `~/.codex/sessions/**/rollout-*.jsonl` (`token_count` events) plus `notify` hook | v2 |
| **Desktop chat apps** | No local usage data. At most "app is active" presence. | v3 / maybe never |

Hook CLIs never block the harness. They append to a local socket or spool file and exit immediately.

## 8. Architecture

```
 Harness hooks ──► hook CLI ──┐
 Local logs/DBs ──► Adapters ─┼─► Event store (SQLite) ─► Signal engine ─► Brain (MLX) ─► Mascot UI
 Gateway alias ──► Poller ────┘                                    │                  (SwiftUI panel
                                                                   └──── fallback ────►  + menu bar)
```

- **Swift 6 + SwiftUI**, arm64 only, macOS 26+. Single app, plus a small bundled CLI for hooks.
- Floating pet: borderless, transparent, non-activating `NSPanel` at floating level, on all Spaces.
- Mascot rendering: **Rive** (its state machines map cleanly onto the moods) or SpriteKit. We'll decide once the character is chosen.
- Storage: SQLite (GRDB). It keeps 90 days of turn events for trends.
- Privacy: everything stays local. The only network calls are the gateway spend poll and a one-time model download.

## 9. Milestones

| # | Scope | Exit criteria |
|---|---|---|
| **M0 Spikes** | Get the gateway alias details. Verify Cursor hook payloads and `state.vscdb` token fields on my machine. Pick the MLX model. Pick the mascot and name. | Written findings in `docs/spikes.md` |
| **M1 Skeleton** | Menu bar + floating panel with a placeholder mascot. Cursor adapter, event store, signal engine. Deterministic moods only. | Live per-thread `$ / next turn` for Cursor on screen |
| **M2 Brain** | MLX brain, speech budget, feedback loop, handoff generation. | Nudges feel right for a week of real use |
| **M3 Money** | Gateway MTD meter, projection, daily allowance, Stressed mood. | Pet numbers match the gateway within a few % |
| **M4 More harnesses** | Claude Code and Codex adapters. | All three harnesses in one view |
| **M5 Character** | Final pop-funk art and animations for every mood. | Looks good enough to leave on all day |

## 10. Open questions
1. **Gateway aliases:** what do they call (CLI, HTTP, log) and what do they return? Can the gateway break spend down by client (Cursor vs Claude Code vs Codex) or by request?
2. **Does Cursor route through the Bedrock gateway** (your own keys), or through Cursor's own billing? This changes which numbers are ground truth for Cursor.
3. Is the budget per calendar month, or on a billing cycle date?
4. Mascot character and name. Brainstorm next.
5. Which MLX model is "smart enough"? We'll evaluate 2–3 candidates on recorded snapshots in M2.
