import '../app_models.dart';

class FinancialSnapshot {
  const FinancialSnapshot({
    required this.transactions,
    required this.subscriptions,
    required this.budgetProgress,
    required this.budgetProgressYear,
    required this.budgetProgressAll,
    required this.stats,
    required this.spendingSummary,
  });

  final List<AppTransaction> transactions;
  final List<DetectedSubscription> subscriptions;
  final List<BudgetCategoryProgress> budgetProgress;
  final List<BudgetCategoryProgress> budgetProgressYear;
  final List<BudgetCategoryProgress> budgetProgressAll;
  final DashboardStats stats;
  final Map<String, dynamic> spendingSummary;
}
