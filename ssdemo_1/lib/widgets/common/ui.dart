import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
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
          for (final w in trailing) ...[const SizedBox(width: 2), w],
        ],
      ),
    );
  }
}

/// Gives a small control a 44×44 touch area (Apple's minimum) without
/// changing how it looks: taps just outside the control still reach it.
class TapTarget extends StatelessWidget {
  const TapTarget({
    super.key,
    required this.child,
    required this.onTap,
    this.minWidth = 44,
    this.minHeight = 44,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double minWidth;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth, minHeight: minHeight),
        child: Center(widthFactor: 1, heightFactor: 1, child: child),
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
    final button = TapTarget(
      onTap: onPressed,
      child: Material(
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

/// SmartSpend's assistant mark: a speech bubble with a small spending line
/// rising inside it, drawn in [color]. Used wherever the app offers to ask.
class AskMark extends StatelessWidget {
  const AskMark({super.key, this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? IconTheme.of(context).color ?? context.colors.text;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _AskMarkPainter(ink)),
    );
  }
}

class _AskMarkPainter extends CustomPainter {
  _AskMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.095
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Bubble: a soft rounded square with a short tail at the bottom left.
    final body = RRect.fromLTRBR(
      s * 0.08,
      s * 0.08,
      s * 0.92,
      s * 0.74,
      Radius.circular(s * 0.24),
    );
    final bubble = Path()
      ..addRRect(body)
      ..moveTo(s * 0.26, s * 0.74)
      ..lineTo(s * 0.18, s * 0.94)
      ..lineTo(s * 0.44, s * 0.74);
    canvas.drawPath(bubble, stroke);
    // A small spending line climbing to a dot: money, talked through.
    final line = Path()
      ..moveTo(s * 0.27, s * 0.55)
      ..lineTo(s * 0.44, s * 0.40)
      ..lineTo(s * 0.56, s * 0.49)
      ..lineTo(s * 0.70, s * 0.30);
    canvas.drawPath(line, stroke..strokeWidth = s * 0.085);
    canvas.drawCircle(
      Offset(s * 0.70, s * 0.30),
      s * 0.07,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_AskMarkPainter old) => old.color != color;
}

/// Space a tab page leaves at its scroll end so the last item clears the
/// floating tab bar (62 tall, 8 above the bottom edge, plus a gap).
double tabBarClearance(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom.clamp(86.0, double.infinity);

/// Card corner radius: large, on a continuous iOS-style curve.
const double cardRadius = 22;

/// Card outline: continuous (iOS squircle) corners, no border; the card's
/// own fill sets it off the page.
ShapeBorder cardShape(BuildContext context, {double radius = cardRadius}) =>
    RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));

/// [cardShape] filled with the card colour, for a Container.
ShapeDecoration cardDecoration(
  BuildContext context, {
  Color? color,
  double radius = cardRadius,
}) => ShapeDecoration(
  color: color ?? context.colors.card,
  shape: cardShape(context, radius: radius),
);

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
        shape: cardShape(context),
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
    this.steps = const {},
  });

  final T value;
  final Map<T, String> segments;
  final ValueChanged<T> onChanged;
  final EdgeInsetsGeometry margin;

  /// Small ‹ › on a segment's sides that step its period back or forward
  /// (e.g. one month on Month). They work on the selected segment; a null
  /// callback greys that arrow (no earlier or later period).
  final Map<T, ({VoidCallback? previous, VoidCallback? next})> steps;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final keys = segments.keys.toList();
    final selected = keys.indexOf(value);
    // A capsule track with one capsule thumb that slides to the chosen
    // segment, like iOS segmented controls.
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        color: c.raised,
        shape: const StadiumBorder(),
      ),
      // Clipped to the track, so the thumb's springy overshoot at either end
      // stays inside the capsule.
      child: ClipPath(
        clipper: const ShapeBorderClipper(shape: StadiumBorder()),
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth / keys.length;
            return Stack(
              children: [
                if (selected >= 0)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 320),
                    // Springy between segments, but no overshoot into the
                    // track's round ends.
                    curve: selected == 0 || selected == keys.length - 1
                        ? Curves.easeOutCubic
                        : Curves.easeOutBack,
                    left: width * selected,
                    top: 0,
                    bottom: 0,
                    width: width,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: dark ? c.line : c.card,
                        shape: const StadiumBorder(),
                        shadows: dark
                            ? null
                            : const [
                                BoxShadow(
                                  color: Color(0x1F000000),
                                  blurRadius: 8,
                                  offset: Offset(0, 3),
                                ),
                              ],
                      ),
                    ),
                  ),
                Row(
                  children: [
                    for (final entry in segments.entries)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(entry.key),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                if (steps[entry.key] case final step?)
                                  _StepArrow(
                                    key: ValueKey('step-previous-${entry.key}'),
                                    icon: Icons.chevron_left_rounded,
                                    tooltip: 'Previous',
                                    onTap: entry.key == value
                                        ? step.previous
                                        : null,
                                  )
                                else
                                  const SizedBox(width: 30),
                                Expanded(
                                  child: AnimatedDefaultTextStyle(
                                    duration: const Duration(milliseconds: 200),
                                    style: DefaultTextStyle.of(context).style
                                        .copyWith(
                                          fontSize: 13,
                                          fontWeight: entry.key == value
                                              ? FontWeight.w600
                                              : FontWeight.w500,
                                        ),
                                    child: Text(
                                      entry.value,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                                if (steps[entry.key] case final step?)
                                  _StepArrow(
                                    key: ValueKey('step-next-${entry.key}'),
                                    icon: Icons.chevron_right_rounded,
                                    tooltip: 'Next',
                                    onTap: entry.key == value
                                        ? step.next
                                        : null,
                                  )
                                else
                                  const SizedBox(width: 30),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Tappable "October 2026 ⌄" line under a title.
class ScopeLine extends StatefulWidget {
  const ScopeLine({
    super.key,
    required this.label,
    this.onTap,
    this.trailing,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 2),
  });

  final String label;

  /// Opens the picker; the box stays lit until the returned future ends.
  final FutureOr<void> Function()? onTap;

  /// Muted text on the right, e.g. "42 transactions".
  final String? trailing;

  /// Small buttons on the right, e.g. the Wallet's bank shortcuts.
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  static const double _inset = 12;

  @override
  State<ScopeLine> createState() => _ScopeLineState();
}

class _ScopeLineState extends State<ScopeLine> {
  static const double _inset = ScopeLine._inset;

  /// The picker is open: the box stays lit so its menu hangs from it.
  bool _open = false;

  Future<void> _tap() async {
    setState(() => _open = true);
    try {
      await widget.onTap!();
    } finally {
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = widget.label;
    final onTap = widget.onTap == null ? null : _tap;
    final trailing = widget.trailing;
    final actions = widget.actions;
    final padding = widget.padding;
    final style = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: c.muted,
    );
    // The tap box reaches [_inset] past the text on each side, so its
    // pull-down menu can hang from the box's edge with the text lined up.
    final scope = InkWell(
      borderRadius: BorderRadius.circular(menuRadius),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _open ? c.raised : Colors.transparent,
          borderRadius: BorderRadius.circular(menuRadius),
        ),
        // Tall enough to tap easily; the text itself stays small.
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: _inset),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label, overflow: TextOverflow.ellipsis, style: style),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 3),
              Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: c.muted),
            ],
          ],
        ),
      ),
    );
    final outer = padding.resolve(Directionality.of(context));
    return Padding(
      padding: outer.copyWith(left: (outer.left - _inset).clamp(0.0, 99.0)),
      child: Row(
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: scope),
          ),
          if (trailing != null)
            Text(trailing, style: style.copyWith(fontSize: 13)),
          ...actions,
        ],
      ),
    );
  }
}

class _StepArrow extends StatelessWidget {
  const _StepArrow({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final arrow = SizedBox(
      width: 30,
      child: Icon(
        icon,
        size: 20,
        // Faint on an unselected segment or at the end of the range.
        color: onTap == null ? c.muted.withValues(alpha: 0.35) : c.text,
      ),
    );
    // A disabled arrow lets the tap through to select the segment.
    if (onTap == null) return arrow;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: arrow,
      ),
    );
  }
}

/// Three dots bouncing one after another: "the assistant is typing".
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color});

  final Color? color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.colors.muted;
    final still = MediaQuery.of(context).disableAnimations;
    return Semantics(
      label: 'Thinking',
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 5),
              Transform.translate(
                // Each dot hops in turn, a third of the loop apart.
                offset: Offset(
                  0,
                  still ? 0 : -5 * _hop((_ctrl.value - i * 0.18) % 1.0),
                ),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 0 → 1 → 0 over the first 40% of the loop, then rest.
  static double _hop(double t) {
    if (t > 0.4) return 0;
    final x = t / 0.4;
    return 4 * x * (1 - x);
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
    final chip = Material(
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
              AskMark(size: 14, color: c.text),
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
    return TapTarget(onTap: onTap, minWidth: 0, child: chip);
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
    this.leading,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  /// Drawn before the label in place of [icon], e.g. an [AskMark].
  final Widget? leading;

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
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 4),
          ] else if (icon != null) ...[
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

/// Corner radius shared by pickers' tap boxes and their pull-down menus.
const double menuRadius = 12;

/// The control under the last finger or click (screen coordinates), so
/// pickers can open as a pull-down menu lined up under it.
Rect? _lastTappedRect;

/// Call once at startup; records each tapped control for [showOptionSheet].
void trackPointerForMenus() {
  GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
    if (event is! PointerDownEvent) return;
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    // The innermost gesture listener is the button that was tapped.
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderPointerListener && target.hasSize) {
        _lastTappedRect = target.localToGlobal(Offset.zero) & target.size;
        return;
      }
    }
    _lastTappedRect = Rect.fromCenter(
      center: event.position,
      width: 0,
      height: 0,
    );
  });
}

/// Pull-down menu listing options with a check on the current one. It drops
/// straight down from the tapped control, its text lined up with the
/// control's left edge.
Future<T?> showOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<T> values,
  required String Function(T value) labelOf,
  required T? selected,
}) {
  const width = 260.0;
  const itemInset = 12.0;
  final c = context.colors;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final size = overlay.size;
  final anchor = _lastTappedRect == null
      ? Rect.fromLTWH(size.width / 2 - width / 2, size.height / 3, 0, 0)
      : Rect.fromPoints(
          overlay.globalToLocal(_lastTappedRect!.topLeft),
          overlay.globalToLocal(_lastTappedRect!.bottomRight),
        );
  // The menu hangs from the control's left edge; controls pad their text by
  // [itemInset], so the menu's text lines up with theirs.
  final left = anchor.left.clamp(8.0, size.width - width - 8);
  // Directly under the control, so it reads as the box opening downward.
  final top = anchor.bottom + 2;
  final room = size.height - top - 16;
  // Opens upward instead when there's little room below.
  final up = room < 220;
  final maxHeight = up ? anchor.top - 2 - 16 : room;
  // Grows out of the tapped control: the scale starts where it was tapped.
  final originX = ((anchor.left - left) / width).clamp(0.0, 1.0);
  final origin = Alignment(originX * 2 - 1, up ? 1 : -1);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: Colors.black.withValues(alpha: 0.16),
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (context, animation, _) {
      final grow = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeInCubic,
      );
      final menu = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight.clamp(120.0, 520.0)),
        child: Material(
          color: c.card,
          shape: cardShape(context, radius: 20),
          clipBehavior: Clip.antiAlias,
          elevation: 12,
          shadowColor: c.cardShadow,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: [
              for (final v in values)
                InkWell(
                  onTap: () => Navigator.of(context).pop(v),
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: itemInset),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            labelOf(v),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              color: c.text,
                              fontWeight: v == selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (v == selected)
                          Icon(Icons.check_rounded, size: 18, color: c.text),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      return Stack(
        children: [
          Positioned(
            left: left,
            width: width,
            top: up ? null : top,
            bottom: up ? size.height - anchor.top + 2 : null,
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              ),
              child: ScaleTransition(
                scale: Tween(begin: 0.4, end: 1.0).animate(grow),
                alignment: origin,
                child: menu,
              ),
            ),
          ),
        ],
      );
    },
  );
}
