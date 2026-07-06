import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../src/rust/bridge.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';

class FmOpenWithDialog extends StatelessWidget {
  final DatieveState state;

  const FmOpenWithDialog({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final dialog = state.openWithDialog;
    if (dialog == null) return const SizedBox.shrink();
    final tw = Tw(state.colors);
    final fileName = dialog.path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? dialog.path;

    return GestureDetector(
      onTap: state.closeOpenWithDialog,
      child: ColoredBox(
        color: const Color(0x660F172A),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 320,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: tw.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tw.slate100),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Open With',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: tw.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: tw.slate400),
                  ),
                  const SizedBox(height: 16),
                  if (dialog.loading)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: tw.slate400,
                        ),
                      ),
                    )
                  else if (dialog.apps.isEmpty)
                    Text(
                      'No applications found for this file type.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: tw.slate400),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: dialog.apps.length,
                        itemBuilder: (context, i) {
                          final app = dialog.apps[i];
                          return ListTile(
                            dense: true,
                            leading: Icon(LucideIcons.appWindow, size: 16, color: tw.slate400),
                            title: Text(
                              app.name,
                              style: TextStyle(fontSize: 13, color: tw.slate800),
                            ),
                            onTap: () => state.openWithApp(app.id, dialog.path),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: state.closeOpenWithDialog,
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OpenWithDialogState {
  final String path;
  final List<AppInfoDto> apps;
  final bool loading;

  const OpenWithDialogState({
    required this.path,
    required this.apps,
    required this.loading,
  });
}