---
name: ise
description: Show or change the user's day in the Ise focus panel. Use for /ise, and whenever the user says a task or step from their day is done, wants to add a task or step, skip or set one aside for later, reopen one, undo a change, or asks what to do now or next.
argument-hint: "[done|add|step|later|reopen|undo|list] [task]"
allowed-tools: Bash(ise *)
---

# Ise

Ise is a floating Mac panel that shows the user's day as blocks of work with steps. The `ise` command changes the same plan the panel shows, and the panel updates at once.

Arguments: $ARGUMENTS

## What to run

| The user wants | Run |
| --- | --- |
| Nothing given, or "what now" | `ise` (also brings the panel forward) |
| To see the whole day | `ise list` |
| A task done | `ise done "<words or number>" --session <id>` |
| The task this session works on done | `ise done --session <id>` |
| A new task | `ise add "<task>" --minutes <length> --session <id>` |
| A new task straight after the current one | `ise add "<task>" --next --session <id>` |
| A step added to a task | `ise add-step "<step>" --to "<task words>" --session <id>` |
| A task or step skipped or set aside for now | `ise later "<words or number>"` (it stays unfinished) |
| Something marked done by mistake, or brought back from Later | `ise reopen "<words or number>"` |
| The last change taken back | `ise undo` |
| A setting changed | `ise settings <name> <value>` (run `ise settings` to see the names) |

- The session id is in this conversation's context, in a line from Ise that says "This Claude session's id is ...". If it is not there, leave out `--session`.
- If `ise done --session <id>` says this session has no task in today's plan, run `ise list` and ask which one the user means.
- When `ise` says several items match, show the numbered choices and ask which one, or pick the number when the user's words make it clear.
- Lengths are minutes: 15, 30, 45, 60, 90 or 120. Use 30 when the user gives none.

## How to reply

Reply in one or two short lines: what changed, and what is next. Do not paste the whole list unless the user asked for it.

If `ise` is not found or says Ise is not installed, tell the user to run `/ise-setup` and stop.
