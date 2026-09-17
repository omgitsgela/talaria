# Changelog

All notable user-visible changes to Talaria. Versioning is `major.minor` for feature
rounds plus a monotonic `+build` code that is mirrored in `lib/src/app_version.dart`.

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
