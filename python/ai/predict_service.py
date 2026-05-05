import datetime as dt

from .explainers import build_predict_explainer_prompt
from .parsers import extract_json_object
from .schemas import build_predict_response
from .validators import (
    sanitize_spending_summary,
    sanitize_budget_progress,
    sanitize_subscriptions,
    sanitize_savings_goal,
    clamp_str,
    to_float,
)


class PredictService:
    """Builds deterministic forecasts and optional AI explanations."""

    def __init__(self, generate_reply):
        self.generate_reply = generate_reply

    def _data_score(self, summary, mode):
        """Estimate data coverage quality from transaction counts."""
        totals = (summary or {}).get("totals") or {}
        annual = (summary or {}).get("annual_summary") or {}
        annual_totals = annual.get("totals") if isinstance(annual, dict) else {}
        if not isinstance(annual_totals, dict):
            annual_totals = {}

        if mode in ("year", "all"):
            tx_count = int(annual_totals.get("expense_tx_count_year", 0) or 0)
            if tx_count >= 120:
                return 1.0
            if tx_count >= 60:
                return 0.8
            if tx_count >= 20:
                return 0.6
            return 0.3
        tx_count = int(totals.get("expense_tx_count_30d", 0) or 0)
        if tx_count >= 30:
            return 1.0
        if tx_count >= 12:
            return 0.8
        if tx_count >= 5:
            return 0.6
        return 0.3

    def _budget_overrun(self, view_mode, budget_progress):
        """Compute budget overrun risk from category spend/limit ratios."""
        ranked = sorted(budget_progress or [], key=lambda x: x.get("ratio", 0), reverse=True)
        at_risk = []
        estimated_overrun = 0.0
        max_ratio = 0.0
        has_spend_signal = False
        for item in ranked[:10]:
            spent = max(0.0, to_float(item.get("spent", 0)))
            ratio = max(0.0, to_float(item.get("ratio", 0)))
            if spent > 0:
                has_spend_signal = True
            max_ratio = max(max_ratio, ratio)
            if ratio >= 0.8:
                overrun = max(0.0, spent - to_float(item.get("limit", 0)))
                estimated_overrun += overrun
                at_risk.append(
                    {
                        "category": item.get("category"),
                        "ratio": round(ratio, 2),
                        "spent": round(spent, 2),
                        "limit": round(to_float(item.get("limit", 0)), 2),
                    }
                )

        forecast = {
            "view_mode": view_mode,
            "at_risk_count": len(at_risk),
            "estimated_overrun_total": round(estimated_overrun, 2),
            "at_risk_categories": at_risk[:5],
        }
        alerts = [
            {
                "level": "high" if item["ratio"] >= 1.0 else "med",
                "message": f"{item['category']} at {int(item['ratio'] * 100)}% of budget",
            }
            for item in at_risk[:3]
        ]
        next_actions = [
            {"id": f"cap_{item['category'].lower().replace(' ', '_')}", "label": f"Cap {item['category']} spending this week"}
            for item in at_risk[:3]
        ]
        if not next_actions and has_spend_signal:
            # Baseline actions for low-risk periods: still actionable without overreacting.
            next_actions = [
                {"id": "monitor_weekly", "label": "Monitor top category weekly"},
                {"id": "review_before_cycle", "label": "Review top spending category before next cycle"},
            ]
        why = [
            "Forecast uses deterministic budget ratio thresholds.",
            "Categories at or above 80% are treated as at-risk.",
        ]
        signal = min(1.0, max(0.2, max_ratio / 1.2))
        sufficient = has_spend_signal or len(at_risk) > 0
        return forecast, why, alerts, next_actions, signal, sufficient

    def _subscription_cost(self, summary, subscriptions):
        """Normalize recurring charges to monthly/annual cost projections."""
        factors = {"monthly": 1.0, "yearly": 1.0 / 12.0, "weekly": 52.0 / 12.0, "daily": 30.0}
        monthly_total = 0.0
        top = []
        for sub in subscriptions:
            freq = sub.get("frequency", "monthly")
            monthly_cost = to_float(sub.get("amount", 0)) * factors.get(freq, 1.0)
            monthly_total += monthly_cost
            top.append({"name": sub.get("name"), "monthly_cost": round(monthly_cost, 2)})
        top = sorted(top, key=lambda x: x["monthly_cost"], reverse=True)
        annual_cost = monthly_total * 12.0
        totals = (summary or {}).get("totals") or {}
        expenses_month = max(1.0, to_float(totals.get("expenses_month", 1)))
        share = monthly_total / expenses_month
        forecast = {
            "projected_monthly_subscription_cost": round(monthly_total, 2),
            "projected_annual_subscription_cost": round(annual_cost, 2),
            "subscription_share_of_monthly_expenses": round(share, 3),
            "top_subscriptions": top[:5],
        }
        alerts = []
        if share >= 0.25:
            alerts.append({"level": "high", "message": "Subscriptions exceed 25% of monthly expenses"})
        elif share >= 0.15:
            alerts.append({"level": "med", "message": "Subscriptions exceed 15% of monthly expenses"})
        next_actions = [
            {"id": "review_subscriptions", "label": "Review top 3 subscriptions"},
            {"id": "cancel_unused", "label": "Cancel unused subscriptions"},
        ]
        why = [
            "Forecast uses deterministic frequency-to-monthly conversion.",
            "Subscription burden is measured against current monthly expenses.",
        ]
        signal = min(1.0, max(0.2, share / 0.25))
        sufficient = len(subscriptions) > 0
        return forecast, why, alerts[:3], next_actions[:3], signal, sufficient

    def _savings_goal(self, summary, goal):
        """Project goal timeline using deterministic contribution pace."""
        target_amount = to_float(goal.get("target_amount", 0))
        current_savings = to_float(goal.get("current_savings", 0))
        monthly_contribution = to_float(goal.get("monthly_contribution", 0))
        totals = (summary or {}).get("totals") or {}
        monthly_surplus = max(0.0, to_float(totals.get("income_month", 0)) - to_float(totals.get("expenses_month", 0)))
        effective_contribution = monthly_contribution if monthly_contribution > 0 else monthly_surplus
        remaining = max(0.0, target_amount - current_savings)

        months_to_goal = None
        if effective_contribution > 0:
            months_to_goal = int((remaining / effective_contribution) + 0.999)

        months_left = None
        on_track = None
        target_date = goal.get("target_date", "")
        if target_date:
            try:
                y, m, d = [int(x) for x in target_date.split("-")]
                today = dt.date.today()
                deadline = dt.date(y, m, d)
                months_left = max(0, (deadline.year - today.year) * 12 + (deadline.month - today.month))
                if months_to_goal is not None:
                    on_track = months_to_goal <= months_left
            except Exception:
                months_left = None
                on_track = None

        forecast = {
            "target_amount": round(target_amount, 2),
            "current_savings": round(current_savings, 2),
            "remaining_amount": round(remaining, 2),
            "effective_monthly_contribution": round(effective_contribution, 2),
            "estimated_months_to_goal": months_to_goal,
            "months_left_to_deadline": months_left,
            "on_track": on_track,
        }
        alerts = []
        if on_track is False:
            alerts.append({"level": "high", "message": "Current pace misses target date"})
        elif effective_contribution <= 0 and remaining > 0:
            alerts.append({"level": "high", "message": "No surplus available for goal progress"})
        next_actions = [
            {"id": "increase_saving_rate", "label": "Increase monthly contribution by 10%"},
            {"id": "reduce_top_spend", "label": "Reduce top discretionary category"},
        ]
        why = [
            "Timeline is computed from deterministic remaining amount and monthly contribution.",
            "On-track status compares projected months to goal with deadline months left.",
        ]
        signal = 0.9 if on_track is False else 0.6
        if effective_contribution <= 0:
            signal = 1.0
        sufficient = target_amount > 0
        return forecast, why, alerts[:3], next_actions[:3], signal, sufficient

    def _rule_explanation(self, predict_type, forecast):
        """Rule-based explanation used in simplified mode and as fallback."""
        if predict_type == "budget_overrun_forecast":
            at_risk_count = int(forecast.get("at_risk_count", 0) or 0)
            if at_risk_count <= 0:
                return (
                    "Current budget overrun risk is low; no categories are near the warning threshold.",
                    ["No category has reached the 80% budget-usage risk threshold."],
                )
            return (
                f"At-risk categories: {forecast.get('at_risk_count', 0)}; "
                f"estimated overrun ${forecast.get('estimated_overrun_total', 0):.0f}.",
                ["Budget ratios near or above threshold indicate overrun risk."],
            )
        if predict_type == "subscription_cost_forecast":
            return (
                f"Projected subscription spend is ${forecast.get('projected_monthly_subscription_cost', 0):.0f}/month.",
                ["Recurring cost is derived from normalized billing frequency."],
            )
        return (
            f"Estimated months to goal: {forecast.get('estimated_months_to_goal')}.",
            ["Goal forecast is based on current savings and monthly contribution pace."],
        )

    def handle_predict(self, payload):
        """Main predict pipeline: sanitize input, forecast, optionally LLM-explain."""
        payload = payload or {}
        predict_type = clamp_str(payload.get("type", ""), 48)
        simplified = bool(payload.get("simplified", False))
        if predict_type not in (
            "budget_overrun_forecast",
            "subscription_cost_forecast",
            "savings_goal_forecast",
        ):
            raise ValueError("Unsupported predict type")

        view_mode = clamp_str(payload.get("view_mode", "month"), 16)
        if view_mode not in ("month", "year", "all"):
            view_mode = "month"

        summary = sanitize_spending_summary(payload.get("spending_summary"))
        budget_progress = sanitize_budget_progress(payload.get("budget_progress"), max_items=20)
        subscriptions = sanitize_subscriptions(payload.get("subscriptions"), max_items=20)
        savings_goal = sanitize_savings_goal(payload.get("savings_goal"))

        if predict_type == "budget_overrun_forecast":
            forecast, why, alerts, next_actions, signal_strength, sufficient = self._budget_overrun(
                view_mode, budget_progress
            )
        elif predict_type == "subscription_cost_forecast":
            forecast, why, alerts, next_actions, signal_strength, sufficient = self._subscription_cost(
                summary, subscriptions
            )
        else:
            forecast, why, alerts, next_actions, signal_strength, sufficient = self._savings_goal(
                summary, savings_goal
            )

        data_score = self._data_score(summary, view_mode)
        confidence = round(max(0.0, min(1.0, data_score * signal_strength)), 2)

        has_budget_spend_signal = any(
            to_float(item.get("spent", 0)) > 0 for item in budget_progress
        )
        allow_low_confidence_budget_summary = (
            simplified
            and predict_type == "budget_overrun_forecast"
            and len(budget_progress) >= 1
            and has_budget_spend_signal
        )

        if not sufficient or (confidence < 0.2 and not allow_low_confidence_budget_summary):
            # Deterministic low-data guardrail: return safe response instead of overconfident advice.
            copy = "Not enough data to generate a reliable forecast for this request."
            return build_predict_response(
                predict_type=predict_type,
                forecast=forecast,
                copy=copy,
                why=["Insufficient data coverage for deterministic forecast."],
                alerts=[],
                next_actions=[{"id": "sync_data", "label": "Refresh transactions and retry"}],
                confidence=confidence,
                fallback_used=True,
            )

        deterministic_payload = {
            "forecast": forecast,
            "why": why,
            "alerts": alerts,
            "next_actions": next_actions,
            "confidence": confidence,
        }

        fallback_used = simplified
        copy, why_out = self._rule_explanation(predict_type, forecast)
        if not simplified:
            try:
                # Non-simplified mode asks the model to rewrite deterministic outputs in natural language.
                prompt = build_predict_explainer_prompt(
                    predict_type=predict_type,
                    deterministic_payload=deterministic_payload,
                    summary=summary,
                    view_mode=view_mode,
                )
                reply = self.generate_reply(
                    prompt,
                    generation_config={"temperature": 0.2, "maxOutputTokens": 220, "responseMimeType": "application/json"},
                )
                parsed = extract_json_object(reply)
                if isinstance(parsed, dict):
                    maybe_copy = clamp_str(parsed.get("copy", ""), 220)
                    if maybe_copy:
                        copy = maybe_copy
                    raw_why = parsed.get("why")
                    if isinstance(raw_why, list):
                        why_out = [clamp_str(item, 160) for item in raw_why if isinstance(item, str) and item.strip()][:3] or why_out
            except Exception:
                # Keep deterministic output when LLM rewrite fails.
                fallback_used = True

        return build_predict_response(
            predict_type=predict_type,
            forecast=forecast,
            copy=copy,
            why=why_out,
            alerts=alerts,
            next_actions=next_actions,
            confidence=confidence,
            fallback_used=fallback_used,
        )
