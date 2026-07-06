import 'package:flutter/material.dart';

import '../models/file_tag.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';

class TagBadges extends StatelessWidget {
  final List<FileTag> tags;
  final DatieveColors colors;
  final bool compact;

  const TagBadges({
    super.key,
    required this.tags,
    required this.colors,
    this.compact = false,
  });

  Color _parseColor(String hex) {
    final h = hex.replaceFirst('#', '');
    if (h.length == 6) {
      return Color(int.parse('FF$h', radix: 16));
    }
    return Tw(colors).slate400;
  }

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final limit = compact ? 2 : 4;
    final shown = tags.take(limit).toList();
    return Padding(
      padding: EdgeInsets.only(top: compact ? 4 : 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: compact ? WrapAlignment.center : WrapAlignment.start,
        children: [
          for (final tag in shown)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _parseColor(tag.color).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tag.name,
                style: TextStyle(
                  fontSize: compact ? 9 : 10,
                  color: _parseColor(tag.color),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (tags.length > limit)
            Text(
              '+${tags.length - limit}',
              style: TextStyle(fontSize: 9, color: Tw(colors).slate300),
            ),
        ],
      ),
    );
  }
}