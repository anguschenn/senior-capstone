import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

/// Shared building blocks for the Wallet look: large titles, rounded
/// sections, a segmented control, the scope line and the ✦ "ask" chip.

class LargeTitle extends StatelessWidget {
  const LargeTitle(this.title, {super.key, this.trailing = const []});

  final String title;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.9,
              ),
            ),
          ),
          for (final w in trailing) ...[const SizedBox(width: 10), w],
        ],
      ),
    );
  }
}

/// A round icon button used in the large-title row (+, gear, sort…).
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final button = Material(
      color: c.raised,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            icon,
            size: 19,
            color: onPressed == null ? c.muted : c.text,
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// "‹ Wallet" back link shown above a pushed page's large title.
class BackLink extends StatelessWidget {
  const BackLink(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => Navigator.of(context).maybePop(),
        icon: Icon(Icons.chevron_left_rounded, size: 26, color: c.text),
        label: Text(label, style: TextStyle(fontSize: 17, color: c.text)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.only(left: 4, right: 8),
        ),
      ),
    );
  }
}

/// Rounded card on the page background.
class Section extends StatelessWidget {
  const Section({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 10),
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: margin,
      child: Material(
        color: color ?? c.card,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Bold section heading with an optional trailing link.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              child: Text(
                action!,
                style: TextStyle(fontSize: 15, color: c.muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Icon + title + subtitle + chevron row inside a [Section].
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.showChevron = true,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        leading,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 12.5, color: c.muted),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        if (showChevron)
          Icon(Icons.chevron_right_rounded, size: 20, color: c.muted),
      ],
    );
  }
}

/// Coloured circle with a category icon, used as a row avatar.
class CategoryDot extends StatelessWidget {
  const CategoryDot({
    super.key,
    required this.color,
    required this.icon,
    this.size = 32,
  });

  final Color color;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.5, color: AppPalette.ink),
    );
  }
}

/// iOS-style segmented control.
class SegmentedTabs<T> extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
    this.margin = const EdgeInsets.fromLTRB(16, 6, 16, 4),
  });

  final T value;
  final Map<T, String> segments;
  final ValueChanged<T> onChanged;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          for (final entry in segments.entries)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(entry.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: entry.key == value
                        ? (dark ? c.line : c.card)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: entry.key == value && !dark
                        ? const [
                            BoxShadow(
                              color: Color(0x1F000000),
                              blurRadius: 8,
                              offset: Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: entry.key == value
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tappable "October 2026 ⌄" line under a title.
class ScopeLine extends StatelessWidget {
  const ScopeLine({
    super.key,
    required this.label,
    this.onTap,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 10),
  });

  final String label;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: c.muted,
                  ),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 3),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: c.muted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small "✦ Why?" chip that opens the AI with a question filled in.
class AskChip extends StatelessWidget {
  const AskChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.raised,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 13, color: c.text),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: c.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded pill such as "$33 under pace".
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet listing options with a check on the current one.
Future<T?> showOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<T> values,
  required String Function(T value) labelOf,
  required T? selected,
}) {
  return showModalBottomSheet<T>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) {
      final c = context.colors;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: c.line,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Material(
                  color: c.card,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: values.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 0.5, thickness: 0.5, color: c.line),
                    itemBuilder: (context, i) {
                      final v = values[i];
                      final isSelected = v == selected;
                      return ListTile(
                        dense: true,
                        title: Text(
                          labelOf(v),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(Icons.check_rounded, color: c.text)
                            : null,
                        onTap: () => Navigator.of(context).pop(v),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
