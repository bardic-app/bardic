# Changelog

## 0.3.0

- **New default cleanup model: Qwen3 4B** (about 2.3 GB). It scores as well as Qwen 2.5 3B on the eval
  and has an open license (Apache-2.0); Qwen 2.5 3B's license allowed research use only. Bardic
  downloads it on first launch after updating and deletes the old Qwen 2.5 3B download.
- **Privacy:** dictated text on the clipboard is marked so clipboard managers skip it and it doesn't
  sync to your other devices. "Hey Bardic" commands aren't written to the system log. The history file
  is readable only by your account.
- In terminals and code editors, the AI can't add a line break you didn't say.
- **Choose what cleanup does.** A new Settings › Cleanup tab has a switch for each of these:
  - applying self-corrections ("Tuesday, no wait, Wednesday")
  - spoken formatting commands ("new line", "bullet point")
  - turning enumerations into lists
  - written forms for numbers, times and emails
  - grammar fixes

  Filler removal and punctuation stay on. The AI cleanup and app-tone switches moved to this tab too.
- If the AI breaks a rule you've switched off, Bardic uses a simple cleanup of the transcript instead.
  This applies to grammar fixes and formatting commands.
- **"Hey Bardic" voice commands.** Start a dictation with "Hey Bardic" to change a setting instead of
  typing, for example:
  - "Hey Bardic, add Living Internet Alliance to my dictionary"
  - "Hey Bardic, change the push-to-talk key to the function key"
  - "Hey Bardic, turn off grammar fixes"

  The pill confirms each change. Switch it off in Settings › General.
- Dictionary terms are no longer added to text that doesn't mention them.
- **Clearer dictionary.** Settings › Dictionary is now a list with one box per term, plus instructions
  and examples. Existing entries carry over.
- "Copy debug info" lists which cleanup rules are off.
- If the AI reorders what you said, for example swapping the two places in "the mall, no wait, the
  bookstore", Bardic uses the simple cleanup instead.
- Faster first cleanup after Bardic has been idle. The model warms up while you talk, and macOS is told
  not to throttle Bardic while it processes a dictation.

## 0.2.1

- The disk image opens without a security warning. 0.2.0's disk image was signed, which makes macOS
  check it and block it because it isn't notarized. Now only the app asks for "Open Anyway".
- Pressing Retry while still offline no longer deletes a speech or cleanup model that had finished
  downloading.
- The setup message now says the one-time preparation of the speech model can take up to 10 minutes.
  It took about 9 on an M1 Pro.

## 0.2.0

The first public release.

- **App icon** and an **About** tab (Settings › About) with the version, links and acknowledgements.
- **Copy debug info** (Settings › About) gathers what's needed for a bug report: versions, Mac model,
  model status and recent log lines. No dictated text is included.
- **Update check.** The menu shows "Bardic x.y.z is available" when a new release is out. It asks GitHub
  at launch and once a day; switch it off in Settings › General.
- **Sturdier first run:**
  - The speech model download shows a percentage.
  - A failed download offers **Retry** in the menu and the setup window.
  - Disk space is checked before downloading.
  - A half-finished or damaged download is detected and fetched again.
- If the AI cleanup model can't load, dictation keeps working and pastes the raw transcript.
- The disk image includes a "Read Me First" file with install steps.

## 0.1.0

Personal build, shared by hand.

- Push-to-talk dictation: WhisperKit (Whisper large-v3 turbo), cleaned up by Qwen 2.5 3B on MLX, then
  pasted at the cursor.
- Hands-free mode, Esc to cancel, and a menu-bar key picker (Right Option, Right Command, Right
  Control or Fn).
- Tone adapts to the app in front. There's also a personal dictionary and a local history.
- First-run setup window, and a live recording pill with level bars and a "Can't hear you" warning.
