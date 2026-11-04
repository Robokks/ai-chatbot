import 'dart:convert';

import 'package:ai_chatbot/data/llm/cloudflare_models.dart';
import 'package:ai_chatbot/data/llm/openai_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const base = 'https://api.cloudflare.com/client/v4/accounts/account123/ai/v1';
  test('Cloudflare discovery uses documented model search with task metadata and pages', () async {
    final pages = <int>[];
    final client = MockClient((request) async {
      expect(
        request.url.path,
        '/client/v4/accounts/account123/ai/models/search',
      );
      expect(request.url.queryParameters['task'], 'Text Generation');
      expect(request.headers['authorization'], 'Bearer test-only');
      final page = int.parse(request.url.queryParameters['page']!);
      pages.add(page);
      // Schema from Cloudflare's official model catalog; not OpenAI data/id.
      return http.Response(
        jsonEncode({
          'success': true,
          'errors': [],
          'messages': [],
          'result': page == 1
              ? [
                  {
                    'id': '7a143886-c9bb-4a1c-be95-377b1973bc3b',
                    'name': '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
                    'task': {
                      'id': 'c329a1f9-323d-4e91-b2aa-582dd4188d34',
                      'name': 'Text Generation',
                    },
                  },
                  {
                    'name': '@cf/embedding',
                    'task': {'name': 'Text Embeddings'},
                  },
                  {'name': '@cf/unknown'},
                ]
              : [],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final provider = OpenAiProvider(settings: ProviderSettings(kind: ProviderKind.custom, baseUrl: base), apiKey: 'test-only', client: client);
    final models = await provider.listModels();
    expect(models, ['@cf/meta/llama-3.3-70b-instruct-fp8-fast']);
    expect(pages, [1, 2]);
  });
  test('account placeholders and unrelated endpoints do not match', () {
    expect(cloudflareModelsEndpoint('https://example.com/v1'), isNull);
    expect(
      cloudflareModelsEndpoint(
        'https://api.cloudflare.com/client/v4/accounts/{id}/ai/v1',
      ),
      isNull,
    );
    expect(cloudflareModelsEndpoint('$base/'), isNotNull);
    expect(cloudflareModelsEndpoint('$base?key=secret'), isNull);
  });
  test('failed envelopes and truncated discovery fail instead of reporting healthy empty list', () async {
    expect(
      () => parseCloudflareModels({'success': false, 'result': []}),
      throwsFormatException,
    );
    expect(() => parseCloudflareModels({'data': []}), throwsFormatException);
    await expectLater(
      fetchCloudflareModels(
        baseUrl: base,
        maxPages: 1,
        get: (_) async => jsonEncode({
          'success': true,
          'result': [
            {
              'name': 'name',
              'task': {'name': 'Text Generation'},
            },
          ],
        }),
      ),
      throwsFormatException,
    );
  });
}
