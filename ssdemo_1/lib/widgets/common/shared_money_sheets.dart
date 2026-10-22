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

/// A list row on a card: the card is the row's Material, so its ink
/// splash and check box show.
class _CardTile extends StatelessWidget {
  const _CardTile({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: context.colors.card,
    shape: cardShape(context),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

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
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _CardTile(
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

/// "Your share \$82.16 · \$15.16 to get back (\$67.00 already paid back)".
String splitPreview(AppTransaction purchase, double others) {
  final left = others - purchase.paidBack;
  final paid = purchase.paidBack > 0
      ? ' (${dollars(purchase.paidBack)} already paid back)'
      : '';
  return 'Your share ${dollars(purchase.displayAmount - others)} · '
      '${dollars(left > 0 ? left : 0)} to get back$paid';
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
          SegmentedTabs<bool>(
            margin: EdgeInsets.zero,
            value: _byPeople,
            segments: const {true: 'Split evenly', false: 'They owe'},
            onChanged: (v) => setState(() {
              _byPeople = v;
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
                : splitPreview(purchase, others),
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

/// Payments from a person that could pay back [purchase]: not linked yet,
/// not marked "not a payback" ([notPaybackIds]), from the purchase's day up
/// to 120 days after, and no bigger than what is left of it. The two weeks
/// after the purchase come first, closest first; then the rest, newest
/// first. The user picks; nothing is chosen for them.
List<AppTransaction> linkablePayments(
  AppTransaction purchase,
  List<AppTransaction> transactions, {
  Set<String> notPaybackIds = const {},
}) {
  final latest = purchase.date.add(kPaybackLookback);
  final room = purchase.displayAmount - purchase.paidBack;
  final candidates = transactions.where((tx) {
    if (!tx.isPeerToPeerInflow || tx.kind == TxKind.payback) return false;
    if (notPaybackIds.contains(tx.id)) return false;
    if (tx.date.isBefore(purchase.date) || tx.date.isAfter(latest)) {
      return false;
    }
    return tx.displayAmount <= room + 0.005;
  }).toList();
  bool soon(AppTransaction tx) =>
      tx.date.difference(purchase.date).inDays <= 14;
  candidates.sort((a, b) {
    if (soon(a) != soon(b)) return soon(a) ? -1 : 1;
    final byDate = soon(a)
        ? a.date.compareTo(b.date)
        : b.date.compareTo(a.date);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });
  return candidates;
}

/// The payments linked to [purchase], oldest first.
List<AppTransaction> paybacksOf(
  AppTransaction purchase,
  List<AppTransaction> transactions,
) =>
    transactions
        .where(
          (tx) => AppTransaction.purchaseByPaybackId[tx.id]?.id == purchase.id,
        )
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

/// Lets the user tick friends' payments that pay back [purchase], several
/// at once (two friends paying their share). Null when closed.
Future<List<AppTransaction>?> showLinkPaymentSheet({
  required BuildContext context,
  required AppTransaction purchase,
  required List<AppTransaction> transactions,
  Set<String> notPaybackIds = const {},
}) {
  final payments = linkablePayments(
    purchase,
    transactions,
    notPaybackIds: notPaybackIds,
  );
  return showModalBottomSheet<List<AppTransaction>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: _sheetShape,
    builder: (_) => _LinkPaymentsSheet(purchase: purchase, payments: payments),
  );
}

class _LinkPaymentsSheet extends StatefulWidget {
  const _LinkPaymentsSheet({required this.purchase, required this.payments});

  final AppTransaction purchase;
  final List<AppTransaction> payments;

  @override
  State<_LinkPaymentsSheet> createState() => _LinkPaymentsSheetState();
}

class _LinkPaymentsSheetState extends State<_LinkPaymentsSheet> {
  final _picked = <String>{};

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final purchase = widget.purchase;
    final room = purchase.displayAmount - purchase.paidBack;
    final chosen = [
      for (final p in widget.payments)
        if (_picked.contains(p.id)) p,
    ];
    final total = chosen.fold<double>(0, (sum, p) => sum + p.displayAmount);
    final fits = total <= room + 0.005;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              children: [
                _sheetHeader(
                  context,
                  'Add a payback',
                  '${purchase.name} · ${dollars(purchase.displayAmount)} on '
                      '${shortDate(purchase.date)}. Tick the money friends '
                      'sent for it. Room left ${dollars(room)}.',
                ),
                if (widget.payments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No money from friends fits this purchase yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.muted),
                      ),
                    ),
                  ),
                for (final tx in widget.payments)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CardTile(
                      child: CheckboxListTile(
                        key: ValueKey('payment-${tx.id}'),
                        value: _picked.contains(tx.id),
                        onChanged: (on) => setState(
                          () => on == true
                              ? _picked.add(tx.id)
                              : _picked.remove(tx.id),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(tx.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          shortDate(tx.date, alwaysShowYear: true),
                          style: TextStyle(color: c.muted, fontSize: 12),
                        ),
                        secondary: Text(
                          '+${dollars(tx.displayAmount)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    chosen.isEmpty
                        ? ''
                        : fits
                        ? '${dollars(total)} of ${dollars(room)}'
                        : 'More than the ${dollars(room)} left',
                    style: TextStyle(
                      color: fits ? c.muted : c.bad,
                      fontSize: 13,
                    ),
                  ),
                ),
                FilledButton(
                  key: const ValueKey('link-payments'),
                  onPressed: chosen.isEmpty || !fits
                      ? null
                      : () => Navigator.of(context).pop(chosen),
                  child: Text(
                    chosen.length > 1 ? 'Link ${chosen.length}' : 'Link',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the user can do with one transaction from Activity.
enum TransactionAction {
  split,
  addPayback,
  linkPayback,
  unlinkPayback,
  notPayback,
}

/// The actions offered for [tx]: split a purchase or add a payback to it;
/// link, unlink or mark as "not a payback" for money from a person.
List<TransactionAction> actionsFor(AppTransaction tx) {
  if (tx.kind == TxKind.spend) {
    return const [TransactionAction.split, TransactionAction.addPayback];
  }
  if (tx.kind == TxKind.payback) {
    return const [TransactionAction.unlinkPayback];
  }
  if (tx.isPeerToPeerInflow) {
    return const [TransactionAction.linkPayback, TransactionAction.notPayback];
  }
  return const [];
}

/// The chosen action, and the payment it is about when it isn't [tx]
/// itself (unlinking one payback from a purchase).
typedef TransactionChoice = ({TransactionAction action, AppTransaction? other});

/// A purchase shows what friends paid back and what's left, with each
/// linked payment and a way to unlink it.
Future<TransactionChoice?> showTransactionActionsSheet({
  required BuildContext context,
  required AppTransaction tx,
  List<AppTransaction> transactions = const [],
}) {
  final actions = actionsFor(tx);
  final paidFor = AppTransaction.purchaseByPaybackId[tx.id];
  final paybacks = tx.kind == TxKind.spend
      ? paybacksOf(tx, transactions)
      : const <AppTransaction>[];
  String label(TransactionAction a) => switch (a) {
    TransactionAction.split =>
      tx.sharedAmount > 0 ? 'Edit split' : 'Split with others',
    TransactionAction.addPayback => 'Add a payback',
    TransactionAction.linkPayback => 'Link to a purchase',
    TransactionAction.unlinkPayback =>
      paidFor == null ? 'Unlink payback' : 'Unlink from ${paidFor.name}',
    TransactionAction.notPayback => 'Not a payback: pick a category',
  };
  IconData icon(TransactionAction a) => switch (a) {
    TransactionAction.split => Icons.call_split_rounded,
    TransactionAction.addPayback => Icons.add_link_rounded,
    TransactionAction.linkPayback => Icons.link_rounded,
    TransactionAction.unlinkPayback => Icons.link_off_rounded,
    TransactionAction.notPayback => Icons.sell_outlined,
  };
  final summary = [
    '${shortDate(tx.date, alwaysShowYear: true)} · '
        '${dollars(tx.displayAmount)}',
    if (tx.paidBack > 0) '${dollars(tx.paidBack)} paid back',
    if (tx.toGetBack > 0)
      '${dollars(tx.toGetBack)} to get back'
    else if (tx.sharedAmount > 0)
      'Settled',
  ].join(' · ');
  return showModalBottomSheet<TransactionChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: _sheetShape,
    builder: (sheetContext) {
      final c = sheetContext.colors;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sheetHeader(sheetContext, tx.name, summary),
            if (paybacks.isNotEmpty) ...[
              Text(
                'PAID BACK BY',
                style: TextStyle(
                  color: c.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final p in paybacks)
                ListTile(
                  key: ValueKey('payback-${p.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${shortDate(p.date, alwaysShowYear: true)} · '
                    '+${dollars(p.displayAmount)}',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  trailing: IconButton(
                    key: ValueKey('unlink-${p.id}'),
                    tooltip: 'Unlink',
                    icon: const Icon(Icons.link_off_rounded),
                    onPressed: () => Navigator.of(
                      sheetContext,
                    ).pop((action: TransactionAction.unlinkPayback, other: p)),
                  ),
                ),
              Divider(height: 16, thickness: 0.5, color: c.line),
            ],
            for (final a in actions)
              ListTile(
                key: ValueKey('action-${a.name}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(icon(a)),
                title: Text(label(a)),
                onTap: () =>
                    Navigator.of(sheetContext).pop((action: a, other: null)),
              ),
          ],
        ),
      );
    },
  );
}
