import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../data/models.dart';

/// Where API keys are kept.
abstract class KeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore / Windows Credential Manager / browser storage.
class SecureKeyStore implements KeyStore {
  static const _s = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryKeyStore implements KeyStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

/// Local persistence: conversations and settings in Hive, attachment bytes in
/// a separate box, API keys in a [KeyStore].
class Storage {
  Storage._(this._conversations, this._blobs, this._settings, this._keys);

  final Box<String> _conversations;
  final Box<Uint8List> _blobs;
  final Box<String> _settings;
  final KeyStore _keys;

  static Future<Storage> open() async {
    await Hive.initFlutter('ai_chatbot');
    return _openBoxes(SecureKeyStore());
  }

  /// Opens storage in [path] with in-memory keys (tests).
  static Future<Storage> openAt(String path) async {
    Hive.init(path);
    return _openBoxes(MemoryKeyStore());
  }

  static Future<Storage> _openBoxes(KeyStore keys) async => Storage._(
        await Hive.openBox<String>('conversations'),
        await Hive.openBox<Uint8List>('blobs'),
        await Hive.openBox<String>('settings'),
        keys,
      );

  // Conversations

  List<Conversation> loadConversations() {
    final list = <Conversation>[];
    for (final raw in _conversations.values) {
      try {
        list.add(Conversation.fromJson(jsonDecode(raw)));
      } catch (_) {
        // Skip corrupt entries rather than failing to start.
      }
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Future<void> saveConversation(Conversation c) async {
    for (final m in c.messages) {
      for (final a in m.attachments) {
        if (a.bytes != null && !_blobs.containsKey(a.id)) {
          await _blobs.put(a.id, a.bytes!);
        }
      }
    }
    await _conversations.put(c.id, jsonEncode(c.toJson()));
  }

  Future<void> deleteConversation(Conversation c) async {
    final ids = [for (final m in c.messages) ...m.attachments.map((a) => a.id)];
    await _blobs.deleteAll(ids);
    await _conversations.delete(c.id);
  }

  /// Loads attachment bytes for [c] (kept out of the JSON for size).
  void hydrate(Conversation c) {
    for (final m in c.messages) {
      for (final a in m.attachments) {
        a.bytes ??= _blobs.get(a.id);
      }
    }
  }

  // Settings

  String? getSetting(String key) => _settings.get(key);
  Future<void> setSetting(String key, String? value) =>
      value == null ? _settings.delete(key) : _settings.put(key, value);

  ProviderSettings providerSettings(ProviderKind kind) {
    final raw = _settings.get('provider.${kind.name}');
    if (raw == null) return ProviderSettings(kind: kind);
    return ProviderSettings.fromJson(kind, jsonDecode(raw));
  }

  Future<void> saveProviderSettings(ProviderSettings s) =>
      _settings.put('provider.${s.kind.name}', jsonEncode(s.toJson()));

  // API keys

  Future<String?> readKey(ProviderKind kind) => _keys.read('key.${kind.name}');
  Future<void> writeKey(ProviderKind kind, String? value) =>
      value == null || value.isEmpty
          ? _keys.delete('key.${kind.name}')
          : _keys.write('key.${kind.name}', value);
}
