"""Canonical query/plan/response contracts for AI chat routing."""

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class QuerySpec:
    """Normalized user query understood by planner/executors."""

    task_type: str = "general"
    metric: str = "unknown"
    period_type: str = "unknown"
    period_key: str = ""
    scope: str = "unknown"
    reason_mode: str = ""
    category: str = ""
    compare_to: str = ""

    def to_dict(self) -> dict[str, str]:
        return {
            "intent": self.task_type,
            "metric": self.metric,
            "period_type": self.period_type,
            "period_key": self.period_key,
            "scope": self.scope,
            "reason_mode": self.reason_mode,
            "category": self.category,
            "compare_to": self.compare_to,
        }


@dataclass(frozen=True)
class ExecutionPlan:
    """Planner output describing how to answer the query."""

    mode: str = "llm"
    operation: str = "free_form"
    required_datasets: tuple[str, ...] = ()
    required_fields: tuple[str, ...] = ()
    notes: tuple[str, ...] = ()


@dataclass
class ResponseEnvelope:
    """Structured response metadata for debugging and contract stability."""

    answer_source: str = "llm"
    resolved_query: dict[str, Any] = field(default_factory=dict)
    facts_used: list[str] = field(default_factory=list)
    period_resolved: str = ""
    missing_fields: list[str] = field(default_factory=list)
