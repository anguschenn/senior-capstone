/// "2026-10": the month key the backend and database use.
String monthKeyOf(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}';

/// Minus sign used in front of amounts (U+2212, same width as "+").
const String kMinus = '\u2212';

/// "1,234.56" (or "1,235" with [decimals] 0). No sign, no "\$".
String groupDigits(double value, {int decimals = 2}) {
  final fixed = value.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final digits = parts[0];
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return parts.length > 1 ? '$out.${parts[1]}' : out.toString();
}

/// "\$1,234.56"; with [sign], "+\$1,234.56" or "−\$1,234.56".
String dollars(double value, {int decimals = 2, bool sign = false}) {
  final body = '\$${groupDigits(value, decimals: decimals)}';
  if (!sign) return body;
  return '${value < 0 ? kMinus : '+'}$body';
}

String formatMoney(double amount, {bool signed = true}) {
  if (!signed) return dollars(amount);
  // Expenses are positive and income negative in this app's data.
  return dollars(-amount, sign: true);
}

String formatTransactionMoney({
  required double amount,
  required bool isIncome,
}) {
  return dollars(isIncome ? amount.abs() : -amount.abs(), sign: true);
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
