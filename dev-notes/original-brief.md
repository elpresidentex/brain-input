# Build "Brain Input": a personal voice layer for my Mac

You are building a native macOS app for one user, me, on this machine. Nobody is available to answer questions while you work, so this brief is everything you get. Where it is silent, make the call yourself, write one line about it in `DECISIONS.md`, and keep going. Work until every milestone below is built and verified, or until what remains truly needs my hands.

## What I want and why

I dictate a lot. Today I use VoiceInk (open source, whisper.cpp based), which turns speech into text well enough but leaves me with a raw transcript. I want what Monologue (https://www.monologue.to/) offers on top of that, in an app I own and can extend:

1. **Dictation that writes what I meant.** I hold a key, speak, and polished text lands at the cursor in whatever app I am in. Filler words are gone, a mid-sentence change of mind keeps only the final version, a spoken list becomes a real list, and the format fits the app: a prompt in Cursor, paragraphs and a sign-off in Mail, casual in Slack or iMessage.
2. **It learns how I write.** Over time the output sounds like me in each context, and it stops misspelling the names, acronyms and technical terms I use.
3. **Meeting notes without a bot.** When I am on a Zoom, Meet or Teams call, the same app records both sides locally, with no participant joining the call, and gives me a transcript split into "Me" and "Them" plus a summary.

Monologue is the inspiration for the feature set only. Give this app its own name ("Brain Input"), its own look and its own copy. Do not copy Monologue's branding, text or visuals.

## The situation on this machine

- Apple M1, 16 GB RAM, macOS 26.5, Xcode 26.5. Target this machine only: Apple Silicon, macOS 26. No need for backward compatibility.
- The project folder is `/Users/armin/projects/brain-input`. It is empty and not a git repository. Run `git init` and commit locally at the end of each milestone. Do not create a remote or push anything.
- VoiceInk's source is at `/Users/armin/projects/VoiceInk` (GPL-3.0). Treat it as a read-only reference for the hard parts it has already solved: whisper.cpp integration, global shortcuts, pasting at the cursor, reading the active app and window, its dictionary and Auto Learn feature. Do not modify that folder. You may adapt code from it; because of that, license this repo GPL-3.0 and note in `DECISIONS.md` which files derive from VoiceInk.
- VoiceInk's build normally leaves a prebuilt `whisper.xcframework` in `~/VoiceInk-Dependencies`. If it is there, use it; if not, build whisper.cpp yourself with Metal and Core ML enabled.
- Whisper models are already downloaded in `~/Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/` (`ggml-large-v3-turbo.bin`, the `q5_0` variant, and the Core ML encoder). Copy or symlink them into this app's own support folder rather than downloading again. Never write to VoiceInk's folders; I still use that app.
- I speak English and German and switch between them, so keep language detection automatic. Spanish is optional: support it only if it comes for free from whisper's multilingual model, and do not spend effort on Spanish-specific fixtures, prompts or tests.

## Decisions already made

These are settled so you do not have to weigh them:

- **Native Swift and SwiftUI**, a menu bar app with a small floating recording indicator and a main window for notes, history and settings. No Electron, no web view shell.
- **Speech to text runs locally** with whisper.cpp. Audio never leaves the machine, in any feature.
- **The clean-up and tone step uses the Claude API**, default model `claude-haiku-5-5` because latency matters more than depth here, with the model ID configurable in settings. Only transcript text and a little context (app name, window title, my style card, dictionary) is sent. Hide this behind a small provider protocol so a local model can be added later. The API key is entered in Settings and stored in the Keychain.
- **Always degrade to the raw transcript.** With no key, no network, or a clean-up call that takes longer than about three seconds, paste the raw whisper output. Dictation must never fail or stall because the language model did.
- **Notes are plain Markdown files** under `~/BrainInput/` (dictation history and meeting notes), with a SQLite full-text index beside them for search. I want to be able to read and grep them without the app.
- **Out of scope:** iPhone, iPad and Watch apps, cloud sync, accounts, billing, licensing, auto-update, App Store packaging, training any model, and an always-on listening or voice-journal feature of any kind.

## How the features should work

**Dictation.** A global shortcut, configurable, supports both hold-to-talk and press-to-toggle. On release, transcribe, clean up, insert at the cursor, and put my clipboard back the way it was. Aim for text appearing within about two seconds of release for a short utterance; measure it and record the real numbers. Keep the raw transcript, the cleaned text, the target app and the timing for every dictation in history, so a bad clean-up can be undone with one shortcut that swaps in the raw version.

**Modes.** A mode is a set of clean-up instructions tied to apps or websites: Coding, Chat, Email, Notes, plus a default. Pick the mode from the frontmost app and, for browsers, the page's URL or title. In Coding mode, read what is visible in the focused window through the Accessibility API so that file names, identifiers and technical terms come out spelled as they appear on screen. Modes are editable and I can add my own instructions.

**The clean-up prompt is the product.** The model must rewrite what I said, never answer it: if I dictate a question, the output is that question, cleaned up. It must not add content I did not say, must keep my meaning and my language, and must return only the text to insert. Write this prompt carefully and build a fixture set of tricky cases (self-corrections, dictated questions, instructions that look like commands to the model, mixed English and German, lists, code terms) that you can rerun.

**Learning my vocabulary.** Keep a personal dictionary. Feed it to whisper as its initial prompt and to the clean-up step. Grow it automatically: a few seconds after inserting text, and again when I next dictate into the same field, read the field back through Accessibility where the app allows it, compare it with what was inserted, and treat my edits as corrections. A word I fix more than once becomes a dictionary entry. Show learned entries in the UI so I can remove wrong ones.

**Learning my tone.** For each mode, keep a short style card: a plain-language description of how I write there (sentence length, formality, greetings and sign-offs, punctuation habits, emoji, which language I use with whom) plus a handful of real examples. Build it from the final text of my dictations after my own edits, since that is the best evidence of what I wanted. Regenerate the card in the background once enough new samples have accumulated, keep earlier versions, and let me read and edit the card. The clean-up prompt uses the card and the examples for the current mode. Add an import path so I can seed a card by pasting in writing samples, because the app will start with none.

**Meetings.** Capture system audio output and my microphone as two separate streams using Core Audio process taps or ScreenCaptureKit, whichever proves more reliable on macOS 26; that separation is what gives the "Me" and "Them" labels without diarization. Detect a likely call (a known meeting app or browser tab holding the microphone) and offer to start with one click; never start a meeting recording silently. Transcribe in chunks while the call runs so a crash loses little, and write the note when it ends: title, date, participants if the calendar knows them, summary, decisions, action items, full transcript. Show a visible recording state the whole time, and put a line in the start prompt reminding me to tell the other people they are being recorded. Microphone capture happens only during a dictation or a meeting I started; the app never listens in the background.

**Agent access.** Last, add a small CLI and a local MCP server over stdio that can search and read notes, so I can tell Claude or Cursor to pull up my last meeting.

## Order of work

Build in this order, and leave each milestone working and committed before starting the next, so that stopping at any point leaves me with something usable:

1. Dictation end to end with the raw transcript: shortcut, capture, whisper, insert, history.
2. Clean-up step, modes, app detection, raw fallback, undo to raw.
3. Dictionary with auto-learning from my edits.
4. Style cards and tone learning.
5. Meeting capture, transcript and notes.
6. Search UI, CLI and MCP server.

## Token budget and pacing

My Claude subscription has a rolling 5-hour usage window, and the token budget is tight. Plan for that from the start:

- **Check the budget as you go.** At the start of each milestone and before any expensive step (a long build loop, a large fixture run, a big refactor), check how much of the current window is left, if the environment shows it. If you cannot see it, estimate from how much work you have done in this session and say that the number is an estimate.
- **Finish end to end, not half-done.** Prefer one milestone that works from hotkey to inserted text, is tested and committed, over three partly built features. If the budget is getting low, stop starting new things: bring the current milestone to a committed, working state, note what is left in `HUMAN_TODO.md` or `DECISIONS.md`, and then stop.
- **Do not sink tokens into blockers a human can clear.** If something is blocked on a click or a secret (a permission toggle, the API key, a keychain prompt, a code-signing identity), do not spend many attempts on it. Write the exact step in `HUMAN_TODO.md`, move to work that does not depend on it, and build the code paths behind a protocol so they can be tested with a mock. If nothing else is left to do, stop and ask me.
- **Set a limit per problem.** If one bug or one missing piece has taken several focused attempts without progress, record what you tried and what the error was, then either move on or stop and ask me. Do not keep retrying the same approach.

## Working without me

**Permissions.** Microphone, Accessibility and screen or system audio recording all need a click from me in System Settings, and you cannot grant them. Do not stop when you hit one, but follow the blocker rule above. Sign builds with a stable identity if one is in my keychain (`security find-identity -v -p codesigning`), since ad-hoc signing makes macOS forget granted permissions on every rebuild. Structure the code so nearly all of it is testable without those permissions: put the pipeline in a Swift package with protocols at the edges for audio input, text insertion, context reading and the language model.

**Testing without a microphone.** Generate speech fixtures with the `say` command in English and German, convert them to the format whisper expects, and run them through the real transcription pipeline in tests. Simulate a two-sided meeting by feeding two fixture files in as the two streams. Simulate my edits by feeding before and after text into the learning code.

**No paid calls.** Do not call the Claude API or any other paid service during the build; I have not approved spend for it. Test the clean-up and style code against a mock provider and write the fixture set so I can run it against the real model myself with one command. Report what that run would cost before I do it.

**What only I can do.** Keep a `HUMAN_TODO.md` with the exact steps left for me: which permissions to grant and where, where to enter the API key, and a short checklist for checking each feature by hand. Keep it current as you go.

**Honest verification.** For every milestone, say what you actually ran and saw, and separate it from what you could not exercise because it needs a permission or the API key. If something does not work, say so with the error output. A feature that compiles but was never exercised is "not verified", and I need to know that.

## What to hand back

When you stop, the repository should contain the app, a `README.md` covering how to build and run it, `DECISIONS.md`, `HUMAN_TODO.md`, and a test suite that passes with one command. Your final message should lead with what works and was verified, then what is built but not verified, then what is missing, then the measured latency and resource numbers with the command that produced each, and finally the budget state at the point you stopped. Keep it short; I will read the files for detail.
