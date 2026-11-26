# Manual test checklist

What cannot be tested automatically because it needs a person, a microphone or a permission click. The dated notes are from the first build day.

## First run
1. Build and start: `scripts/build-app.sh && open build/BrainInput.app`. The setup guide opens on first launch; later use the menu bar icon.
2. **Microphone**: hold `⌃⌥Space` once; macOS asks for microphone access. Click Allow. (Or Settings › Permissions › Request.)
3. **Accessibility**: in the app, Settings › Permissions › "Open prompt", then enable *Brain Input* in System Settings › Privacy & Security › Accessibility. Needed for pasting at the cursor, reading app context and learning from your edits. Until then dictations land on the clipboard.
4. If `⌃⌥Space` clashes with something, change it in Settings › Shortcuts.

5. **Claude API key**: Settings › Clean-up › paste the key › Save (stored in the login Keychain as service `BrainInput`). Without it every dictation is pasted raw.
6. **Run the clean-up fixtures against the real model** (I made no paid calls). From the repo root:
   `swift run brain eval-cleanup` prints the cost and sends nothing; `swift run brain eval-cleanup --yes` runs the 16 cases through the Batch API (estimated $0.001, results in minutes); add `--live` for immediate full-price calls (about $0.002) that also print per-call latency. The CLI reads `ANTHROPIC_API_KEY` or the Keychain item (macOS asks once to let `brain` read it).

## Checklist by hand
- [x] Dictation: hold `⌃⌥Space` in TextEdit, say a sentence, release. (Checked 2026-11-16: "This is a sentence." appeared; clipboard test text still pasted correctly.) Text appears at the cursor; your clipboard is unchanged afterwards.
- [x] Tap `⌃⌥Space` briefly, speak, tap again: toggle mode works. (Checked 2026-11-16: "Toggle mode test one." inserted.)
- [x] Speak a German sentence: it is transcribed in German. (Checked 2026-11-16: "Das ist ein Test auf Deutsch." inserted as German.)
- [x] The dictation shows up in the Dictations list and in `~/BrainInput/Dictations/<today>.md`; `~/Library/Logs/BrainInput.log` has a timing line. (Checked 2026-11-16: the dictation file and log both have the entries. The in-app list was not opened.)
- [ ] With the key saved: dictate "um let's meet at three, no, at four" in Slack. (Partly checked 2026-11-16: chat mode confirmed in WhatsApp Web in Brave with a German message. The English filler sentence is still to do; Slack was replaced by WhatsApp because Slack isn't installed.) The inserted text has no filler and only the final time; history shows mode `chat`.
- [x] Dictate a question ("what is the capital of Australia") and check that the question is inserted, not an answer. (Checked 2026-11-16: "What is the capital of Australia?" inserted, not answered.)
- [x] Press `⌃⌥Z` right after a cleaned dictation: the raw transcript replaces it. (Checked 2026-11-16: reported working by the user.)
- [x] Turn Wi-Fi off and dictate: (Checked 2026-11-16: reported working after the rebuild.) raw text is pasted, history shows `raw · clean-up failed` or `raw · timed out` (wording updated 2026-11-16; the raw error is still in the log).
- [x] In Cursor or VS Code, dictate a file name visible on screen ("open pipeline dot swift") and check the spelling. (Checked 2026-11-16: reported passing.)
- [x] In Safari or Chrome on mail.google.com the history entry shows mode `email` (URL detection through Accessibility). (2026-11-16: passed in a normal browser tab, reported by user. Earlier attempt in the installed Gmail app showed `default`. Tested in Gmail installed as a Brave web app (`com.brave.Browser.app.…`): no URL, empty window title, mode `default`. Retest in a normal Brave/Safari/Chrome tab.)
- [ ] Dictionary: dictate a name whisper gets wrong, fix it by hand within a few seconds, do the same once more. The indicator shows "Learned: …" and the entry appears under Dictionary with a `learned` chip. Remove it there if wrong. (Needs Accessibility; works in native text fields, patchy in Electron apps and browsers.)
- [ ] Style: open Style, pick Email, "Import writing samples…", paste three real emails separated by `---`. With the API key a description appears; edit it and "Save edit"; "Earlier versions" lists the previous one.

## Meetings (nothing here could be exercised without your clicks)
1. Menu bar icon › "Record a Meeting…" › Record. macOS asks for **System Audio Recording**; allow it (System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only › Brain Input). It may also ask for **Calendar** access; optional.
2. Checklist:
- [x] Play a YouTube video with speech, speak a few sentences yourself, stop from the menu after a minute. (Checked 2026-11-16: reported working by the user.) A note appears under Meetings and in `~/BrainInput/Meetings/` with **Me** and **Them** turns. If "Them" is empty and the indicator warned "No call audio heard", the system audio permission is missing. This path (the Core Audio tap) is the least verified part of the app; if it fails, send me the line starting `tap failed` from `~/Library/Logs/BrainInput.log`.
- [ ] Join a Zoom, Meet or Teams test call: within about 5 s a panel offers to record, with the reminder to tell the others. "Not now" keeps it quiet for that call. `swift run brain mic-users` shows what the detector sees.
- [ ] While recording, the indicator shows a red dot and a clock, and the menu bar icon is a record symbol. Leaving the call stops the recording about 15 s later.
- [ ] With the API key set, the note has Summary, Decisions and Action items.
- [ ] Use headphones, otherwise the other side is also picked up by the microphone and labelled "Me".

## Agent access
- [x] `build/BrainInput.app/Contents/MacOS/brain search <word>` finds a dictation or meeting. (Checked 2026-11-16: `search Toggle` found "Toggle mode test one." in today's dictations.)
- [ ] Register the MCP server (commands in `README.md`), then ask Claude or Cursor to "pull up my last meeting". (2026-11-16: registered with Claude Code as `brain-input`; `claude mcp list` shows it Connected. Cursor not registered. Still to do: ask Claude Code in a new session.) Verified here only by piping JSON-RPC into `brain mcp`, not from inside Claude Code or Cursor.

## Seen while building
- You dictated once into MarkEdit at 13:41 (21 s of audio, 2.27 s to the clipboard). Accessibility was still off then, so the text was left on the clipboard instead of pasted: step 3 above fixes that.
