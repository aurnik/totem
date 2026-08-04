---
name: testflight-release
description: Ships a processed Totem build to the external TestFlight group with tester notes written in plain language. Use when asked to release a build, send a build to testers, submit for Beta App Review, or write release notes for TestFlight.
---

<objective>
Turn a build that has finished processing into a release the friends testing
Totem can actually understand: work out what changed for them, say it in their
words, and submit it for Beta App Review.

The mechanics are already scripted. The part that needs judgment — and the
reason this skill exists — is the notes. Commit titles are written for whoever
maintains the code. Testers are friends with a chat app on their phone.
</objective>

<quick_start>
All commands run from the repo root and need the App Store Connect key:

```sh
export ASC_KEY_ID=XDXW768THD
export ASC_ISSUER_ID=df950a66-401d-472a-83c5-8b63058088b2
export ASC_KEY_PATH="$HOME/.appstoreconnect/AuthKey_XDXW768THD.p8"
S=Server/onboard/.venv/bin/python
```

- `$S Server/onboard/testflight_submit.py --status` — build states, groups, what review gates on
- `$S Server/onboard/testflight_submit.py --commits <build>` — commits this build carries
- `$S Server/onboard/testflight_submit.py --submit <build> --notes-file notes.txt` — ship it

Never read the `.p8` key. Pass its path; the script signs with it.
</quick_start>

<process>
**1. Confirm the build is ready.**

Run `--status`. The build must be `processingState: VALID`. If it is still
`PROCESSING`, wait — Apple takes 5-15 minutes after upload. Note whether a
`reviewSubmission` already exists: editing notes on an approved build is fine
and does not re-trigger review, but a second submission returns 422.

If no build exists yet, `Server/onboard/testflight.sh` builds and uploads one
(absolute path — its cwd drifts).

**2. Find out what actually changed.**

`--commits <build>` lists the commit subjects the build carries, derived from
the build-number timestamps. That is the raw material, not the answer.

Read the commits themselves before writing — `git log` with bodies, and
`git show` on anything whose subject is unclear. Commit bodies in this repo
explain reasoning, which is usually where the user-facing consequence hides.

**3. Sort every change into one of three buckets.**

- **Forces the tester to act** — they must update, or something they set up is
  gone, or a habit no longer works. This leads, always, in the first line.
- **They will notice it** — new thing, changed thing, fixed annoyance.
- **They will notice nothing** — refactors, dead-code removal, server-side
  cleanup. These do not get described. If one touched a risky area, convert it
  into a request to try that area instead.

**4. Write the notes.**

Follow references in `<voice>`. Draft, then cut. Three or four short lines beat
a changelog nobody reads.

**5. Show the user the draft and wait.**

These notes go to real people the moment they are submitted, and they cannot be
unsent. Print the draft and ask before submitting — unless the user has already
said to go ahead without checking.

**6. Submit.**

Write the approved text to a file, then
`--submit <build> --notes-file <path>`. Add `--dry-run` first to see exactly
what would be sent. The script sets the notes, attaches the build to every
external group, and files the review submission.

**7. Verify.**

Re-run `--status`. Expect the notes to be in place and `reviewSubmission` to be
`WAITING_FOR_REVIEW` or `APPROVED`. Builds under an already-approved
`MARKETING_VERSION` usually clear in about a minute. Report the state plainly;
if review rejects, the reason appears here.
</process>

<voice>
Write the way you would text a friend who is doing you a favour by testing.

**Lead with what they must do.** If old builds stop working, that is the first
line. Never bury it under a list of improvements.

**Say what they see, not what changed underneath.** "Your buddy list loads
faster" — not "removed a redundant query". If a change has no visible effect,
it does not belong in the notes at all.

**Ban the internal vocabulary.** No DTO, wire, frame, relay, fan-out, actor,
socket, migration, refactor, endpoint, TTL, presence machine. If a sentence
needs one of those words, it is describing the wrong thing.

**Name features the way the app does.** Buddy list, away message, soundboard,
voice chat, dictation, avatar — the words on the screen.

**Turn risky cleanups into asks.** When a release moves code under voice,
dictation or group chat without meaning to change it, say so and ask them to
try exactly those flows. A tester who knows where to look is worth more than
one who reads a summary.

**Keep it short and specific.** No marketing voice, no "various improvements
and bug fixes", no emoji, no version headers. If nothing user-facing changed,
say that honestly and ask for the specific check you want.
</voice>

<example>
A release that was pure internal cleanup plus one breaking change:

```
Housekeeping release — no new features, but everyone needs it.

Older builds can't sign in anymore, so update when you get a chance.

A lot of unused code came out behind the scenes, including bits near voice
chat, dictation and group chats. None of it should look any different — so
if something does, that's a bug and I want to hear about it. Worth a quick
try: voice in a group chat, the dictation toggle, and signing out and back in.
```

Why it works: the forced update is line two, no internal vocabulary survives,
and the twenty-odd refactor commits become one honest sentence plus a specific
request.
</example>

<success_criteria>
- Build was `VALID` before submitting
- Every commit was read, not just its subject line
- Anything forcing tester action leads the notes
- No internal vocabulary reached the notes
- Changes with no visible effect were either omitted or turned into a request to test
- The user saw the draft before it was sent
- `--status` afterwards shows the notes in place and review `WAITING_FOR_REVIEW` or `APPROVED`
</success_criteria>
