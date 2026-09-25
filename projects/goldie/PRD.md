# PRD — Goldie 🐠

> Status: draft v0.1 · Owner: Yasin

## 1. Problem

My enterprise AI allowance is **$800/month**, measured in API cost. I currently spend **~$20,000/month**, so I need a **25× reduction**.

**Where the money actually goes (Sep 2026 month-to-date, as of the 25th):**

| Harness | MTD | Share |
|---|---|---|
| Codex | $18,195.83 (279,936 credits) | **~97%** |
| Cursor | ~$412 | ~2% |
| Claude | ~$79 | <1% |
| **Total** | **~$18,687**, on pace for ~$22.4k/month | |

**Codex is the problem.** Even if Cursor and Claude went to zero, Codex alone is ~23× over budget.

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
- Config is a file (`~/.config/goldie/config.toml`). A settings UI is optional.

## 4. Experience

### The mascot: Goldie
- A **floating desktop pet**: an always-on-top, draggable panel that stays on every Space and never steals focus. It has a menu bar icon for settings and quit.
- **Goldie is a goldfish in a round fishbowl**, styled as a Funko-Pop-esque "pop-funk" vinyl figure: oversized head, big glossy black eyes, chunky fins, saturated orange, and a soft vinyl sheen.
- **Why a goldfish:** goldfish memory is the whole point. Short context is cheap context. Goldie is happiest with a fresh bowl and a fresh memory.
- Personality: **mostly silent**. It speaks (a small speech bubble) only when it matters, or when clicked.

### The bowl is the dashboard
Goldie shows real numbers visually, so you can read state from across the screen without hovering:

| Visual | Encodes |
|---|---|
| **Water level** | Monthly budget left (full bowl = $800 left; it drains as you spend) |
| **Water clarity** | Context bloat of the worst live thread (clear, then cloudy, then murky green) |
| **Goldie's size / puffiness** | Next-turn cost of the focused thread (Goldie bloats as a thread gets heavy) |
| **Small fry fish** | One per parallel agent running (a crowded bowl means many agents burning money) |
| **Swim pattern** | Circling the bowl in tight laps = runaway loop |

### Moods (the animation set)
The *decision* of which mood to show comes from the AI brain (see §6). The *set* of moods is finite so we can animate them:

| Mood | Meaning | Goldie does |
|---|---|---|
| Sleeping | No agents active | Drifts near the bottom, eyes shut, slow "z" bubbles |
| Working | Agents running, costs healthy | Lazy happy laps, occasional bubble |
| Heavy | A thread is getting expensive per turn | Puffed up, slow, water clouding. Glances at an empty fresh bowl. |
| Alarmed | Runaway loop, huge marginal turn, or too many parallel agents burning | Tight frantic circles, wide eyes, bowl flashes |
| Stressed | Monthly pace projects well over $800 | Water level visibly low. Goldie presses against the glass. |
| Celebrating | I started fresh after a nudge, or today is under pace | Hops into a fresh clear bowl, flips, sparkle bubbles |

**Signature "start fresh" moment:** a new empty bowl of clear water appears beside Goldie. Clicking it copies the handoff, and Goldie jumps across. The nudge copy stays tiny: *"fresh water?"*

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
| `model_tier` | Premium model, Max Mode, or high reasoning effort (Codex `model_reasoning_effort`) vs standard |
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

## 7. Data sources

There are two layers, because no single source gives both *true money* and *per-thread detail*:

- **Meters** answer "how much have I really spent?" They are billing truth, but only totals.
- **Thread sensors** answer "what is *this* thread costing per turn?" They are local, real-time, and estimated.

### 7a. Meters (money truth)

There are **three separate meters, not one API**. Goldie adds them up.

| Harness | Meter | Auth | Notes |
|---|---|---|---|
| **Claude** | LLM Gateway (LiteLLM): `GET /key/info` (key spend/budget) and `GET /v2/user/info` (user spend/budget) | LLMG virtual key, `Authorization: Bearer …` | Claude is the **only** harness on this key, since traffic is tagged `x-sf-ai-harness-client-id: claude`. So every $ on this key is Claude Code. `/user/daily/activity` returns **403** for virtual keys, so there's no server-side daily or tag breakdown. |
| **Cursor** | Cursor `GET /api/usage-summary` (amounts in **cents**) | Signed-in Cursor session | Not on the gateway. Cursor's own billing. |
| **Codex** | ChatGPT **credits** | ChatGPT login | No known usage URL. The known sources are DevBar's `Codex usage fetched … credits` log line, or Codex Settings → Usage. Rate: **$0.065 / credit**, derived from DevBar ($18,195.83 ÷ 279,936). Stored in config in case it changes. |

**DevBar already reads all three.** v1 option: **tail DevBar's log** instead of re-implementing three auth flows. Goldie then only needs to parse the log. Direct providers stay as a fallback if DevBar isn't running.

DevBar also exposes a company budget view (`/proxy/budget/api/v1/budget?periodType=month` via the DevBar proxy, personal-spend scope). It's a candidate for the "vs budget" denominator, though my own $800 target lives in config either way.

**Totals → time series.** All the meters return running totals, so Goldie **polls and stores snapshots, then diffs them**. That diff is the only way to get per-day and per-hour spend (it gets around the 403 on daily activity).

**Calibration trick (Claude).** The gateway key is Claude-only, so `gateway Δ$` over a window should equal the sum of Goldie's local per-turn estimates for Claude Code in that window. The ratio gives a **live correction factor** for the local cost model (pricing, caching and gateway markup). Same idea for Cursor: compare the summary's Δ with local estimates.

**Secrets** (LLMG key, any session tokens) live in the **macOS Keychain**, never in `config.toml` or the repo. Internal hostnames go in local config only.

### 7b. Thread sensors (per-thread, real-time)

Each harness gets an adapter that emits normalized `TurnEvent`s:
`{harness, thread_id, workspace, model, ts, input_tokens, cache_read, cache_write, output_tokens, tool_calls[], user_initiated}`.

| Harness | Mechanism | Phase |
|---|---|---|
| **Cursor** | (a) Cursor agent hooks (`~/.cursor/hooks.json`) call our tiny `goldie-hook` CLI for real-time turn/stop events. (b) Read Cursor's local state DB (`state.vscdb`, composer/bubble records) for token counts and model. (c) If the dashboard's per-request usage events are reachable with the session, that gives **exact per-request cost**. **Spike all three.** | v1 |
| **Claude Code** | Tail `~/.claude/projects/**/*.jsonl` (per-message `usage`, the same data `ccusage` reads) plus Claude Code hooks (`Stop`, `UserPromptSubmit`) | v2 |
| **Codex** | Tail `~/.codex/sessions/**/rollout-*.jsonl` (`token_count` events) plus `notify` hook | v2 |
| **Desktop chat apps** | No local usage data. At most "app is active" presence. | v3 / maybe never |

Hook CLIs never block the harness. They append to a local socket or spool file and exit immediately.

## 8. Architecture

```
 Harness hooks ──► hook CLI ──┐
 Local logs/DBs ──► Adapters ─┼─► Event store (SQLite) ─► Signal engine ─► Brain (MLX) ─► Mascot UI
 Meters (3) ────► Poller ────┘                                    │                  (SwiftUI panel
                                                                   └──── fallback ────►  + menu bar)
```

- **Swift 6 + SwiftUI**, arm64 only, macOS 26+. Single app, plus a small bundled CLI for hooks.
- Floating pet: borderless, transparent, non-activating `NSPanel` at floating level, on all Spaces.
- Mascot rendering: **Rive** (its state machines map cleanly onto the moods) or SpriteKit. We'll decide once the character is chosen.
- Storage: SQLite (GRDB). It keeps 90 days of turn events for trends.
- Privacy: everything stays local. The only network calls are the meter polls (or none, if reading DevBar's log) and a one-time model download.

## 9. Milestones

| # | Scope | Exit criteria |
|---|---|---|
| **M0 Spikes** | Locate DevBar's log and format. Get the Codex credits → $ rate. Verify Cursor hook payloads and `state.vscdb` token fields on my machine. Pick the MLX model. Commission/draw Goldie concept art. | Written findings in `docs/spikes.md` |
| **M1 Skeleton** | Menu bar + floating panel with a placeholder mascot. Cursor adapter, event store, signal engine. Deterministic moods only. | Live per-thread `$ / next turn` for Cursor on screen |
| **M2 Brain** | MLX brain, speech budget, feedback loop, handoff generation. | Nudges feel right for a week of real use |
| **M3 Money** | Three meters (DevBar log first, direct fallback), snapshot diffing, calibration factor, projection, daily allowance, Stressed mood. | Pet totals match DevBar within a few % |
| **M4 More harnesses** | Claude Code and Codex adapters. | All three harnesses in one view |
| **M5 Goldie** | Final pop-funk Goldie + bowl art, a Rive state machine for every mood and the bowl encodings. | Looks good enough to leave on all day |

## 10. Open questions
1. **DevBar log:** path, format, how often it refreshes, and is DevBar always running?
2. Is the $800 per calendar month (assumed), or on a billing-cycle date?
3. Which MLX model is "smart enough"? We'll evaluate 2–3 candidates on recorded snapshots in M2.

### Resolved
- Meters report **monthly** (month-to-date) values.
- Codex credits → $: **$0.065 / credit**.
- **Cursor first.** Day-to-day work has moved to Cursor running Grok because it's cheap, so the POC targets Cursor only. Meters and credit conversion are deferred.
- **Brain runtime for the POC:** `mlx_lm.server` (MLX, local, OpenAI-compatible HTTP) instead of embedding `mlx-swift`. Same model, far less integration risk. Embedding can come later.

## 11. v1 scope & sign-off

**v1 = Cursor-only Goldie, for personal use.**

**In v1 (built):**
- **Sensors:** Cursor hooks (observe-only) plus a read-only reader for Cursor's state DB, with an incremental message cache.
- **Real costs from Cursor usage:**
  - today and month totals;
  - per chat: spent, last task, per step;
  - month projection against the budget, with a silent "stressed" mood when the month runs hot.
- **Signals:** context size, loops and re-asks, parallel chats, big reads, heavy starting context.
- **Brain:** a local non-Chinese model (Llama 3.2 3B via MLX) with a rules fallback, plus guardrails (speech budget, "Not now", alarms can't be hidden).
- **Start fresh:** handoff for any selected chat, then Cursor is brought forward.
- **Cost per task, by kind of work:**
  - an evidence-gated model scorecard and advice, which can recommend a pricier model;
  - a bloat detector and a setup tip.
- **UI:**
  - budget bar;
  - details card (verdict, sorted chats, context meters, legend, setup checklist);
  - hover peek, sizes, remembered position, Reduce Motion support;
  - menu bar with today's $.
- **Model policy:** no Chinese-vendor models, for Goldie's brain or for flagged Cursor chats.

**Deferred to v2:**
- **Codex and Claude Code sensors and meters.** Codex is ~97% of total spend, so v1 alone won't close the $20k → $800 gap.
- Keychain.
- Final art (Rive).
- DevBar log reader.
- Price tag before Enter (Cursor before-submit hook).
- Savings scoreboard.
- Embedded `mlx-swift`.

**Sign-off checklist:**

| # | Item | Owner | Blocking? |
|---|---|---|---|
| 1 | `swift build -c release` and `swift test` pass on the Mac at the latest commit | Yasin → Claude fixes | Yes |
| 2 | Send `goldiectl probe` and `goldiectl usage` output; Claude corrects schema assumptions (message timestamps, token fields, hook payloads, usage endpoint). Costs and task tracking depend on these. | Yasin → Claude | Yes |
| 3 | 3–5 day soak: note wrong or missed nudges; Claude tunes thresholds and wording | Yasin → Claude | Yes |
| 4 | Package `Goldie.app`: double-click to run, launch at login, no Terminal needed | Claude | Yes |
| 5 | Privacy pass: Cursor token never logged or stored; hooks observe-only; one-step uninstall that removes hooks and local data | Claude | Yes |
| 6 | Brain: confirm the Llama model runs (or accept rules-only) | Yasin | No |
| 7 | Docs: README install/uninstall, PRD final | Claude | No |
| 8 | Open a PR into `main`, review, merge | Yasin | Yes |

**Exit criteria:**
- Clean build and tests.
- Goldie's month total within ~5% of Cursor's dashboard.
- Start fresh works end to end.
- At most ~1 unwanted nudge a day during the soak.
- No Chinese-vendor models anywhere.
