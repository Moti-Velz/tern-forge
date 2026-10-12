# Granola for Tern

Your Granola meetings in a panel beside the terminal. Preview summaries, tick the meetings that
matter, and send them to an agent session as context, with full transcripts if you want them.

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
| **Granola: Send a meeting to an agent…** | Picks one recent meeting and sends it, no panel needed |
| **Granola: Set API key** | Stores or replaces the key |

In the panel:

- **Click a title** to preview attendees and the AI summary, with **Send to agent**, **Copy**
  (as Markdown) and **Open in Granola**.
- **☐** adds a meeting to the gathered context. The dock then offers **Send to agent**, **Copy** and
  **Clear** for everything you ticked.
- **Transcripts: on/off** chooses whether full transcripts go along. Summaries always go. The setting is remembered.
- **Filter** narrows the loaded meetings by title, owner or attendee. **Load older meetings** pages back.

**Send to agent** lists the agent blocks you have open, with the one you last worked in first, plus
**New agent in <dir>**. That option starts your default agent in the directory of the pane you last
worked in. You can then type an instruction such as "draft the follow-up email" or
"turn the action items into issues". If you leave it empty, the agent reads the context, sends a
three-line recap and waits for you.

The context is one Markdown document listing each meeting oldest first. Each meeting has its time,
attendees, folders, Granola link, summary and your private notes, plus the transcript when it is turned on. A document of
up to 6000 characters goes inline in the prompt inside `<granola-context>`. A longer one is written to
`<plugin data>/context/<timestamp>-<title>.md`, and the prompt tells the agent to read that file.

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
| `window.luau` | Panel lifecycle, palette commands, actions, send-to-agent flow, Carly exports |
| `lib/api.luau` | Granola API client (`/v1/notes`, `/v1/notes/{id}`, transcript paging) |
| `lib/context.luau` | Pure: dates, speaker labels, the Markdown context document and prompt |
| `lib/view.luau` | Pure: the panel's canvas nodes |
| `styles.css` | Panel styling (`data-role='granola.*'`) |
