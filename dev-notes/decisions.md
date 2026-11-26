# Decisions

> Engineering log from the first build day, kept as written. Two things changed for the public release: models are now downloaded by the app (setup guide, `Sources/BrainWhisper/Models.swift`) instead of being linked from VoiceInk's folder, and `whisper.xcframework` is built by `scripts/fetch-whisper.sh`.

One line per call made where the brief was silent, newest milestone last.

## Structure
- Swift package, no Xcode project: `BrainCore` (pipeline, notes, learning; Foundation only), `BrainWhisper` (whisper.cpp + audio), `BrainInputApp` (SwiftUI menu bar app), `brain` (CLI + MCP). `scripts/build-app.sh` wraps the release binaries into `build/BrainInput.app`.
- Edges are protocols in `Sources/BrainCore/Types.swift` (`Transcriber`, `TextInserter`, `ContextReader`, `LanguageModel`, `Polisher`); mocks live in `Sources/BrainCore/Testing.swift`.
- Swift language mode 5 (toolchain 6.3) to avoid spending the budget on strict-concurrency annotations.
- Bundle ID `com.arminbognar.BrainInput`, signed with the "Apple Development" identity found in the keychain, so granted permissions survive rebuilds.
- `Vendor/whisper.xcframework` is a symlink to `~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework` (git-ignored; the build script recreates it).

## Derived from VoiceInk (GPL-3.0, hence this repo is GPL-3.0)
- `Sources/BrainWhisper/WhisperTranscriber.swift`: whisper context handling adapted from `LibWhisper.swift`.
- `Sources/BrainInputApp/System.swift`, `ClipboardPaster`: clipboard snapshot/restore, transient pasteboard markers and ⌘V posting adapted from `CursorPaster.swift` and `ClipboardManager.swift`.
- Everything else (shortcuts, accessibility reading, dictionary learning, diffing) is new code that follows the same general approach.

## Milestone 1: dictation
- Default whisper model is `ggml-large-v3-turbo-q5_0.bin`: same latency as the full model on this M1 (1.25 s vs 1.30 s for a 3 s utterance) at 750 MB instead of 1.7 GB footprint. Switchable in Settings.
- Models are symlinked from VoiceInk's folder into `~/Library/Application Support/BrainInput/Models/` (read-only use; if VoiceInk is ever deleted, copy the files there instead).
- The Core ML encoder is used: 1.3 s vs 4.1 s on Metal alone. Cost: a one-off compile of about two minutes per new binary/path (2.6 s afterwards in the signed app), so the app warms the model at launch. Tests set `BRAININPUT_COREML=0` to skip that compile.
- Tried whisper's reduced `audio_ctx` to get under 1 s on Metal: output was garbage with large-v3-turbo, dropped.
- Shortcuts use Carbon hot keys (press and release events, no permission needed). Default dictate `⌃⌥Space`, swap-to-raw `⌃⌥Z`, both configurable. Modifier-only keys (Fn, right ⌥) are not supported yet.
- "Hybrid" key behaviour is the default: hold longer than 0.45 s is hold-to-talk, a short tap toggles.
- Language is always auto-detected per utterance; whisper picks one language per utterance, so a sentence mixing English and German is transcribed in the dominant one.
- Silence is detected by energy before whisper runs, because whisper invents text for silent audio.
- Insertion is clipboard + ⌘V with the previous clipboard restored 0.7 s later. Without Accessibility the text is left on the clipboard and the indicator says so.
- Dictation history: SQLite holds the structured records; each day is rendered to `~/BrainInput/Dictations/YYYY-MM-DD.md` with the record JSON in an HTML comment, so `brain reindex` can rebuild the index from Markdown alone.
- The index lives at `~/BrainInput/.index.sqlite`.
- No app icon; menu bar symbol only.

## Milestone 2: clean-up and modes
- Raw HTTP via URLSession (no official Swift SDK). `anthropic-version: 2023-06-01`, no sampling parameters (current models reject them), `thinking: disabled` + `effort: low` on the clean-up call because latency matters; style cards and summaries use the model's default adaptive thinking.
- The system prompt (rules + mode + style card + dictionary) is identical across dictations in a mode and is marked `cache_control: ephemeral`. It is probably below Haiku's minimum cacheable length today, in which case the marker is ignored; it starts paying once cards and dictionary grow.
- Mode choice: website patterns win over app bundle IDs (a browser shows many kinds of page); for browsers without a readable URL the tab title is matched instead.
- Browser URL comes from Accessibility (`AXDocument`, then the `AXWebArea` URL), not AppleScript, so no per-browser Automation permission is needed.
- Email mode and "do not add what I did not say": a sign-off is added only when the dictation is a whole email and the style card states my usual sign-off. Without a card nothing is invented.
- Output guard: a reply more than twice the transcript's length (+120 chars) is treated as an answer rather than a rewrite and the raw transcript is pasted instead. Refusals and `max_tokens` stops also fall back to raw.
- The timeout (default 3 s, Settings) covers screen reading plus the API call; on expiry the request is cancelled and raw text is pasted.
- Swap-to-raw selects the inserted text through Accessibility where the field exposes its value, otherwise sends ⌘Z, then pastes the raw transcript.
- Fixture runs against the real model go through the Message Batches API by default (half price), `--live` for direct calls; nothing is sent without `--yes`.
- `Fixtures/cleanup.json` checks are substring rules plus a length cap: cheap and deterministic, but they cannot judge tone. Read the printed outputs after a real run.

## Milestones 3 and 4: dictionary and style (committed together; the app wiring is shared)
- A correction counts as vocabulary only if 1–2 words were replaced by 1–2 similar-looking words (edit distance ≤ 60 % of the longer form) or the casing changed inside a word (GitHub, iOS). Bigger rewrites are treated as rephrasing and ignored.
- Each dictation votes once per correction; two votes promote it (`DictionaryStore.promoteAfter`). Single sightings are listed in the Dictionary view under "Seen once" with an "Add now" button.
- The field is read back 8 s after insertion and again when the dictate key is next pressed, both only if the same app is frontmost. Field text is compared in memory; only the span that corresponds to the dictation is stored (as `finalText`).
- Learned mishearings are also fixed deterministically in the raw transcript, but only when the target looks like a name or identifier (contains a capital or digit), so the fix works with no model and ordinary words stay untouched.
- Whisper's initial prompt holds about 220 tokens; the newest terms up to 560 characters go in.
- Style cards are Markdown at `~/BrainInput/Style/<mode>.md`, earlier versions in `Style/history/`. Samples are not stored separately: they are the dictations of that mode since the card's date, using the text after my edits where it is known.
- A card regenerates in the background after 12 new dictations of at least 25 characters in a mode. Examples returned by the model are kept only if they appear verbatim in my samples.
- Importing samples without an API key stores them as examples with a placeholder description, so seeding works before the key exists.
- Dictionary and modes live in `~/Library/Application Support/BrainInput/` (`dictionary.json`, `modes.json`).

## Milestone 5: meetings
- System audio comes from a Core Audio process tap (global stereo tap + private aggregate device), not ScreenCaptureKit: no screen-recording indicator, no video pipeline, and the permission is the narrower "System Audio Recording Only". Not exercised on this machine yet (needs your click), so the ScreenCaptureKit fallback was not built.
- Turns are cut at pauses of 1 s (max 25 s per chunk) per stream, each transcribed as it ends and appended to `~/BrainInput/Meetings/.inprogress-<timestamp>.jsonl`. A crash loses only the utterance in progress; the next launch turns leftover journals into "(recovered)" notes.
- "Me" is the microphone, "Them" is everything the Mac plays. Without headphones the microphone also hears the speakers, so the other side can show up under "Me" as well: use headphones.
- A call is "likely" when a known meeting app or a browser is capturing microphone input (polled every 5 s through Core Audio process objects, no permission needed). Any browser holding the mic counts; the tab is not inspected.
- The offer panel is the only way a recording starts (detection or menu); it carries the reminder to tell the others. Declining mutes the offer until that app releases the microphone.
- Recording stops from the menu or the Meetings toolbar, and on its own 15 s after the detected call app releases the microphone. Stopping silently is fine; starting silently is not.
- The red dot with a running clock stays in the floating indicator and the menu bar icon changes for the whole recording.
- Participants and title come from the calendar event overlapping "now" (EventKit, optional). Without calendar access the model's suggested title is used and participants read "not known".
- Summary, decisions and action items are one Claude call at the end (default adaptive thinking). Without a key the note is still written with the full transcript and "Not generated" sections.
- Meeting audio is never written to disk; only text is kept.

## Milestone 6: search, CLI, MCP
- The MCP server is hand-written JSON-RPC over stdio inside the `brain` binary (five read-only tools); no SDK dependency. It echoes the client's protocol version.
- `read_note` and `brain read` refuse paths outside `~/BrainInput`.
- The in-app note reader renders headings and inline Markdown line by line; it is a reader, not an editor. "Show in Finder" opens the file for your own editor.

## Live dictation transcription
- Each dictation is transcribed in chunks while recording (`IncrementalTranscriber`, `DictationCutter` in `Sources/BrainCore/LiveTranscription.swift`); after release only the open chunk is left. Before, the whole recording was transcribed again after release (about 30 ms per audio second on Parakeet, 5 to 17 s for five minutes).
- Hand-written chunker rather than FluidAudio's `SlidingWindowAsrSession`: that one is Parakeet-only, keeps its own model and decoder state outside the `Transcriber` seam (whisper, meetings and mocks share it), and runs a 15 s window per 11 s of audio.
- Chunks are contiguous (nothing is dropped, unlike the meeting cutter). Cut at a 0.6 s pause once a chunk holds 5 s (0.3 s past 9 s). At the 14 s cap, cut in the longest silent run, else the quietest 300 ms: a single quiet frame is often a plosive inside a word. 14 s keeps every Parakeet call inside its 15 s window.
- Whisper's language is pinned after the first chunk of at least 3 s. Chunk texts are joined with one space.
- A failed chunk, or no text at all, falls back to one full pass over the recording. Esc cancels queued chunks and skips the fallback.
- The live preview shows committed chunks plus the open chunk only, and runs only while the engine is idle.
- `ParakeetTranscriber` now serialises calls itself: as a reentrant actor it used to start a second call while the first waited on FluidAudio, so `queueWaitMs` read about 0 and the wait was booked as inference.

## File transcription
- A dropped file is one engine call over the whole file, as in VoiceInk (`FileTranscription` in `Sources/BrainCore/FileTranscription.swift`). The engine handles long audio itself: FluidAudio runs overlapping 15 s windows merged by token.
- The first version reused the dictation cutter (about 10 s chunks). On a 164 s German voice message that differed from one pass of the same Parakeet model in 78 words: sentences ended at every cut, hyphenated compounds came apart, and words were lost at the seams. Now the output is word for word the one-pass output. Live dictation keeps its short chunks; there the wait after release matters more.
- The cost: the engine serves one call at a time, about 34 ms per audio second on Parakeet, so during an hour-long file a dictation waits up to about 2 minutes. The indicator then says "Waiting for file transcription…". Progress is indeterminate, and Cancel discards the result once the call returns.
- Timestamps and paragraphs come from Parakeet's token timings: one segment per sentence, a new paragraph only between sentences, at a pause of at least 1.2 s once a paragraph holds 20 s, always by 45 s. Whisper reports no timings here, so its paragraphs break by length and only span starts carry a time.
- No clean-up model runs on file transcripts: they stay what the speech model heard. On the same message whisper large-v3-turbo got "Lehrerin" right but repeated one sentence four times and took 2:41 against 5 s for Parakeet, so Parakeet stays the default.

## Known gaps
- Not built: modifier-only shortcut keys, app icon, launch at login, ScreenCaptureKit fallback for system audio, a "summarise later" action for notes written without a key, Spanish-specific work (whisper handles it; nothing was tested).
- Model load time after a rebuild was anywhere from 1.8 s to 140 s across this session (Core ML compile cache); steady state is 2–3 s.
