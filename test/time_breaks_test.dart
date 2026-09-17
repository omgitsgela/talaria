import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Time-category section breaks in the conversation view (2026-09-11):
///   1. store mappers populate ChatMessage.time from the gateway `timestamp`
///      (Unix seconds) — history refresh AND resume paths
///   2. the transcript renders a modern pill break at each calendar-day
///      boundary (Today / Yesterday / date) and NOT within a single day
final _cfg = GatewayConfig(url: 'http://localhost:1');

class TbGateway extends GatewayClient {
  TbGateway() : super(_cfg);
  final responses = <String, Map<String, dynamic>>{};
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => _stateCtl.stream;
  @override
  Future<void> connect({bool isReconnect = false}) async {
    _stateCtl.add(GwConnectionState.open);
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    if (responses.containsKey(method)) return responses[method]!;
    return switch (method) {
      'session.create' => {'session_id': 'live-a'},
      'prompt.submit' => {'status': 'streaming'},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-a'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

/// Calendar-midnight-safe "today at [hour]" that is always in the past or
/// ~now, so the Today/Yesterday buckets are unambiguous.
DateTime _todayAt(int hour) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour.clamp(0, 12));
}

DateTime _dayAt(int daysAgo, int hour) =>
    _todayAt(hour).subtract(Duration(days: daysAgo));

double _unix(DateTime d) => d.millisecondsSinceEpoch / 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── 1. Store mappers stamp time from the gateway timestamp ─────────

  test('resume mapper stamps ChatMessage.time from the row timestamp',
      () async {
    final gw = TbGateway();
    final tenDaysAgo = _dayAt(10, 10);
    final yesterday = _dayAt(1, 12);
    final today = _todayAt(9);
    gw.responses['session.resume'] = {
      'session_id': 'live-r',
      'resumed': 'stored-r',
      'running': false,
      'info': {'model': 'grok-4.20'},
      'messages': [
        {'role': 'user', 'text': 'old', 'timestamp': _unix(tenDaysAgo)},
        {'role': 'assistant', 'text': 'y', 'timestamp': _unix(yesterday)},
        {'role': 'user', 'text': 'now', 'timestamp': _unix(today)},
      ],
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await store.resumeSession('stored-r');

    expect(store.messages.length, 3);
    expect(store.messages[0].time, isNotNull,
        reason: 'the first row\'s timestamp must be carried through');
    expect(store.messages[0].time!.day, tenDaysAgo.day,
        reason: 'the local calendar day must match the source');
    expect(store.messages[2].time!.day, today.day);
  });

  test('history refresh mapper stamps time (and a ts alias)', () async {
    final gw = TbGateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    gw.emit('message.start', {});
    gw.emit('message.complete', {'text': 'a'});

    final yday = _dayAt(1, 9);
    final today = _todayAt(11);
    gw.responses['session.history'] = {
      'messages': [
        {'role': 'user', 'text': 'q1', 'timestamp': _unix(yday)},
        // the `ts` alias must also be honored
        {'role': 'assistant', 'text': 'a1', 'ts': _unix(today)},
      ]
    };
    gw.emit('sessions.changed', {});
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(store.messages.length, 2);
    expect(store.messages[0].time, isNotNull,
        reason: 'timestamp field must survive the history refresh');
    expect(store.messages[1].time, isNotNull,
        reason: 'the ts alias must also be honored');
    expect(store.messages[1].time!.day, today.day);
  });

  // ── 2. Pills render per day-group; same-day messages share a group ──

  testWidgets('transcript shows a time pill at each day boundary only',
      (tester) async {
    final gw = TbGateway();
    // 4 messages across 3 calendar days:
    //   [10 days ago] -> [yesterday, yesterday] -> [today]
    // Expect exactly 3 pills (one per day-group) and NO break between the two
    // yesterday messages.
    final tenDaysAgo = _dayAt(10, 9);
    final y1 = _dayAt(1, 10);
    final y2 = _dayAt(1, 14);
    final today = _todayAt(11);
    gw.responses['session.resume'] = {
      'session_id': 'live-b',
      'resumed': 'stored-b',
      'running': false,
      'info': {'model': 'grok-4.20'},
      'messages': [
        {'role': 'user', 'text': 'm0', 'timestamp': _unix(tenDaysAgo)},
        {'role': 'assistant', 'text': 'm1', 'timestamp': _unix(y1)},
        {'role': 'user', 'text': 'm2', 'timestamp': _unix(y2)},
        {'role': 'assistant', 'text': 'm3', 'timestamp': _unix(today)},
      ],
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();
    await store.resumeSession('stored-b');
    await tester.pumpAndSettle();

    expect(store.messages.length, 4);
    // Each pill carries exactly one calendar (schedule) icon. 4 messages in 3
    // calendar days => exactly 3 breaks. This is date-independent and is the
    // core assertion: the two same-day (yesterday) rows produced no break.
    expect(find.byIcon(Icons.schedule), findsNWidgets(3),
        reason: '3 calendar-day groups must yield exactly 3 time pills');

    // The dynamic labels land on the right buckets.
    expect(find.text('Today'), findsOneWidget,
        reason: 'the newest day-group is labelled Today');
    expect(find.text('Yesterday'), findsOneWidget,
        reason: 'yesterday\'s single group is labelled Yesterday');

    // All four messages are still present (the pills are additions, not
    // replacements of content).
    expect(find.text('m0'), findsOneWidget);
    expect(find.text('m1'), findsOneWidget);
    expect(find.text('m2'), findsOneWidget);
    expect(find.text('m3'), findsOneWidget);
  });

  testWidgets('a single-day transcript shows exactly one leading pill',
      (tester) async {
    final gw = TbGateway();
    final today = _todayAt(10);
    gw.responses['session.resume'] = {
      'session_id': 'live-c',
      'resumed': 'stored-c',
      'running': false,
      'info': {'model': 'grok-4.20'},
      'messages': [
        {'role': 'user', 'text': 'p1', 'timestamp': _unix(_todayAt(8))},
        {'role': 'assistant', 'text': 'p2', 'timestamp': _unix(_todayAt(9))},
        {'role': 'user', 'text': 'p3', 'timestamp': _unix(today)},
      ],
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();
    await store.resumeSession('stored-c');
    await tester.pumpAndSettle();

    // All three messages are the same calendar day => only the leading break.
    expect(find.byIcon(Icons.schedule), findsOneWidget,
        reason: 'one day = one leading time pill, no breaks in the middle');
    expect(find.text('Today'), findsOneWidget);
  });
}
