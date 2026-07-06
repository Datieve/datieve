import 'package:flutter/material.dart';

import '../models/fm_search_filters.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';

class FmFiltersPanel extends StatelessWidget {
  final DatieveState state;

  const FmFiltersPanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    final f = state.fmSearchFilters;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tw.slate50,
        border: Border(bottom: BorderSide(color: tw.slate100)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          _FilterGroup(
            tw: tw,
            label: 'SIZE',
            child: _SizeRangeRow(state: state, filters: f),
          ),
          _FilterGroup(
            tw: tw,
            label: 'CREATED',
            child: _DateDropdown(
              tw: tw,
              value: f.createdRange,
              onChanged: (v) => state.setSearchFilters(f.copyWith(createdRange: v)),
            ),
          ),
          _FilterGroup(
            tw: tw,
            label: 'MODIFIED',
            child: _DateDropdown(
              tw: tw,
              value: f.modifiedRange,
              onChanged: (v) => state.setSearchFilters(f.copyWith(modifiedRange: v)),
            ),
          ),
          _FilterGroup(
            tw: tw,
            label: 'TYPE',
            child: _TypeDropdown(state: state, filters: f),
          ),
          if (state.viewMode == 'nas' && state.fmSearchQuery.trim().isNotEmpty)
            SizedBox(
              height: 28,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: tw.slate900,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: Size.zero,
                ),
                onPressed: state.submitNasSearch,
                child: const Text('Apply', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterGroup extends StatelessWidget {
  final Tw tw;
  final String label;
  final Widget child;

  const _FilterGroup({required this.tw, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
            color: tw.slate400,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _SizeRangeRow extends StatelessWidget {
  final DatieveState state;
  final FmSearchFilters filters;

  const _SizeRangeRow({required this.state, required this.filters});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    final unit = filters.sizeMinUnit;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CompactNumberField(
          tw: tw,
          key: ValueKey('min-${filters.sizeMinVal}'),
          hint: '0',
          suffix: unit,
          onChanged: (v) => state.setSearchFilters(filters.copyWith(sizeMinVal: v)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('–', style: TextStyle(fontSize: 11, color: tw.slate400)),
        ),
        _CompactNumberField(
          tw: tw,
          key: ValueKey('max-${filters.sizeMaxVal}'),
          hint: '∞',
          suffix: unit,
          onChanged: (v) => state.setSearchFilters(filters.copyWith(sizeMaxVal: v)),
        ),
        const SizedBox(width: 6),
        _CompactUnitDropdown(
          tw: tw,
          value: unit,
          onChanged: (v) => state.setSearchFilters(
            filters.copyWith(sizeMinUnit: v, sizeMaxUnit: v),
          ),
        ),
      ],
    );
  }
}

class _CompactNumberField extends StatelessWidget {
  final Tw tw;
  final String hint;
  final String suffix;
  final ValueChanged<String> onChanged;

  const _CompactNumberField({
    super.key,
    required this.tw,
    required this.hint,
    required this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      height: 28,
      child: TextField(
        decoration: _inputDeco(tw).copyWith(
          hintText: '$hint ($suffix)',
          hintStyle: TextStyle(fontSize: 10, color: tw.slate300),
        ),
        style: TextStyle(fontSize: 11, color: tw.ink),
        keyboardType: TextInputType.number,
        onChanged: onChanged,
      ),
    );
  }
}

class _CompactUnitDropdown extends StatelessWidget {
  final Tw tw;
  final String value;
  final ValueChanged<String> onChanged;

  const _CompactUnitDropdown({
    required this.tw,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 28,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isDense: true,
          isExpanded: true,
          itemHeight: 32,
          value: value,
          style: TextStyle(fontSize: 10, color: tw.ink),
          icon: Icon(Icons.arrow_drop_down, size: 16, color: tw.slate400),
          items: const [
            DropdownMenuItem(value: 'KB', child: Text('KB')),
            DropdownMenuItem(value: 'MB', child: Text('MB')),
            DropdownMenuItem(value: 'GB', child: Text('GB')),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class _DateDropdown extends StatelessWidget {
  final Tw tw;
  final String value;
  final ValueChanged<String> onChanged;

  const _DateDropdown({
    required this.tw,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 28,
      child: DropdownButtonHideUnderline(
        child: DropdownButtonFormField<String>(
          isDense: true,
          isExpanded: true,
          itemHeight: 32,
          value: value.isEmpty ? '' : value,
          decoration: _inputDeco(tw),
          style: TextStyle(fontSize: 11, color: tw.ink),
          items: const [
            DropdownMenuItem(value: '', child: Text('Any time')),
            DropdownMenuItem(value: 'last_1h', child: Text('Last hour')),
            DropdownMenuItem(value: 'today', child: Text('Today')),
            DropdownMenuItem(value: 'last_24h', child: Text('Last 24 hours')),
            DropdownMenuItem(value: 'last_3d', child: Text('Last 3 days')),
            DropdownMenuItem(value: 'last_7d', child: Text('Last 7 days')),
            DropdownMenuItem(value: 'last_14d', child: Text('Last 14 days')),
            DropdownMenuItem(value: 'last_30d', child: Text('Last 30 days')),
            DropdownMenuItem(value: 'last_45d', child: Text('Last 45 days')),
            DropdownMenuItem(value: 'last_60d', child: Text('Last 60 days')),
            DropdownMenuItem(value: 'older_60d', child: Text('60+ days ago')),
          ],
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }
}

class _TypeDropdown extends StatelessWidget {
  final DatieveState state;
  final FmSearchFilters filters;

  const _TypeDropdown({required this.state, required this.filters});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    return SizedBox(
      width: 128,
      height: 28,
      child: DropdownButtonHideUnderline(
        child: DropdownButtonFormField<String>(
          isDense: true,
          isExpanded: true,
          itemHeight: 32,
          value: filters.typeKind,
          decoration: _inputDeco(tw),
          style: TextStyle(fontSize: 11, color: tw.ink),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All items')),
            DropdownMenuItem(value: 'folders', child: Text('Folders')),
            DropdownMenuItem(value: 'files', child: Text('Files')),
            DropdownMenuItem(value: 'images', child: Text('Images')),
            DropdownMenuItem(value: 'documents', child: Text('Documents')),
            DropdownMenuItem(value: 'media', child: Text('Media')),
            DropdownMenuItem(value: 'archives', child: Text('Archives')),
          ],
          onChanged: (v) {
            if (v != null) state.setSearchFilters(filters.copyWith(typeKind: v));
          },
        ),
      ),
    );
  }
}

InputDecoration _inputDeco(Tw tw) {
  return InputDecoration(
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    filled: true,
    fillColor: tw.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: tw.slate200),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: tw.slate200),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: tw.slate400),
    ),
  );
}