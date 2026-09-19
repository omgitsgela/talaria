import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gateway/client.dart';
import '../models/models.dart';
import '../store/chat_store.dart';
import '../app_scope.dart';
import '../widgets/context_meter.dart';
import '../widgets/message_bubble.dart';
import '../widgets/queued_prompt_strip.dart';
import '../widgets/attachment_strip.dart';
import '../media/image_attachment.dart';
import 'settings_screen.dart';

typedef PhoneImagePicker = Future<XFile?> Function(ImageSource source);

Future<XFile?> _pickPhoneImage(ImageSource source) =>
    ImagePicker().pickImage(source: source);

/// Main connected surface: transcript + composer + session rail.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.storeOverride, this.imagePicker});

  final PhoneImagePicker? imagePicker;

  /// Optional test seam: when non-null, bypasses [AppScope] and uses this
  /// store directly.  Production callers leave it null.
  final ChatStore? storeOverride;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _composerDirty = false;

  /// Auto-scroll bookkeeping.
  ///
  /// A conversation (re)open is a "take me to the newest message" event. The
  /// store raises a STICKY [ChatStore.pendingJumpToBottom] flag when it opens
  /// or resumes a session; because the transcript hydrates in a later build
  /// than the one that flips the session id, the jump must be retried until the
  /// list actually has scrollable content (a one-shot jump measured an empty
  /// list and never re-fired — the reopen-to-top bug). Within the same
  /// conversation we only auto-follow new messages when the user is already
  /// near the bottom, so scrolling up to re-read is never fought. When they
  /// read upward we drop a "where you left off" divider and show a jump arrow.
  bool _stickToBottom = true;

  /// Set the follow latch AND tell the store whether the reader is away from the
  /// newest end.
  ///
  /// The store defers per-character content updates while the reader is away
  /// (see `ChatStore.setReaderAway`): a streamed character that lands off the
  /// bottom of the viewport does not need to be painted, and re-laying out the
  /// transcript for every one of them is what drifts the content under the
  /// reader and jitters it against the read-position hold. Structural events (a
  /// new message, a tool starting, the turn ending) still repaint immediately.
  void _setStick(bool stick) {
    _stickToBottom = stick;
    _trackedStore?.setReaderAway(!stick);
  }

  /// Row keys carry the CHRONOLOGICAL message index, so a row stays identifiable
  /// as the list grows.
  static const String _rowKey = 'msg-';

  /// Map a transcript row's [key] back to its CURRENT builder index, or `null`
  /// when the row is no longer in the list.
  ///
  /// The transcript is a REVERSED list whose builder index depends on the total
  /// count (`v = count - 1 - i`), so appending a message moves every row's slot.
  /// `ListView` locates children BY INDEX, so without this the sliver mismatches
  /// keys at every shifted slot and RE-CREATES those rows, losing their State:
  /// an expanded reasoning trace collapsed the instant new content streamed in
  /// while the user was reading it. Keys make a row identifiable; this is what
  /// lets the sliver find it again at its new index.
  int? _rowIndexFor(Key key, int count) {
    if (key is! ValueKey<String>) return null;
    final id = key.value;
    if (!id.startsWith(_rowKey)) return null;
    final v = int.tryParse(id.substring(_rowKey.length));
    if (v == null || v < 0 || v >= count) return null;
    return count - 1 - v;
  }

  /// Max scroll extent seen while the user is READING (not following the
  /// bottom). Used to compensate for the reversed-list geometry: when the
  /// newest message grows by Δ (streaming text appended at offset 0), the
  /// max extent increases by Δ but the user's offset stays fixed, so the
  /// content at that offset is now Δ newer — their reading position drifts.
  /// We track the extent and adjust the offset by the delta on each content
  /// change to keep the same content in view. Null when following or when
  /// the content is being replaced (session switch, open-jump).
  double? _pinnedMaxExtent;

  String? _lastSessionId;

  /// The store's transcript epoch last seen here. A CHANGE means the list under
  /// the reader was replaced rather than grown (see [ChatStore.transcriptEpoch]).
  int? _seenTranscriptEpoch;
  ChatStore? _trackedStore;

  /// The topmost message index in the current viewport (min index built this
  /// frame); committed to [lastReadIndex] after the frame to drive the divider.
  int? _topBuilt;

  /// Per session: the topmost message index the user has read down through.
  /// The divider is drawn just above this row, separating already-read history
  /// from newer content below. Cleared (set to the last index) when the user
  /// is at the newest message.
  final Map<String, int> _lastReadIndex = {};

  /// Whether the floating scroll-to-newest arrow is shown.
  bool _showJumpArrow = false;

  /// Failures raised by the store (`ChatStore.notices`). The transcript's gray
  /// status pill used to carry these; it was removed (it mostly showed the
  /// agent's internal chatter and stuck on "Using terminal…"), so a failure
  /// now surfaces as a SnackBar instead of going silent.
  StreamSubscription<String>? _noticeSub;

  ChatStore get store {
    final override = widget.storeOverride;
    if (override != null) return override;
    return AppScope.of(context).store!;
  }

  @override
  void initState() {
    super.initState();
    _input.addListener(() {
      final dirty = _input.text.trim().isNotEmpty;
      if (dirty != _composerDirty) {
        setState(() => _composerDirty = dirty);
      }
    });
    // Track whether the user is pinned to the bottom (drives follow + arrow).
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The store can come from AppScope (null in tests) or a storeOverride;
    // re-bind our listener whenever the instance changes.
    final s = _resolveStoreOrNull();
    if (s != _trackedStore) {
      _trackedStore?.removeListener(_onStoreChanged);
      unawaited(_noticeSub?.cancel());
      _noticeSub = null;
      _trackedStore = s;
      if (s != null) {
        _lastSessionId = null; // first bind: treat as a switch → jump to bottom.
        _seenTranscriptEpoch = s.transcriptEpoch;
        s.addListener(_onStoreChanged);
        _noticeSub = s.notices.listen((text) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(text),
              duration: const Duration(seconds: 5),
            ),
          );
        });
        _onStoreChanged();
      }
    }
  }

  ChatStore? _resolveStoreOrNull() {
    final override = widget.storeOverride;
    if (override != null) return override;
    return AppScope.maybeOf(context)?.store;
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeOverride != widget.storeOverride) {
      didChangeDependencies();
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // The transcript is a REVERSED list: offset 0 is the newest (bottom) and
    // offset max is the oldest (top). "At the bottom" (newest) is therefore a
    // small offset, not a large one.
    //
    // A finger on the list disarms the follow OUTRIGHT, even while the offset is
    // still inside the near-bottom band. The band alone is not enough to disarm
    // it during a streamed reply: a store change lands every few milliseconds,
    // each one jumping back to the newest end, so the drag is reset before it
    // can ever accumulate past 48px and the reader can never get away from the
    // bottom. While the gesture lasts, the user is driving; settling back inside
    // the band (the events after the finger lifts) re-arms the follow.
    final pos = _scroll.position;
    final dragging = pos.userScrollDirection != ScrollDirection.idle;
    final atBottom = pos.pixels <= 48;
    // Only the USER may change the follow latch. A programmatic move - the
    // read-hold's own adjustment, the open jump, a layout clamp - must never
    // re-arm it from the resulting offset, because ANY path that lands the
    // offset inside the near-bottom band would otherwise silently resume
    // following. That is how a streamed trace pinned readers to the newest
    // message: a mid-stream extent shrink clamped the offset to 0 and this line
    // read that clamp as "the user wants the bottom". Re-arming happens on a
    // deliberate settle at the newest end (see [_onScrollEnd]).
    if (dragging) {
      _setStick(false);
    }
    // Streaming-compensation (read-hold) arming: capture the extent ONCE, the
    // moment the user moves up from the newest end. From then on only the
    // content-change path updates the reference — re-reading it on every
    // scroll tick would swallow the very delta the hold is meant to apply
    // (a content-change scroll already moved the offset before this fires).
    // Returning to the newest end disarms (offset 0 needs no compensation).
    if (atBottom) {
      _pinnedMaxExtent = null;
    } else if (_pinnedMaxExtent == null) {
      _pinnedMaxExtent = pos.maxScrollExtent;
    }
    // Both helpers self-guard (only setState when their derived value changes),
    // so running them on every scroll tick is cheap and keeps the read divider
    // tracking as the user moves up/down, not just at the follow-threshold.
    _commitReadMarker();
    _updateArrow();
  }

  /// A list that has come to REST at the newest end is following again.
  ///
  /// Re-arming from the offset alone is unsafe (see [_onScroll]): anything that
  /// moves the offset programmatically - the read-hold's adjustment, a layout
  /// clamp - would read as user intent, and a streamed reply then pins the
  /// reader to the bottom. The deliberate "I am back at the live end" signal is
  /// the END of a scroll: a drag, a fling, or the jump-to-latest button that
  /// settles inside the near-bottom band. Horizontal inner scrollers (markdown
  /// code blocks) are ignored.
  void _onScrollEnd(ScrollEndNotification n) {
    if (n.metrics.axis != Axis.vertical) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels > 48) return;
    _setStick(true);
    _pinnedMaxExtent = null;
    _updateArrow();
  }

  void _onStoreChanged() {
    final s = _trackedStore;
    if (s == null) return;
    final sid = s.activeSessionId;
    if (sid != _lastSessionId) {
      // Conversation switch: jump to the most recent message.
      _lastSessionId = sid;
      _setStick(true);
      _pinnedMaxExtent = null;
      _lastReadIndex.remove(sid); // fresh open — no stale divider
      _scheduleOpenJump(s);
      _updateArrow();
      return;
    }
    // Same conversation: honor a sticky open-jump (content may have just
    // hydrated), else follow new messages only when near the bottom.
    if (s.pendingJumpToBottom) {
      _scheduleOpenJump(s);
      return;
    }
    if (_stickToBottom) {
      _seenTranscriptEpoch = s.transcriptEpoch;
      _scheduleScrollToBottom();
    } else {
      // A REPLACED transcript is not a grown one. The reader's offset no longer
      // describes the same content, and compensating for the extent change is
      // what flung a parked reader (offset 2500 of 9112) to 9978 of 12851 when a
      // silent rehydrate landed mid-turn: exactly twice the extent change,
      // because the compensation applied once per layout pass. Hold still and
      // re-baseline instead; the hold resumes on the next real growth.
      if (_seenTranscriptEpoch != s.transcriptEpoch) {
        _seenTranscriptEpoch = s.transcriptEpoch;
        _pinnedMaxExtent = null;
        _lastReadIndex.remove(sid);
        _updateArrow();
        return;
      }
      // The user is READING (scrolled up). The reversed list drifts toward
      // the newest end as that end grows (a streamed reply appended at
      // offset 0 widens the extent without moving the offset), so pin their
      // reading position by shifting the offset with the extent delta.
      _scheduleReadPositionHold();
    }
    _updateArrow();
  }

  /// Hold the user's reading position while new content streams in at the
  /// newest end of the REVERSED list.
  ///
  /// Geometry: offset is measured from the newest end (offset 0 = bottom).
  /// When that end grows by Δ (text appended to the live reply, or a new
  /// message), maxScrollExtent increases by Δ while the offset is unchanged —
  /// so the content under the viewport slides toward the newest end and the
  /// user's view "drifts". Adding Δ to the offset keeps exactly the same
  /// content in the viewport (like the anchor you get in a forward list).
  ///
  /// The measurement is deferred to post-frame: the store notifies BEFORE the
  /// frame that renders the grown content is laid out, so the extent delta
  /// only exists after layout. Only applied while the user is NOT following
  /// the bottom (no drift there — offset 0 is the newest end itself) and NOT
  /// actively dragging or settling a fling (adjusting mid-gesture would fight
  /// the user's finger).
  void _scheduleReadPositionHold() {
    final ref = _pinnedMaxExtent;
    if (ref == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final np = _scroll.position;
      if (np.userScrollDirection == ScrollDirection.forward ||
          np.userScrollDirection == ScrollDirection.reverse) {
        // Actively scrolling: do not fight the finger; the next scroll event
        // refreshes the reference.
        return;
      }
      final delta = np.maxScrollExtent - ref;
      if (delta.abs() < 0.5) return;
      _pinnedMaxExtent = np.maxScrollExtent;
      // A SHRINK is not something the newest end of a streaming reply does, and
      // applying one is how a reader gets dragged to the newest message. The
      // trace row is an `ExpansionTile` whose height changes as it animates,
      // reflows or is collapsed, so mid-stream the extent can drop by hundreds
      // of pixels: the negative delta lands `pixels + delta` on the 0 clamp,
      // and the follow latch then re-arms OFF that clamped offset, after which
      // every streamed character pins the view to the bottom. Re-baseline
      // instead of compensating: the offset is anchored at the newest end, so
      // older content shrinking above the viewport does not move what is on
      // screen.
      if (delta < 0 && store.streaming) return;
      final target = (np.pixels + delta).clamp(0.0, np.maxScrollExtent);
      if ((target - np.pixels).abs() > 0.5) {
        np.jumpTo(target);
      }
    });
  }

  /// Follow a freshly appended message, only meaningful when the list is
  /// non-empty.
  ///
  /// The list is REVERSED, so "the bottom" (newest message) is scroll offset
  /// 0 — no extent measurement is ever needed. During live streaming the
  /// transcript grows and the viewport naturally stays anchored at the newest
  /// end; an INSTANT `jumpTo(0)` (not a timed animation) pins it there on any
  /// frame where the user is still pinned, eliminating the wobble a 200ms
  /// animateTo caused.
  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      // A live gesture wins. Jumping to the newest end mid-drag cancels the
      // drag, which is how "scroll up while it streams" was impossible: every
      // streamed character reset the offset to 0 and re-armed the follow.
      if (pos.userScrollDirection != ScrollDirection.idle) {
        _setStick(false);
        _pinnedMaxExtent ??= pos.maxScrollExtent;
        _updateArrow();
        return;
      }
      if (pos.pixels != 0) {
        pos.jumpTo(0);
      }
      _setStick(true);
      _pinnedMaxExtent = null;
      _updateArrow();
    });
  }

  /// Perform (or, for an empty transcript, consume) the sticky open-jump.
  /// Called from a post-frame so the just-hydrated list is laid out. Retries
  /// while the transcript is still loading by leaving the flag set.
  ///
  /// In a REVERSED list the newest message is scroll offset 0, so a fresh open
  /// is anchored there by construction — no full-list extent measurement. This
  /// is exactly the perf win: opening a long conversation no longer forces the
  /// framework to measure every message before it can land, and it no longer
  /// flashes the top of the transcript first.
  void _scheduleOpenJump(ChatStore s) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!s.pendingJumpToBottom) return; // consumed elsewhere
      if (s.messages.isNotEmpty) {
        _jumpToBottom();
      } else if (!s.loadingSession) {
        // Fresh conversation: nothing to scroll to; consume the flag.
        s.consumeJumpToBottom();
        _setStick(true);
        _updateArrow();
        if (mounted) setState(() => _showJumpArrow = false);
      }
      // else: still hydrating — keep the flag; the next notification retries.
    });
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    // Newest = offset 0 in the reversed list.
    if (_scroll.position.pixels != 0) _scroll.jumpTo(0);
    _setStick(true);
    _pinnedMaxExtent = null;
    final sid = store.activeSessionId;
    if (sid != null) _lastReadIndex[sid] = store.messages.length - 1;
    store.consumeJumpToBottom();
    _updateArrow();
    if (mounted) setState(() => _showJumpArrow = false);
  }

  void _scrollToBottom() => _scheduleScrollToBottom();

  /// Show/hide the floating "newest message" arrow based on scroll position.
  /// Re-derive the follow/arrow state after a CONTENT-SIZE change.
  ///
  /// A size change (collapse/expand of a trace or tool list, markdown reflow)
  /// fires [ScrollMetricsNotification], not a scroll, so `_onScroll` — the only
  /// other place that maintains `_stickToBottom` / `_showJumpArrow` — never
  /// runs. Without this, shrinking the content so the transcript clamps back to
  /// the newest end left the jump-to-latest arrow on screen.
  ///
  /// Deferred to a post-frame callback: the notification arrives DURING layout
  /// and [_updateArrow] calls `setState`. Horizontal inner scrollers (markdown
  /// code blocks) are ignored.
  void _onTranscriptMetricsChanged(ScrollMetricsNotification n) {
    if (n.metrics.axis != Axis.vertical) return;
    if (_metricsResyncScheduled) return;
    _metricsResyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsResyncScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      final atBottom = pos.pixels <= 48;
      // A content-size change is never user intent, and while a turn streams the
      // extent changes with every character, so re-deriving the latch here is
      // how a reader gets overruled into "follow". Outside a stream keep the
      // round-20 behaviour, so collapsing a trace at the newest end still hides
      // the arrow and resumes following.
      if (!store.streaming) {
        _setStick(atBottom);
        _pinnedMaxExtent = atBottom ? null : pos.maxScrollExtent;
      }
      _updateArrow();
    });
  }

  bool _metricsResyncScheduled = false;

  void _updateArrow() {
    final show = _scroll.hasClients &&
        _scroll.position.maxScrollExtent > 1 &&
        !_stickToBottom;
    if (show != _showJumpArrow && mounted) {
      setState(() => _showJumpArrow = show);
    }
  }

  /// Fold the topmost-visible index into the per-session read marker (drives
  /// the "where you left off" divider) and rebuild if it changed.
  void _commitReadMarker() {
    final sid = store.activeSessionId;
    final top = _topBuilt;
    _topBuilt = null;
    if (sid == null || top == null) return;
    final last = store.messages.length - 1;
    int next;
    if (_stickToBottom || top >= last) {
      next = last; // at the newest — divider at the end (hidden)
    } else {
      next = top;
    }
    if (_lastReadIndex[sid] == next) return;
    if (mounted) setState(() => _lastReadIndex[sid] = next);
  }

  /// Record a built item for the read-divider. [i] is the REVERSED builder
  /// index (0 = newest); [count] is the total item count this frame. We
  /// convert to the chronological index and keep the OLDEST visible (smallest
  /// chronological) built — the "topmost of the viewport," exactly what the
  /// read divider uses, so its meaning is unchanged by the list reversal.
  void _topBuiltAssign(int i, int count) {
    final v = count - 1 - i;
    if (_topBuilt == null || v < _topBuilt!) _topBuilt = v;
  }

  /// The time-category break to show above the message at [i], or `null`.
  ///
  /// A break appears above the first message whose time BUCKET differs from
  /// the previous message's bucket (Today / Yesterday / older-date). Bucketing
  /// by calendar day (not wall-clock hour) keeps a single conversation readable
  /// — a 9-minute gap at 23:50→00:05 is a break (new day), but a 90-minute
  /// gap within the same day is not. The very first message always breaks, so
  /// the transcript opens with its date. Messages with no timestamp are
  /// skipped (never break) so an unknown-time gap can't manufacture a fake
  /// section.
  static String? _timeBreakLabel(List<ChatMessage> messages, int i) {
    final t = messages[i].time;
    if (t == null) return null;
    if (i == 0) return _timeBucketLabel(t);
    final prev = messages[i - 1].time;
    if (prev == null) return _timeBucketLabel(t);
    if (_dayBucket(t) != _dayBucket(prev)) return _timeBucketLabel(t);
    return null;
  }

  /// Calendar-day key (local timezone) used to detect a day boundary.
  static String _dayBucket(DateTime t) =>
      '${t.year}-${t.month}-${t.day}';

  /// Human label for a time bucket: "Today", "Yesterday", or a localized
  /// date (e.g. "Sep 8" / "Aug 14, 2025"). Localized via `intl`'s date
  /// formatter (falls back to a manual pattern if initialization is missing).
  static String _timeBucketLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(t.year, t.month, t.day);
    final days = today.difference(that).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    try {
      return _fmtDay(t);
    } catch (_) {
      final months = const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      final sameYear = t.year == now.year;
      return sameYear
          ? '${months[t.month - 1]} ${t.day}'
          : '${months[t.month - 1]} ${t.day}, ${t.year}';
    }
  }

  static String _fmtDay(DateTime t) {
    final now = DateTime.now();
    final sameYear = t.year == now.year;
    final fmt = sameYear
        ? DateFormat.MMMd() // "Sep 8"
        : DateFormat.yMMMMd(); // "August 14, 2025"
    return fmt.format(t);
  }

  /// True when [text] is an explicit slash command: the trimmed text starts
  /// with `/`. A bare `/help` (as inserted by the completion menu) or a full
  /// invocation like `/model gpt-5` both qualify. Ordinary messages that
  /// merely mention a slash mid-sentence (`send /usr to the server`) do NOT
  /// start with `/` after trim and stay prompt.
  static bool _isSlashCommand(String text) => text.trim().startsWith('/');

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty && store.pendingAttachments.isEmpty) return;
    _input.clear();
    if (_isSlashCommand(text)) {
      // Explicit slash → gateway slash.exec (prompt.submit does not dispatch
      // commands).  Pending attachments are preserved, not consumed.
      //
      // Ensure a live session first (draft → real on first command).
      if (store.activeSessionId == null || store.activeSessionId!.isEmpty) {
        await store.createSession();
      }
      // execSlashDispatch ACTS on the directive: /queue, /steer, /retry, /goal
      // and plain mid-turn sends are submitted (busy-queued by the gateway
      // when a turn is running); /undo prefills the composer; /alias targets
      // re-execute. Only display-only results surface a snackbar.
      final d = await store.execSlashDispatch(text);
      final prefill = store.takeComposerPrefill();
      if (prefill != null) {
        // /undo hands the backed-up message back for editing: restore it into
        // the composer instead of resubmitting.
        _input.text = prefill;
      }
      if (mounted && context.mounted) {
        final out = d.isSend || d.isSkill || d.isPrefill
            ? (d.isPrefill ? d.notice : '')
            : d.display;
        if (out.trim().isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(out.trim())));
        }
      }
    } else {
      // Plain text — always sendable, mid-turn included. A running turn
      // busy-queues it (status "queued"/"steered"/"redirected"), which is how
      // a mid-turn message influences the current run, like the desktop.
      final sent = await store.send(text);
      if (!sent && mounted && _input.text.isEmpty) {
        // The submit never reached the gateway. The store already removed the
        // optimistic transcript entry (no ghost message); put the draft back
        // so nothing the user typed is lost.
        _input.text = text;
      }
    }
    _scrollToBottom();
  }

  @override
  void dispose() {
    _trackedStore?.removeListener(_onStoreChanged);
    unawaited(_noticeSub?.cancel());
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Each full rebuild starts a fresh viewport pass; the itemBuilder tracks
    // the topmost visible index here for the read-marker divider.
    _topBuilt = null;
    return Scaffold(
      body: ConsumerStore(
          store: store,
          builder: (context, store) {
            final req = store.pendingRequest;
            final messages = store.messages;
            final sid = store.activeSessionId;
            // The "where you left off" divider sits just above the row the user
            // has read up to — it separates read history (below) from the
            // unread tail (above). Hidden when at the newest message.
            final lastRow = messages.length - 1;
            final readIdx = sid == null ? null : _lastReadIndex[sid];
            final dividerIndex = (readIdx != null &&
                    readIdx < lastRow &&
                    !_stickToBottom &&
                    !store.loadingSession)
                ? readIdx
                : null;
            return Column(
              children: [
                _ChatAppbar(store: store),
                Expanded(
                  child: messages.isEmpty && !store.streaming
                      ? (store.awaitingTranscript
                          ? _LoadingConversation(store: store)
                          : _EmptyState(store: store))
                      : Stack(
                          children: [
                            // Content-size changes (expanding/collapsing a
                            // reasoning trace or tool list, markdown reflow)
                            // dispatch ScrollMetricsNotification — NOT a
                            // scroll — so the follow/arrow state derived from
                            // scroll notifications can go stale: collapsing a
                            // trace at the bottom clamps the offset to 0 while
                            // the jump-to-latest arrow stays on screen.
                            // Catches BOTH content-size changes and scroll
                            // settles. `ScrollMetricsNotification` and
                            // `ScrollEndNotification` share no subtype, so the
                            // base `Notification` is the only type that sees
                            // both. Handlers filter by axis and this returns
                            // false, so inner scrollers keep bubbling.
                            NotificationListener<Notification>(
                              onNotification: (n) {
                                if (n is ScrollMetricsNotification) {
                                  _onTranscriptMetricsChanged(n);
                                } else if (n is ScrollEndNotification) {
                                  _onScrollEnd(n);
                                }
                                return false;
                              },
                              child:
                              ListView.builder(
                                controller: _scroll,
                                // NO automatic keep-alives. Each transcript row
                                // can hold a `SelectableText`, whose inner
                                // `EditableText` announces `wantKeepAlive` the
                                // moment it gains focus (`editable_text.dart`:
                                // `wantKeepAlive => widget.focusNode.hasFocus`) —
                                // i.e. as soon as the user taps to select text.
                                // A kept-alive child parked in the sliver's
                                // keep-alive bucket, in a list whose itemCount
                                // changes on every streaming delta, is the
                                // element/render-tree bookkeeping path that
                                // asserts (`dropChild`'s `child._parent == this`,
                                // `_InactiveElements.remove`'s
                                // `_elements.contains(element)`). Nothing in the
                                // transcript needs keep-alive: the composer's
                                // field lives outside this list, and an
                                // off-screen row losing its selection is a
                                // far better outcome than a corrupted tree.
                                addAutomaticKeepAlives: false,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12, horizontal: 12),
                                // REVERSED: the newest message is the FIRST
                                // (bottom) item. A fresh open lands on the latest
                                // message by construction (offset 0), so no
                                // full-list extent measurement is needed and the
                                // top of a long transcript never flashes first.
                                // Builder index i (0 = bottom) maps to
                                // chronological index v (0 = oldest), which keeps
                                // the read-divider / time-pill / status-row logic
                                // in its original message-index space.
                                reverse: true,
                                itemCount: messages.length,
                                // Appending a message shifts EVERY builder index
                                // (`i` maps to `v = count - 1 - i`), so the sliver
                                // cannot find a row at the index it last built it
                                // at. Keys alone do NOT save a lazy sliver: it
                                // matches children per index, so every shifted slot
                                // mismatches and the row is RE-CREATED, dropping
                                // its State - which is how an expanded reasoning
                                // trace collapsed the moment new content streamed
                                // in while the user was reading it. This callback
                                // maps a row's key back to its CURRENT slot so the
                                // element is re-used in place.
                                findChildIndexCallback: (key) =>
                                    _rowIndexFor(key, messages.length),
                                itemBuilder: (context, i) {
                                  final count = messages.length;
                                  final v = count - 1 - i;
                                  _topBuiltAssign(i, count);
                                  // Stable per-MESSAGE keys. The list itemCount
                                  // changes constantly (streaming appends, the
                                  // trailing status row appearing/disappearing)
                                  // and the divider/time-pill can re-wrap a row
                                  // between builds; without keys the framework
                                  // matches children by INDEX, so every append
                                  // shifts which element renders which message
                                  // (losing per-bubble state and churning the
                                  // subtrees). Keying on the chronological index
                                  // keeps element identity attached to the
                                  // message itself.
                                  // Pass a SNAPSHOT (frozen revision), not
                                  // the live message: the row's build gate
                                  // compares the widget it last built against
                                  // the incoming one. Two live instances of
                                  // the same message would always compare
                                  // "equal" (both read the same current
                                  // revision) and a changed row would never
                                  // rebuild; the snapshot is stable until the
                                  // message's revision actually moves.
                                  final msg = MessageBubble(
                                    message: messages[v].copy(),
                                    isUser: messages[v].role == 'user',
                                  );
                                  // Modern time-category break: a centered pill
                                  // marks the start of each new time bucket
                                  // (Today / Yesterday / date). Rendered ABOVE the
                                  // first message of the bucket, so the list index
                                  // space stays message-indexed and the read
                                  // divider + top-of-viewport tracking are
                                  // untouched.
                                  final breakLabel =
                                      _timeBreakLabel(messages, v);
                                  // Order above the message: time pill (its
                                  // chronological position) first, then the
                                  // "you were here" divider, then the message.
                                  // SHAPE IS CONSTANT, and that is the point.
                                  //
                                  // This used to wrap the row in extra widgets
                                  // only while it was the divider row or the
                                  // first of a time bucket, so the wrapper
                                  // APPEARED and DISAPPEARED as the divider
                                  // moved - and the divider moves both as the
                                  // reader scrolls and as content streams in.
                                  // Changing the nesting re-creates that row's
                                  // element, and re-creating an element drops
                                  // its State: an expanded reasoning trace
                                  // silently COLLAPSED while the user was
                                  // reading it. Fixed slots keep the child count
                                  // and the nesting constant, so `msg` is
                                  // updated in place and keeps its state.
                                  // `stretch` gives the children the same full
                                  // width the bare row used to receive.
                                  final dividerSlot = v == dividerIndex
                                      ? const _ReadDivider()
                                      : const SizedBox.shrink();
                                  final pillSlot = breakLabel == null
                                      ? const SizedBox.shrink()
                                      : _TimeBreakPill(label: breakLabel);
                                  // The KEY belongs on the widget the builder
                                  // RETURNS. A sliver matches children by the key
                                  // of that direct child (it is wrapped in a
                                  // salted KeyedSubtree), so a key buried inside
                                  // a wrapper is invisible to it: the rows then
                                  // have no identity to match on, every index
                                  // shift re-creates the whole visible list, and
                                  // the per-row State goes with it (a trace
                                  // collapsing while it is read). With the key
                                  // out here, `_rowIndexFor` maps the row to its
                                  // new slot and the element is re-used in place.
                                  return Column(
                                    key: ValueKey('$_rowKey$v'),
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [pillSlot, dividerSlot, msg],
                                  );
                                },
                              ),
                            ),
                            if (_showJumpArrow)
                              Positioned(
                                right: 14,
                                bottom: 14,
                                child: _JumpToLatestArrow(
                                  onPressed: () => _jumpToBottom(),
                                ),
                              ),
                          ],
                        ),
                ),
                if (req != null) _RequestCard(req: req, store: store),
                _GoalBar(store: store),
                _Composer(
                  controller: _input,
                  imagePicker: widget.imagePicker ?? _pickPhoneImage,
                  canSend: store.connection == GwConnectionState.open &&
                      !store.sendingAttachments,
                  streaming: store.streaming,
                  dirty: _composerDirty,
                  onSend: _send,
                  onInterrupt: () => unawaited(store.interrupt()),
                  store: store,
                ),
              ],
            );
          }),
    );
  }
}

class ConsumerStore extends StatefulWidget {
  const ConsumerStore({super.key, required this.store, required this.builder});
  final ChatStore store;
  final Widget Function(BuildContext, ChatStore) builder;

  @override
  State<ConsumerStore> createState() => _ConsumerStoreState();
}

class _ConsumerStoreState extends State<ConsumerStore> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.store.addListener(_on);
  }

  void _on() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.removeListener(_on);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.store);
}

class _ReadDivider extends StatelessWidget {
  const _ReadDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Container(height: 1, color: cs.primary.withValues(alpha: 0.55)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'you were here',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Container(height: 1, color: cs.primary.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}

class _TimeBreakPill extends StatelessWidget {
  const _TimeBreakPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Time-category break: a centered chip that clearly separates the
    // transcript into buckets (Today / Yesterday / date). It uses the theme's
    // primary (caduceus-gold) accent on a raised surface step so it reads as
    // intentional structure with real contrast — not a faint gray smudge.
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 13, color: cs.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JumpToLatestArrow extends StatelessWidget {
  const _JumpToLatestArrow({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.primaryContainer,
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.arrow_downward,
              color: cs.onPrimaryContainer, size: 22),
        ),
      ),
    );
  }
}

class _ModelQuickConfigSheet extends StatefulWidget {
  const _ModelQuickConfigSheet({required this.store});

  final ChatStore store;

  @override
  State<_ModelQuickConfigSheet> createState() =>
      _ModelQuickConfigSheetState();
}

class _ModelQuickConfigSheetState extends State<_ModelQuickConfigSheet> {
  ChatStore get store => widget.store;
  String? _flashMsg;
  Timer? _flashTimer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    _flashTimer?.cancel();
    super.dispose();
  }

  void _showFlash(String msg) {
    _flashTimer?.cancel();
    setState(() => _flashMsg = msg);
    _flashTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _flashMsg = null);
    });
  }

  /// Tapping Thinking off sends effort 'none'; turning it back on restores
  /// the last non-off level (or the profile default).
  Future<void> _toggleThinking(bool on) async {
    final prev = store.reasoningEffort;
    final target = on
        ? (ChatStore.reasoningLevels.any((l) => l == prev)
            ? prev
            : ChatStore.defaultReasoningEffort)
        : 'none';
    _busy = true;
    final r = await store.setReasoning(target);
    if (!mounted) return;
    _busy = false;
    _showFlash(on ? 'Thinking on (${target})' : 'Thinking off');
    if (r != target && !r.startsWith('Thinking')) _showFlash(r);
  }

  Future<void> _setLevel(String level) async {
    _busy = true;
    final r = await store.setReasoning(level);
    if (!mounted) return;
    _busy = false;
    _showFlash(r == level ? 'Reasoning: $level' : r);
  }

  Future<void> _toggleFast(bool on) async {
    _busy = true;
    final r = await store.setFast(on);
    if (!mounted) return;
    _busy = false;
    _showFlash(r == (on ? 'fast' : 'normal') ? (on ? 'Fast on' : 'Fast off') : r);
  }

  Future<void> _toggleShowTraces(bool on) async {
    _busy = true;
    final r = await store.setReasoningDisplay(on);
    if (!mounted) return;
    _busy = false;
    _showFlash(r == (on ? 'show' : 'hide')
        ? (on ? 'Traces shown' : 'Traces hidden')
        : r);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final thinking = store.thinkingEnabled;
    final level = store.reasoningEffort;
    final levelActive =
        thinking && ChatStore.reasoningLevels.contains(level);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.smart_toy_outlined, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Model',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: mounted ? () => Navigator.of(context).pop() : null,
                  child: const Text('Done'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                store.currentModel.isNotEmpty ? store.currentModel : 'No model',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Text(
              'Model settings for this conversation. Changes apply from the '
              'next message.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Thinking',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                thinking
                    ? levelActive
                        ? level
                        : level
                    : 'off',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              value: thinking,
              onChanged: _busy ? null : _toggleThinking,
            ),
            // Reasoning level — meaningful only while thinking is on.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Opacity(
                opacity: thinking ? 1 : 0.4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reasoning level',
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final l in ChatStore.reasoningLevels)
                          ChoiceChip(
                            label: Text(l),
                            selected: levelActive && level == l,
                            onSelected: thinking && !_busy
                                ? (_) => _setLevel(l)
                                : null,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Fast',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Priority service tier',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              value: store.fastEnabled,
              onChanged: _busy ? null : _toggleFast,
            ),
            // Trace VISIBILITY — the gateway `reasoning` display switch.
            // Independent of whether the model thinks: hides/shows the
            // "Thinking…" sections in the transcript live, without deleting
            // anything.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Show thinking traces',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Reveal or collapse the reasoning blocks in the transcript',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              value: store.showReasoning,
              onChanged: _busy ? null : _toggleShowTraces,
            ),
            if (_flashMsg != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Text(
                  _flashMsg!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChatAppbar extends StatelessWidget {
  const _ChatAppbar({required this.store});
  final ChatStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final connected = store.connection == GwConnectionState.open;
    return SafeArea(
      bottom: false,
      child: Container(
        // 10 not 12: the title row carries three buttons, the model name, the
        // context readout and the status pill.
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.4))),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.menu_open),
              tooltip: 'Sessions',
              // Compact density: the title row also carries the model name and
              // the context readout, and default-density buttons overflowed a
              // 420dp phone by ~4px once the readout was added.
              visualDensity: VisualDensity.compact,
              onPressed: () => _showSessions(context, store),
            ),
            IconButton(
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: 'New conversation',
              visualDensity: VisualDensity.compact,
              onPressed: connected && !store.creatingSession
                  ? () => store.createSession()
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(store: store, configTransport: store.client.request),
                  ),
                );
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    store.activeSessionId == null ? 'New chat' : 'Hermes',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Tappable model label — opens the quick model-config popover
                  // (thinking on/off + reasoning level + fast). The full model
                  // picker and global config live in Settings.
                  InkWell(
                    onTap: () => _showModelQuickConfig(context, store),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              store.currentModel.isNotEmpty
                                  ? store.currentModel
                                  : _host(store),
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // Current context-window occupancy, right of the model
                          // name. Hidden until the gateway reports a real
                          // reading (it omits the field when the engine cannot
                          // measure occupancy), so it never shows a fake 0%.
                          if (store.contextLabel != null) ...[
                            const SizedBox(width: 6),
                            // Flexible + ellipsis: the title row also carries
                            // the menu/new/settings buttons and the status pill,
                            // so on a narrow phone the readout must be able to
                            // shrink instead of overflowing the row.
                            Flexible(
                              child: Tooltip(
                                // One compact reading fits here; the full
                                // breakdown of what is filling the window opens
                                // as a sheet, which is what turns a manual
                                // compaction into a decision instead of a guess.
                                message: (store.contextBreakdown?.hasData ??
                                        false)
                                    ? 'Tap for the context breakdown'
                                    : (store.contextUsage.description ?? ''),
                                child: InkWell(
                                  onTap: () => _showContextMeter(context),
                                  borderRadius: BorderRadius.circular(6),
                                  child: Text(
                                    store.contextLabel!,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontSize: 10,
                                      color: theme.colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.75),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(width: 2),
                          Icon(Icons.tune,
                              size: 13,
                              color:
                                  theme.colorScheme.onSurfaceVariant.withValues(
                                      alpha: 0.8)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Semantics(
              button: true,
              liveRegion: true,
              label: store.streaming
                  ? 'Working. Open connection details.'
                  : connected
                      ? 'Connected. Open connection details.'
                      : 'Offline. Open connection details.',
              child: InkWell(
                onTap: () => _showConnectionSheet(context, store),
                borderRadius: BorderRadius.circular(24),
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: !connected
                            ? cs.errorContainer
                            : store.streaming
                                ? cs.tertiaryContainer
                                : cs.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            store.streaming ? Icons.auto_awesome : Icons.circle,
                            size: 10,
                            color: !connected
                                ? cs.onErrorContainer
                                : store.streaming
                                    ? cs.onTertiaryContainer
                                    : cs.onPrimaryContainer,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            store.streaming
                                ? 'working'
                                : (connected ? 'connected' : 'offline'),
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: !connected
                                    ? cs.onErrorContainer
                                    : store.streaming
                                        ? cs.onTertiaryContainer
                                        : cs.onPrimaryContainer),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _host(ChatStore store) {
    final u = Uri.tryParse(store.config.baseUrl);
    return u == null ? store.config.url : u.host;
  }

  /// Quick model config: a bottom sheet that edits the SESSION's live model
  /// settings (thinking on/off = reasoning effort, the reasoning level, and
  /// fast mode) via the gateway's session-scoped `config.set`. No settings
  /// round-trip — it applies to the next turn immediately. Selecting WHICH
  /// model (and global config) stays in the full Settings screen.
  void _showModelQuickConfig(BuildContext context, ChatStore store) {
    if (store.connection != GwConnectionState.open) {
      _snack(context, 'Connect to the gateway first');
      return;
    }
    store.loadModelConfig(); // best-effort read; the sheet live-binds anyway
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: false,
      builder: (sheetContext) => _ModelQuickConfigSheet(store: store),
    );
  }

  /// The app bar carries one compact reading; the meter explains what is
  /// filling the window, category by category, against the model's window.
  Future<void> _showContextMeter(BuildContext context) async {
    // Fetched on open so the numbers are live, and only when asked for.
    final breakdown = await store.loadContextBreakdown();
    if (!context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: false,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: !breakdown.hasData
            ? Text(
                'No context breakdown reported by the gateway yet.',
                style: Theme.of(context).textTheme.bodyMedium,
              )
            : ContextMeter(breakdown: breakdown),
      ),
    );
  }

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  void _showSessions(BuildContext context, ChatStore store) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionsSheet(store: store),
      ),
    );
  }

  void _showConnectionSheet(BuildContext context, ChatStore store) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final host = _host(store);

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: store,
        builder: (sheetContext, _) {
          final connected = store.connection == GwConnectionState.open;
          final model = store.currentModel;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Connection status
                  Row(
                    children: [
                      Icon(
                        connected ? Icons.check_circle : Icons.error_outline,
                        color: connected ? cs.primary : cs.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        connected ? 'Connected' : 'Disconnected',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Gateway info
                  if (host.isNotEmpty) ...[
                    Text('Gateway',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(host, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 8),
                  ],
                  if (model.isNotEmpty) ...[
                    Text('Model',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(model, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 16),
                  ],
                  // Actions
                  if (!connected)
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        store.connect();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reconnect'),
                    ),
                  if (connected)
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        store.disconnect();
                      },
                      icon: const Icon(Icons.link_off),
                      label: const Text('Disconnect'),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SettingsScreen(store: store, configTransport: store.client.request),
                        ),
                      );
                    },
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Settings'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                    onPressed: () async {
                      Navigator.of(sheetContext).pop();
                      await store.disconnect();
                      if (context.mounted) {
                        SystemNavigator.pop();
                      }
                    },
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Quit Talaria'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Shown while an existing conversation's transcript is still on its way from
/// the gateway.
///
/// Without this the view falls back to [_EmptyState] while the history loads,
/// which reads as "this is a new conversation" and makes a long conversation
/// look as though it, and everything else, had disappeared. The conversation's
/// own title is shown whenever the store already knows it, so the user can see
/// which conversation is opening rather than guessing.
class _LoadingConversation extends StatelessWidget {
  const _LoadingConversation({required this.store});
  final ChatStore store;

  String? get _title {
    final id = store.activeStoredSessionId;
    if (id == null || id.isEmpty) return null;
    for (final s in store.sessions) {
      if (s.id == id && s.title.trim().isNotEmpty) return s.title.trim();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final title = _title;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 20),
            Text('Loading conversation…',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              title == null
                  ? 'Fetching the history from your gateway.'
                  : 'Fetching “$title” from your gateway.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.store});
  final ChatStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum,
                size: 56,
                color: theme.colorScheme.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text('Ask Hermes anything',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Start a new chat or open a past session from the menu.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Empty result for the roster filter. Always paired with the search field
/// above it (which is rendered outside the list) plus a way back to the full
/// list, so a typo cannot strand the user on an empty screen.
class _NoConversationMatches extends StatelessWidget {
  const _NoConversationMatches({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 32, color: muted.withValues(alpha: 0.7)),
            const SizedBox(height: 10),
            Text('No conversations match “$query”.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
            const SizedBox(height: 4),
            Text('Titles and previews are searched.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Clear search'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A persistent, long-horizon status bar for the active session's GOAL.
///
/// A `/goal <text>` goal survives many turns, so — unlike the transient turn
/// status row (which vanishes when a turn ends) — the goal is shown in a
/// sticky bar pinned above the composer. The store reads its live state via
/// the read-only `slash.exec {command: 'goal status'}` RPC (see
/// [ChatStore.refreshGoal]) and stores it in [ChatStore.activeGoal]; this
/// widget renders it. It disappears entirely when there is no goal. Mirrors
/// the Hermes desktop's composer goal indicator.
class _GoalBar extends StatelessWidget {
  const _GoalBar({required this.store});
  final ChatStore store;

  @override
  Widget build(BuildContext context) {
    final goal = store.activeGoal;
    if (goal == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // State-driven accent + glyph. Active = primary (working), waiting =
    // amber (parked), paused = grey (held), done = green (achieved).
    final (IconData icon, Color accent, String label) = switch (goal.status) {
      'active' => (Icons.flag_rounded, cs.primary, 'Goal'),
      'waiting' => (Icons.hourglass_top_rounded, cs.tertiary, 'Goal — waiting'),
      'paused' => (Icons.pause_circle_outline_rounded, cs.onSurfaceVariant, 'Goal — paused'),
      'done' => (Icons.check_circle_rounded,
          cs.brightness == Brightness.dark
              ? const Color(0xFF4ADE80)
              : const Color(0xFF16A34A),
          'Goal — done'),
      _ => (Icons.flag_rounded, cs.primary, 'Goal'),
    };

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: accent, fontWeight: FontWeight.w700),
                    ),
                    if (goal.detail != null && goal.detail!.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          goal.detail!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  goal.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface, height: 1.3),
                ),
              ],
            ),
          ),
          // Explicit dismiss: sends `/goal clear` to the gateway (the
          // authoritative action — the gateway keeps a finished goal around
          // until it's cleared, so this is what actually makes it go away).
          // It runs immediately (dispatch) even mid-turn, and the bar drops
          // optimistically so the tap responds instantly.
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 1),
            child: IconButton(
              tooltip: 'Clear goal',
              onPressed: () => unawaited(store.dismissGoal()),
              icon: Icon(Icons.close_rounded,
                  size: 18, color: cs.onSurfaceVariant),
              splashRadius: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatefulWidget {
  const _RequestCard({required this.req, required this.store});
  final dynamic req;
  final ChatStore store;

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  /// Answer fields for OPEN-ENDED batch questions, keyed by question id.
  final Map<String, TextEditingController> _free = {};

  /// Friendly labels for the approval choices the gateway advertises
  /// (`_approval_request_payload`: once / session / always / deny).
  static const Map<String, String> _approvalLabels = {
    'once': 'Allow once',
    'session': 'Allow this session',
    'always': 'Always allow',
    'deny': 'Deny',
  };

  @override
  void dispose() {
    for (final c in _free.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctlFor(String qid) =>
      _free.putIfAbsent(qid, TextEditingController.new);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = widget.store;
    final req = widget.req;
    final isApproval = req.type == 'approval.request';
    final payload = (req.payload as Map).cast<String, dynamic>();
    // The gateway emits TWO clarify shapes (see `_clarify_block`): a single
    // question (`{question, choices}`) and a BATCH form
    // (`{questions: [{qid, question, choices, multi_select}]}`). Rendering only
    // the first is what produced a card whose text fell back to "Hermes needs
    // your input" with a lone "No" button and no way to answer.
    final batch = payload['questions'];
    final isBatch = batch is List && batch.isNotEmpty;
    final hasRequestId = (payload['request_id'] ?? '').toString().isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isApproval ? Icons.verified_user : Icons.help_outline,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    isApproval ? 'Approval requested' : 'Hermes is asking',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(store.dismissPendingRequest()),
                icon: Icon(Icons.close_rounded,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          if (isBatch)
            ..._batchQuestions(theme, store, batch)
          else
            ..._singleQuestion(theme, store, isApproval, payload),
          if (!hasRequestId)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'This prompt arrived without a request id, so it cannot be answered. Dismiss it to clear the card.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  /// One question with its choices (or the plain fallback when the payload
  /// advertises none). When the gateway DOES advertise choices they are the
  /// whole answer surface: approval choices already include "deny", so adding
  /// a generic Deny button next to them would render the same word twice.
  List<Widget> _singleQuestion(ThemeData theme, ChatStore store,
      bool isApproval, Map<String, dynamic> payload) {
    final question =
        (payload['question'] ?? payload['command'] ?? 'Hermes needs your input')
            .toString();
    final choices = payload['choices'];
    if (choices is List && choices.isNotEmpty) {
      return [
        const SizedBox(height: 8),
        Text(question, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in choices)
              ChoiceChip(
                label: Text(isApproval
                    ? (_approvalLabels[c.toString()] ?? c.toString())
                    : c.toString()),
                selected: false,
                onSelected: (_) => unawaited(
                    store.respondApproval(approved: true, choice: c.toString())),
              ),
          ],
        ),
      ];
    }
    return [
      const SizedBox(height: 8),
      Text(question, style: theme.textTheme.bodyMedium),
      const SizedBox(height: 12),
      Row(
        children: [
          if (isApproval) ...[
            FilledButton.tonal(
              onPressed: () => unawaited(store.respondApproval(approved: true)),
              child: const Text('Approve'),
            ),
            const SizedBox(width: 8),
          ],
          OutlinedButton(
            onPressed: () => unawaited(store.respondApproval(approved: false)),
            child: Text(isApproval ? 'Deny' : 'No'),
          ),
        ],
      ),
    ];
  }

  /// Every question of a batch form, each answered on its own (the gateway
  /// locks answers per `question_id` and resolves once the last one is in).
  List<Widget> _batchQuestions(
      ThemeData theme, ChatStore store, List questions) {
    final answered = store.clarifyAnswers;
    final widgets = <Widget>[];
    for (final raw in questions) {
      if (raw is! Map) continue;
      final q = raw.cast<String, dynamic>();
      final qid = (q['qid'] ?? '').toString();
      final done = qid.isNotEmpty && answered.containsKey(qid);
      widgets.add(const SizedBox(height: 10));
      widgets.add(Text(
        done ? '\u2713 ${q['question']}' : (q['question'] ?? '').toString(),
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
          color: done ? theme.colorScheme.onSurfaceVariant : null,
        ),
      ));
      final choices = q['choices'];
      if (choices is List && choices.isNotEmpty) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in choices)
                ChoiceChip(
                  label: Text(c.toString()),
                  selected: answered[qid] == c.toString(),
                  onSelected: (_) => unawaited(store.respondApproval(
                      approved: true, choice: c.toString(), questionId: qid)),
                ),
            ],
          ),
        ));
      } else {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctlFor(qid),
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: done ? answered[qid] : 'Type your answer',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () {
                  final text = _ctlFor(qid).text.trim();
                  if (text.isEmpty) return;
                  unawaited(store.respondApproval(
                      approved: true, choice: text, questionId: qid));
                },
                child: const Text('Send'),
              ),
            ],
          ),
        ));
      }
    }
    widgets.add(const SizedBox(height: 8));
    widgets.add(Text(
      'Answer every question. The card clears when the last answer is sent.',
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    ));
    return widgets;
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onInterrupt,
    required this.streaming,
    required this.dirty,
    required this.canSend,
    required this.imagePicker,
    required this.store,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onInterrupt;
  final bool streaming;
  final bool dirty;
  final bool canSend;
  final PhoneImagePicker imagePicker;
  final ChatStore store;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  ChatStore get store => widget.store;
  List<Map<String, dynamic>> _slashItems = [];
  int _slashReplaceFrom = 0;
  bool _slashActive = false;
  Timer? _slashDebounce;
  int _slashGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    _slashDebounce?.cancel();
    super.dispose();
  }

  void _onText() {
    final t = widget.controller.text;
    final pos = widget.controller.selection.baseOffset;
    // A slash token is active when the token under the cursor starts with '/'.
    final before = t.substring(0, pos.clamp(0, t.length));
    final tokenStart = before.lastIndexOf(' ');
    final token = before.substring(tokenStart + 1);
    if (token.startsWith('/') && !token.contains(' ')) {
      _scheduleSlash(token);
    } else {
      _clearSlash();
    }
  }

  void _clearSlash() {
    _slashDebounce?.cancel();
    if (_slashActive) setState(() => _slashActive = false);
    _slashItems = [];
  }

  void _scheduleSlash(String token) {
    _slashDebounce?.cancel();
    final gen = ++_slashGeneration;
    _slashDebounce = Timer(const Duration(milliseconds: 180), () async {
      final res = await store.completeSlash(token);
      if (gen != _slashGeneration || !mounted) return;
      final items = res['items'];
      if (items is List && items.isNotEmpty) {
        final list = items
            .whereType<Map<String, dynamic>>()
            .take(8)
            .toList(growable: false);
        setState(() {
          _slashItems = list;
          _slashReplaceFrom =
              (res['replace_from'] is int ? res['replace_from'] as int : 1);
          _slashActive = true;
        });
      } else {
        _clearSlash();
      }
    });
  }

  void _acceptSlash(Map<String, dynamic> item) {
    final c = widget.controller;
    final full = item['text']?.toString() ?? '';
    if (full.isEmpty) return;
    final text = c.text;
    final pos = c.selection.baseOffset.clamp(0, text.length);
    final tokenStart = _slashReplaceFrom <= pos ? _slashReplaceFrom : 0;
    final next = '${text.substring(0, tokenStart)}$full ${text.substring(pos)}';
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
          offset: (tokenStart + full.length + 1).clamp(0, next.length)),
    );
    _clearSlash();
  }

  bool _pickingImage = false;

  Future<void> _attachImage(ImageSource source) async {
    if (_pickingImage) return;
    setState(() => _pickingImage = true);
    final target = store;
    final session = target.activeSessionId;
    try {
      final file = await widget.imagePicker(source);
      if (file == null) return;
      // Check before reading so a huge original is never loaded just to reject it.
      if (await file.length() > ImageAttachmentService.maxBytes) {
        throw GatewayError('Image is too large. The gateway limit is 25 MiB.');
      }
      final bytes = await file.readAsBytes();
      if (!mounted || target != store || session != target.activeSessionId) return;
      target.queueImage(bytes, filename: file.name.isEmpty ? 'image.png' : file.name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e is GatewayError ? e.message : 'Could not pick photo: $e'),
        ));
      }
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  Future<void> _attachFile() async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return;
    final f = files.first;
    final bytes = await f.readAsBytes();
    final name = f.name.isEmpty ? 'file' : f.name;
    await store.attachFileBytes(bytes, name: name);
  }

  Future<void> _toggleVoice() async {
    await store.toggleVoice();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConsumerStore(
      store: store,
      builder: (context, store) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QueuedPromptStrip(
              prompts: store.queuedPrompts,
              editingId: store.editingQueuedId,
              onToggleEdit: (q) {
                if (store.editingQueuedId == q.id) {
                  store.cancelQueuedEdit();
                  widget.controller.clear();
                } else {
                  // Load it into the composer: sending then UPDATES this entry
                  // rather than starting a turn (see ChatStore.send).
                  store.beginQueuedEdit(q.id);
                  widget.controller.text = q.text;
                  widget.controller.selection =
                      TextSelection.collapsed(offset: q.text.length);
                }
              },
              onRemove: (id) {
                if (store.editingQueuedId == id) {
                  store.cancelQueuedEdit();
                  widget.controller.clear();
                }
                store.removeQueuedPrompt(id);
              },
              onSendNow: (id) {
                if (store.editingQueuedId == id) {
                  store.cancelQueuedEdit();
                  widget.controller.clear();
                }
                unawaited(store.sendQueuedPromptNow(id));
              },
            ),
            AttachmentStrip(
              attachments: store.attachmentDetails,
              enabled: !store.sendingAttachments,
              onRemove: (ref) => unawaited(store.detachAttachment(ref)),
            ),
            if (_slashActive)
              _SlashMenu(
                items: _slashItems,
                onPick: _acceptSlash,
                onDismiss: _clearSlash,
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Attach image',
                          icon: const Icon(Icons.image_outlined),
                          onPressed: _pickingImage || store.sendingAttachments
                              ? null : () => _attachImage(ImageSource.gallery),
                        ),
                        IconButton(
                          tooltip: 'Take photo',
                          icon: const Icon(Icons.camera_alt_outlined),
                          onPressed: _pickingImage || store.sendingAttachments
                              ? null : () => _attachImage(ImageSource.camera),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Attach file',
                      icon: const Icon(Icons.attach_file),
                      onPressed: store.sendingAttachments ? null : _attachFile,
                    ),
                    IconButton(
                      tooltip:
                          store.voiceOn ? 'Voice off' : 'Voice (push-to-talk)',
                      icon: Icon(store.voiceOn ? Icons.mic : Icons.mic_none),
                      color: store.voiceOn ? theme.colorScheme.primary : null,
                      onPressed: _toggleVoice,
                    ),
                    Expanded(
                      // The input has a FIXED height: it never resizes the
                      // composer. A variable-height field (minLines 1→5) used to
                      // grow/shrink as you scrolled a multi-line selection,
                      // which changed the transcript's viewport height and
                      // re-fired the jump-to-bottom — the jarring "thrash" while
                      // selecting. Now the field is a constant size and scrolls
                      // its own content internally when it exceeds it.
                      child: SizedBox(
                        height: 96,
                        child: TextField(
                          controller: widget.controller,
                          minLines: 1,
                          maxLines: null,
                          textCapitalization: TextCapitalization.sentences,
                          style: theme.textTheme.bodyLarge,
                          decoration: InputDecoration(
                            hintText: 'Message Hermes…  ( / for commands )',
                            isDense: true,
                            filled: true,
                            fillColor:
                                theme.colorScheme.surfaceContainerHighest,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide(
                                  color: theme.colorScheme.primary, width: 2),
                            ),
                          ),
                          onSubmitted: (_) => widget.onSend(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Send is ALWAYS available while connected — including
                    // mid-turn. The gateway busy-queues a send made during a
                    // running turn (prompt.submit → status "queued" /
                    // "steered"), so typing "focus on X" or `/queue …` while
                    // Hermes is working influences the current run, exactly
                    // like the desktop. Stop is a companion control, not a
                    // replacement for Send.
                    IconButton.filledTonal(
                      onPressed: widget.canSend &&
                              (widget.dirty ||
                                  store.pendingAttachments.isNotEmpty)
                          ? widget.onSend
                          : null,
                      tooltip: widget.streaming
                          ? 'Send (queued after the current turn)'
                          : 'Send',
                      icon: const Icon(Icons.arrow_upward_rounded),
                      style: (widget.canSend &&
                              (widget.dirty ||
                                  store.pendingAttachments.isNotEmpty))
                          ? IconButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.onPrimary,
                            )
                          : null,
                    ),
                    if (widget.streaming) ...[
                      const SizedBox(width: 4),
                      IconButton.filledTonal(
                        onPressed: widget.onInterrupt,
                        tooltip: 'Stop current turn',
                        icon: const Icon(Icons.stop_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.errorContainer,
                          foregroundColor: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Overlay row of slash-command completions above the composer.
class _SlashMenu extends StatelessWidget {
  const _SlashMenu({
    required this.items,
    required this.onPick,
    required this.onDismiss,
  });
  final List<Map<String, dynamic>> items;
  final void Function(Map<String, dynamic>) onPick;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        elevation: 3,
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in items)
                ListTile(
                  minTileHeight: 48,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  leading: Icon(Icons.terminal,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  title: Text(
                    (item['text'] ?? '').toString(),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: (item['meta'] ?? '').toString().isNotEmpty
                      ? Text(
                          (item['meta'] as String).length > 64
                              ? '${(item['meta'] as String).substring(0, 64)}…'
                              : item['meta'].toString(),
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis)
                      : null,
                  onTap: () => onPick(item),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Minimal marquee: scrolls long status lines.
class MarqueeText extends StatefulWidget {
  const MarqueeText({super.key, required this.text});
  final String text;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _offset;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 12))
      ..repeat();
    _offset = Tween<double>(begin: 0, end: -1).animate(_c);
  }

  @override
  void didUpdateWidget(covariant MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect the OS reduced-motion setting: don't run the 12s scroll loop.
    if (MediaQuery.maybeOf(context)?.disableAnimations == true) {
      return Text(widget.text, overflow: TextOverflow.ellipsis);
    }
    if (widget.text.length <= 60)
      return Text(widget.text, overflow: TextOverflow.ellipsis);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final d = _offset.value;
        return OverflowBox(
          maxWidth: double.infinity,
          alignment: Alignment.centerLeft,
          child: FractionalTranslation(
            translation: Offset(d, 0),
            child: Text(widget.text),
          ),
        );
      },
    );
  }
}

/// Small status dot for a session row, colored like the desktop sidebar:
///   - `working`     → filled accent (the turn is running)
///   - `needs-input` → filled amber (a clarify/approval is blocking — the
///                     only state that demands a response)
///   - anything else → faint outline (idle / no live turn)
class _SessionDot extends StatelessWidget {
  const _SessionDot({required this.state});
  final String state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color color;
    final bool filled;
    switch (state) {
      case 'needs-input':
        color = const Color(0xFFE0A800); // amber
        filled = true;
      case 'working':
        color = cs.primary;
        filled = true;
      default:
        color = cs.outlineVariant;
        filled = false;
    }
    return Semantics(
      label: state == 'working'
          ? 'Working'
          : state == 'needs-input'
              ? 'Needs input'
              : 'Idle',
      child: Container(
        width: state == 'idle' ? 7 : 9,
        height: state == 'idle' ? 7 : 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? color : Colors.transparent,
          border: filled ? null : Border.all(color: color, width: 1),
        ),
      ),
    );
  }
}

/// Sessions full-screen sheet: the conversation roster with per-row status
/// dots, rename/hide/compress/move/delete actions, and a new-chat button.
class SessionsSheet extends StatefulWidget {
  const SessionsSheet({super.key, required this.store});
  final ChatStore store;

  @override
  State<SessionsSheet> createState() => _SessionsSheetState();
}

class _SessionsSheetState extends State<SessionsSheet> {
  ChatStore get store => widget.store;

  /// Persisted pinned-set key, scoped to the gateway host so a different
  /// gateway keeps its own pins (same pattern as the model-picker bookmarks).
  static const _pinsPfx = 'talaria.pins.';
  String get _pinsKey {
    final host =
        Uri.tryParse(store.config.baseUrl)?.host ?? store.config.baseUrl.trim();
    return '$_pinsPfx$host';
  }

  @override
  void initState() {
    super.initState();
    _loadPins();
    _search.addListener(_onSearch);
  }

  /// Roster filter. Matches the title AND the preview: the gateway's titles are
  /// often auto-generated, so the preview is usually what someone actually
  /// remembers about an old conversation.
  final _search = TextEditingController();
  String _query = '';

  void _onSearch() {
    final q = _search.text.trim();
    if (q != _query) setState(() => _query = q);
  }

  List<SessionRow> _filtered(List<SessionRow> all) {
    final q = _query.toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((s) =>
            s.title.toLowerCase().contains(q) ||
            s.preview.toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  void dispose() {
    _search.removeListener(_onSearch);
    _search.dispose();
    super.dispose();
  }

  /// Hydrate the store's in-memory pinned set from prefs. Best-effort: a
  /// missing/corrupt pref file simply yields an unpinned list.
  Future<void> _loadPins() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_pinsKey) ?? const <String>[];
      store.applyPinned(ids, clear: true);
    } catch (_) {
      // Leave the set empty on failure.
    }
  }

  /// Persist the current pinned set to prefs (fire-and-forget).
  Future<void> _savePins() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pinsKey, store.pinnedIds.toList());
    } catch (_) {
      // In-memory set remains the source of truth.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConsumerStore(
      store: store,
      builder: (context, store) {
        final empty = store.sessions.isEmpty;
        final matches = _filtered(store.sessions);
        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          appBar: AppBar(
            title: const Text('Conversations'),
            actions: [
              IconButton(
                icon: const Icon(Icons.add_comment),
                tooltip: 'New chat',
                onPressed: () {
                  store.createSession();
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
          body: empty
              ? const Center(child: Text('No conversations yet.'))
              : Column(
                  children: [
                    // The search field sits OUTSIDE the list, so it survives an
                    // empty result. A filter that removes the control you need
                    // to undo the filter is a dead end (see the model picker).
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                      child: TextField(
                        controller: _search,
                        minLines: 1,
                        maxLines: 1,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search conversations…',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  tooltip: 'Clear search',
                                  onPressed: _search.clear,
                                ),
                          isDense: true,
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerHighest,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: matches.isEmpty
                          ? _NoConversationMatches(
                              query: _query, onClear: _search.clear)
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                              children: [
                                for (final seg
                                    in store.segmentedSessions(matches))
                                  ...[
                                    // Section header. The pinned group gets a
                                    // distinct "Pinned" header with a pin
                                    // glyph; time groups get their bucket label
                                    // (Today / Yesterday / …).
                                    _SectionHeader(
                                      label: seg.label.isEmpty
                                          ? 'Pinned'
                                          : seg.label,
                                      pinned: seg.label.isEmpty,
                                    ),
                                    for (final s in seg.rows)
                                      _buildTile(context, s),
                                  ],
                              ],
                            ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildTile(BuildContext context, SessionRow s) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // The roster is the STORED-session list (session.list ids are session
    // keys), so the active-row identity is the stored id — NOT the runtime
    // session sid, which only matches after a resume binds it. A fresh draft
    // has no stored id and correctly matches no row.
    final active = s.id == store.activeStoredSessionId;
    final pinned = store.isPinned(s.id);
    return ListTile(
      key: ValueKey('conv_${s.id}'),
      selected: active,
      selectedTileColor: cs.primaryContainer.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: pinned
          ? Icon(Icons.push_pin,
              size: 20, color: cs.primary)
          : Icon(
              active ? Icons.chat_bubble : Icons.chat_bubble_outline,
              size: 20,
              color:
                  active ? cs.primary : cs.onSurfaceVariant,
            ),
      title: Row(
        children: [
          // Per-conversation status dot — accent while a turn is running,
          // amber when a clarify/approval is blocking (the only "act now"
          // state), a faint dot when idle. The ACTIVE row uses the store's
          // live state; other rows use the last gateway-reported status.
          _SessionDot(
            state: active
                ? store.activeSessionState
                : store.sessionDotState(s.id),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                s.title.isEmpty ? 'Untitled' : s.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
          ),
        ],
      ),
      subtitle: Text(
          s.preview.isEmpty ? _ts(s.startedAt) : s.preview,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall),
      trailing: PopupMenuButton<String>(
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'pin',
            child: Row(children: [
              Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin, size: 20),
              const SizedBox(width: 12),
              Text(pinned ? 'Unpin' : 'Pin to top'),
            ]),
          ),
          const PopupMenuItem(
            value: 'rename',
            child: Row(children: [
              Icon(Icons.edit_outlined, size: 20),
              SizedBox(width: 12),
              Text('Rename'),
            ]),
          ),
          PopupMenuItem(
            value: 'hide',
            child: Row(children: [
              Icon(Icons.visibility_off_outlined,
                  size: 20, color: cs.error),
              const SizedBox(width: 12),
              Text('Hide from list',
                  style: TextStyle(color: cs.error)),
            ]),
          ),
          const PopupMenuItem(
            value: 'compress',
            child: Row(children: [
              Icon(Icons.compress, size: 20),
              SizedBox(width: 12),
              Text('Compress context'),
            ]),
          ),
          const PopupMenuItem(
            value: 'move',
            child: Row(children: [
              Icon(Icons.drive_file_move_outlined, size: 20),
              SizedBox(width: 12),
              Text('Move workspace'),
            ]),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(children: [
              Icon(Icons.delete_outline,
                  size: 20, color: cs.error),
              const SizedBox(width: 12),
              Text('Delete', style: TextStyle(color: cs.error)),
            ]),
          ),
        ],
        onSelected: (v) async {
          switch (v) {
            case 'pin':
              final nowPinned = store.togglePin(s.id);
              await _savePins();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(nowPinned
                        ? 'Pinned to top'
                        : 'Unpinned')));
              }
            case 'rename':
              final title = await _promptTitle(context, s.title);
              if (title != null && title.trim().isNotEmpty) {
                await store.setTitle(s.id, title.trim());
              }
            case 'hide':
              await store.setHidden(s.id, true);
            case 'compress':
              final r = await store.compressSession(storedId: s.id);
              if (r != null && context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(r)));
              }
            case 'move':
              final cwd = await _promptCwd(context, s.id);
              if (cwd != null && cwd.trim().isNotEmpty) {
                final r = await store.moveWorkspace(s.id, cwd.trim());
                if (r != null && context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(r)));
                }
              }
            case 'delete':
              final confirmed = await _confirmDelete(context, s.title);
              if (confirmed != true) break;
              final ok = await store.deleteSession(s.id);
              // A deleted conversation can't stay pinned; persist the cleanup
              // so a re-open doesn't resurrect a phantom pin.
              if (ok && store.isPinned(s.id)) {
                store.togglePin(s.id);
                await _savePins();
              }
              // A delete that silently does nothing is the old bug — always
              // tell the user what happened.
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(ok
                        ? 'Conversation deleted'
                        : (store.statusLine.isEmpty
                            ? 'Could not delete conversation'
                            : store.statusLine))));
              }
          }
        },
      ),
      onTap: () {
        store.resumeSession(s.id);
        Navigator.of(context).pop();
      },
    );
  }

  String _ts(double t) {
    if (t == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Confirm an irreversible conversation delete before it runs. Returns
  /// true only when the user confirms (null/cancel means abort).
  Future<bool?> _confirmDelete(BuildContext context, String title) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text(
            title.trim().isEmpty
                ? 'This conversation and its transcript will be deleted. This cannot be undone.'
                : '"$title" and its transcript will be deleted. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    return result;
  }

  Future<String?> _promptTitle(BuildContext context, String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _promptCwd(BuildContext context, String id) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move workspace'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration:
              const InputDecoration(hintText: '/absolute/path/to/project'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Move')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

/// Section header for the segmented conversations list. Pinned groups render
/// in the accent (gold) color with a pin glyph; time groups render as
/// high-contrast full-ink labels so they stand out against the list background.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.pinned = false});

  final String label;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Pinned = gold accent (the one highlighted group). Time buckets = full
    // surface ink (not the muted onSurfaceVariant), which gives real contrast
    // against the list background without competing with the gold highlight.
    final color = pinned ? cs.primary : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
      child: Row(
        children: [
          if (pinned) ...[
            Icon(Icons.push_pin, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          // Both children are TIGHT Expanded, so the label always ellipsizes
          // to its share and the divider fills the rest — this combination
          // can never overflow on a narrow width.
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 1,
              color: cs.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}
