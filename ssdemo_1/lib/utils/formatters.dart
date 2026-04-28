String formatMoney(double amount, {bool signed = true}) {
  final absAmount = amount.abs().toStringAsFixed(2);
  if (!signed) return '\$$absAmount';
  final isIncome = amount < 0;
  return '${isIncome ? '+' : '-'} \$$absAmount';
}

String formatTransactionMoney({
  required double amount,
  required bool isIncome,
}) {
  return '${isIncome ? '+' : '-'} \$${amount.abs().toStringAsFixed(2)}';
}

String shortDate(DateTime value, {bool alwaysShowYear = false}) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final now = DateTime.now();
  final showYear = alwaysShowYear || value.year != now.year;
  return showYear
      ? '${months[value.month - 1]} ${value.day}, ${value.year}'
      : '${months[value.month - 1]} ${value.day}';
}

String normalizeCategoryKey(String raw) {
  return raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

String prettifyCategoryLabel(String raw) {
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return 'Uncategorized';
  final spaced = cleaned.replaceAll('_', ' ').toLowerCase();
  return spaced
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}
