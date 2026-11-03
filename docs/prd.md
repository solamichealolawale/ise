# Ise as a Claude Code plugin

Product notes, 3 November 2026. Free and open source.

## The problem

- People who run many Claude sessions lose track of what is unfinished. Work stops mid-task in one session while they move to another.
- To-do apps do not see that work, so the next morning starts from memory.
- For people with ADHD, a list is not enough. They need one thing on screen, a clock, and a nudge when they drift.

## Who it is for

Anyone on a Mac who works with Claude Code. The panel also works without Claude, as a plain focus timer and list. Windows comes later with the same look.

## Decisions

| Question | Decision |
| --- | --- |
| How people get it | A Claude Code plugin from a public GitHub repo, also submitted to Anthropic's plugin directory. |
| Where it shows | A native floating panel: always on top, rings, works with Claude closed. |
| Where tasks come from | Claude sessions that stopped with work left, plus anything the person adds. |
| When it plans | Each morning, unfinished work carries over. A day-end report and an empty start are settings. Claude plans in more depth on request with `/ise-plan`. |
| Several Macs | A setting: this Mac only, or one plan shared through iCloud Drive. |
| Every chat connected | `/ise` in any session ticks, adds, reopens and undoes. Sessions learn their own id, so their tasks stay linked. |
| Accounts and tokens | None. Planning runs inside the person's own Claude. |

## How it works

- **The app** is one Swift program. Opened normally it is the panel; run with a command word it is the `ise` command, so both share the same code and files.
- **The plan file** is the contract. The panel, the command, the hooks and any outside script all read and write it. A lock keeps writers from colliding, and a small history makes Undo work from anywhere, but never over a change someone else made.
- **Hooks** record a few fields per session: id, folder, first prompt line, open task names, last reply. Ise never reads the conversation files, whose format Claude Code does not promise to keep.
- **A new day** starts from yesterday's unfinished blocks when that setting is on. Meetings and lunch are left behind; today's lunch is added only if it has not already passed.

## Not in the first version

- Cloud sessions on claude.ai/code, which are not visible on the Mac.
- Windows and Linux.
- Reading Git branches or pull requests.
- Other AI tools. The plan file and `ise` command make this possible later.

## Risks

- Hook fields can change between Claude Code versions. The hook code ignores what it does not understand and never fails a session.
- Two Macs writing at once in shared mode: the newest write wins.
- The app is built on the person's Mac, so it needs Xcode Command Line Tools. A signed download needs a paid Apple developer account, which can come later.

## How we will know it works

- Its author uses it 5 working days in a row.
- Each morning, unfinished work from the day before shows up without typing it.
- A new person goes from install to a visible panel in under 5 minutes.
