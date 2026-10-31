import 'package:ai_chatbot/core/device_stats.dart';
import 'package:ai_chatbot/core/usage.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

Message _reply(ProviderKind p, String model, {int? input, int? output, int? cached, DateTime? at}) =>
    Message(
      role: Role.assistant,
      provider: p,
      model: model,
      usage: UsageStats(inputTokens: input, outputTokens: output, cachedTokens: cached),
      createdAt: at,
    );

void main() {
  test('Claude cost uses list prices, including cheaper cached input', () {
    expect(costOf(_reply(ProviderKind.anthropic, 'claude-opus-5-5', input: 1000000, output: 1000000)),
        closeTo(24.0, 1e-9));
    expect(
        costOf(_reply(ProviderKind.anthropic, 'claude-opus-5-5',
            input: 1000000, output: 0, cached: 1000000)),
        closeTo(0.20, 1e-9));
    expect(costOf(_reply(ProviderKind.anthropic, 'claude-haiku-5-5', input: 2000000, output: 0)),
        closeTo(0.20, 1e-9));
  });

  test('no cost guess for providers without a known price', () {
    expect(costOf(_reply(ProviderKind.openai, 'gpt-5', input: 100, output: 100)), isNull);
    expect(costOf(_reply(ProviderKind.local, 'LFM2-1.2B-Q4_K_M', input: 100, output: 100)), isNull);
  });

  test('usage stats: speed, merge and save/load', () {
    final u = UsageStats(outputTokens: 100, firstTokenMs: 1000, durationMs: 6000);
    expect(u.tokensPerSecond, 20);
    u.merge(UsageStats(inputTokens: 50));
    expect(u.inputTokens, 50);
    expect(u.outputTokens, 100);
    final m = Message.fromJson(
        _reply(ProviderKind.deepseek, 'deepseek-chat', input: 5, output: 7).toJson());
    expect(m.provider, ProviderKind.deepseek);
    expect(m.usage!.inputTokens, 5);
    expect(m.usage!.outputTokens, 7);
  });

  test('totals group by model and can be limited to recent replies', () {
    final old = DateTime.now().subtract(const Duration(days: 60));
    final c = Conversation(messages: [
      Message(role: Role.user, text: 'hi'),
      _reply(ProviderKind.anthropic, 'claude-sonnet-5-5', input: 1000, output: 500),
      _reply(ProviderKind.anthropic, 'claude-sonnet-5-5', input: 1000, output: 500, at: old),
      _reply(ProviderKind.openai, 'gpt-5', input: 10, output: 20),
    ]);
    final all = usageByModel([c]);
    final sonnet = all[(ProviderKind.anthropic, 'claude-sonnet-5-5')]!;
    expect(sonnet.replies, 2);
    expect(sonnet.outputTokens, 1000);
    expect(sonnet.cost, closeTo((2000 * 2 + 1000 * 10) / 1e6, 1e-12));
    expect(all[(ProviderKind.openai, 'gpt-5')]!.cost, isNull);

    final recent = usageByModel([c], since: DateTime.now().subtract(const Duration(days: 30)));
    expect(recent[(ProviderKind.anthropic, 'claude-sonnet-5-5')]!.replies, 1);
  });

  test('formatting', () {
    expect(formatTokens(950), '950');
    expect(formatTokens(1234), '1.2k');
    expect(formatTokens(45000), '45k');
    expect(formatBytes(730893248), '697 MB');
    expect(formatBytes(1563668704), '1.5 GB');
    expect(formatCost(0.004), r'<$0.01');
    expect(formatCost(0.1234), r'$0.123');
    expect(formatMs(850), '850 ms');
    expect(formatMs(1500), '1.5 s');
  });

  group('model fit', () {
    const phone8gb = DeviceStats(totalRamMb: 8192, freeDiskBytes: 20 * 1024 * 1024 * 1024);
    test('small models fit, large ones are flagged', () {
      expect(modelFit(phone8gb, ramGb: 2, sizeMb: 700), ModelFit.fits);
      expect(modelFit(phone8gb, ramGb: 5, sizeMb: 1500), ModelFit.tight);
      expect(modelFit(phone8gb, ramGb: 8, sizeMb: 1500), ModelFit.tooBig);
    });
    test('storage is checked first', () {
      const full = DeviceStats(totalRamMb: 8192, freeDiskBytes: 100 * 1024 * 1024);
      expect(modelFit(full, ramGb: 1, sizeMb: 700), ModelFit.noSpace);
    });
    test('unknown when the device does not report RAM', () {
      expect(modelFit(const DeviceStats(), ramGb: 2, sizeMb: 700), ModelFit.unknown);
    });
  });
}
