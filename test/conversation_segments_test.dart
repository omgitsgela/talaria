import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Segmented + pinnable conversations list (2026-09-11):
///   1. store: pin toggle/isPinned/pinnedIds/applyPinned (pure set logic)
///   2. store: segmentedSessions — pinned group first, then time buckets
///      (Today / Yesterday / This week / This month / Older), each in the
///      gateway's most-recent-first order
///   3. widget: the sheet renders a "Pinned" section header and a time-bucket
///      header, and pinning moves a row into the pinned section
final _cfg = GatewayConfig(url: 'http://localhost:1');

class PinGateway extends GatewayClient {
  PinGateway() : super(_cfg);
  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => const Stream.empty();
  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();
  @override
  Future<void> connect({bool isReconnect = false}) async {}
  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async =>
      const <String, dynamic>{};
}

/// unix-seconds "N days ago at [hour]".
double _daysAgoAt(int days, int hour) {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day, hour.clamp(0, 23))
      .subtract(Duration(days: days));
  return d.millisecondsSinceEpoch / 1000;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ChatStore fresh() => ChatStore(config: _cfg, client: PinGateway());

  // ── 1. Pin set logic (pure) ──────────────────────────────────────

  test('togglePin flips membership and reports the new state', () {
    final store = fresh();
    addTearDown(store.dispose);
    expect(store.isPinned('a'), isFalse);
    expect(store.togglePin('a'), isTrue);
    expect(store.isPinned('a'), isTrue);
    expect(store.togglePin('a'), isFalse);
    expect(store.isPinned('a'), isFalse);
  });

  test('pinnedIds reflects the pinned set', () {
    final store = fresh();
    addTearDown(store.dispose);
    store.togglePin('x');
    expect(store.pinnedIds, {'x'});
    // A fresh store has no pins.
    final empty = fresh();
    addTearDown(empty.dispose);
    expect(empty.pinnedIds, isEmpty);
  });

  test('applyPinned replaces the set (clear=true) and merges without clear',
      () {
    final store = fresh();
    addTearDown(store.dispose);
    store.togglePin('a');
    store.applyPinned(['b', 'c'], clear: true);
    expect(store.pinnedIds, {'b', 'c'},
        reason: 'clear=true must replace, not merge');
    store.applyPinned(['d']);
    expect(store.pinnedIds, {'b', 'c', 'd'},
        reason: 'without clear it merges');
  });

  // ── 2. Segmentation (pure) ───────────────────────────────────────

  test('segmentedSessions puts pinned first, then time buckets in order',
      () {
    final store = fresh();
    addTearDown(store.dispose);
    // Five conversations across four buckets. The 'this-month' one is pinned,
    // so it must leave its time bucket and lead the list under Pinned.
    final rows = [
      SessionRow(id: 'today1', title: 'T1', startedAt: _daysAgoAt(0, 9)),
      SessionRow(id: 'today2', title: 'T2', startedAt: _daysAgoAt(0, 10)),
      SessionRow(id: 'yest', title: 'Y', startedAt: _daysAgoAt(1, 12)),
      SessionRow(id: 'week', title: 'W', startedAt: _daysAgoAt(4, 8)),
      SessionRow(id: 'month', title: 'M', startedAt: _daysAgoAt(20, 8)),
    ];
    store.togglePin('month'); // pin the 20-day-old one

    final segs = store.segmentedSessions(rows);
    expect(segs.length, 4,
        reason: 'Pinned + Today + Yesterday + This week (This month drained)');

    // First segment is the pinned group, and it holds ONLY the pinned row.
    expect(segs.first.label, '', reason: 'the pinned group has an empty label');
    expect(segs.first.rows.map((r) => r.id), ['month']);

    // The remaining segments are the time buckets in newest-first order, each
    // preserving the gateway's (input) most-recent-first order.
    expect(segs[1].label, 'Today');
    expect(segs[1].rows.map((r) => r.id), ['today1', 'today2'],
        reason: 'two same-day rows, most-recent first as supplied');
    expect(segs[2].label, 'Yesterday');
    expect(segs[2].rows.map((r) => r.id), ['yest']);
    expect(segs[3].label, 'This week');
    expect(segs[3].rows.map((r) => r.id), ['week']);

    // The pinned row is NOT double-counted in a time bucket.
    expect(segs.expand((s) => s.rows).map((r) => r.id),
        {'month', 'today1', 'today2', 'yest', 'week'});
  });

  test('untimestamped rows fall into Older', () {
    final store = fresh();
    addTearDown(store.dispose);
    final rows = [
      SessionRow(id: 'unt', title: 'No time', startedAt: 0),
    ];
    final segs = store.segmentedSessions(rows);
    expect(segs.length, 1);
    expect(segs.single.label, 'Older');
    expect(segs.single.rows.map((r) => r.id), ['unt']);
  });

  test('an all-unpinned list has no pinned segment', () {
    final store = fresh();
    addTearDown(store.dispose);
    final rows = [SessionRow(id: 't', title: 'T', startedAt: _daysAgoAt(0, 9))];
    final segs = store.segmentedSessions(rows);
    expect(segs.first.label, 'Today',
        reason: 'no pins => the first segment is a time bucket');
  });

  // ── 3. Widget: segmented + pinnable roster ───────────────────────
  //
  // The sheet is ~92% of the phone width; a bare pumpWidget gives 800x600
  // logical, which is wider than any phone Talaria runs on. We pump at a
  // realistic phone surface (420x900) so the sheet renders at its real width.
  void _phoneSurface(WidgetTester tester) {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1260, 2700);
    tester.view.devicePixelRatio = 3.0;
  }

  testWidgets('sheet renders a Pinned section and a time section',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _phoneSurface(tester);
    final gw = PinGateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);

    // Seed the roster directly (the gateway list call is a no-op here), and
    // pin one row so a Pinned section exists.
    _seedSessions(store, [
      SessionRow(id: 'pin1', title: 'Pinned convo', startedAt: _daysAgoAt(2, 9)),
      SessionRow(id: 'today1', title: 'Today convo', startedAt: _daysAgoAt(0, 9)),
    ]);
    store.togglePin('pin1');

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SessionsSheet(store: store))));
    await tester.pumpAndSettle();

    // Both section headers are present: the pinned group and Today.
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    // And the conversations themselves render.
    expect(find.text('Pinned convo'), findsOneWidget);
    expect(find.text('Today convo'), findsOneWidget);
  });

  testWidgets('pinning a row moves it into the Pinned section',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _phoneSurface(tester);
    final gw = PinGateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    _seedSessions(store, [
      SessionRow(id: 'today1', title: 'Today convo', startedAt: _daysAgoAt(0, 9)),
    ]);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SessionsSheet(store: store))));
    await tester.pumpAndSettle();

    // No pins yet: no Pinned header, only Today.
    expect(find.text('Pinned'), findsNothing);
    expect(find.text('Today'), findsOneWidget);

    // Pin via the store (the exact path the row's "Pin to top" action takes,
    // minus the popup overlay, which we skip to keep this test deterministic).
    store.togglePin('today1');
    await tester.pumpAndSettle();

    // Now a Pinned section appears and holds the row; the Today bucket is gone.
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Today convo'), findsOneWidget);
    expect(find.text('Today'), findsNothing);
    expect(store.isPinned('today1'), isTrue);

    // A pin affordance is present on the row (push_pin).
    expect(find.byIcon(Icons.push_pin), findsWidgets);
  });
}

/// Bypass the (no-op) gateway list and install rows directly on the store.
void _seedSessions(ChatStore store, List<SessionRow> rows) {
  final dyn = List<Map<String, dynamic>>.generate(rows.length, (i) => {
        'id': rows[i].id,
        'title': rows[i].title,
        'started_at': rows[i].startedAt,
      });
  store.seedSessionsForTest(dyn);
}
