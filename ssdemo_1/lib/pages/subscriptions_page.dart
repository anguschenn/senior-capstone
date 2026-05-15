import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../utils/app_helpers.dart';

class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({
    super.key,
    required this.subscriptions,
    required this.monthlyTotal,
  });

  final List<DetectedSubscription> subscriptions;
  final double monthlyTotal;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

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
            '${subscriptions.length} recurring charge${subscriptions.length == 1 ? '' : 's'} detected',
          ),
          const SizedBox(height: 16),

          // Monthly total summary card
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

          if (subscriptions.isEmpty)
            const Text('No recurring subscriptions detected yet.')
          else
            ...subscriptions.map(
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
      ),
    );
  }
}
