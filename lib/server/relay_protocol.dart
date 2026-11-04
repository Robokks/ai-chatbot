import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'openai_bridge.dart';

Object? _canonical(Object? value) {
  if (value is List) return value.map(_canonical).toList();
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  return value;
}
String _digest(Object? value) => sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
bool _equal(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) { difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i); }
  return difference == 0;
}
class RelayIdentity {
  const RelayIdentity(this.id, this.key, this.via);
  final String id;
  final String key;
  final List<String> via;
}
class RelayHop {
  const RelayHop(this.id, this.time, this.nonce, this.signature);
  final String id;
  final int time;
  final String nonce;
  final String signature;
  Map<String, dynamic> toJson() => {'id': id, 'time': time, 'nonce': nonce, 'signature': signature};
  factory RelayHop.fromJson(Map<String, dynamic> j) {
    if (j['id'] is! String || j['time'] is! int || j['nonce'] is! String || j['signature'] is! String ||
        (j['nonce'] as String).length > 100 || (j['signature'] as String).length != 64) {
      throw BridgeException('Invalid relay hop', status: 403);
    }
    return RelayHop(j['id'] as String, j['time'] as int, j['nonce'] as String, j['signature'] as String);
  }
}
class RelayEnvelope {
  RelayEnvelope(Map<String, dynamic> payload, [List<RelayHop> hops = const []])
      : payload = Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map), hops = List.unmodifiable(hops);
  static const maxHops = 8;
  final Map<String, dynamic> payload;
  final List<RelayHop> hops;
  List<String> get path => hops.reversed.map((h) => h.id).toList();
  Map<String, dynamic> toJson() => {'payload': payload, 'hops': hops.map((h) => h.toJson()).toList()};
  factory RelayEnvelope.fromJson(Map<String, dynamic> j) {
    if (j['payload'] is! Map || j['hops'] is! List || (j['hops'] as List).length > maxHops) {
      throw BridgeException('Invalid relay envelope', status: 403);
    }
    return RelayEnvelope(Map<String, dynamic>.from(j['payload'] as Map),
      (j['hops'] as List).map((h) => RelayHop.fromJson(Map<String, dynamic>.from(h as Map))).toList());
  }
  String _signature(String id, int time, String nonce, String key, List<RelayHop> prior) =>
      Hmac(sha256, utf8.encode(key)).convert(utf8.encode('chatbot-relay-v1\n${_digest(payload)}\n'
        '${_digest(prior.map((h) => h.toJson()).toList())}\n$id\n$time\n$nonce')).toString();
  RelayEnvelope append(RelayIdentity identity, {DateTime? now, String? nonce}) {
    if (hops.length >= maxHops || hops.any((h) => h.id == identity.id)) {
      throw BridgeException('Relay loop or hop limit reached', status: 403);
    }
    final stamp = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final random = Random.secure();
    final n = nonce ?? base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
    return RelayEnvelope(payload, [...hops, RelayHop(identity.id, stamp, n, _signature(identity.id, stamp, n, identity.key, hops))]);
  }
  /// Verify a complete chain before accepting any of its nonces or touching a model.
  void verify(RelayIdentity Function(String) resolve, RelayReplayCache replay, {DateTime? now}) {
    final current = now ?? DateTime.now();
    if (hops.isEmpty || hops.length > maxHops || hops.map((h) => h.id).toSet().length != hops.length) {
      throw BridgeException('Missing or cyclic relay chain', status: 403);
    }
    for (var i = 0; i < hops.length; i++) {
      final hop = hops[i];
      if ((current.millisecondsSinceEpoch - hop.time).abs() > const Duration(minutes: 5).inMilliseconds) {
        throw BridgeException('Relay clock is out of sync or the request expired.', status: 403);
      }
      final identity = resolve(hop.id);
      final expectedPath = hops.skip(i + 1).toList().reversed.map((h) => h.id).toList();
      if (!_equal(jsonEncode(identity.via), jsonEncode(expectedPath)) ||
          !_equal(hop.signature, _signature(hop.id, hop.time, hop.nonce, identity.key, hops.take(i).toList()))) {
        throw BridgeException('Invalid relay path or signature', status: 403);
      }
    }
    replay.accept(hops, current);
  }
}
class RelayReplayCache {
  final _seen = <String, DateTime>{};
  void accept(List<RelayHop> hops, DateTime now) {
    _seen.removeWhere((_, expiry) => !now.isBefore(expiry));
    final ids = hops.map((h) => '${h.id}:${h.nonce}').toList();
    if (ids.any(_seen.containsKey)) throw BridgeException('Relay request replay rejected', status: 403);
    if (_seen.length + ids.length > 10000) throw BridgeException('Relay is busy. Try again later.', status: 429);
    for (final id in ids) { _seen[id] = now.add(const Duration(minutes: 10)); }
  }
}
