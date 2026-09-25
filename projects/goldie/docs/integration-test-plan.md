# Goldie: install and integration test plan (for a local agent)

You are a coding agent on the user's Mac. Your job: install the latest Goldie, verify it works against the user's **real** Cursor setup, and write a report the user can paste back to the Claude session that built Goldie.

Work through the steps in order. After each step, record what happened (pass/fail plus evidence) for the report in step 9.

## Ground rules

- **Secrets:** never print, copy, log or put in the report the Cursor access token, cookies, or raw values from `state.vscdb`. `goldiectl probe` and `goldiectl usage` are designed not to print them; don't work around that.
- **Privacy:** don't put chat text, prompts, code or command output from the user's Cursor chats in the report. Structure, counts and field names only.
- **Code changes:** don't change Goldie's behavior. If the build fails, you may make the *minimal* compile fix, but leave it uncommitted and include `git diff` in the report. Don't push anything.
- **Config:** if you change `~/.config/goldie/config.json` for a test, back it up first and restore it afterwards. Say so in the report.
- **Models:** no Chinese-vendor models (Qwen, DeepSeek, GLM, Kimi, MiniMax, etc.). The brain model is `mlx-community/Llama-3.2-3B-Instruct-4bit`.
- **Ask the user when:**
  - a step needs a human: restarting Cursor, running a Cursor agent chat, looking at the screen, or reading the cursor.com dashboard;
  - something would delete user data.
- **If you're running inside Cursor:** restarting Cursor will end your session. At step 5, stop and ask the user to restart Cursor, then to re-invoke you with "continue the Goldie test plan from step 6".

## 1. Preflight

```bash
sw_vers; uname -m; swift --version; ls -d /Applications/Cursor.app; python3 --version
```

Pass when:
- `uname -m` prints `arm64`;
- macOS is 14 or later (26 expected);
- Swift is 6.x;
- Cursor.app exists.

## 2. Get the latest code

```bash
if [ -d ~/playground/.git ]; then cd ~/playground && git fetch origin && git checkout claude/beautiful-brown-d8r9ji && git pull --ff-only;
else git clone https://github.com/ydarar/playground.git ~/playground && cd ~/playground && git checkout claude/beautiful-brown-d8r9ji; fi
git log --oneline -1
```

If Goldie is running, quit it first: `pkill -x Goldie`.

## 3. Build and unit tests

```bash
cd ~/playground/projects/goldie
swift build -c release 2>&1 | tail -30
swift test 2>&1 | tail -30
```

Pass when:
- the build prints `Build complete!`;
- the tests report 0 failures.

Warnings are fine. On errors, copy the first 40 lines starting at the first `error:` into the report.

## 4. Diagnostics (structure only)

```bash
.build/release/goldiectl probe > /tmp/goldie-probe.txt; cat /tmp/goldie-probe.txt
.build/release/goldiectl usage > /tmp/goldie-usage.txt; cat /tmp/goldie-usage.txt
```

Answer these in the report. They check assumptions Goldie makes about Cursor's undocumented data:

| # | Question | Where to look |
|---|---|---|
| D1 | Do bubbles have a `createdAt` field? (Task tracking needs it.) | "bubble fields" line |
| D2 | Are `tokenCount` values non-zero for assistant bubbles (type2)? | "tokenCount samples" |
| D3 | What `context source` does Goldie derive: reported, lastRequest or estimated? | "What Goldie derives" |
| D4 | Does "newest by rowid" roughly match "newest by lastUpdatedAt"? | the two newest lists |
| D5 | Which top-level composer fields mention context or tokens? | "top-level fields" |
| D6 | Usage API: HTTP status, event keys, and this month's total | usage output |

## 5. Install Cursor hooks (observe-only)

```bash
.build/release/goldiectl install-cursor-hooks
cat ~/.cursor/hooks.json
```

Pass when `hooks.json` lists `goldiectl … hook <event>` for `afterAgentResponse`, `afterShellExecution`, `afterFileEdit`, `afterMCPExecution` and `stop`, and any hooks the user already had are still there. A backup is written to `~/.cursor/hooks.json.goldie-backup`.

**Ask the user to quit Cursor fully (⌘Q) and reopen it.**

## 6. Local AI brain (Llama 3.2 3B via MLX)

```bash
# Remove old Qwen weights if present (user asked for no Chinese models):
ls ~/.cache/huggingface/hub | grep -i qwen && rm -rf ~/.cache/huggingface/hub/models--mlx-community--Qwen*
python3 -m venv ~/.goldie-venv && ~/.goldie-venv/bin/pip install -q mlx-lm
nohup ~/.goldie-venv/bin/mlx_lm.server --model mlx-community/Llama-3.2-3B-Instruct-4bit --port 8080 > /tmp/goldie-mlx.log 2>&1 &
# Wait for the model to download and load, then:
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Llama-3.2-3B-Instruct-4bit","messages":[{"role":"user","content":"Reply with only: {\"ok\": true}"}],"max_tokens":20}'
```

Pass when the curl returns JSON with `choices[0].message.content`.

If the model name can't be found:
- note it in the report;
- try `mlx-community/gemma-3-4b-it-4bit` (Google) or `mlx-community/Phi-4-mini-instruct-4bit` (Microsoft);
- put the one that works in the config as `llm.model`.

Then check the config:
```bash
cat ~/.config/goldie/config.json 2>/dev/null | grep -i '"model"'
```
If it names a Qwen model, change it to the Llama model above. That config may have been written with the old default.

## 7. Launch Goldie

```bash
nohup .build/release/Goldie > /tmp/goldie-app.log 2>&1 &
sleep 5; pgrep -x Goldie && tail -20 /tmp/goldie-app.log
```

Pass when the process is running and the log shows no crash. **Ask the user** to confirm:
- a goldfish bowl is visible (bottom-right on first launch);
- a 🐠 is in the menu bar.

You may take a screenshot with `screencapture -x /tmp/goldie.png` and look at it yourself.

## 8. Integration tests

For the tests marked **(user)**, ask the user to run the Cursor chat described, then verify with the commands shown. `goldiectl snapshot` prints what Goldie sees (no chat text). Summarize its fields rather than pasting it whole.

**Before IT-6:** back up the config (`cp ~/.config/goldie/config.json /tmp/goldie-config.bak` if it exists).

| ID | Test | How | Pass when |
|---|---|---|---|
| IT-1 | Hooks fire **(user)** | User runs any Cursor **agent** chat that runs one terminal command and edits one file. Then `tail -5 ~/"Library/Application Support/Goldie/cursor-hook-events.jsonl"`, reporting event names and `keys` only. | Events arrive with a `conversation_id`. Report which payload keys Cursor sends. |
| IT-2 | Chat detection | `.build/release/goldiectl snapshot` | The chat from IT-1 appears with the right title and model, `contextSource` ≠ `unknown`, and plausible `contextTokens`. |
| IT-3 | Task tracking | Same snapshot: `threads[].tasks` | At least one task, with a `start` time, a sensible `kind`, and `steps` > 0. If `tasks` is empty, say so (likely no `createdAt`; see D1). |
| IT-4 | Real costs **(user)** | Menu bar 🐠 shows today's $. Click Goldie: the budget bar shows the month total. User reads the month total at cursor.com/settings (usage). | Goldie's month total is within ~5% of Cursor's. Report both numbers. |
| IT-5 | Loop detection **(user)** | User asks a Cursor agent: "Run `echo goldie-loop-test` five times, as five separate terminal commands." Then take a snapshot. | That chat shows `maxRepeatCommand` ≥ 3, and the card shows "Ran `echo goldie-loop-test` N× in a row." |
| IT-6 | Big-read detection **(user)** | `python3 -c "print('x'*200000)" > /tmp/goldie-big.txt`. User asks a Cursor agent: "Read /tmp/goldie-big.txt and tell me its length." Then take a snapshot. | That chat has `bloatTokens` ≥ 10000 and `bloatLabel` `goldie-big.txt`. |
| IT-7 | Nudge, fresh bowl, handoff **(user)** | Temporarily set `{"heavyRatio": 1.2, "alarmedRatio": 2, "speechCooldownMinutes": 1}` in the config, then restart Goldie. Wait for a nudge. The user clicks the fresh bowl, then runs `pbpaste \| head -5` (report only the section headers). | The fresh bowl names the chat. The clipboard has a handoff with `## Goal` etc. Cursor comes to the front. The toast says to paste. |
| IT-8 | Chat selection **(user)** | With 2+ chats active, the user clicks Goldie, then clicks a non-flagged chat row. | The row gets an orange outline, and the fresh bowl label changes to that chat. |
| IT-9 | Brain | Menu bar → status line, and the card header | Shows "local AI" (not "rules (LLM unreachable)") within ~5 minutes of agent activity. |
| IT-10 | Model policy | Temporarily set `llm.model` to `mlx-community/Qwen3-4B-Instruct-2507-4bit`, then restart Goldie. | The menu shows the brain as "not allowed by policy", and no request reaches the MLX server (`/tmp/goldie-mlx.log`). |
| IT-11 | Persistence | Drag Goldie somewhere, set Size → Large, quit (menu → Quit), relaunch. | Same spot and size. `~/Library/Application Support/Goldie/tasks.jsonl` exists if tasks completed with costs. |
| IT-12 | Performance | Idle, and during an agent run: `top -l 3 -stats pid,command,cpu,mem -pid $(pgrep -x Goldie) \| tail -2` | CPU under ~5% when idle; memory under ~150 MB. Report the numbers. |
| IT-13 | Uninstall path | `goldiectl uninstall-cursor-hooks`, `cat ~/.cursor/hooks.json`, then reinstall with `install-cursor-hooks`. | Goldie's entries are removed and the user's own hooks are kept; reinstall works. |

**After IT-10:** restore the config from `/tmp/goldie-config.bak`, or delete the test keys. Restart Goldie. Then confirm `llm.model` is the Llama model.

## 9. Report

Write `~/goldie-test-report.md` with:

1. **Environment:** macOS version, chip, Swift version, commit hash, Cursor version if known.
2. **Build and unit tests:** pass/fail. Include errors and any uncommitted `git diff`.
3. **Diagnostics D1–D6:** short answers, plus `/tmp/goldie-probe.txt` and `/tmp/goldie-usage.txt` pasted in full (they contain no secrets).
4. **IT-1 to IT-13:** a table with ID, pass/fail/blocked, and evidence (numbers, field values, what the user saw).
5. **Issues found:** each with what happened, what you expected, and how to reproduce.
6. **Cleanup:** config restored? Hooks installed? Goldie and the MLX server still running?

Then tell the user: "Paste ~/goldie-test-report.md into the Claude session that built Goldie."
