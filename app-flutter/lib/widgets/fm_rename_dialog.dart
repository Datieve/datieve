import 'package:flutter/material.dart';

import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';

class FmRenameDialog extends StatefulWidget {
  final DatieveState state;

  const FmRenameDialog({super.key, required this.state});

  @override
  State<FmRenameDialog> createState() => _FmRenameDialogState();
}

class _FmRenameDialogState extends State<FmRenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.state.fmRenameValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final tw = Tw(s.colors);
    final title = s.fmRenameBulk ? 'Bulk Rename' : 'Rename';

    return GestureDetector(
      onTap: s.closeRename,
      child: ColoredBox(
        color: const Color(0x660F172A),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 360,
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
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: tw.ink,
                    ),
                  ),
                  if (s.fmRenameBulk)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '${s.fmSelectedPaths.length} items will be renamed with a numbered suffix.',
                        style: TextStyle(fontSize: 12, color: tw.slate500),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    onChanged: s.setRenameValue,
                    onSubmitted: (_) => s.submitRename(),
                    decoration: InputDecoration(
                      labelText: s.fmRenameBulk ? 'Base name' : 'Name',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: s.closeRename, child: const Text('Cancel')),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: s.submitRename,
                        child: const Text('Rename'),
                      ),
                    ],
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