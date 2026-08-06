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
- `$S Server/onboard/testflight_submit.py --submit <build> --notes-file notes.txt` — ship it,
  then expire every older build
- `$S Server/onboard/testflight_submit.py --submit <build> --notes-file notes.txt --notify` —
  same, but also emails every tester that it's available
- `$S Server/onboard/testflight_submit.py --expire-previous <build>` — retire older builds on
  their own, for when a submission half-finished

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
- **They will notice it** — new thing, changed thing, fixed annoyance. This is
  the body of the notes and very nearly all of them.
- **They will notice nothing** — refactors, dead-code removal, server-side
  cleanup. These produce no text at all. Not a summary, not a caveat, not a
  request to go and check the areas they touched. A release of nothing but
  internal work produces one plain line, like "Small fixes." — the work being
  large is not a reason to mention it.

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
what would be sent, including which older builds would be expired. The script
sets the notes, silences the release email, attaches the build to every
external group, files the review submission, and then expires every older
build.

Releases are **silent by default** (`autoNotifyEnabled: false`). Builds go out
several times a day here, and an inbox full of them is one nobody reads on the
release that matters. Testers still get the build — silently if their
TestFlight auto-updates, otherwise next time they open it — and since older
builds are expired, anyone who falls behind is told to update by the app
rather than by a mail they've learned to ignore. Pass `--notify` for a release
worth interrupting people about; it has to be set before the build reaches an
external group, which is what sends the mail, so it can't be added afterwards.

That last step matters because the client and server ship together here.
TestFlight keeps offering a build until it expires, so a tester reinstalling
can land on an old client talking to a server that has moved past it — which
surfaces as sign-in failing for no visible reason. Expiring leaves exactly one
installable build. It runs last on purpose: a failure earlier leaves the old
builds installable rather than retiring them in favour of one that never
shipped.

**7. Verify.**

Re-run `--status`. Expect the notes to be in place, `reviewSubmission` to be
`WAITING_FOR_REVIEW` or `APPROVED`, and every build but the new one to show
`expired: True`. Builds under an already-approved `MARKETING_VERSION` usually
clear in about a minute. Report the state plainly; if review rejects, the
reason appears here.
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

**Nothing but the updates.** No asking testers to try particular flows, no
flagging which areas were touched, no requests for feedback. Feedback is what
the group is for; the notes are the list of what is new.

**Third person, never first.** These read as an app's release notes, not a
message from whoever built it. No "I", no "me", no "I want to hear about it".

**Keep it short and specific.** No marketing voice, no "various improvements
and bug fixes", no emoji, no version headers.
</voice>

<example>
A release carrying four user-facing features, one breaking change, and roughly
twenty commits of internal cleanup:

```
Update when you get a chance — older builds can't sign in anymore.

New since the last build you got:

Avatars. Make a face for yourself in Settings and your friends will see it
next to you in chats and on their buddy list. Until you pick one, nobody sees
a face for you.

Dictation. Start voice in a chat and a dictation toggle appears above the
message box. Turn it on and whatever you say gets sent as a normal message.

Friend requests now reach you even when the app is closed, and if you and
someone have both added each other you're friends straight away — no
accepting.

Settings picked up soundboard management and a light/dark choice.
```

Why it works: the forced update is the first line, every entry is something a
tester can see or do and is described in the words on the screen, and the
cleanup commits produced no text whatsoever — no summary of them, no note that
they were near voice or group chat, no invitation to go and test anything.
</example>

<success_criteria>
- Build was `VALID` before submitting
- Every commit was read, not just its subject line
- Anything forcing tester action leads the notes
- No internal vocabulary reached the notes
- Changes with no visible effect produced no text, in any form
- Nothing is written in first person, and nothing asks the tester to try or report anything
- The user saw the draft before it was sent
- `--status` afterwards shows the notes in place and review `WAITING_FOR_REVIEW` or `APPROVED`
- Every build older than the one just shipped shows `expired: True`
</success_criteria>
