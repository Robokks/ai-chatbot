import 'package:material_ui/material_ui.dart';

import '../../server/labview_approval_hub.dart';
import '../../tools/tool_source.dart';
import '../host/widgets.dart';

/// Main can answer requests while viewing any screen.
class LabviewApprovalOverlay extends StatelessWidget {
  const LabviewApprovalOverlay({
    super.key,
    required this.hub,
    required this.child,
  });
  final LabviewApprovalHub hub;
  final Widget child;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) => Stack(
      children: [
        child,
        if (hub.pending.isNotEmpty)
          Positioned(
            top: 12,
            right: 12,
            left: 12,
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Material(
                    color: Colors.transparent,
                    child: CardBox(
                      children: [
                        ListTile(
                          title: Text(
                            '${hub.pending.first.device} requests LabVIEW',
                          ),
                          subtitle: Text(hub.pending.first.tool),
                        ),
                        SizedBox(
                          height: 120,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              prettyJson(hub.pending.first.arguments),
                            ),
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  hub.answer(hub.pending.first, false),
                              child: const Text('Deny'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  hub.answer(hub.pending.first, true),
                              child: const Text('Allow once'),
                            ),
                            const SizedBox(width: 12),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
