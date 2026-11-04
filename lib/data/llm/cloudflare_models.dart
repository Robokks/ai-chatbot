import 'dart:convert';

/// Verified against Cloudflare's generated SDK/OpenAPI, not the OpenAI /models
/// convention. Sources:
/// https://github.com/cloudflare/cloudflare-python/blob/main/src/cloudflare/resources/ai/models/models.py
/// https://github.com/cloudflare/api-schemas/blob/main/openapi.json
/// Model metadata example (name and task.name):
/// https://github.com/cloudflare/cloudflare-docs/blob/production/src/content/workers-ai-models/llama-3.3-70b-instruct-fp8-fast.json
Uri? cloudflareModelsEndpoint(
  String baseUrl, {
  int page = 1,
  int perPage = 100,
}) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'api.cloudflare.com' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (parts.length != 6 ||
      parts[0] != 'client' ||
      parts[1] != 'v4' ||
      parts[2] != 'accounts' ||
      parts[4] != 'ai' ||
      parts[5] != 'v1' ||
      parts[3].contains(RegExp(r'[{}\s/]'))) {
    return null;
  }
  if (page < 1 || perPage < 1) {
    throw ArgumentError('Page sizes must be positive');
  }
  return uri.replace(
    pathSegments: [...parts.take(5), 'models', 'search'],
    queryParameters: {
      'task': 'Text Generation',
      'page': '$page',
      'per_page': '$perPage',
    },
  );
}

class CloudflareModelPage {
  CloudflareModelPage({required this.names, required this.resultCount});
  final List<String> names;

  /// Count unfiltered rows for pagination, not only compatible chat models.
  final int resultCount;
}

CloudflareModelPage parseCloudflareModels(Object? decoded) {
  if (decoded is! Map ||
      decoded['success'] != true ||
      decoded['result'] is! List) {
    throw const FormatException(
      'Cloudflare did not return a successful model search envelope',
    );
  }
  final result = decoded['result'] as List;
  final names = <String>{};
  for (final row in result) {
    if (row is! Map) {
      throw const FormatException('Invalid Cloudflare model metadata');
    }
    final name = row['name'];
    final task = row['task'];
    // Never guess a capability from a model name or accept UUID ids as names.
    if (task is Map &&
        task['name'] == 'Text Generation' &&
        name is String &&
        name.isNotEmpty) {
      names.add(name);
    }
  }
  return CloudflareModelPage(names: names.toList(), resultCount: result.length);
}

/// The caller supplies its existing authenticated HTTP/error-handling path.
/// Cloudflare's SDK advances page until an empty result, not an invented total.
Future<List<String>> fetchCloudflareModels({
  required String baseUrl,
  required Future<String> Function(Uri endpoint) get,
  int maxPages = 100,
}) async {
  if (maxPages < 1) throw ArgumentError('maxPages must be positive');
  final names = <String>{};
  for (var page = 1; page <= maxPages; page++) {
    final endpoint = cloudflareModelsEndpoint(baseUrl, page: page);
    if (endpoint == null) {
      throw ArgumentError('Not a Cloudflare account AI endpoint');
    }
    final result = parseCloudflareModels(jsonDecode(await get(endpoint)));
    names.addAll(result.names);
    if (result.resultCount == 0) return names.toList();
  }
  throw const FormatException(
    'Cloudflare model discovery exceeded its page limit',
  );
}
