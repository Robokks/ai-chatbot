import '../data/models.dart';

/// USD per million tokens.
class ModelPrice {
  const ModelPrice(this.input, this.output, {double? cachedInput})
      : cachedInput = cachedInput ?? input * 0.1;
  final double input;
  final double output;
  final double cachedInput;
}

/// Published list prices (Anthropic API). Other providers change prices
/// often, so they show token counts without a cost estimate.
const _claudePrices = {
  'claude-fable-5-1': ModelPrice(10, 50),
  'claude-opus-5-5': ModelPrice(4, 20, cachedInput: 0.20),
  'claude-opus-5': ModelPrice(5, 25),
  'claude-sonnet-5-5': ModelPrice(2, 10, cachedInput: 0.20),
  'claude-sonnet-5': ModelPrice(2, 10),
  'claude-haiku-5-5': ModelPrice(0.10, 0.50),
};

ModelPrice? priceFor(ProviderKind? provider, String? model) =>
    provider == ProviderKind.anthropic ? _claudePrices[model] : null;

/// Estimated cost of one reply in USD, or null when the price is unknown.
double? costOf(Message m) {
  final u = m.usage, price = priceFor(m.provider, m.model);
  if (u == null || price == null || (u.inputTokens == null && u.outputTokens == null)) {
    return null;
  }
  final cached = u.cachedTokens ?? 0;
  final fresh = (u.inputTokens ?? 0) - cached;
  return (fresh * price.input + cached * price.cachedInput + (u.outputTokens ?? 0) * price.output) /
      1e6;
}

String formatTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  return '${(n / 1e6).toStringAsFixed(1)}M';
}

String formatCost(double usd) {
  if (usd == 0) return r'$0';
  if (usd < 0.01) return '<\$0.01';
  return '\$${usd.toStringAsFixed(usd < 1 ? 3 : 2)}';
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
}

String formatMs(int ms) =>
    ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0)} s';

/// Totals across many replies, grouped by provider and model.
class UsageTotals {
  int replies = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  double? cost;

  void add(Message m) {
    replies++;
    inputTokens += m.usage?.inputTokens ?? 0;
    outputTokens += m.usage?.outputTokens ?? 0;
    final c = costOf(m);
    if (c != null) cost = (cost ?? 0) + c;
  }
}

/// Usage of assistant replies in [conversations], keyed by "provider|model".
Map<(ProviderKind?, String), UsageTotals> usageByModel(
  Iterable<Conversation> conversations, {
  DateTime? since,
}) {
  final out = <(ProviderKind?, String), UsageTotals>{};
  for (final c in conversations) {
    for (final m in c.messages) {
      if (m.role != Role.assistant || m.usage == null) continue;
      if (since != null && m.createdAt.isBefore(since)) continue;
      out.putIfAbsent((m.provider, m.model ?? 'unknown'), UsageTotals.new).add(m);
    }
  }
  return out;
}
