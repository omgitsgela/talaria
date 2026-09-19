# Changelog

All notable user-visible changes to Talaria. Versioning is `major.minor` for feature
rounds plus a monotonic `+build` code that is mirrored in `lib/src/app_version.dart`.

## 1.3.1

### build 40
- **Stopping a turn no longer leaves anything spinning.** Both the "Hermes is working…" indicator and a
  reasoning trace's spinner are driven by one flag on the row, and an interrupted turn does not always
  deliver the event that clears it. So a turn you stopped kept its indicator running, and repeating that
  left earlier messages stuck in a rendering state, each of them still believing it was working. The
  app now settles the transcript the moment you press Stop, and again whenever the gateway confirms the
  session is idle, so a stopped turn leaves neither a spinner nor a stuck row behind. What the
  interrupted turn had already thought is still kept. (#18)

## 1.3.0

### build 39
- **Queued messages are visible, editable and droppable.** `/queue` (and `/q`) used to hand the message
  straight to the gateway, which keeps one queued prompt and offers no way to see or change it, so it
  had already committed by the time you wanted to fix a typo. Queued messages are now held by the app:
  a strip above the composer shows what is waiting, labelled "Queued for the next turn", and each entry
  can be edited in place (loading it into the composer, where sending updates it instead of starting a
  turn), sent immediately, or dropped. Clearing the composer while editing drops it too. The queue is
  saved, so closing the app does not lose it, and a send that fails leaves the message queued rather
  than losing what you wrote. When the running turn ends the next queued message goes out with queue
  mode forced, so it still can never become a live correction of a running turn. (#17)

## 1.2.9

### build 38
- **Reading is no longer interrupted by a jump.** If you were scrolled up while a reply streamed,
  the view could occasionally jump to a different part of the conversation, sometimes to the very
  start of it. The reading-position hold compensates for new content arriving at the newest end, and
  it was also compensating when the transcript was *replaced* underneath you (which happens when the
  app recovers a session that the gateway has moved on from). Your offset no longer means the same
  content after a replacement, so the compensation was moving you to somewhere else entirely, once
  per layout pass, which is why the jump overshot. A replaced transcript is now recognised and left
  alone: your position is kept, and following the newest message still works as before. (#16)

## 1.2.8

### build 37
- **Images the agent produces now appear.** The gateway sends a client the parsed result of a tool,
  and a tool that generates or downloads a picture names it there. The transcript now looks for a
  fetchable source in that result, meaning a link to an image or embedded image data, and shows the
  picture under the tool row that made it, tappable to open full size. A source that is only a path
  on the gateway is still skipped, because a phone cannot load it, and the placeholder keeps saying
  so rather than showing a broken box. (#15)

## 1.2.7

### build 36
- **Select text across a whole reply.** In markdown mode every paragraph was its own selectable
  widget, so a selection could not leave the block it started in. The message body now renders
  inside a single selection region: one drag or one long-press extends across the whole reply, and
  "Select all" covers the message. Plain-text mode and the reasoning-trace body behave the same
  way, and a vertical drag on the transcript still scrolls the list. (#10)
- **Send photos from the gallery or the camera.** Attach one or more images, see what is pending
  with a preview, filename and size, and remove any of them before sending. Images are staged
  through the gateway's image path with its byte cap enforced before anything is uploaded, and
  removing a staged image detaches it server-side. Non-image files keep using the file path. (#11)
- **Images in replies render.** Data URLs, http(s) images, markdown image syntax and bare image
  paths all render: constrained to a phone-sized preview, rounded, and tappable to open full size.
  Anything the phone genuinely cannot fetch shows a labelled placeholder rather than a broken box,
  so a reply is never silently missing a picture. (#12)
- **A photo you sent now appears in the conversation.** The transcript names a sent photo by the
  gateway-staged path, which a phone cannot fetch, so it used to appear as a placeholder even though
  the app had the bytes moments earlier. Those bytes are now retained for the run under the same
  path, bounded in size and count, and the transcript draws from them. The placeholder is unchanged
  as the fallback. One limitation remains and is documented: an image the *agent* produces is named
  in the transcript but its bytes are never sent to a remote client, so it still shows a placeholder.
  (#11, #12)
- **Tap the context reading for a breakdown.** The compact reading in the title bar now opens a
  meter: category slices (system prompt, tools, memory, conversation) against the model's window,
  with used and remaining. It is fetched when you open it, so the ordinary turn path costs no extra
  round trip, and a gateway that does not report a breakdown shows nothing rather than a guess. (#13)
- **Reasoning level from Settings.** A Reasoning section reads the level currently in force, writes
  the global default, and re-reads afterwards so a write that did not stick is reported as not
  applied rather than shown as success. Unsupported levels are refused. (#14)

## 1.2.6

### build 35
- **Reading earlier no longer jitters.** With the reader scrolled away from the newest message,
  every streamed character still re-laid-out the transcript: the newest end grew, the content
  shifted, and the read-position correction moved it back, two phases per character. Those
  characters are off the bottom of the viewport while you read, so they are no longer painted
  per character at all: the app accumulates them and repaints in one frame when you return to
  the newest end. New messages, tool activity and the end of a turn still appear immediately,
  so the transcript is never frozen. (#1)
- **An expanded reasoning trace stays open while new content streams in.** A trace you had open
  collapsed by itself as soon as a new message started. The transcript is a reversed list, so
  appending a message moves every row's slot, and the rows were being re-created rather than
  moved, which discarded their state (the trace's expansion lives in that state). The rows now
  keep their identity across a shift, and their layout shape is constant rather than changing
  around the read divider. (#9)

## 1.2.5

### build 34
- **Scrolling up while a reply streams no longer snaps back to the newest message.** The real cause
  was not the streaming growth but a mid-stream SHRINK: the reasoning trace is an expandable row
  whose height changes as it animates or reflows, so the content size could drop by hundreds of
  pixels while a turn was running. The read-position hold applied that negative delta, which clamped
  the scroll offset onto the newest end, and the follow-to-bottom latch then re-armed off that
  clamped offset. From there every single streamed character pulled the view back to the bottom, so
  reading an earlier part of the conversation was impossible. Three changes fix it: the follow latch
  now changes only on a real user gesture (never on a programmatic move or a layout clamp), the hold
  ignores a shrinking extent while a turn is streaming (the offset is anchored at the newest end, so
  older content shrinking above the viewport does not move what is on screen), and a scroll that
  settles at the newest end re-arms following as before. (#1)
- The change is pinned by four tests, including the shrink-during-stream case that reproduced the
  original report exactly (`pixels` collapsing to `0.0`).

## 1.2.4

### build 33
- **`/queue` now actually queues.** The command submitted its message as a plain mid-turn
  prompt, so the gateway applied the session's busy mode to it: with the default `interrupt`
  mode the current turn could be redirected or even interrupted instead of the message running
  after it. `/queue` and its `/q` alias now pass `queued: true`, which forces queue mode on the
  gateway so a run-after message can never become a live correction of the running turn. Plain
  mid-turn sends and skill kickoffs keep the session's busy mode, matching the desktop. (#2)
- **Compression acknowledges when it starts.** Tapping *Compress context* was silent until the
  result toast at the end, and the gateway's own progress line only appears for conversations of
  four or more messages and was easy to miss. The app now shows a start notice the moment the
  request is accepted, and the gateway's progress text still fills the status line while it
  runs. (#3)
- **Scrolling while a reasoning trace streams is now pinned in tests.** Build 32 already let a
  live gesture win while a message streams; the reasoning path uses the same guard, and a
  regression test now proves the trace case directly so it cannot regress. (#1)
- CI pins `ubuntu-24.04` ahead of GitHub's October 19 migration of the `ubuntu-latest` label to
  Ubuntu 26, so the runner image does not change under the project. (#5)

## 1.2.3

### build 32
- **You can read while a reply streams.** Scrolling up during a streaming reply now holds your
  position with the response continuing to grow below, instead of the view being dragged back to the
  newest message on every streamed character. Following resumes when you return to the bottom.
- The cause was that the follow path jumped to the newest end without checking whether a gesture was
  in flight. A streamed reply delivers a change every few milliseconds, so each jump cancelled the
  drag before it could move the view far enough to stop following: the offset could never escape the
  near-bottom band. A live gesture now wins, and a content-size change can no longer re-arm the
  follow mid-drag either.

## 1.2.2

### build 31
- No user-visible changes. This build exists to correct the packaging metadata that an F-Droid
  submission depends on: Flutter is now pinned exactly (`flutter: 3.47.2`) rather than to the old
  `>=3.22.0` range, which both understated what the project needs and could not be read by F-Droid's
  build tooling, and the recipe now clones the Flutter SDK's stable branch and checks out the version
  the project declares, which is the convention other Flutter apps in their repository follow.

## 1.2.1

### build 30
- The connection screen offers **Sign in with Hermes** as soon as it knows the gateway, instead of
  only appearing after you press Test connection.
- That screen now also keeps the **bearer token field available alongside the sign-in button**, so a
  token minted elsewhere is still a way in. Previously the field vanished for exactly the gateways
  that support signing in, leaving no way to paste one.
- The connection screen shows the app's own logo in place of a generic aeroplane icon.
- Its tagline now comes from the same constant the splash uses, so the two screens can no longer
  disagree about the app's one-liner.
- Field explanations wrap properly. Flutter ellipsizes a helper after one line unless a line limit
  is set, which was hiding most of the token explanations on a phone.
- The README explains, in plain terms, the three ways to reach a gateway: the same Wi-Fi, a private
  network between your devices, or a hosted gateway shared with you.

## 1.2.0

### build 29
- The application ID is now `com.ionfyre.talaria`, under a domain the project owns, which is what
  F-Droid asks for. This installs as a **new app**: uninstall any earlier build first, and the
  saved gateway settings will not carry over.
- Markdown rendering moved from the discontinued `flutter_markdown` to `flutter_markdown_plus`.
- Prepared for F-Droid: listing text, screenshots and a per-version changelog under `fastlane/`, a
  submission recipe at `docs/fdroid/com.ionfyre.talaria.yml`, and a documented read against their
  inclusion policy.
- The README's privacy section now states plainly what the app does not do: no tracking, no
  analytics, no advertising, no crash reporting, no backend of ours, and nothing leaves the device
  unless you send it.
- Build documentation names OpenJDK (Temurin) explicitly, since F-Droid rejects proprietary build
  tools including Oracle's JDK.

## 1.1.3

### build 28
- A conversation can be searched from the conversation list. The filter matches titles and previews
  as you type, keeps the search box visible when nothing matches, and offers Clear search.
- Settings has a Diagnostics section that copies a bug report: app version, platform, gateway host,
  and the most recent error with its stack trace. Never the gateway token. The same report is offered
  in place when a screen hits an error, and the report panel now works in released builds, not only
  debug ones, so a bug can be reported without installing a debug APK.
- Fixed the app getting stuck on "Loading conversation…" after a force close and reopen.

## 1.1.2

### build 27
- Opening a long conversation now shows a loading state instead of the "Ask Hermes anything" empty
  state, which made a conversation that was still loading look like a brand new one, and could read
  as though the rest of the list had gone missing.
- A model switch is now sent only when the conversation is genuinely live on the gateway. A switch
  the gateway defers to the next turn, or refuses, is reported as such instead of being shown as
  applied, which is how the app bar could disagree with the model that actually answered.
- Searching the model list with no results no longer removes the search field, and offers a Clear
  search action to get back to the full list.

## 1.1.1

### build 26
- The app bar now shows how much of the model's context window the current conversation is
  using, right of the model name, for example `24.5k/128k`. It stays hidden until the gateway
  reports a real measurement, so it never shows a fabricated 0%.

## 1.1.0

### build 25
- Fixed assistant commentary being printed twice when a tool call followed it: the sentence
  appeared once before the tool block and once after it. An authoritative text update from
  the gateway now replaces the segment it belongs to instead of adding a second copy.

### build 24
- Clarify and approval prompts are answerable again. Replies now carry the request id the
  gateway resolves them by (and a question id for multi-question forms), so the card can be
  answered and cleared instead of sitting on screen. Multi-question prompts render every
  question with its own choices, and there is a Dismiss button.
- Expired requests clear their card, and a reply the gateway no longer knows about drops the
  card rather than re-arming it.

### build 23
- The gateway now reports an error instead of a false success when a session-scoped
  setting names a session that no longer exists; the app recovers by re-attaching the
  stored conversation and retrying once.
- Removed the trailing status pill from the transcript. It mostly echoed internal agent
  chatter and could sit on a stale "Using <tool>…" line for a whole turn. Failures now
  surface as a SnackBar so nothing goes silent.
- Fixed a transcript that could blank during a long turn on a very large conversation:
  context compaction rewrites the history mid-turn, so transcript reads are now deferred
  until the compaction reports done.

### build 22
- Changing the model in an open conversation now verifies it lands on that conversation's
  live session first, so the pick can no longer be applied to nothing.
- An empty history read can no longer wipe a transcript that is on screen, and a resume
  that hydrates no rows arms a follow-up read instead of leaving a blank view.
- Status notices only carry meaningful kinds; internal lifecycle narration is ignored.

### build 21
- Fixed unreadable blockquotes in dark mode (white text on the markdown package's
  hardcoded light-blue panel).

### build 20
- Streaming performance: transcript rows are memoized against a per-message revision so a
  streamed delta rebuilds only the row that changed; derived message text is cached; the
  conversation roster skips no-op refreshes.
- Fixed a bug where resuming or refreshing a conversation re-displayed reasoning traces
  that the user had hidden.

### build 19
- Fixed the follow/jump-to-latest arrow going stale when content size changed (expanding
  or collapsing a trace), rather than on scroll.

### build 18
- Hardened the transcript list against a render-tree assertion that could replace the
  conversation with an error screen after selecting text while streaming.

### build 17
- Recovery for a conversation whose runtime session was reaped after a background
  disconnect: the app re-attaches the stored session, so the next send, Stop, and the
  status dot work again.
- The reconnect banner no longer lingers after recovery.

### build 16
- Delete conversation now works, with a confirmation dialog and an honest result message,
  instead of silently doing nothing.

### build 15
- A send that never reaches the gateway no longer leaves a ghost message; the draft is
  restored to the composer instead.

### build 14
- Reading position is held while a reply streams in, so the transcript no longer drifts
  under the reader.

### build 13
- Assistant turns render in their true order: text, thinking, and tool activity are kept
  as an ordered part list instead of being regrouped by kind.
- Fixed composer thrash caused by a variable-height input resizing the transcript.
- Splash brand identity.

### build 12
- Conversation roster headers and time pills restyled for contrast.

### build 11
- Goal bar gains a close button that clears the goal through the gateway.

### build 10
- Reversed transcript list, so opening a long conversation anchors on the newest message
  instead of painting from the top and jumping.
- Fixed a status line that stuck on "Refreshing session…" after a reconnect.

### build 9
- Rich Markdown rendering for assistant replies (selectable text, working links, themed
  code blocks) with a settings toggle.
- Persistent goal bar mirroring the gateway's goal state.

### build 8
- Conversation list segmentation into pinned plus time buckets, with client-side pinning.

### builds 6–7
- Time-section breaks in the transcript (Today / Yesterday / date).

Older internal builds predate this changelog.
