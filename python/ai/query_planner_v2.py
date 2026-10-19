"""V2 planner: choose deterministic vs llm execution path from QuerySpec."""

from .query_contracts import ExecutionPlan


def build_execution_plan_v2(query_spec, summary):
    if query_spec is None:
        return ExecutionPlan()
    if query_spec.task_type == "explain" and query_spec.reason_mode == "spending_change":
        return ExecutionPlan(
            mode="deterministic",
            operation="spending_change_month_over_month",
            required_datasets=("month_index", "time_anchor"),
            required_fields=("period_key",),
            notes=("compare target month with previous month",),
        )
    if query_spec.task_type == "amount_lookup" and query_spec.period_type == "day":
        return ExecutionPlan(
            mode="deterministic",
            operation="amount_day_lookup",
            required_datasets=("day_index_recent",),
            required_fields=("period_key", "metric"),
            notes=(),
        )
    if query_spec.task_type == "amount_lookup" and query_spec.period_type == "month":
        return ExecutionPlan(
            mode="deterministic",
            operation="amount_month_lookup",
            required_datasets=("month_index",),
            required_fields=("period_key", "metric"),
            notes=(),
        )
    if query_spec.task_type == "what_if" and query_spec.reason_mode in {
        "cut_percent",
        "cancel_merchant",
        "cut_dollars",
    }:
        return ExecutionPlan(
            mode="deterministic",
            operation=f"what_if_{query_spec.reason_mode}",
            required_datasets=("month_index", "recent_transactions"),
            required_fields=(),
            notes=(),
        )
    simple_ops = {
        "category_change": "category_change",
        "spending_trend": "spending_trend",
        "hotspots": "hotspots",
        "month_extreme": "month_extreme",
        "savings_goal": "savings_goal",
        "affordability": "affordability",
        "budget_suggestion": "budget_suggestion",
        "amount_judgement": "amount_judgement",
        "derived_metric": "derived_metric",
        "goal_time": "goal_time",
        "threshold_check": "threshold_check",
        "count_months": "count_months",
        "percent_of": "percent_of",
        "all_time": "all_time",
        "day_span": "day_span",
        "saving_target": "saving_target",
        "month_outlook": "month_outlook",
        "extra_spend": "extra_spend",
        "week_compare": "week_compare",
    }
    if query_spec.task_type in simple_ops:
        return ExecutionPlan(
            mode="deterministic",
            operation=simple_ops[query_spec.task_type],
            required_datasets=("month_index",),
            required_fields=(),
            notes=(),
        )
    if query_spec.task_type == "amount_lookup" and query_spec.period_type == "year":
        return ExecutionPlan(
            mode="deterministic",
            operation="year_amount",
            required_datasets=("month_index",),
            required_fields=("period_key",),
            notes=(),
        )
    if query_spec.task_type == "amount_lookup" and query_spec.period_type == "rolling_days":
        return ExecutionPlan(
            mode="deterministic",
            operation="amount_rolling",
            required_datasets=("windows_rolling",),
            required_fields=("period_key",),
            notes=(),
        )
    if query_spec.task_type == "amount_lookup" and query_spec.period_type == "month_range":
        return ExecutionPlan(
            mode="deterministic",
            operation="amount_month_range",
            required_datasets=("month_index",),
            required_fields=("period_key",),
            notes=(),
        )
    if query_spec.task_type == "what_if" and query_spec.reason_mode == "cap_amount":
        return ExecutionPlan(
            mode="deterministic",
            operation="what_if_cap_amount",
            required_datasets=("month_index",),
            required_fields=("period_key", "category"),
            notes=(),
        )
    if query_spec.task_type == "what_if" and query_spec.reason_mode == "rate_math":
        return ExecutionPlan(
            mode="deterministic",
            operation="what_if_rate_math",
            required_datasets=(),
            required_fields=("period_key",),
            notes=(),
        )
    if query_spec.task_type == "pace_check":
        return ExecutionPlan(
            mode="deterministic",
            operation="pace_check",
            required_datasets=("month_index",),
            required_fields=("period_key",),
            notes=(),
        )
    if query_spec.task_type == "data_pointer":
        return ExecutionPlan(
            mode="deterministic",
            operation="data_pointer",
            required_datasets=(),
            required_fields=("reason_mode",),
            notes=(),
        )
    if query_spec.task_type == "month_overview" and query_spec.period_type == "month":
        return ExecutionPlan(
            mode="deterministic",
            operation="month_overview",
            required_datasets=("month_index",),
            required_fields=("period_key",),
            notes=(),
        )
    if query_spec.task_type == "category_spending" and query_spec.period_type in {
        "month",
        "month_range",
    }:
        return ExecutionPlan(
            mode="deterministic",
            operation="category_month_lookup",
            required_datasets=("month_index",),
            required_fields=("period_key", "category"),
            notes=(),
        )
    if query_spec.task_type == "compare_periods":
        return ExecutionPlan(
            mode="deterministic",
            operation="compare_periods",
            required_datasets=("month_index", "year_index"),
            required_fields=("period_key",),
            notes=(),
        )
    if query_spec.task_type == "top_category_lookup":
        return ExecutionPlan(
            mode="deterministic",
            operation="top_category_lookup",
            required_datasets=("month_index", "annual_summary", "top_expense_categories"),
            required_fields=(),
            notes=(),
        )
    if query_spec.task_type == "recent_transactions":
        return ExecutionPlan(
            mode="deterministic",
            operation="recent_transactions",
            required_datasets=("recent_transactions",),
            required_fields=(),
            notes=(),
        )
    return ExecutionPlan(
        mode="llm", operation="free_form", required_datasets=(), required_fields=()
    )
