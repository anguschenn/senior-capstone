import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../utils/app_helpers.dart';

class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({super.key, required this.subscriptions});

  final List<DetectedSubscription> subscriptions;

  @override
  Widget build(BuildContext context) {
    // Read-only list of recurring charges detected from synced transaction data.
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // This page is intentionally simple: it is just the full subscriptions list.
          const Text('Subs', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Recurring ${subscriptions.length} subscriptions'),
          const SizedBox(height: 16),
          if (subscriptions.isEmpty)
            const Text('No recurring subscriptions detected yet.'),
          ...subscriptions.map(
            (sub) => ListTile(
              leading: const Icon(Icons.subscriptions_outlined),
              title: Text(sub.merchant),
              subtitle: Text('Renews ${shortDate(sub.nextChargeDate)} • ${sub.frequency}'),
              trailing: Text(formatMoney(sub.amount, signed: false)),
            ),
          ),
        ],
      ),
    );
  }
}
