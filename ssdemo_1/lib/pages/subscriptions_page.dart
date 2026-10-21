import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import '../widgets/common/ui.dart';

class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({
    super.key,
    required this.subscriptions,
    required this.monthlyTotal,
    required this.onConfirm,
    required this.onDismiss,
  });

  final List<DetectedSubscription> subscriptions;
  final double monthlyTotal;
  final void Function(String id) onConfirm;
  final void Function(String id) onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final confirmed = subscriptions.where((s) => !s.needsConfirmation).toList();
    final pending = subscriptions.where((s) => s.needsConfirmation).toList();

    return SafeArea(
      bottom: false,
      child: ListView(
        // Clears the floating tab bar.
        padding: EdgeInsets.only(bottom: 24 + tabBarClearance(context)),
        children: [
          const LargeTitle('Subscriptions'),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            decoration: BoxDecoration(
              color: AppPalette.subscriptions,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: c.cardShadow,
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: DefaultTextStyle(
              style: const TextStyle(color: AppPalette.ink),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Monthly Total',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatMoney(monthlyTotal, signed: false),
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${confirmed.length} recurring charge${confirmed.length == 1 ? '' : 's'} detected',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ),

          if (pending.isNotEmpty) ...[
            const SectionHeader('Needs Review'),
            ...pending.map(
              (sub) => _PendingSubscriptionCard(
                sub: sub,
                onConfirm: () => onConfirm(sub.id),
                onDismiss: () => onDismiss(sub.id),
              ),
            ),
          ],

          if (confirmed.isEmpty && pending.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'No recurring subscriptions detected yet.',
                style: TextStyle(color: c.muted),
              ),
            )
          else if (confirmed.isNotEmpty) ...[
            const SectionHeader('Confirmed'),
            Section(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              child: Column(
                children: [
                  for (final (i, sub) in confirmed.indexed) ...[
                    if (i > 0)
                      Divider(height: 0.5, thickness: 0.5, color: c.line),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: InfoRow(
                        leading: CategoryDot(
                          color: AppPalette.subscriptions,
                          icon: iconForBudgetCategory('Subscriptions'),
                        ),
                        title: sub.merchant,
                        subtitle:
                            'Renews ${shortDate(sub.effectiveNextChargeDate)} · ${sub.frequency}',
                        trailing: Text(
                          formatMoney(sub.amount, signed: false),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        showChevron: false,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PendingSubscriptionCard extends StatelessWidget {
  const _PendingSubscriptionCard({
    required this.sub,
    required this.onConfirm,
    required this.onDismiss,
  });

  final DetectedSubscription sub;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Is this a subscription?',
            style: TextStyle(fontSize: 12.5, color: c.muted),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  sub.merchant,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                formatMoney(sub.amount, signed: false),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Renews ${shortDate(sub.effectiveNextChargeDate)} · ${sub.frequency}',
            style: TextStyle(fontSize: 13, color: c.muted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: onConfirm,
                  child: const Text('Yes'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: onDismiss,
                  style: OutlinedButton.styleFrom(foregroundColor: c.bad),
                  child: const Text('No'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
