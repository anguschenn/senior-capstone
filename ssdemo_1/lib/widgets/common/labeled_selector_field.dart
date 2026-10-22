import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'ui.dart';

class SelectorOption<T> {
  const SelectorOption({required this.value, required this.label});

  final T value;
  final String label;
}

/// Small label over a value; tapping opens a sheet to pick another value.
class LabeledSelectorField<T> extends StatelessWidget {
  const LabeledSelectorField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<SelectorOption<T>> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selectedLabel = options
        .firstWhere(
          (option) => option.value == value,
          orElse: () => SelectorOption(value: value, label: '$value'),
        )
        .label;
    return Pressable(
      hoverScale: 1.02,
      pressScale: 0.98,
      child: Material(
        color: c.raised,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            final picked = await showOptionSheet<T>(
              context: context,
              title: label,
              values: [for (final o in options) o.value],
              labelOf: (v) => options.firstWhere((o) => o.value == v).label,
              selected: value,
            );
            if (picked != null) onChanged(picked);
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 7),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(fontSize: 11, color: c.muted),
                      ),
                      Text(
                        selectedLabel,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: c.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
