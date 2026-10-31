import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:http/http.dart' as http;

import 'host_server.dart';

/// A Chatbot host found on the local network.
class FoundHost {
  const FoundHost({required this.name, required this.address, required this.port});

  final String name;
  final String address;
  final int port;

  /// Base URL, bracketing IPv6 addresses.
  Uri get base => Uri(scheme: 'http', host: address, port: port);

  @override
  bool operator ==(Object other) =>
      other is FoundHost && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);
}

/// Advertises this host on the network; returns a function that stops it.
Future<Future<void> Function()> advertiseHost(String name, int port) async {
  final broadcast = BonsoirBroadcast(
    service: BonsoirService(
      name: name,
      type: hostServiceType,
      port: port,
      attributes: const {'app': 'chatbot', 'v': '1'},
    ),
  );
  await broadcast.initialize();
  await broadcast.start();
  return broadcast.stop;
}

/// Finds Chatbot hosts on the Wi-Fi. Emits the current list as hosts appear
/// and disappear. Cancel the subscription to stop searching.
Stream<List<FoundHost>> discoverHosts() {
  final found = <String, FoundHost>{};
  BonsoirDiscovery? discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? sub;
  late final StreamController<List<FoundHost>> out;

  out = StreamController<List<FoundHost>>(
    onListen: () async {
      try {
        final d = discovery = BonsoirDiscovery(type: hostServiceType);
        await d.initialize();
        sub = d.eventStream!.listen((event) {
          final s = event.service;
          if (s == null) return;
          switch (event) {
            case BonsoirDiscoveryServiceFoundEvent():
              d.serviceResolver.resolveService(s);
            case BonsoirDiscoveryServiceResolvedEvent() || BonsoirDiscoveryServiceUpdatedEvent():
              // Prefer IPv4: easier to type and works everywhere.
              final addresses = s.hostAddresses;
              final ip = addresses.firstWhere(
                (a) => InternetAddress.tryParse(a)?.type == InternetAddressType.IPv4,
                orElse: () => addresses.firstOrNull ?? '',
              );
              if (ip.isEmpty) return;
              found[s.name] = FoundHost(name: s.name, address: ip, port: s.port);
              out.add(found.values.toList());
            case BonsoirDiscoveryServiceLostEvent():
              found.remove(s.name);
              out.add(found.values.toList());
            default:
          }
        });
        await d.start();
        out.add(const []);
      } catch (e) {
        out.addError(e);
      }
    },
    onCancel: () async {
      await sub?.cancel();
      await discovery?.stop();
    },
  );
  return out.stream;
}

class PairingException implements Exception {
  PairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parses what the user typed: "192.168.1.5", "192.168.1.5:8484" or a URL.
Uri parseHostAddress(String input) {
  var text = input.trim();
  if (text.isEmpty) throw const FormatException('Enter the address shown on the host');
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) throw const FormatException('Invalid address');
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : defaultHostPort,
  );
}

/// Checks that [base] is a Chatbot host and returns its name.
Future<String> checkHost(Uri base, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c.get(base.replace(path: '/health')).timeout(const Duration(seconds: 5));
    final body = jsonDecode(res.body);
    if (res.statusCode != 200 || body is! Map || body['app'] != 'chatbot-host') {
      throw PairingException('That address is not a Chatbot host.');
    }
    return body['name'] as String? ?? 'Host';
  } on PairingException {
    rethrow;
  } on TimeoutException {
    throw PairingException('The host did not answer. Check that both devices are on the same Wi-Fi.');
  } catch (_) {
    throw PairingException('Could not reach the host. Check the address and the Wi-Fi.');
  } finally {
    if (client == null) c.close();
  }
}

/// Exchanges the host's PIN for an access key.
Future<String> pairWithHost(Uri base, String pin, String deviceName, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c
        .post(
          base.replace(path: '/pair'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'pin': pin.trim(), 'device': deviceName}),
        )
        .timeout(const Duration(seconds: 10));
    final body = jsonDecode(res.body);
    if (res.statusCode == 200 && body is Map && body['key'] is String) return body['key'] as String;
    if (res.statusCode == 429) throw PairingException('Too many wrong PINs. Wait a minute and try again.');
    if (res.statusCode == 401) throw PairingException('Wrong PIN. Check the PIN on the host screen.');
    throw PairingException('Pairing failed (status ${res.statusCode}).');
  } on PairingException {
    rethrow;
  } catch (_) {
    throw PairingException('Could not reach the host. Check the Wi-Fi.');
  } finally {
    if (client == null) c.close();
  }
}
