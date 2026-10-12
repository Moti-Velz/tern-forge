# Granola for Tern

Your Granola meetings in a panel beside the terminal. Tick the meetings that matter and add them
to the agent session you're working in with one click, as the AI synthesis or with full transcripts.

![Granola panel next to an omp agent that drafted a follow-up email from two meetings](docs/screenshot.png)

## Install

```sh
tern plugin install https://github.com/Moti-Velz/tern-granola
```

You need a Granola **personal API key**, which requires a Business or Enterprise plan. Create one in the Granola app under
**Settings › Connectors › API keys**. Then run **Granola: Set API key** from the palette, or click
**Set API key** in the panel. The key goes into the system keychain
(`plugin.granola.api-key`).

## Use

| Palette command | What it does |
| --- | --- |
| **Granola: Show or hide meetings** (`Super+Alt+Shift+G`) | Toggles the panel beside the focused pane |
| **Granola: Add a meeting to the agent** | Picks one recent meeting and adds it, no panel needed |
| **Granola: Set API key** | Stores or replaces the key |

In the panel:

- **Click a title** to preview attendees and the AI summary, with **Add to agent**, **Copy**
  (as Markdown) and **Open in Granola**.
- **☐** gathers a meeting. The dock then offers **Add to agent**, **Copy** and **Clear** for
  everything you ticked.
- **Synthesis | Full transcript** chooses what goes along: the AI summary and your private notes, or
  those plus the transcript. The choice is remembered.
- **Filter** narrows the loaded meetings by title, owner or attendee. **Load older meetings** pages back.

**Add to agent** puts the meetings into the composer of the agent you last worked in, without
sending. You can add your question and send it yourself. If you haven't used an agent yet, the newest
agent in the panel's tab is used. If there isn't one, an agent starts in the directory you were
working in, reads the meetings, and waits for your instructions.

The context is one Markdown document with each meeting, oldest first. Each meeting has its time,
attendees, folders, Granola link, summary and private notes, plus the transcript in Full transcript
mode. Up to 6000 characters, it is pasted inline inside `<granola-context>`. A longer one is written to
`<plugin data>/context/<timestamp>-<title>.md`, and only that path is added to the composer.

## Carly

The plugin gives Carly two exports and one piece of context:

- `plugins.granola.recent()` returns recent meetings as `{id, title, when}`.
- `plugins.granola.note(id, transcript?)` returns one meeting as Markdown.
- Context: the titles of the meetings currently ticked in the panel, so you can say things like
  "send these to the frugio agent".

## Notes

- Granola's API only returns meetings that already have an AI summary and transcript. Meetings
  still being processed don't show up.
- Requests stay well under the rate limit of 5/s: gathered notes are fetched one at a time, and previews are
  cached for the window's lifetime. A transcript too large to come inline (`413`) is fetched page by page from
  `/v1/notes/{id}/transcript`.
- `GRANOLA_API_BASE` in Tern's environment points the client at a different server, such as a proxy or a
  stub. The default is `https://public-api.granola.ai`.

## Files

| File | Role |
| --- | --- |
| `window.luau` | Panel lifecycle, palette commands, actions, add-to-agent flow, Carly exports |
| `lib/api.luau` | Granola API client (`/v1/notes`, `/v1/notes/{id}`, transcript paging) |
| `lib/context.luau` | Pure: dates, speaker labels, the Markdown context document and composer attachment |
| `lib/view.luau` | Pure: the panel's canvas nodes |
| `styles.css` | Panel styling (`data-role='granola.*'`) |
