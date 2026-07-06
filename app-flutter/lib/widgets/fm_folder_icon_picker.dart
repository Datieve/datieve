import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../utils/custom_folder_icons_store.dart';

class FmFolderIconPicker extends StatelessWidget {
  final DatieveState state;
  final String path;
  final String name;

  const FmFolderIconPicker({
    super.key,
    required this.state,
    required this.path,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    final current = resolveFolderIconId(
      path: path,
      name: name,
      customIcons: state.customFolderIcons,
    );

    return GestureDetector(
      onTap: state.closeFolderIconPicker,
      child: ColoredBox(
        color: const Color(0x33000000),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 420,
              constraints: const BoxConstraints(maxHeight: 480),
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: tw.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tw.slate200),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Change folder icon',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: tw.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: tw.slate400),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: GridView.builder(
                      shrinkWrap: true,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 0.9,
                      ),
                      itemCount: papirusFolderIcons.length,
                      itemBuilder: (context, index) {
                        final icon = papirusFolderIcons[index];
                        final selected = icon.id == current;
                        return Material(
                          color: selected ? tw.slate100 : tw.slate50,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              state.setCustomFolderIcon(path, icon.id);
                              state.closeFolderIconPicker();
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SvgPicture.asset(
                                    'assets/icons/${icon.id}.svg',
                                    width: 36,
                                    height: 36,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    icon.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 10, color: tw.slate600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          state.clearCustomFolderIcon(path);
                          state.closeFolderIconPicker();
                        },
                        child: Text('Reset to default', style: TextStyle(color: tw.slate500)),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: state.closeFolderIconPicker,
                        child: Text('Cancel', style: TextStyle(color: tw.slate500)),
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