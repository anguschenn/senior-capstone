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
    if query_spec.task_type == "amount_lookup" and query_spec.period_type == "month":
        return ExecutionPlan(
            mode="deterministic",
            operation="amount_month_lookup",
            required_datasets=("month_index",),
            required_fields=("period_key", "metric"),
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
