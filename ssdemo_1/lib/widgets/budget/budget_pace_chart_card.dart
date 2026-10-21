import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/budget_pace.dart';
import '../common/ui.dart';

/// Monthly budget remaining chart: solid actual spend, dashed even-pace line.
class BudgetPaceChartCard extends StatelessWidget {
  const BudgetPaceChartCard({super.key, required this.snapshot});

  final BudgetPaceSnapshot snapshot;

  /// X-axis labels: day 1, every 5th day, and the month's last day. A 5-day
  /// mark within 2 days of the end is dropped so labels don't collide.
  /// Line colour for a point [gap] above (+) or below (-) the even-pace line,
  /// as a share of the month's budget, in earth tones: sage well under, ochre
  /// then terracotta as it nears the line, brick red once it crosses and pulls
  /// away.
  static Color paceColor(double gap) {
    const stops = <(double, Color)>[
      (-0.10, Color(0xFF6E9A5E)),
      (-0.04, Color(0xFFCFA24A)),
      (0.00, Color(0xFFC77A44)),
      (0.08, Color(0xFFB4523C)),
    ];
    if (gap <= stops.first.$1) return stops.first.$2;
    for (var i = 1; i < stops.length; i++) {
      final (x1, c1) = stops[i];
      if (gap <= x1) {
        final (x0, c0) = stops[i - 1];
        return Color.lerp(c0, c1, (gap - x0) / (x1 - x0))!;
      }
    }
    return stops.last.$2;
  }

  static List<int> axisDays(int daysInMonth) => [
    1,
    for (var d = 5; d < daysInMonth - 2; d += 5) d,
    if (daysInMonth > 1) daysInMonth,
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final over = snapshot.isOverBudget;
    final underPace = snapshot.isUnderPace;
    final delta = snapshot.paceDelta.abs().round();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: !snapshot.hasBudget
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'Set budgets to see pace',
                  style: TextStyle(color: c.muted, fontWeight: FontWeight.w500),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  over ? 'Over budget' : 'Budget left',
                  style: TextStyle(fontSize: 13, color: c.muted),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '\$${_fmt(snapshot.remaining.abs())}',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.2,
                        color: over ? c.bad : c.text,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'of \$${_fmt(snapshot.totalBudgeted)}',
                      style: TextStyle(fontSize: 15, color: c.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                StatusPill(
                  label: underPace
                      ? '\$$delta under pace'
                      : '\$$delta over pace',
                  icon: underPace
                      ? Icons.trending_down_rounded
                      : Icons.trending_up_rounded,
                  background: underPace
                      ? c.goodTint
                      : c.bad.withValues(alpha: 0.16),
                  foreground: underPace ? c.good : c.bad,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 200,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _BudgetPaceChartPainter(
                      snapshot: snapshot,
                      dashColor: c.muted,
                      gridColor: c.line,
                      labelColor: c.muted,
                      dotFill: c.card,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const _ChartLegend(),
              ],
            ),
    );
  }

  static String _fmt(double value) {
    final whole = value.abs().round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
      buf.write(whole[i]);
    }
    return buf.toString();
  }
}

/// Explains the two lines: the dashed even-pace line and the solid spend line.
class _ChartLegend extends StatelessWidget {
  const _ChartLegend();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        _LegendItem(dashed: true, label: 'Even pace to budget'),
        _LegendItem(dashed: false, label: 'Your spending so far'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.dashed, required this.label});

  final bool dashed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 26,
          height: 10,
          child: CustomPaint(
            painter: _LegendSwatchPainter(
              dashed: dashed,
              dashColor: context.colors.muted,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: context.colors.muted),
        ),
      ],
    );
  }
}

/// Mini sample of each chart line, drawn with the same strokes as the chart.
class _LegendSwatchPainter extends CustomPainter {
  _LegendSwatchPainter({required this.dashed, required this.dashColor});

  final bool dashed;
  final Color dashColor;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final a = Offset(2, y);
    final b = Offset(size.width - 2, y);
    if (dashed) {
      final paint = Paint()
        ..color = dashColor
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(a, Offset(a.dx + 8, y), paint);
      canvas.drawLine(Offset(b.dx - 8, y), b, paint);
    } else {
      // Green-to-red, as the spend line changes colour against the pace line.
      canvas.drawLine(
        a,
        b,
        Paint()
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(
            a,
            b,
            [
              BudgetPaceChartCard.paceColor(-0.10),
              BudgetPaceChartCard.paceColor(0.0),
              BudgetPaceChartCard.paceColor(0.08),
            ],
            [0.0, 0.5, 1.0],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LegendSwatchPainter oldDelegate) =>
      oldDelegate.dashed != dashed || oldDelegate.dashColor != dashColor;
}

class _BudgetPaceChartPainter extends CustomPainter {
  _BudgetPaceChartPainter({
    required this.snapshot,
    required this.dashColor,
    required this.gridColor,
    required this.labelColor,
    required this.dotFill,
    this.showAxis = true,
    this.strokeScale = 1,
  });

  final BudgetPaceSnapshot snapshot;
  final Color dashColor;
  final Color gridColor;
  final Color labelColor;
  final Color dotFill;
  final bool showAxis;
  final double strokeScale;

  @override
  void paint(Canvas canvas, Size size) {
    final points = snapshot.cumulativePoints;
    if (points.isEmpty || snapshot.daysInMonth <= 0) return;

    const pad = 8.0;
    final axisH = showAxis ? 18.0 : 0.0;
    final chartW = size.width - pad * 2;
    final chartH = size.height - pad * 2 - axisH;
    if (chartW <= 0 || chartH <= 0) return;

    final maxY = math.max(snapshot.totalBudgeted, snapshot.spentToDate);
    final yMax = maxY <= 0 ? 1.0 : maxY * 1.08;

    Offset map(double day, double spent) {
      final xNorm = snapshot.daysInMonth <= 1
          ? 0.0
          : ((day - 1) / (snapshot.daysInMonth - 1)).clamp(0.0, 1.0);
      final yNorm = (spent / yMax).clamp(0.0, 1.0);
      return Offset(pad + xNorm * chartW, pad + chartH * (1 - yNorm));
    }

    if (showAxis) {
      _dayAxis(canvas, map, chartH + pad);
    } else {
      canvas.drawLine(
        Offset(pad, chartH + pad),
        Offset(size.width - pad, chartH + pad),
        Paint()
          ..color = gridColor
          ..strokeWidth = 1,
      );
    }

    final actual = <Offset>[
      map(1, 0),
      for (final p in points) map(p.day.toDouble(), p.cumulativeSpent),
    ];
    // Gap to the even-pace line at each point, as a share of the budget.
    double gapAt(double day, double spent) {
      final budget = snapshot.totalBudgeted;
      if (budget <= 0) return 0;
      final dim = snapshot.daysInMonth;
      final expected = dim <= 1 ? budget : budget * (day - 1) / (dim - 1);
      return (spent - expected) / budget;
    }

    final colors = <Color>[
      BudgetPaceChartCard.paceColor(-0.10),
      for (final p in points)
        BudgetPaceChartCard.paceColor(
          gapAt(p.day.toDouble(), p.cumulativeSpent),
        ),
    ];

    final budgetLine = Paint()
      ..color = dashColor
      ..strokeWidth = 2 * strokeScale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    _dashed(
      canvas,
      map(1, 0),
      map(snapshot.daysInMonth.toDouble(), snapshot.totalBudgeted),
      budgetLine,
    );

    // Each segment blends between its endpoints' colours, so the line shifts
    // smoothly from green to yellow/orange to red as it approaches and
    // crosses the budget line.
    for (var i = 1; i < actual.length; i++) {
      final a = actual[i - 1];
      final b = actual[i];
      if ((b - a).distance < 0.5) continue;
      canvas.drawLine(
        a,
        b,
        Paint()
          ..strokeWidth = 3.5 * strokeScale
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(a, b, [colors[i - 1], colors[i]]),
      );
    }

    final last = actual.last;
    final dot = colors.last;
    canvas.drawCircle(last, 6 * strokeScale, Paint()..color = dotFill);
    canvas.drawCircle(
      last,
      5 * strokeScale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * strokeScale
        ..color = dot,
    );
  }

  /// Faint vertical guides with day labels underneath the plot.
  void _dayAxis(
    Canvas canvas,
    Offset Function(double day, double spent) map,
    double baselineY,
  ) {
    final guide = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final day in BudgetPaceChartCard.axisDays(snapshot.daysInMonth)) {
      final x = map(day.toDouble(), 0).dx;
      canvas.drawLine(Offset(x, 8), Offset(x, baselineY), guide);
      final label = TextPainter(
        text: TextSpan(
          text: '$day',
          style: TextStyle(fontSize: 11, color: labelColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x - label.width / 2, baselineY + 4));
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final dist = (b - a).distance;
    if (dist < 1) return;
    const dash = 9.0;
    const gap = 6.0;
    final dir = (b - a) / dist;
    var drawn = 0.0;
    while (drawn < dist) {
      canvas.drawLine(
        a + dir * drawn,
        a + dir * math.min(drawn + dash, dist),
        paint,
      );
      drawn += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _BudgetPaceChartPainter oldDelegate) => true;
}

/// Small pace chart for the Wallet's Cash Flow card: no axis or legend.
class BudgetPaceMiniChart extends StatelessWidget {
  const BudgetPaceMiniChart({
    super.key,
    required this.snapshot,
    this.width = 150,
    this.height = 60,
  });

  final BudgetPaceSnapshot snapshot;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _BudgetPaceChartPainter(
          snapshot: snapshot,
          dashColor: c.muted,
          gridColor: c.line,
          labelColor: c.muted,
          dotFill: c.card,
          showAxis: false,
          strokeScale: 0.7,
        ),
      ),
    );
  }
}
