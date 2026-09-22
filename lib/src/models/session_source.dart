/// Where a conversation came from, and how the roster should treat it.
///
/// The gateway's `session.list` row carries a `source` id but no category, and
/// there is no way to ask the gateway for one category at a time (the RPC
/// accepts only `title`, `limit` and `include_hidden`). So the classification
/// lives here, on the client.
///
/// It deliberately mirrors the desktop client's
/// `apps/desktop/src/lib/session-source.ts`: the same local and platform id
/// lists and the same labels, so both clients group one gateway's
/// conversations the same way instead of inventing two taxonomies.
///
/// The governing rule is conservative: only a source this file POSITIVELY
/// recognises as non-human is held back from the roster. An empty or unknown
/// source stays visible, because hiding a conversation we cannot classify
/// would be worse than showing one we could have hidden.
library;

/// Sources that run on the gateway's own machine with a person driving them.
/// These are the conversations the roster exists to show.
const List<String> kLocalSessionSourceIds = <String>[
  'cli',
  'codex',
  'desktop',
  'gateway',
  'kanban',
  'local',
  'tui',
];

/// External platforms and machine callers. No person is sitting at this
/// gateway, so by default these do not belong in the middle of human traffic.
const List<String> kMessagingSessionSourceIds = <String>[
  'telegram',
  'discord',
  'slack',
  'mattermost',
  'matrix',
  'signal',
  'whatsapp',
  'bluebubbles',
  'photon',
  'homeassistant',
  'email',
  'sms',
  'webhook',
  'api_server',
  'weixin',
  'wecom',
  'qqbot',
  'yuanbao',
  'dingtalk',
  'feishu',
];

/// Sources that are neither a person on this gateway nor a messaging platform:
/// scheduled work and the agent's own child runs. `kanban` and `tool` are
/// already hidden by the gateway itself, and are listed for completeness.
const List<String> kAutomatedSessionSourceIds = <String>[
  'cron',
  'subagent',
  'tool',
  'kanban',
];

const Map<String, String> _sourceLabels = <String, String>{
  'api_server': 'API',
  'bluebubbles': 'iMessage',
  'cli': 'CLI',
  'codex': 'Codex',
  'desktop': 'Desktop',
  'discord': 'Discord',
  'email': 'Email',
  'gateway': 'Gateway',
  'kanban': 'Kanban',
  'local': 'Local',
  'matrix': 'Matrix',
  'mattermost': 'Mattermost',
  'photon': 'Photon',
  'qqbot': 'QQ',
  'signal': 'Signal',
  'slack': 'Slack',
  'sms': 'SMS',
  'telegram': 'Telegram',
  'tui': 'TUI',
  'webhook': 'Webhook',
  'weixin': 'WeChat',
  'whatsapp': 'WhatsApp',
  'yuanbao': 'Yuanbao',
  // Not in the desktop's table, but real sources: a group header has to read
  // as a category, not as a raw id.
  'cron': 'Cron jobs',
  'subagent': 'Subagent runs',
  'tool': 'Tool runs',
  'homeassistant': 'Home Assistant',
  'wecom': 'WeCom',
  'dingtalk': 'DingTalk',
  'feishu': 'Feishu',
};

/// Lowercase, trimmed source id, or null when there is nothing to classify.
String? normalizeSessionSource(String? source) {
  final id = (source ?? '').trim().toLowerCase();
  return id.isEmpty ? null : id;
}

/// Human label for a source id (`api_server` becomes `API`), or null when the
/// source is empty. An id with no table entry is spaced and capitalised rather
/// than dropped, so a platform this build has never heard of still shows up
/// readably instead of blank.
String? sessionSourceLabel(String? source) {
  final id = normalizeSessionSource(source);
  if (id == null) return null;
  final known = _sourceLabels[id];
  if (known != null) return known;
  return id
      .split(RegExp(r'[_-]+'))
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1))
      .join(' ');
}

/// The roster group a non-human conversation belongs in, or null when the
/// conversation belongs in the ordinary time buckets.
String? sessionCategoryLabel(String? source) {
  final id = normalizeSessionSource(source);
  if (id == null) return null;
  if (kLocalSessionSourceIds.contains(id)) return null;
  if (kMessagingSessionSourceIds.contains(id) ||
      kAutomatedSessionSourceIds.contains(id)) {
    return sessionSourceLabel(id);
  }
  // Recognised as neither: treat as human traffic rather than inventing a
  // category for it.
  return null;
}

/// True when a conversation stays in the roster with the automation view off:
/// a person on this gateway, or a source that cannot be classified. Exactly the
/// complement of [isBackgroundSessionSource], so the two can never disagree.
bool isDirectSessionSource(String? source) =>
    !isBackgroundSessionSource(source);

/// True when the roster holds this conversation back by default. Requires
/// positive recognition, so an unknown future platform is never hidden.
bool isBackgroundSessionSource(String? source) {
  final id = normalizeSessionSource(source);
  if (id == null) return false;
  if (kLocalSessionSourceIds.contains(id)) return false;
  return kMessagingSessionSourceIds.contains(id) ||
      kAutomatedSessionSourceIds.contains(id);
}

/// Group ordering when the automation view is on: scheduled and agent work
/// first (the noisiest, least human), then platforms alphabetically. Fixed
/// rather than recency-sorted so the list does not reshuffle underneath
/// someone while they are reading it.
int sessionCategoryRank(String label) {
  switch (label) {
    case 'Cron jobs':
      return 0;
    case 'Subagent runs':
      return 1;
    case 'Tool runs':
      return 2;
    case 'Kanban':
      return 3;
    default:
      return 4;
  }
}
