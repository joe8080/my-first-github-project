# JEV — Joe's personal assistant

JEV is Joe's JARVIS: a voice-friendly assistant built on Claude and the
apps Joe already uses (Gmail, Google Calendar, Google Sheets).
No servers, no code to run, no passwords stored here.

## Phase 1 — Morning briefing (live)

Every morning at about **6:56am UK time**, JEV:

1. Reads today's diary.
2. Checks unread email for anything that needs Joe.
3. Reads last night's market-close newsletter.
4. Emails Joe a short briefing written to be read aloud.

Listen hands-free: ask your phone assistant to "read my latest email",
or open it in Gmail and use read-aloud.

The exact instructions JEV follows are in [`briefing-prompt.md`](briefing-prompt.md).

## Safety rules

- JEV only **reads**. The only thing it sends is one email, to Joe.
- It never trades, pays, deletes, replies or unsubscribes.
- It never repeats codes, card numbers or account IDs.

## Change or stop it (just say it to Claude)

1. "Change JEV's briefing time to 7:30."
2. "Add Amy's calendar to JEV."
3. "Pause JEV" or "Stop JEV."

## Roadmap

| Phase | What JEV does | Status |
|---|---|---|
| 1 | Daily briefing by email | Live, 1-week trial |
| 2 | Voice commands: draft replies, book diary blocks, log dividends | Next |
| 3 | Spoken audio briefing (ElevenLabs voice) and phone agent | Planned |
| 4 | Weekly £1m-plan check, income tracker, ISA allowance alerts | Planned |

## Known gaps

- **Live share prices:** the FMP price feed needs a paid plan, so the market section
  uses newsletter data for now. Picking a free price source is a Phase 2 task.
