import 'package:flutter/material.dart';

class SelectorOption<T> {
  const SelectorOption({required this.value, required this.label});

  final T value;
  final String label;
}

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
    final theme = Theme.of(context);
    final selectedLabel = options
        .firstWhere(
          (option) => option.value == value,
          orElse: () => SelectorOption(value: value, label: '$value'),
        )
        .label;
    final valueStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w500,
      color: Colors.black87,
    );
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      color: Colors.black.withValues(alpha: 0.58),
      fontWeight: FontWeight.w500,
    );
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final picked = await showModalBottomSheet<T>(
          context: context,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (context) {
            return SafeArea(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                itemCount: options.length,
                separatorBuilder: (_, _) => const SizedBox(height: 2),
                itemBuilder: (context, index) {
                  final option = options[index];
                  final isSelected = option.value == value;
                  return ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    tileColor: isSelected
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
                        : null,
                    title: Text(
                      option.label,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(option.value),
                  );
                },
              ),
            );
          },
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          filled: true,
          fillColor: const Color(0xFFF6F8F4),
          labelText: label,
          labelStyle: labelStyle,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.12)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.12)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.4),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selectedLabel,
                style: valueStyle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Colors.black54),
          ],
        ),
      ),
    );
  }
}
