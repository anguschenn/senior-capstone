import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../utils/app_helpers.dart';

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
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = subscriptions.where((s) => !s.needsConfirmation).toList();
    final pending = subscriptions.where((s) => s.needsConfirmation).toList();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Subscriptions',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '${confirmed.length} recurring charge${confirmed.length == 1 ? '' : 's'} detected',
          ),
          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Monthly Total',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                Text(
                  formatMoney(monthlyTotal, signed: false),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          if (pending.isNotEmpty) ...[
            const Text(
              'Needs Review',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ...pending.map(
              (sub) => _PendingSubscriptionCard(
                sub: sub,
                onConfirm: () => onConfirm(sub.id),
                onDismiss: () => onDismiss(sub.id),
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (confirmed.isEmpty && pending.isEmpty)
            const Text('No recurring subscriptions detected yet.')
          else if (confirmed.isNotEmpty) ...[
            if (pending.isNotEmpty)
              const Text(
                'Confirmed',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            if (pending.isNotEmpty) const SizedBox(height: 8),
            ...confirmed.map(
              (sub) => ListTile(
                leading: const Icon(Icons.subscriptions_outlined),
                title: Text(sub.merchant),
                subtitle: Text(
                  'Renews ${shortDate(sub.nextChargeDate)} • ${sub.frequency}',
                ),
                trailing: Text(formatMoney(sub.amount, signed: false)),
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
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.help_outline,
                  size: 18,
                  color: colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 6),
                Text(
                  'Is this a subscription?',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSecondaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  sub.merchant,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(formatMoney(sub.amount, signed: false)),
              ],
            ),
            Text(
              'Renews ${shortDate(sub.nextChargeDate)} • ${sub.frequency}',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: onConfirm,
                  child: const Text('Yes, subscription'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onDismiss,
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.error,
                  ),
                  child: const Text('Not a subscription'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
