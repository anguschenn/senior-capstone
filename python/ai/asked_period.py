"""The period a question asks about when it spans several months or a run of days ("the
last 3 months", "the past 2 weeks", "since September"), and whether an answer covers it.

Chat answers for the period asked, or says it can't; it never quietly answers for a
different one (asking about the last 3 months and getting this month alone)."""

import datetime as dt
import re
from dataclasses import dataclass

from .time_parsing import month_mentions
from .time_scope_resolver import selected_month_key

_COUNT_WORDS = {
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
    "couple": 2,
    "few": 3,
    "several": 3,
}
_COUNT = r"(\d{1,3}|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|few|several|(?:a )?couple(?: of)?)"
_RUN = r"(?:the )?(?:last|past|previous|recent)"
_MONTHS_RE = re.compile(rf"\b{_RUN} {_COUNT} months\b|\b(?:in )?recent months\b")
_WEEKS_RE = re.compile(rf"\b{_RUN} {_COUNT} weeks\b")
_DAYS_RE = re.compile(rf"\b{_RUN} {_COUNT} days\b")
_ONE_WEEK_RE = re.compile(r"\b(this|last|past|current) week\b")
_SINCE_RE = re.compile(r"\bsince (?:the (?:start|beginning) of )?([a-z]+)\b")
_SPAN_RE = re.compile(r"\b(?:between|from)\b.*\b(?:and|to|through|thru|until)\b")
_THIS_YEAR_RE = re.compile(r"\b(?:this year|so far this year|year to date|ytd)\b")


@dataclass(frozen=True)
class AskedPeriod:
    """kind "months" (also this year) lists the months asked for; alt_months is the
    other common reading of "the last N months" (ending with this month). kind "days"
    is a run of `days` days ending today. ends, for "from February to May", are the two
    months a comparison of the span may show alone. label reads after a verb: "for the
    last 3 months", "since September"."""

    kind: str
    label: str
    months: tuple = ()
    alt_months: tuple = ()
    days: int = 0
    ends: tuple = ()


def _count(word):
    word = word.replace("a couple of", "couple").replace("couple of", "couple").strip()
    return int(word) if word.isdigit() else _COUNT_WORDS.get(word, 0)


def months_back(month_key, count):
    """The month `count` months before `month_key` (after it when negative)."""
    year, month = (int(part) for part in month_key.split("-"))
    month -= count
    while month <= 0:
        month += 12
        year -= 1
    while month > 12:
        month -= 12
        year += 1
    return f"{year}-{month:02d}"


def months_between(start, end):
    keys = []
    year, month = (int(part) for part in start.split("-"))
    while f"{year}-{month:02d}" <= end and len(keys) < 24:
        keys.append(f"{year}-{month:02d}")
        month += 1
        if month > 12:
            month, year = 1, year + 1
    return keys


def asked_period(text, summary):
    """The several-month or several-day period lowercased `text` asks about, else None
    (a single month, a day, or no period at all)."""
    current = selected_month_key(summary)
    match = _MONTHS_RE.search(text)
    if match:
        count = _count(match.group(1)) if match.group(1) else 3
        if count >= 2:
            label = match.group(0).removeprefix("in ")
            if not label.startswith("the "):
                label = f"the {label}"
            return AskedPeriod(
                kind="months",
                label=f"for {label}",
                months=tuple(months_between(months_back(current, count), months_back(current, 1))),
                alt_months=tuple(months_between(months_back(current, count - 1), current)),
            )
    for pattern, size in ((_WEEKS_RE, 7), (_DAYS_RE, 1)):
        match = pattern.search(text)
        if match and _count(match.group(1)) >= 1:
            label = match.group(0) if match.group(0).startswith("the ") else f"the {match.group(0)}"
            return AskedPeriod(
                kind="days", label=f"for {label}", days=_count(match.group(1)) * size
            )
    match = _ONE_WEEK_RE.search(text)
    if match:
        return AskedPeriod(kind="days", label=f"for {match.group(0)}", days=7)
    year = int(current[:4])
    match = _SINCE_RE.search(text)
    named = month_mentions(match.group(1)) if match else []
    if named:
        start = f"{year}-{named[0][1]:02d}"
        if start > current:
            start = f"{year - 1}-{named[0][1]:02d}"
        months = months_between(start, current)
        if len(months) >= 2:
            name = match.group(1).capitalize()
            return AskedPeriod(kind="months", label=f"since {name}", months=tuple(months))
    if _SPAN_RE.search(text):
        numbers = []
        for _, number in month_mentions(text):
            if number not in numbers:
                numbers.append(number)
        if len(numbers) == 2:
            start, end = (f"{year}-{n:02d}" for n in numbers)
            if start > end:
                start = f"{year - 1}-{numbers[0]:02d}"
            months = months_between(start, end)
            first, last = (dt.date(2000, n, 1).strftime("%B") for n in (numbers[0], numbers[1]))
            return AskedPeriod(
                kind="months",
                label=f"for {first} to {last}",
                months=tuple(months),
                ends=(months[0], months[-1]),
            )
    if _THIS_YEAR_RE.search(text):
        return AskedPeriod(
            kind="months",
            label="for this year",
            months=tuple(months_between(f"{year}-01", current)),
        )
    return None


_MONTH_KEY_RE = re.compile(r"\b(20\d{2}-\d{2})\b(?!-\d)")
_MONTH_SPAN_RE = re.compile(r"\b(20\d{2}-\d{2}) (?:to|through) (20\d{2}-\d{2})\b(?!-\d)")
_DAY_SPAN_RE = re.compile(r"\b(20\d{2}-\d{2}-\d{2}) to (20\d{2}-\d{2}-\d{2})\b")
_LAST_DAYS_RE = re.compile(r"\blast (\d{1,3}) days\b", re.IGNORECASE)
_YEAR_ONLY_RE = re.compile(r"^(20\d{2})$")
_IN_YEAR_RE = re.compile(r"\b(?:In|For) (20\d{2})\b(?!-)")


def _shown(response, summary):
    """(months, day runs) an answer is about: month keys and spans, whole years, and
    runs of days as (length, last day). None for an answer about all months."""
    period = str(response.get("period_resolved") or "").strip()
    if period in {"all months", "all time"}:
        return None
    text = f"{period} {response.get('reply') or ''}"
    runs = [(int(n), None) for n in _LAST_DAYS_RE.findall(text)]
    for start, end in _DAY_SPAN_RE.findall(text):
        try:
            first, last = dt.date.fromisoformat(start), dt.date.fromisoformat(end)
        except ValueError:
            continue
        runs.append(((last - first).days + 1, last))
    months = set(_MONTH_KEY_RE.findall(text))
    for start, end in _MONTH_SPAN_RE.findall(text):
        months.update(months_between(start, end))
    current = selected_month_key(summary)
    years = set(_IN_YEAR_RE.findall(text))
    if _YEAR_ONLY_RE.match(period):
        years.add(period)
    elif period == "year":
        years.add(current[:4])
    for year in years:
        months.update(months_between(f"{year}-01", min(f"{year}-12", current)))
    return months, runs


def covers(asked, response, summary, today=None):
    """Whether `response` (a chat answer) is about the period `asked`."""
    shown = _shown(response, summary)
    if shown is None:
        return True
    months, runs = shown
    if asked.kind == "days":
        # "the last N days" ends today; a run of the same length elsewhere doesn't count.
        today = today or dt.date.today()
        return any(
            abs(length - asked.days) <= 1 and (last is None or abs((today - last).days) <= 1)
            for length, last in runs
        )
    if asked.ends and set(asked.ends) <= months:
        return True  # "did it go up from February to May": the two ends compared
    current = selected_month_key(summary)
    month_index = summary.get("month_index") if isinstance(summary, dict) else None
    have = set(month_index) if isinstance(month_index, dict) and month_index else None

    def shows(asked_months, running_optional):
        need = set(asked_months) & have if have is not None else set(asked_months)
        if not need:
            # No data in any month asked: fine unless the answer is about other months.
            return bool(asked_months) and not (months - set(asked_months))
        if need <= months:
            return True
        # A whole-months answer may leave out the month still running, but only when
        # the months asked end with it ("since September"), not the other reading of
        # "the last N months", which would then be a month short.
        rest = need - {current}
        return running_optional and bool(rest) and rest <= months

    return shows(asked.months, True) or shows(asked.alt_months, False)


def shows_other_period(asked, response, summary):
    """Whether `response` shows a month or run of days outside the period `asked`."""
    shown = _shown(response, summary)
    if shown is None:
        return False
    months, runs = shown
    if asked.kind == "days":
        return bool(months) or any(abs(length - asked.days) > 1 for length, _ in runs)
    return bool(months - set(asked.months) - set(asked.alt_months))
