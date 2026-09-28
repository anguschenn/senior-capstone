import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/budget_pace.dart';

/// Monthly budget remaining chart: solid actual spend, dashed even-pace line.
class BudgetPaceChartCard extends StatelessWidget {
  const BudgetPaceChartCard({super.key, required this.snapshot});

  final BudgetPaceSnapshot snapshot;

  /// X-axis labels: day 1, every 5th day, and the month's last day. A 5-day
  /// mark within 2 days of the end is dropped so labels don't collide.
  /// Line colour for a point [gap] above (+) or below (-) the even-pace line,
  /// as a share of the month's budget: green well under, yellow then orange as
  /// it nears the line, red once it crosses and pulls away.
  static Color paceColor(double gap) {
    const stops = <(double, Color)>[
      (-0.10, Color(0xFF2E7D32)),
      (-0.04, Color(0xFFF9A825)),
      (0.00, Color(0xFFEF6C00)),
      (0.08, Color(0xFFE53935)),
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
    final over = snapshot.isOverBudget;
    final underPace = snapshot.isUnderPace;
    final tone = underPace ? const Color(0xFF1B5E20) : const Color(0xFFC62828);
    final delta = snapshot.paceDelta.abs().round();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withValues(alpha: 0.22)),
      ),
      child: !snapshot.hasBudget
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'Set budgets to see pace',
                  style: TextStyle(
                    color: Colors.black54,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            )
          : Column(
              children: [
                Text(
                  over
                      ? '\$${_fmt(snapshot.remaining.abs())} over'
                      : '\$${_fmt(snapshot.remaining)} left',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'out of \$${_fmt(snapshot.totalBudgeted)} budgeted',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF8A8A8A),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 200,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _BudgetPaceChartPainter(snapshot: snapshot),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: tone,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    underPace ? '\$$delta under pace' : '\$$delta over pace',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
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

class _BudgetPaceChartPainter extends CustomPainter {
  _BudgetPaceChartPainter({required this.snapshot});

  final BudgetPaceSnapshot snapshot;

  @override
  void paint(Canvas canvas, Size size) {
    final points = snapshot.cumulativePoints;
    if (points.isEmpty || snapshot.daysInMonth <= 0) return;

    const pad = 8.0;
    const axisH = 18.0;
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

    _dayAxis(canvas, map, chartH + pad);

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
      ..color = const Color(0xFF1B5E20)
      ..strokeWidth = 4
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
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(a, b, [colors[i - 1], colors[i]]),
      );
    }

    final last = actual.last;
    final dot = colors.last;
    canvas.drawCircle(last, 6, Paint()..color = Colors.white);
    canvas.drawCircle(
      last,
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
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
      ..color = Colors.black.withValues(alpha: 0.06)
      ..strokeWidth = 1;
    for (final day in BudgetPaceChartCard.axisDays(snapshot.daysInMonth)) {
      final x = map(day.toDouble(), 0).dx;
      canvas.drawLine(Offset(x, 8), Offset(x, baselineY), guide);
      final label = TextPainter(
        text: TextSpan(
          text: '$day',
          style: const TextStyle(fontSize: 11, color: Color(0xFF8A8A8A)),
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
