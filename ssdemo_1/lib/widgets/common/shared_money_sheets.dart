import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';
import 'ui.dart';

/// How far back a payback's purchase can be.
const kPaybackLookback = Duration(days: 120);

/// Purchases [inflow] can pay back, in the order the picker lists them.
/// The user always picks; nothing is chosen for them. Split purchases come
/// first, then purchases in the week before it that are at least its size,
/// then the rest, newest first. A purchase is offered only while it has
/// room left for all of [inflow] (what friends pay back never exceeds it).
List<AppTransaction> linkablePurchases(
  AppTransaction inflow,
  List<AppTransaction> transactions,
) {
  final earliest = inflow.date.subtract(kPaybackLookback);
  final candidates = transactions.where((tx) {
    if (tx.kind != TxKind.spend || tx.id == inflow.id) return false;
    if (tx.date.isAfter(inflow.date) || tx.date.isBefore(earliest)) {
      return false;
    }
    final room = tx.displayAmount - tx.paidBack;
    return room + 0.005 >= inflow.displayAmount;
  }).toList();
  int rank(AppTransaction tx) {
    if (tx.sharedAmount > 0) return 0;
    final days = inflow.date.difference(tx.date).inDays;
    if (days <= 7) return 1;
    return 2;
  }

  candidates.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    final byDate = b.date.compareTo(a.date);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });
  return candidates;
}

Widget _sheetHeader(BuildContext context, String title, String subtitle) {
  final c = context.colors;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Center(
        child: Container(
          width: 36,
          height: 5,
          decoration: BoxDecoration(
            color: c.line,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        title,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      Text(subtitle, style: TextStyle(color: c.muted, fontSize: 13)),
      const SizedBox(height: 12),
    ],
  );
}

const _sheetShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
);

/// Lets the user pick the purchase [inflow] pays back. Null when closed.
Future<AppTransaction?> showLinkPurchaseSheet({
  required BuildContext context,
  required AppTransaction inflow,
  required List<AppTransaction> transactions,
}) {
  final purchases = linkablePurchases(inflow, transactions);
  return showModalBottomSheet<AppTransaction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: _sheetShape,
    builder: (sheetContext) {
      final c = sheetContext.colors;
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _sheetHeader(
              sheetContext,
              'Link to a purchase',
              '${inflow.name} · ${dollars(inflow.displayAmount)} on '
                  '${shortDate(inflow.date)}. Pick the purchase it pays back: '
                  'it then counts in that purchase\'s month and category.',
            ),
            if (purchases.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No purchase of at least ${dollars(inflow.displayAmount)} '
                    'in the last 120 days.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.muted),
                  ),
                ),
              ),
            for (final tx in purchases)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: cardDecoration(sheetContext),
                child: ListTile(
                  key: ValueKey('link-${tx.id}'),
                  onTap: () => Navigator.of(sheetContext).pop(tx),
                  title: Text(tx.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      shortDate(tx.date, alwaysShowYear: true),
                      if (tx.toGetBack > 0)
                        '${dollars(tx.toGetBack)} to get back',
                    ].join(' · '),
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  trailing: Text(
                    dollars(tx.displayAmount),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// Asks how much of [purchase] others will pay back: an amount, or a
/// number of people splitting it evenly. Returns the amount, 0 to remove
/// the split, or null when closed.
Future<double?> showSplitPurchaseSheet({
  required BuildContext context,
  required AppTransaction purchase,
}) {
  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: _sheetShape,
    builder: (_) => _SplitPurchaseSheet(purchase: purchase),
  );
}

/// Others' part of [total] split evenly between [people] (you included).
double othersShareOf(double total, int people) {
  if (people < 2) return 0;
  final yours = (total / people * 100).roundToDouble() / 100;
  return ((total - yours) * 100).roundToDouble() / 100;
}

class _SplitPurchaseSheet extends StatefulWidget {
  const _SplitPurchaseSheet({required this.purchase});

  final AppTransaction purchase;

  @override
  State<_SplitPurchaseSheet> createState() => _SplitPurchaseSheetState();
}

class _SplitPurchaseSheetState extends State<_SplitPurchaseSheet> {
  bool _byPeople = true;
  late final _controller = TextEditingController(
    text: widget.purchase.sharedAmount > 0
        ? widget.purchase.sharedAmount.toStringAsFixed(2)
        : '2',
  );

  @override
  void initState() {
    super.initState();
    _byPeople = widget.purchase.sharedAmount <= 0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _others {
    final total = widget.purchase.displayAmount;
    final text = _controller.text.trim();
    if (_byPeople) {
      final people = int.tryParse(text);
      if (people == null || people < 2) return null;
      return othersShareOf(total, people);
    }
    final amount = double.tryParse(text.replaceAll(r'$', ''));
    if (amount == null || amount <= 0 || amount >= total + 0.005) return null;
    return (amount * 100).roundToDouble() / 100;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final purchase = widget.purchase;
    final others = _others;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sheetHeader(
            context,
            'Split with others',
            '${purchase.name} · ${dollars(purchase.displayAmount)}. It still '
                'counts in full until they pay you back; link their payments '
                'to it when they arrive.',
          ),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Split evenly')),
              ButtonSegment(value: false, label: Text('They owe')),
            ],
            selected: {_byPeople},
            onSelectionChanged: (v) => setState(() {
              _byPeople = v.first;
              _controller.text = _byPeople ? '2' : '';
            }),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('split-input'),
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(decimal: !_byPeople),
            decoration: InputDecoration(
              labelText: _byPeople
                  ? 'People, you included'
                  : 'Amount others will pay you',
              prefixText: _byPeople ? null : r'$',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          Text(
            others == null
                ? (_byPeople
                      ? 'Enter 2 or more people.'
                      : 'Enter less than ${dollars(purchase.displayAmount)}.')
                : 'Your share ${dollars(purchase.displayAmount - others)} · '
                      '${dollars(others)} to get back',
            style: TextStyle(color: c.muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (purchase.sharedAmount > 0)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(0.0),
                  child: const Text('Remove split'),
                ),
              const Spacer(),
              FilledButton(
                onPressed: others == null
                    ? null
                    : () => Navigator.of(context).pop(others),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the user can do with one transaction from Activity.
enum TransactionAction { split, linkPayback, unlinkPayback, notPayback }

/// The actions offered for [tx]: split a purchase; link, unlink or mark
/// as "not a payback" for money from a person.
List<TransactionAction> actionsFor(AppTransaction tx) {
  if (tx.kind == TxKind.spend) return const [TransactionAction.split];
  if (tx.kind == TxKind.payback) {
    return const [TransactionAction.unlinkPayback];
  }
  if (tx.isPeerToPeerInflow) {
    return const [TransactionAction.linkPayback, TransactionAction.notPayback];
  }
  return const [];
}

Future<TransactionAction?> showTransactionActionsSheet({
  required BuildContext context,
  required AppTransaction tx,
}) {
  final actions = actionsFor(tx);
  final paidFor = AppTransaction.purchaseByPaybackId[tx.id];
  String label(TransactionAction a) => switch (a) {
    TransactionAction.split =>
      tx.sharedAmount > 0 ? 'Edit split' : 'Split with others',
    TransactionAction.linkPayback => 'Link to a purchase',
    TransactionAction.unlinkPayback =>
      paidFor == null ? 'Unlink payback' : 'Unlink from ${paidFor.name}',
    TransactionAction.notPayback => 'Not a payback: pick a category',
  };
  IconData icon(TransactionAction a) => switch (a) {
    TransactionAction.split => Icons.call_split_rounded,
    TransactionAction.linkPayback => Icons.link_rounded,
    TransactionAction.unlinkPayback => Icons.link_off_rounded,
    TransactionAction.notPayback => Icons.sell_outlined,
  };
  return showModalBottomSheet<TransactionAction>(
    context: context,
    useSafeArea: true,
    shape: _sheetShape,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sheetHeader(
            sheetContext,
            tx.name,
            '${shortDate(tx.date, alwaysShowYear: true)} · '
            '${dollars(tx.displayAmount)}',
          ),
          for (final a in actions)
            ListTile(
              key: ValueKey('action-${a.name}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon(a)),
              title: Text(label(a)),
              onTap: () => Navigator.of(sheetContext).pop(a),
            ),
        ],
      ),
    ),
  );
}
