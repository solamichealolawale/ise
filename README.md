# Ise

Ise (iṣẹ́, Yoruba for work) is a small panel that floats at a corner of your Mac and shows one block of work at a time.
It rings when a block has not started or runs past its time, so the day keeps moving.
It also notices which of your Claude Code sessions stopped with work left, so nothing slips through between sessions.

Built for people with ADHD who run many Claude sessions at once. It works on its own too: you can add and tick tasks in the panel without Claude.

Free and open source (MIT). macOS 14 or later. Windows is planned.

## Install

In Claude Code (2.1.275 or later):

```
/plugin install ise --marketplace solamichealolawale/ise
```

Then run `/ise-setup`. It builds the app from this repository's source, puts it in `~/Applications/Ise.app`, adds the `ise` command to `~/.local/bin`, and asks four questions:

1. How to plan your days: carry over unfinished work each morning, add a day-end report, or start each day empty.
2. Whether your Macs share one plan through iCloud Drive, or each Mac keeps its own.
3. Whether to notice Claude sessions that stop with work left.
4. Your working hours and lunch.

Building needs Xcode Command Line Tools. If they are missing, setup tells you to run `xcode-select --install` first.

## Use it from any Claude chat

| Type | What happens |
| --- | --- |
| `/ise` | What to do now, and the panel comes forward |
| `/ise done login bug` | Ticks the task or step that matches |
| `/ise add Write release notes` | Adds a task, placed in clock order |
| `/ise later release notes` | Sets it aside in Later, not done |
| `/ise undo` | Takes back the last change, from the chat or the panel |
| `/ise-plan` | Claude plans or replans the day with you, including unfinished sessions |

You can also just say it: "I finished the release notes" ticks it.
Each new Claude session learns its own id, so a task added from a session stays linked to it. When that session completes one of its tasks, the matching step in the panel ticks itself.

The same commands work in a terminal: `ise`, `ise list`, `ise done 2.1`, `ise help`. Setup puts `ise` in `~/.local/bin`, and tells you if that folder is not on your PATH yet.

## The panel

- Three views, switched in the title bar: List, Focus timer, and Card. The green window button cycles through them.
- Red and yellow shrink the panel into a bubble that shows the minutes left and the number of blocks left. Click the bubble to open it. Drag either one to a corner and it stays there.
- Start, Pause, Done, add 15 minutes, park a block you are blocked on, or move it to **Later**. Every button explains itself when you hover over it.
- **Later** holds what you set aside. Nothing there is marked done: it still counts as work left, one click brings it back as the next task, and with carry-over on (the default), anything still there at the end of the day moves to tomorrow.
- Drag the bar on the panel's free edge (above the footer, or under the title when the panel sits at a bottom corner) to make it taller or shorter. Anything that does not fit scrolls, and the panel never grows past your screen.
- Drag tasks and steps by the handle that shows on hover to reorder them. Click a block's length to change it, and the blocks after it move to match.
- **From Claude** lists sessions that stopped with open tasks or a question for you. Add one to today, reopen it in Terminal, or hide it.
- The gear in the footer holds the settings.

### What rings

| When | Panel | Sound |
| --- | --- | --- |
| A block comes up | normal | one chime |
| Not started after 3 minutes | orange | every 3 minutes |
| Started and past its time | red | every 5 minutes |
| Paused for 10 minutes or more | orange | every 10 minutes |
| A parked block or blocked step reaches its chase time | orange line in Waiting | once |

Snooze silences orange or red for 10 minutes, twice per block.

## What Ise stores, and where

Everything stays on your Mac, or in your own iCloud Drive if you turn sharing on. There is no server, no account, and no analytics.

| File | What it holds |
| --- | --- |
| `~/.ise/plan.json` | Today's blocks and steps |
| `~/.ise/plan.undo.json` | The last 20 versions of the plan, for Undo |
| `~/.ise/sessions.json` | Recent Claude sessions: id, project folder, the first line of the first prompt, open task names, and the last reply cut to 280 characters. Sessions older than 7 days are dropped. |
| `~/.ise/tomorrow.json` | A plan made ahead for a later day, until that morning |
| `~/.ise/settings.json` | Your choices |

Ise never reads Claude's conversation files. It only keeps what the hooks below hand it.

With sharing on, every file except `settings.json` lives in `iCloud Drive/Ise` instead, so each Mac keeps its own hours.

### What the plugin adds to Claude Code

- Hooks on session start, prompt submit, task created and completed, notifications, stop, and session end. Each runs `bin/ise hook`, which records the session fields above. All but the session-start hook run in the background, and that one has a 5 second limit, so a session is never held up. If the app is not installed they do nothing.
- The session-start hook adds one line to each conversation: the session's id, and its linked block if there is one.
- Three skills: `ise`, `ise-setup` and `ise-plan`.

### Plan file format

Anything that writes this file can feed the panel, such as your own morning script.

```json
{
  "date": "2026-11-03",
  "dayEnd": "17:30",
  "blocks": [
    {
      "title": "Fix the checkout bug",
      "minutes": 60,
      "peopleWaiting": "Sam",
      "link": "https://github.com/you/shop/pull/12",
      "steps": [{ "text": "Write a failing test" }, { "text": "Ask for review" }]
    },
    { "title": "Lunch", "minutes": 60, "fixedStart": "13:00" }
  ]
}
```

- `minutes` is a length, not a clock time. Blocks run in list order from whenever the last one finished.
- `fixedStart` ties a block to the clock. Use it only for meetings and lunch.
- The app adds `status`, `startedAt`, `extraMinutes`, `snoozes`, `blockedBy`, `chaseAt`, `sessionId` and `folder` as you work.

## Build from source

```bash
./install.sh
```

This builds the app, copies it to `~/Applications/Ise.app`, adds `ise` to `~/.local/bin`, and restarts it.
To try a change without replacing your copy, run `./build.sh` and `open build/Ise.app`. Run the tests with `swift test`.

## Uninstall

1. In Claude Code: `/plugin uninstall ise`
2. In a terminal:

```bash
ise settings open-at-login off; pkill -x Ise; rm -rf ~/Applications/Ise.app ~/.local/bin/ise
```

Your plans stay in `~/.ise` until you delete that folder.

## License

MIT. See [LICENSE](LICENSE).
