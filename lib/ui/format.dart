import '../models/chat.dart';

String formatTime(DateTime t) {
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String formatHeard(DateTime? t) {
  if (t == null) return 'noch nie gehört';
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inHours < 1) return 'vor ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'vor ${diff.inHours} h';
  return 'vor ${diff.inDays} d';
}

String formatHops({int? hopCount, double? snr}) {
  final hops = hopCount == null
      ? null
      : (hopCount == 0 ? 'direkt' : '$hopCount Hop${hopCount == 1 ? '' : 's'}');
  final signal = snr == null ? null : '${snr.toStringAsFixed(1)} dB';
  return [hops, signal].whereType<String>().join(' · ');
}

String deliveryLabel(ChatMessage m) {
  if (m.hasChannelTracking) return m.channelTrackLabel;
  switch (m.delivery) {
    case DeliveryStatus.sending:
      return 'sendet…';
    case DeliveryStatus.sent:
      return 'gesendet';
    case DeliveryStatus.delivered:
      return m.rttMs != null ? 'zugestellt · ${m.rttMs} ms' : 'zugestellt';
    case DeliveryStatus.failed:
      return 'fehlgeschlagen';
  }
}

String channelPeerLabel(ChannelPeerState s) {
  switch (s) {
    case ChannelPeerState.pending:
      return 'fehlt';
    case ChannelPeerState.live:
      return 'gehört';
    case ChannelPeerState.replayed:
      return 'nachgereicht';
    case ChannelPeerState.delivered:
      return 'da';
  }
}
