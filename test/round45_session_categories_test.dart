import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/models/session_source.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Conversation categories in the roster (2026-09-20).
///
/// The gateway keeps ONE session list and cannot filter it by source, so every
/// client sees cron jobs, subagent runs and platform sessions mixed in with the
/// conversations a person actually had. On a busy gateway those outnumber human
/// conversations many times over (measured on Angela's: cron 927, telegram 709,
/// desktop 125, cli 71, subagent 64, tui 46, api_server 18), which is what
/// buries the human ones.
///
///   1. classification: the source id lists and labels, which mirror the
///      desktop client's `lib/session-source.ts`
///   2. the conservative rule: only a POSITIVELY recognised non-human source is
///      ever held back, so an unknown platform is never hidden from someone
///   3. store: segmentedSessions holds those rows back by default, groups them
///      by source label when asked, and never hides a pinned row
///   4. widget: the sheet offers the filter, badges the rows it reveals, and
///      counts what it is holding back
final _cfg = GatewayConfig(url: 'http://localhost:1');

class CategoryGateway extends GatewayClient {
  CategoryGateway() : super(_cfg);
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

/// Bypass the (no-op) gateway list and install rows directly on the store,
/// carrying the source through so the classification has something to work on.
void _seedSessions(ChatStore store, List<SessionRow> rows) {
  final dyn = List<Map<String, dynamic>>.generate(rows.length, (i) => {
        'id': rows[i].id,
        'title': rows[i].title,
        'started_at': rows[i].startedAt,
        'source': rows[i].source,
      });
  store.seedSessionsForTest(dyn);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ChatStore fresh() => ChatStore(config: _cfg, client: CategoryGateway());

  // ── 1. Classification (pure) ─────────────────────────────────────

  test('platform labels match the desktop client wording', () {
    expect(sessionSourceLabel('api_server'), 'API');
    expect(sessionSourceLabel('telegram'), 'Telegram');
    expect(sessionSourceLabel('desktop'), 'Desktop');
    expect(sessionSourceLabel('cli'), 'CLI');
    expect(sessionSourceLabel('cron'), 'Cron jobs');
    expect(sessionSourceLabel('subagent'), 'Subagent runs');
    expect(sessionSourceLabel('  TELEGRAM  '), 'Telegram');
    expect(sessionSourceLabel(''), isNull);
    expect(sessionSourceLabel(null), isNull);
  });

  test('an unrecognised source is labelled, not dropped', () {
    // A platform this build has never heard of must still read as something.
    expect(sessionSourceLabel('my_platform'), 'My Platform');
    expect(sessionSourceLabel('zulip'), 'Zulip');
  });

  test('only positively recognised non-human sources are held back', () {
    for (final s in ['cron', 'subagent', 'telegram', 'api_server', 'email']) {
      expect(isBackgroundSessionSource(s), isTrue, reason: s);
    }
    // Human sources stay in the roster.
    for (final s in ['desktop', 'cli', 'tui', 'codex', 'gateway', 'local']) {
      expect(isBackgroundSessionSource(s), isFalse, reason: s);
    }
    // The conservative rule: anything unclassifiable is never hidden. Hiding a
    // conversation we cannot identify would be worse than showing one we could
    // have hidden.
    expect(isBackgroundSessionSource(''), isFalse);
    expect(isBackgroundSessionSource(null), isFalse);
    expect(isBackgroundSessionSource('zulip'), isFalse);
    expect(isDirectSessionSource(''), isTrue);
    expect(isDirectSessionSource('zulip'), isTrue);
    expect(isDirectSessionSource('telegram'), isFalse);
  });

  test('a group exists for recognised non-human sources only', () {
    expect(sessionCategoryLabel('cron'), 'Cron jobs');
    expect(sessionCategoryLabel('telegram'), 'Telegram');
    expect(sessionCategoryLabel('api_server'), 'API');
    expect(sessionCategoryLabel('desktop'), isNull);
    expect(sessionCategoryLabel(''), isNull);
    expect(sessionCategoryLabel('zulip'), isNull);
  });

  test('scheduled work sorts before platforms, which sort by name', () {
    expect(sessionCategoryRank('Cron jobs'),
        lessThan(sessionCategoryRank('Subagent runs')));
    expect(sessionCategoryRank('Subagent runs'),
        lessThan(sessionCategoryRank('Telegram')));
    expect(sessionCategoryRank('Telegram'), equals(sessionCategoryRank('API')));
  });

  // ── 2. Store segmentation ────────────────────────────────────────

  test('the roster hides non-human conversations by default', () {
    final store = fresh();
    addTearDown(store.dispose);
    _seedSessions(store, [
      SessionRow(
          id: 'human',
          title: 'Real conversation',
          startedAt: _daysAgoAt(0, 9),
          source: 'desktop'),
      SessionRow(
          id: 'tg', title: 'Telegram chatter', startedAt: _daysAgoAt(0, 9),
          source: 'telegram'),
      SessionRow(
          id: 'cron', title: 'Job run', startedAt: _daysAgoAt(0, 9),
          source: 'cron'),
    ]);

    final segs = store.segmentedSessions(store.sessions);
    final labels = segs.map((s) => s.label).toList();
    expect(labels, contains('Today'));
    expect(labels, isNot(contains('Telegram')));
    expect(labels, isNot(contains('Cron jobs')));
    final ids = segs.expand((s) => s.rows).map((r) => r.id).toList();
    expect(ids, contains('human'));
    expect(ids, isNot(contains('tg')));
    expect(ids, isNot(contains('cron')));
    expect(store.hiddenBackgroundCount(store.sessions), 2);
  });

  test('showing automation groups it by source, scheduled work first', () {
    final store = fresh();
    addTearDown(store.dispose);
    _seedSessions(store, [
      SessionRow(
          id: 'human',
          title: 'Real conversation',
          startedAt: _daysAgoAt(0, 9),
          source: 'desktop'),
      SessionRow(
          id: 'tg', title: 'Telegram chatter', startedAt: _daysAgoAt(0, 9),
          source: 'telegram'),
      SessionRow(
          id: 'api', title: 'API call', startedAt: _daysAgoAt(0, 9),
          source: 'api_server'),
      SessionRow(
          id: 'cron', title: 'Job run', startedAt: _daysAgoAt(0, 9),
          source: 'cron'),
    ]);
    store.setShowBackgroundSessions(true);

    final segs = store.segmentedSessions(store.sessions);
    final labels = segs.map((s) => s.label).toList();
    // Human traffic keeps its time bucket, and it comes first.
    expect(labels.first, 'Today');
    expect(labels, containsAll(<String>['Cron jobs', 'Telegram', 'API']));
    // Cron leads the category groups, then platforms alphabetically.
    expect(labels.indexOf('Cron jobs'), lessThan(labels.indexOf('API')));
    expect(labels.indexOf('API'), lessThan(labels.indexOf('Telegram')));
    final ids = segs.expand((s) => s.rows).map((r) => r.id).toList();
    expect(ids, containsAll(<String>['human', 'tg', 'api', 'cron']));
    // Nothing is held back once they are shown, so the count is zero.
    expect(store.hiddenBackgroundCount(store.sessions), 0);
  });

  test('a pinned non-human conversation is never held back', () {
    final store = fresh();
    addTearDown(store.dispose);
    _seedSessions(store, [
      SessionRow(
          id: 'tg', title: 'Telegram chatter', startedAt: _daysAgoAt(0, 9),
          source: 'telegram'),
      SessionRow(
          id: 'human',
          title: 'Real conversation',
          startedAt: _daysAgoAt(0, 9),
          source: 'desktop'),
    ]);
    store.togglePin('tg');

    // Pinning is an explicit act by the person using the app, so it outranks
    // the category default.
    final segs = store.segmentedSessions(store.sessions);
    final pinned = segs.firstWhere((s) => s.label.isEmpty);
    expect(pinned.rows.map((r) => r.id), contains('tg'));
    // And it does not inflate the "held back" count.
    expect(store.hiddenBackgroundCount(store.sessions), 0);
  });

  test('an unclassifiable conversation stays in the roster', () {
    final store = fresh();
    addTearDown(store.dispose);
    _seedSessions(store, [
      SessionRow(
          id: 'odd', title: 'From somewhere new', startedAt: _daysAgoAt(0, 9),
          source: 'zulip'),
    ]);
    final segs = store.segmentedSessions(store.sessions);
    expect(segs.expand((s) => s.rows).map((r) => r.id), contains('odd'));
    expect(store.hiddenBackgroundCount(store.sessions), 0);
  });

  // ── 3. Widget: the sheet ─────────────────────────────────────────

  /// A bare pumpWidget gives an 800x600 surface, which is wider than any phone
  /// Talaria runs on. Pump at a realistic phone size instead.
  void _phoneSurface(WidgetTester tester) {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1260, 2700);
    tester.view.devicePixelRatio = 3.0;
  }

  Future<ChatStore> _pumpSheet(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    _phoneSurface(tester);
    final store = ChatStore(config: _cfg, client: CategoryGateway());
    addTearDown(store.dispose);
    _seedSessions(store, [
      SessionRow(
          id: 'human',
          title: 'Real conversation',
          startedAt: _daysAgoAt(0, 9),
          source: 'desktop'),
      SessionRow(
          id: 'tg', title: 'Telegram chatter', startedAt: _daysAgoAt(0, 9),
          source: 'telegram'),
      SessionRow(
          id: 'cron', title: 'Job run', startedAt: _daysAgoAt(0, 9),
          source: 'cron'),
    ]);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SessionsSheet(store: store))));
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('the sheet offers the filter and counts what it hides',
      (tester) async {
    await _pumpSheet(tester);

    // The human conversation is there; the others are not, and are counted.
    expect(find.text('Real conversation'), findsOneWidget);
    expect(find.text('Telegram chatter'), findsNothing);
    expect(find.text('Job run'), findsNothing);
    expect(find.text('Show automation and API (2)'), findsOneWidget);
  });

  testWidgets('tapping the filter reveals the sessions, labelled',
      (tester) async {
    final store = await _pumpSheet(tester);

    await tester.tap(find.byKey(const ValueKey('roster_categories_chip')));
    await tester.pumpAndSettle();

    expect(store.showBackgroundSessions, isTrue);
    // Grouped by source, and each row carries its origin.
    expect(find.text('Telegram'), findsWidgets);
    expect(find.text('Cron jobs'), findsWidgets);
    expect(find.text('Telegram chatter'), findsOneWidget);
    expect(find.text('Job run'), findsOneWidget);
    expect(find.byKey(const ValueKey('badge_Telegram')), findsOneWidget);
    expect(find.byKey(const ValueKey('badge_Cron jobs')), findsOneWidget);
    // The human row is NOT badged: the badge marks exactly the rows that were
    // being held back, so an ordinary conversation is unmarked.
    expect(find.byKey(const ValueKey('badge_Desktop')), findsNothing);
  });

  testWidgets('searching a platform name finds its conversations',
      (tester) async {
    final store = await _pumpSheet(tester);
    store.setShowBackgroundSessions(true);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'telegram');
    await tester.pumpAndSettle();

    // The desktop client indexes a session by its platform name too, so
    // searching "telegram" has to find those conversations.
    expect(find.text('Telegram chatter'), findsOneWidget);
    expect(find.text('Real conversation'), findsNothing);
    expect(find.text('Job run'), findsNothing);
  });
}
