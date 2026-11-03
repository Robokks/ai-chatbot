import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/lab_role.dart';
import '../../state/app_state.dart';

/// A local preference only: selecting a role never starts a server or grants access.
class RolePicker extends StatelessWidget {
  const RolePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('How will this PC be used?', style: serif(context, size: 30)),
                const SizedBox(height: 12),
                const Text('You can change this later in Settings.'),
                const SizedBox(height: 32),
                for (final role in LabRole.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: OutlinedButton(
                      key: ValueKey('role-${role.name}'),
                      onPressed: () => state.setLabRole(role),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(role.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            Text(role.description),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
