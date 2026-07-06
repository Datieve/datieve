import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';

class FmStatusBar extends StatelessWidget {
  final DatieveState state;

  const FmStatusBar({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    final count = state.visibleFmFiles.length;
    final selected = state.fmSelectedPaths.length;
    final activeOps = state.operationCards.where((c) => c.status == 'in-progress').toList();
    final lastOp = activeOps.isNotEmpty ? activeOps.first : null;

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: tw.white,
        border: Border(top: BorderSide(color: tw.slate100)),
      ),
      child: Row(
        children: [
          Text(
            '$count item${count == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 11, color: tw.slate400),
          ),
          if (selected > 0) ...[
            Text('  |  ', style: TextStyle(fontSize: 11, color: tw.slate200)),
            Text(
              '$selected selected',
              style: TextStyle(fontSize: 11, color: tw.slate400),
            ),
          ],
          if (state.fmClipboard != null) ...[
            Text('  |  ', style: TextStyle(fontSize: 11, color: tw.slate200)),
            Text(
              '${state.fmClipboard!.op == 'cut' ? 'Cut' : 'Copied'} ${state.fmClipboard!.paths.length} item${state.fmClipboard!.paths.length == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 11,
                color: state.fmClipboard!.op == 'cut'
                    ? const Color(0xFFF59E0B)
                    : tw.slate400,
              ),
            ),
          ],
          const Spacer(),
          if (lastOp != null) ...[
            SizedBox(
              width: 112,
              height: 6,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  backgroundColor: tw.slate100,
                  color: const Color(0xFFFBBF24),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              lastOp.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFFF59E0B)),
            ),
            if (activeOps.length > 1)
              Text(' +${activeOps.length - 1}', style: TextStyle(fontSize: 11, color: tw.slate300)),
            const SizedBox(width: 8),
          ],
          Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                if (event.scrollDelta.dy < 0) {
                  state.zoomIn();
                } else {
                  state.zoomOut();
                }
              }
            },
            child: Text(
              'Zoom: ${(state.gridZoom / 1.4 * 100).round()}%',
              style: TextStyle(fontSize: 11, color: tw.slate400),
            ),
          ),
          if (state.settings.showInfoPane) ...[
            Text('  |  ', style: TextStyle(fontSize: 11, color: tw.slate200)),
            Text(
              'Details pane',
              style: TextStyle(fontSize: 11, color: tw.slate400),
            ),
          ],
        ],
      ),
    );
  }
}
