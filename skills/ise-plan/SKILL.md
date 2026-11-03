---
name: ise-plan
description: Plan or replan the user's day in the Ise panel, using their unfinished work and Claude sessions that stopped with work left. Use for /ise-plan, or when the user asks to plan their day, plan tomorrow, or sort out what to do.
argument-hint: "[today|tomorrow] [anything to include]"
allowed-tools: Bash(ise *)
---

# Plan the day

The user may have ADHD: keep messages short, ask with buttons (AskUserQuestion), at most 3 questions, recommended option first.

Arguments: $ARGUMENTS

## 1. Read what is there

Run `ise json`. It returns:
- `plan`: today's blocks. Each has `title`, `minutes` (a length, not a clock time), `status`, `steps`, and maybe `fixedStart` ("HH:mm", only for meetings and lunch), `sessionId` and `folder`. A `status` of `"skipped"` means the user moved it to Later: set aside, not done. Call it "in Later", never "skipped", and keep it unless the user drops it.
- `sessionsWithWorkLeft`: Claude sessions that stopped with open tasks or a question for the user. Each has `id`, `title`, `folder`, `openTasks`, `lastMessage`.
- `settings`: the user's hours.

## 2. Decide with the user

1. Draft an order: blocks already in progress first, then anything someone is waiting on, then the rest by importance. Add the user's own words from the arguments.
2. Show the draft as a short numbered list with lengths, and the total against the hours left in the day.
3. If `sessionsWithWorkLeft` is not empty, ask which to add (multiSelect, up to 4 options, one per session, labelled by title).
4. If the total runs past the day's end, ask what to drop or move to tomorrow.

## 3. Write the plan

Build the whole plan as JSON and save it with:

```bash
ise save-plan - <<'JSON'
{ "date": "YYYY-MM-DD", "dayEnd": "HH:mm", "blocks": [ ... ] }
JSON
```

Rules:
- `date` is today, or tomorrow when the user asked to plan tomorrow. A plan for tomorrow is kept aside and becomes the plan that morning, with anything still unfinished added after it, so today's plan is not touched.
- For today, keep every existing block's fields as they are, including `status`, `startedAt` and step statuses. Only change order, lengths, or add and remove blocks the user agreed to.
- For tomorrow, leave out blocks that are done, and give every block a fresh `"status": "todo"`.
- A block from a session gets `"sessionId"` and `"folder"` from that session, and its open tasks as steps: `{"text": "..."}`.
- Lengths are 15, 30, 45, 60, 90 or 120 minutes. Each block has 1 to 4 small first steps when you can name them.
- Use `fixedStart` only for meetings and lunch.

## 4. Confirm

Run `ise` and reply in two lines: the first block and its first step, and how many blocks are planned. For a plan saved for today, say `ise undo` puts the old plan back. For a plan saved for tomorrow, say it starts that morning. If `ise` said the old file could not be read, say where it was kept instead.
