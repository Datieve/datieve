import 'package:flutter/material.dart';

import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';

class SettingsSectionHeader extends StatelessWidget {
  final String title;

  const SettingsSectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = dark ? DatieveColors.dark : DatieveColors.light;
    final tw = Tw(c);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      decoration: BoxDecoration(
        color: tw.slate50,
        border: Border(bottom: BorderSide(color: tw.line)),
      ),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
          color: tw.slate400,
        ),
      ),
    );
  }
}

class SettingsRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget trailing;
  final DatieveColors colors;

  const SettingsRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: null,
        hoverColor: tw.slate50,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tw.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: 13, color: tw.ink)),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 11, color: tw.slate400),
                    ),
                  ],
                ),
              ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final DatieveColors colors;

  const SettingsToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 36,
        height: 20,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value ? tw.slate900 : tw.slate200,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsSegmented extends StatelessWidget {
  final List<String> options;
  final String value;
  final ValueChanged<String> onChanged;
  final DatieveColors colors;

  const SettingsSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: tw.slate200),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            GestureDetector(
              onTap: () => onChanged(options[i]),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: value == options[i] ? tw.slate900 : Colors.transparent,
                  border: i > 0
                      ? Border(left: BorderSide(color: tw.slate200))
                      : null,
                ),
                child: Text(
                  options[i],
                  style: TextStyle(
                    fontSize: 12,
                    color: value == options[i] ? tw.onBrand : tw.slate500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SettingsDropdown extends StatelessWidget {
  final String value;
  final List<(String, String)> options;
  final ValueChanged<String> onChanged;
  final DatieveColors colors;

  const SettingsDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        itemHeight: 32,
        isDense: true,
        items: options
            .map((o) => DropdownMenuItem(value: o.$1, child: Text(o.$2, style: TextStyle(fontSize: 12, color: tw.slate700))))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
        style: TextStyle(fontSize: 12, color: tw.slate700),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}