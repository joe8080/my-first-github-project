# JEV — Joe's personal assistant

JEV is Joe's JARVIS: a voice-friendly assistant built on Claude and the
apps Joe already uses (Gmail, Google Calendar, Google Sheets).
No servers, no code to run, no passwords stored here.

## Phase 1 — Morning briefing

Scheduled task "JEV Morning Briefing" is live. Every morning at about
**6:56am UK time**, JEV:

1. Reads today's diary.
2. Checks unread email for anything that needs Joe.
3. Reads last night's market-close newsletter.
4. Emails Joe a short briefing written to be read aloud.

Listen hands-free: ask your phone assistant to "read my latest email",
or open it in Gmail and use read-aloud.

The exact instructions JEV follows are in [`briefing-prompt.md`](briefing-prompt.md).

## Phase 2 — Voice commands (live once the skill is uploaded)

Talk to Claude (voice mode or dictation) and start with "JEV":

1. "JEV, briefing" — today's day, spoken.
2. "JEV, what's next" — next three diary items.
3. "JEV, reply to DistroKid saying the card is updated" — saves a Gmail draft, reads it back.
   Say "send it" to send.
4. "JEV, book deep work Tuesday 10 till 12" — checks clashes, confirms, books.
5. "JEV, move / cancel <event>" — confirms first.
6. "JEV, log a dividend: Microsoft 4 pounds 12, ISA" — adds a row to the
   "JEV Dividend Log" tab in Portfolio_Dividend_Tracker.xlsx.
7. "JEV, dividends this year" — totals and progress to £1,000 a month.
8. "JEV, check for new dividends" — looks for Trading 212 statements in Gmail.

The commands live in [`skill/jev/SKILL.md`](skill/jev/SKILL.md).
To install: upload `jev-skill.zip` in claude.ai under Settings → Capabilities → Skills.

## Safety rules

- The morning briefing only **reads**; the only thing it sends is one email, to Joe.
- Voice commands read back every change and wait for "yes" before acting.
- Emails to anyone else are only sent after Joe hears them and says "send it".
- JEV never trades, moves money, pays, deletes emails or unsubscribes.
- It never repeats codes, card numbers or account IDs.

## Change or stop it (just say it to Claude)

1. "Change JEV's briefing time to 7:30."
2. "Add Amy's calendar to JEV."
3. "Pause JEV" or "Stop JEV."

## Roadmap

| Phase | What JEV does | Status |
|---|---|---|
| 1 | Daily briefing by email | Live (6:56am daily) |
| 2 | Voice commands: draft replies, book diary blocks, log dividends | Built — upload skill to switch on |
| 3 | Spoken audio briefing (ElevenLabs voice) and phone agent | Planned |
| 4 | Weekly £1m-plan check, income tracker, ISA allowance alerts | Planned |

## Known gaps

- **Live share prices:** the FMP price feed needs a paid plan, so the market section
  uses newsletter data for now. Still open: pick a free price source.
- **Dividend auto-detect:** Trading 212 doesn't email each dividend, so logging is
  by voice; "check for new dividends" only works if a statement lists them in the email.
