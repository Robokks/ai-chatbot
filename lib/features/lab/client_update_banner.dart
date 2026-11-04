import 'package:material_ui/material_ui.dart';

import '../../data/models.dart';
import '../../server/lan_updates.dart';
import '../../state/app_state.dart';
import 'app_updates_screen.dart';

/// Metadata arrives through Main's authenticated access-status poll. It reports
/// a different available archive, never guesses which build is installed.
class ClientUpdateBanner extends StatefulWidget {
  const ClientUpdateBanner({super.key, this.windowsUpdate});
  final Map<String, dynamic>? windowsUpdate;
  @override
  State<ClientUpdateBanner> createState() => _ClientUpdateBannerState();
}

class _ClientUpdateBannerState extends State<ClientUpdateBanner> {
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final upstream = app.providers[ProviderKind.network]?.baseUrl;
    final raw = widget.windowsUpdate;
    if (raw == null || upstream == null || !app.hasKey(ProviderKind.network)) {
      return const SizedBox.shrink();
    }
    final LanUpdateManifest info;
    try {
      info = LanUpdateManifest.fromJson(raw);
      if (app.storage.getSetting(updateDownloadSettingKey(upstream)) ==
          info.fingerprint) {
        return const SizedBox.shrink();
      }
    } on Object {
      return const SizedBox.shrink();
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.system_update_alt, size: 20),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'A Windows release is ready on Main. Review and download.',
              ),
            ),
            TextButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AppUpdatesScreen(),
                  ),
                );
                if (mounted) setState(() {});
              },
              child: const Text('View update'),
            ),
          ],
        ),
      ),
    );
  }
}
