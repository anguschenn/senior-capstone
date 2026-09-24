import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/budget_pace.dart';

/// Monthly budget remaining chart: solid actual spend, dashed even-pace line.
class BudgetPaceChartCard extends StatelessWidget {
  const BudgetPaceChartCard({
    super.key,
    required this.snapshot,
  });

  final BudgetPaceSnapshot snapshot;

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
                  height: 88,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _BudgetPaceChartPainter(snapshot: snapshot),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
    final chartW = size.width - pad * 2;
    final chartH = size.height - pad * 2;
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

    final actual = <Offset>[
      map(1, 0),
      for (final p in points) map(p.day.toDouble(), p.cumulativeSpent),
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

    final path = Path()..moveTo(actual.first.dx, actual.first.dy);
    for (var i = 1; i < actual.length; i++) {
      path.lineTo(actual[i].dx, actual[i].dy);
    }
    final over = !snapshot.isUnderPace;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = ui.Gradient.linear(
          Offset(actual.first.dx, 0),
          Offset(math.max(actual.last.dx, actual.first.dx + 1), 0),
          over
              ? const [Color(0xFFF9A825), Color(0xFFE53935)]
              : const [Color(0xFFF9A825), Color(0xFF2E7D32)],
        ),
    );

    final last = actual.last;
    final dot = over ? const Color(0xFFE53935) : const Color(0xFF2E7D32);
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

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final dist = (b - a).distance;
    if (dist < 1) return;
    const dash = 9.0;
    const gap = 6.0;
    final dir = (b - a) / dist;
    var drawn = 0.0;
    while (drawn < dist) {
      canvas.drawLine(a + dir * drawn, a + dir * math.min(drawn + dash, dist), paint);
      drawn += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _BudgetPaceChartPainter oldDelegate) => true;
}
