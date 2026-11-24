import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/gateway/http_service.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 64 (feature): the roster sorts by LAST REPLY, not creation date —
/// matching Hermes Desktop's sidebar, which calls GET
/// /api/sessions?order=recent (the WS session.list row drops last_active,
/// which is why Talaria bucketed by startedAt and an old conversation with
/// a fresh reply sank to "Older").
final _cfg = GatewayConfig(
    url: 'http://gw.example.internal:9119', bearerToken: 'test-bearer');

double _nowSec() => DateTime.now().millisecondsSinceEpoch / 1000.0;
double _daysAgo(int d) => _nowSec() - d * 86400;

class _FakeWs extends GatewayClient {
  _FakeWs() : super(_cfg);
  final calls = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> rows = [];

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
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    if (method == 'session.list') return {'sessions': rows};
    return {};
  }
}

/// REST /api/sessions fake: pages at limit=100, honours order=recent by
/// returning rows pre-sorted newest-last_active-first (as the gateway's
/// order_by_last_active CTE does).
MockClient _restRoster(List<Map<String, dynamic>> all,
    {int status = 200, List<String>? seenQueries}) {
  final sorted = [...all]
    ..sort((a, b) =>
        ((b['last_active'] ?? 0) as num).compareTo((a['last_active'] ?? 0) as num));
  return MockClient((req) async {
    if (!req.url.path.endsWith('/api/sessions')) {
      return http.Response('', 404);
    }
    seenQueries?.add(req.url.query);
    final offset = int.tryParse(req.url.queryParameters['offset'] ?? '0') ?? 0;
    final limit = int.tryParse(req.url.queryParameters['limit'] ?? '100') ?? 100;
    if (status != 200) return http.Response('nope', status);
    final page = sorted.skip(offset).take(limit).toList();
    return http.Response(
        jsonEncode({'sessions': page, 'total': sorted.length,
          'limit': limit, 'offset': offset}),
        200,
        headers: {'content-type': 'application/json'});
  });
}

void main() {
  group('roster comes from REST order=recent and carries last_active', () {
    test('REST rows populate lastActiveAt and the WS RPC is not called',
        () async {
      final ws = _FakeWs();
      ws.rows = [
        {'id': 'ws-only', 'title': 'should not be used'}
      ];
      final rest = [
        {
          'id': 'old-but-active',
          'title': 'started long ago, answered now',
          'started_at': _daysAgo(60),
          'last_active': _nowSec(),
          'message_count': 42,
          'source': 'cli',
        },
        {
          'id': 'recent-both',
          'title': 'new and active',
          'started_at': _daysAgo(1),
          'last_active': _daysAgo(1),
          'message_count': 3,
          'source': 'cli',
        },
      ];
      final store = ChatStore(
          config: _cfg,
          client: ws,
          http: GatewayHttp(_cfg, client: _restRoster(rest)));
      addTearDown(store.dispose);
      await store.loadSessions();
      expect(ws.calls.where((c) => c.$1 == 'session.list'), isEmpty,
          reason: 'REST hit means the WS session.list fallback must not run');
      expect(store.sessions.map((s) => s.id),
          containsAll(['old-but-active', 'recent-both']));
      final old = store.sessions.firstWhere((s) => s.id == 'old-but-active');
      expect(old.lastActiveAt, greaterThan(0));
      expect(old.effectiveActivity, greaterThan(old.startedAt));
    });

    test('a 60-day-old conversation answered NOW buckets under Today',
        () async {
      final ws = _FakeWs();
      final rest = [
        {
          'id': 'veteran',
          'title': 'started in September, replied today',
          'started_at': _daysAgo(60),
          'last_active': _nowSec(),
        },
        {
          'id': 'young-but-stale',
          'title': 'created this week, last touched last week',
          'started_at': _daysAgo(3),
          'last_active': _daysAgo(9),
        },
      ];
      final store = ChatStore(
          config: _cfg,
          client: ws,
          http: GatewayHttp(_cfg, client: _restRoster(rest)));
      addTearDown(store.dispose);
      await store.loadSessions();
      final segs = store.segmentedSessions(store.sessions);
      final labels = segs.map((s) => s.label).toList();
      final byLabel = {for (final s in segs) s.label: s.rows.map((r) => r.id)};
      expect(byLabel['Today'], contains('veteran'),
          reason: 'bucket must follow the last REPLY, not the creation date');
      expect(byLabel.keys, isNot(contains('Older')));
      // And the most-recently-answered conversation leads its bucket.
      expect(labels.first, 'Today');
      expect(segs.first.rows.first.id, 'veteran');
    });

    test('WS fallback still works when REST answers 404', () async {
      final ws = _FakeWs();
      ws.rows = [
        {'id': 'ws-row', 'title': 'from the RPC', 'started_at': _daysAgo(2)}
      ];
      final store = ChatStore(
          config: _cfg,
          client: ws,
          http: GatewayHttp(_cfg,
              client: MockClient((_) async => http.Response('no', 404))));
      addTearDown(store.dispose);
      await store.loadSessions();
      expect(store.sessions.single.id, 'ws-row');
      expect(store.sessions.single.lastActiveAt, 0);
      // Degraded bucketing = creation date, never a bogus zero bucket.
      expect(store.segmentedSessions(store.sessions).single.rows.single.id, 'ws-row');
      expect(ws.calls.any((c) => c.$1 == 'session.list'), isTrue);
    });

    test('WS-fallback rows sort most-recent-reply first inside a bucket',
        () async {
      // The RPC delivers oldest-first; the explicit sort must reorder so
      // both fetch paths look identical to the user.
      final ws = _FakeWs();
      ws.rows = [
        {'id': 'stale', 'started_at': _daysAgo(2)},
        {'id': 'freshest', 'started_at': _daysAgo(0) + 3600},
        {'id': 'middling', 'started_at': _daysAgo(1)},
      ];
      final store = ChatStore(
          config: _cfg,
          client: ws,
          http: GatewayHttp(_cfg,
              client: MockClient((_) async => http.Response('no', 404))));
      addTearDown(store.dispose);
      await store.loadSessions();
      final flat = store
          .segmentedSessions(store.sessions)
          .expand((s) => s.rows)
          .map((r) => r.id)
          .toList();
      expect(flat, ['freshest', 'middling', 'stale'],
          reason: 'segments lead with Today, and within Yesterday the '
              'freshest reply comes first even though the RPC delivered '
              'oldest-first');
    });

    test('the 600-row roster pages the 100-per-request REST cap', () async {
      final ws = _FakeWs();
      final rest = List.generate(
          250,
          (i) => {
                'id': 's$i',
                'title': 't$i',
                'started_at': _daysAgo(1),
                'last_active': _daysAgo(1) - i,
              });
      final queries = <String>[];
      final store = ChatStore(
          config: _cfg,
          client: ws,
          http: GatewayHttp(_cfg, client: _restRoster(rest, seenQueries: queries)));
      addTearDown(store.dispose);
      await store.loadSessions();
      expect(store.sessions.length, 250);
      expect(queries.length, 3, reason: '250 rows at limit<=100 = 3 pages');
      expect(queries.every((q) => q.contains('order=recent')), isTrue);
      expect(store.sessions.first.id, 's0',
          reason: 'newest last_active leads');
    });

    test('a changed last_active re-notifies (roster equality notices it)',
        () async {
      final ws = _FakeWs();
      // FIXED timestamps everywhere except last_active: if the mock
      // recomputed started_at per response it would drift by milliseconds,
      // and the equality check would fire on that instead — the test would
      // pass for the wrong reason and never guard the last_active clause.
      final started = _daysAgo(5);
      final firstStamp = _daysAgo(5) - 1;
      final secondStamp = _daysAgo(1);
      var httpCalls = 0;
      final store = ChatStore(
          config: _cfg,
          client: ws,
          http: GatewayHttp(_cfg, client: MockClient((req) async {
            httpCalls++;
            return http.Response(
                jsonEncode({
                  'sessions': [
                    {
                      'id': 'a',
                      'started_at': started,
                      'last_active':
                          httpCalls == 1 ? firstStamp : secondStamp,
                    }
                  ],
                  'total': 1
                }),
                200,
                headers: {'content-type': 'application/json'});
          })));
      addTearDown(store.dispose);
      var notifies = 0;
      store.addListener(() => notifies++);
      await store.loadSessions();
      expect(store.sessions.single.lastActiveAt, firstStamp);
      notifies = 0;
      await store.loadSessions();
      expect(store.sessions.single.lastActiveAt, secondStamp);
      expect(notifies, greaterThan(0),
          reason: 'a fresh reply must move the row without waiting for an '
              'unrelated field to change');
    });
  });

  group('SessionRow activity semantics', () {
    test('effectiveActivity falls back to startedAt when last_active absent',
        () {
      const r = SessionRow(id: 'x', startedAt: 100);
      expect(r.effectiveActivity, 100);
      const r2 = SessionRow(id: 'x', startedAt: 100, lastActiveAt: 200);
      expect(r2.effectiveActivity, 200);
      expect(r2.copyWithTitle('y').lastActiveAt, 200,
          reason: 'rename must not drop the activity stamp');
    });
  });
}
