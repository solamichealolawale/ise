---
name: ise-setup
description: Install or update the Ise panel app on this Mac and choose its settings. Use for /ise-setup, after installing or updating the Ise plugin, or when `ise` says it is not installed.
disable-model-invocation: true
allowed-tools: Bash(uname *) Bash(xcrun *) Bash(swift --version) Bash(ISE_BUILD_DIR=* *) Bash(ise *)
---

# Set up Ise

Keep every message short. Ask with buttons (AskUserQuestion), with the recommended option first.

## 1. Check this Mac

1. Run `uname -s`. If it is not `Darwin`, say Ise needs a Mac for now and stop.
2. Run `xcrun --find swift`. If it fails, tell the user to run `xcode-select --install`, wait for it to finish, and run `/ise-setup` again. Stop.

## 2. Build and install the app

Run this. It builds from the plugin's source, which takes one to three minutes the first time:

```bash
ISE_BUILD_DIR="${CLAUDE_PLUGIN_DATA}/build" "${CLAUDE_PLUGIN_ROOT}/install.sh"
```

It copies the app to `~/Applications/Ise.app`, adds the `ise` command to `~/.local/bin`, and opens the panel. If the build fails, show the last 20 lines of its output and stop.

## 3. Choose settings

Ask these in one AskUserQuestion call:

1. "How should Ise plan your days?"
   - "Carry over each morning (Recommended)": unfinished work from yesterday starts today.
   - "Morning, plus a day-end report": the same, and at day end the panel shows what got done.
   - "Start each day empty"
2. "Should your Macs share one plan?"
   - "This Mac only (Recommended)"
   - "Share through iCloud Drive": every Mac signed in to the same iCloud sees the same day.
3. "Should Ise notice Claude sessions that stop with work left?"
   - "Yes (Recommended)": they appear under From Claude in the panel, ready to add.
   - "No"
4. "What are your working hours?"
   - "9:00 to 17:30, lunch at 13:00 (Recommended)"
   - "8:00 to 16:30, lunch at 12:00"
   - "9:00 to 17:30, no lunch block"

Apply the answers with `ise settings <name> <value>`:

| Answer | Commands |
| --- | --- |
| Carry over each morning | `carry-over on`, `day-report off` |
| Morning, plus a day-end report | `carry-over on`, `day-report on` |
| Start each day empty | `carry-over off`, `day-report off` |
| This Mac only | `sync off` |
| Share through iCloud Drive | `sync icloud` |
| Notice sessions: Yes or No | `track-sessions on` or `track-sessions off` |
| Hours | `day-start`, `day-end`, and `lunch` with a time or `none` |

If the user typed their own hours, use them. Then run `ise settings open-at-login on`.

## 4. Finish

Run `ise` and show its output. Then show this, and nothing more:

```
Ise is set up. In any Claude chat:
  /ise            what to do now
  /ise done ...   tick a task or step
  /ise add ...    add a task
  /ise undo       take back the last change
  /ise-plan       plan or replan the day with Claude
Settings are behind the gear in the panel.
```

Mention that new Claude sessions pick up Ise automatically, and that sessions already open need a restart to be noticed.
