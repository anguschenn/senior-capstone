import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';

class CashFlowCategoryChart extends StatefulWidget {
  const CashFlowCategoryChart({super.key, required this.spendingByCategory});

  final Map<String, double> spendingByCategory;

  @override
  State<CashFlowCategoryChart> createState() => _CashFlowCategoryChartState();
}

class _CashFlowCategoryChartState extends State<CashFlowCategoryChart> {
  static const _chartSize = 176.0;
  String? _hoveredCategory;

  List<MapEntry<String, double>> get _categories {
    final categories =
        widget.spendingByCategory.entries
            .where((entry) => entry.value > 0)
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return categories;
  }

  String? _categoryAt(Offset position, List<MapEntry<String, double>> data) {
    final center = const Offset(_chartSize / 2, _chartSize / 2);
    final delta = position - center;
    final radius = _chartSize / 2;
    if (delta.distance > radius || data.isEmpty) return null;

    final total = data.fold<double>(0, (sum, entry) => sum + entry.value);
    var angle = (math.atan2(delta.dy, delta.dx) + math.pi / 2) % (2 * math.pi);
    if (angle < 0) angle += 2 * math.pi;
    var boundary = 0.0;
    for (final entry in data) {
      boundary += entry.value / total * 2 * math.pi;
      if (angle <= boundary) return entry.key;
    }
    return data.last.key;
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    final c = context.colors;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Spending by category',
            style: TextStyle(
              color: c.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          if (categories.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'No spending in this period',
                  style: TextStyle(color: c.muted),
                ),
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in categories)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colorForDetailedCategory(entry.key),
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  entry.key,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: c.text, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: _chartSize,
                  height: _chartSize,
                  child: MouseRegion(
                    onHover: (event) {
                      final category = _categoryAt(
                        event.localPosition,
                        categories,
                      );
                      if (category != _hoveredCategory) {
                        setState(() => _hoveredCategory = category);
                      }
                    },
                    onExit: (_) {
                      if (_hoveredCategory != null) {
                        setState(() => _hoveredCategory = null);
                      }
                    },
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _SpendingPiePainter(categories),
                          ),
                        ),
                        if (_hoveredCategory case final category?)
                          Positioned(
                            top: 4,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(
                              child: Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: c.text,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 5,
                                    ),
                                    child: Text(
                                      '$category - ${formatMoney(widget.spendingByCategory[category]!, signed: false)}',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: c.card,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SpendingPiePainter extends CustomPainter {
  const _SpendingPiePainter(this.categories);

  final List<MapEntry<String, double>> categories;

  @override
  void paint(Canvas canvas, Size size) {
    final total = categories.fold<double>(0, (sum, entry) => sum + entry.value);
    if (total <= 0) return;

    final bounds = Rect.fromLTWH(0, 0, size.width, size.height);
    var startAngle = -math.pi / 2;
    for (final entry in categories) {
      final sweepAngle = entry.value / total * 2 * math.pi;
      canvas.drawArc(
        bounds,
        startAngle,
        sweepAngle,
        true,
        Paint()..color = colorForDetailedCategory(entry.key),
      );
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _SpendingPiePainter oldDelegate) =>
      oldDelegate.categories != categories;
}
