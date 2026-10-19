"""V2 query parser: normalize natural-language asks into canonical QuerySpec."""

import calendar
import dataclasses
import re
from datetime import date as date_cls
from datetime import timedelta

from .query_contracts import QuerySpec
from .time_parsing import MONTH_NAME_TO_NUM, extract_specific_month_key, month_mentions
from .time_scope_resolver import previous_month_key, selected_month_key
from .typo_fix import fix_typos
from .validators import clamp_str

# "list my last 5 transactions", "show my transactions in 2026-10", "my transactions".
_TRANSACTION_LIST_RE = re.compile(
    r"\b(list|show|see|view|display|give me|what are|what were)\b.*\btransactions?\b"
    r"|\b(last|latest|recent|past)\s+(\d+\s+|few\s+)?transactions?\b"
    r"|\bmy transactions\b"
    r"|\bwhat (did|have) i (buy|bought|purchase|purchased|get)\b"
    r"|\b(everything|all|stuff|things|what) i (bought|purchased|got)\b"
    r"|\b(latest|last|most recent|recent) (purchase|purchases|buy|charge|charges)\b"
)


_AMOUNT_ASK_RE = re.compile(
    r"\b(how much|what (was|is|s|were) my|what did i|(see|show|view|tell me|give me)( me)? my|"
    r"what s left|whats left|left over)\b"
)
_MONTHS_AGO_RE = re.compile(r"\b(\d{1,2}|one|two|three|four|five|six)\s+months?\s+ago\b")
_NUMBER_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6}
_ADVICE_RE = re.compile(
    r"\b(how (can|do|should) i|tips?|advice|ways? to|help me|cut|reduce|lower|save|saving|"
    r"ideas? (to|for|on)|suggestions? (to|for|on))\b"
)


def _amount_metric(text):
    if re.search(
        r"\b(what s left|whats left|left over|leftover|take home after|net income|left after|"
        r"after bills|better off|worse off|lose money|lost money|money did i lose|how much did i lose)\b",
        text,
    ):
        return "net"
    has_income = re.search(
        r"\b(income|earn|earned|earning|earnings|salary|paycheck|paychecks|take home|takehome)\b"
        r"|\b(did|do|have) i (make|made)\b|\bi made\b|\b(was|were) i paid\b|"
        r"\b(get|got|getting) paid\b|\b(came|come|comes|coming) in\b|\bmoney in\b",
        text,
    )
    has_spend = re.search(
        r"\b(spend|spent|spending|expenses?|outflow|outgoings|damage|costs?|burn|burned)\b"
        r"|\bwent out\b|\bgone out\b|\bmoney out\b",
        text,
    )
    if has_income and has_spend:
        return "both"
    if has_income:
        return "income"
    if re.search(r"\b(net|cash flow)\b", text):
        return "net"
    if has_spend:
        return "expenses"
    return ""


def _months_back(month_key, count):
    year, month = (int(part) for part in month_key.split("-"))
    month -= count
    while month <= 0:
        month += 12
        year -= 1
    while month > 12:
        month -= 12
        year += 1
    return f"{year}-{month:02d}"


_MONTH_DAY_RE = re.compile(
    r"\b(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|"
    r"sep|sept|september|oct|october|nov|november|dec|december)\s+(\d{1,2})(st|nd|rd|th)?\b"
)


def _valid_day(year, month, day):
    try:
        return date_cls(year, month, day).isoformat()
    except ValueError:
        return ""


def _day_key(text, year=None, month_key=None):
    """YYYY-MM-DD for "today", "yesterday", "10/15", "oct 18", "the 14th" (in month_key)
    or YYYY-MM-DD, else ""."""
    explicit = re.search(r"\b(20\d{2})-(\d{2})-(\d{2})\b", text)
    if explicit:
        return _valid_day(*(int(x) for x in explicit.groups()))
    edge = re.search(r"\b(first|last) day of ([a-z]+)\b", text)
    if edge and MONTH_NAME_TO_NUM.get(edge.group(2)):
        month = MONTH_NAME_TO_NUM[edge.group(2)]
        y = year or date_cls.today().year
        last = calendar.monthrange(y, month)[1]
        return _valid_day(y, month, 1 if edge.group(1) == "first" else last)
    of_month = re.search(r"\b(\d{1,2})(st|nd|rd|th)? of ([a-z]+)\b", text)
    if of_month and MONTH_NAME_TO_NUM.get(of_month.group(3)):
        return _valid_day(
            year or date_cls.today().year,
            MONTH_NAME_TO_NUM[of_month.group(3)],
            int(of_month.group(1)),
        )
    ordinal = re.search(r"\bthe (\d{1,2})(st|nd|rd|th)\b", text)
    if ordinal and month_key and not month_mentions(text):
        return _valid_day(int(month_key[:4]), int(month_key[5:7]), int(ordinal.group(1)))
    year = year or date_cls.today().year
    slash = re.search(r"\b(\d{1,2})/(\d{1,2})\b", text)
    if slash:
        return _valid_day(year, int(slash.group(1)), int(slash.group(2)))
    named = _MONTH_DAY_RE.search(text)
    if named:
        month = MONTH_NAME_TO_NUM.get(named.group(1), 0)
        return _valid_day(year, month, int(named.group(2))) if month else ""
    weekday = re.search(
        r"\b(on|last|this past|this) (monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b",
        text,
    )
    if weekday:
        names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        today = date_cls.today()
        back = (today.weekday() - names.index(weekday.group(2))) % 7
        if back == 0 and weekday.group(1) != "this":
            back = 7  # "what did I spend on monday", asked on a monday, means the last one
        return (today - timedelta(days=back)).isoformat()
    if re.search(r"\byesterday\b", text):
        return (date_cls.today() - timedelta(days=1)).isoformat()
    if re.search(r"\btoday\b", text):
        return date_cls.today().isoformat()
    return ""


def _day_range_spec(text, summary, scope):
    """ "between august 1 and august 15", "from 10/1 to 10/10": a span of days."""
    span = re.search(r"\b(?:between|from)\s+(.+?)\s+(?:and|to|through|thru|until)\s+(.+)$", text)
    if not span:
        return None
    year = _selected_year(summary)
    named = _named_month_keys(text, summary)
    month_key = (
        previous_month_key(summary)
        if "last month" in text
        else (named[0] if named else selected_month_key(summary))
    )
    start = _day_key(span.group(1), year, month_key)
    end_text = span.group(2)
    bare = re.fullmatch(r"(\d{1,2})(st|nd|rd|th)?", end_text.strip())
    if start and bare:
        # "from august 1 to 15" keeps the first date's month.
        end = _valid_day(int(start[:4]), int(start[5:7]), int(bare.group(1)))
    else:
        end = _day_key(end_text, year, month_key)
    if not start or not end or end < start:
        return None
    return QuerySpec(
        task_type="day_span",
        metric="expenses",
        period_type="days",
        period_key=f"{start},{end}",
        scope=scope,
    )


def _relative_month_amount(text, summary, scope):
    """ "income last month", "net cash flow this month", "spending 2 months ago",
    "spent yesterday": one income/expense/net total for a day or month the user named
    in words. Advice asks ("how can I cut ...") are left alone."""
    if not _AMOUNT_ASK_RE.search(text) or _ADVICE_RE.search(text):
        return None
    metric = _amount_metric(text)
    if not metric:
        return None
    if re.search(r"\b(spend|spent|spending) (the )?most( money)? on\b", text):
        return None  # "what did I spend the most on" asks for the top category
    if re.search(r"\b(this month and last month|last month and this month)\b", text):
        return QuerySpec(
            task_type="compare_periods",
            metric=metric if metric in {"income", "net"} else "expenses",
            period_type="month_range",
            period_key=f"{selected_month_key(summary)},{previous_month_key(summary)}",
            scope=scope,
        )
    day_range = _day_range_spec(text, summary, scope)
    if day_range is not None:
        return day_range
    if re.search(r"\b(from|between)\b.*\b(to|through|thru|and|until)\b", text) and (
        len(_named_month_keys(text, summary)) == 2
    ):
        return None  # a span of months; the fallback sums it
    if re.search(r"\bsince\b", text):
        return None  # "since april" runs to now; the fallback sums it
    if len(_named_month_keys(text, summary)) >= 2 and _COMPARE_WORD_RE.search(text):
        return None  # "income in august or september": the named-month rule compares them
    ordinal_month = (
        previous_month_key(summary) if "last month" in text else selected_month_key(summary)
    )
    day_key = _day_key(text, _selected_year(summary), ordinal_month)
    if day_key:
        return QuerySpec(
            task_type="amount_lookup",
            metric=metric,
            period_type="day",
            period_key=day_key,
            scope=scope,
        )
    months_ago = _MONTHS_AGO_RE.search(text)
    if "this month" in text or "current month" in text:
        month_key = selected_month_key(summary)
    elif "last month" in text:
        month_key = previous_month_key(summary)
    elif months_ago:
        raw = months_ago.group(1)
        count = int(raw) if raw.isdigit() else _NUMBER_WORDS[raw]
        month_key = _months_back(selected_month_key(summary), count)
    else:
        month_key = _transaction_list_month(text, summary)
        if not month_key:
            return None
    return QuerySpec(
        task_type="amount_lookup",
        metric=metric,
        period_type="month",
        period_key=month_key,
        scope=scope,
    )


# Everyday words for the app's budget categories.
_CATEGORY_SYNONYMS = {
    "food": "Food",
    "foods": "Food",
    "dining": "Food",
    "eating out": "Food",
    "restaurants": "Food",
    "groceries": "Food",
    "grocery": "Food",
    "transport": "Transport",
    "transportation": "Transport",
    "shopping": "Shopping",
    "subscriptions": "Subscriptions",
    "subscription": "Subscriptions",
    "entertainment": "Entertainment",
    "bills": "Bills & Utilities",
    "utilities": "Bills & Utilities",
    "rent": "Housing",
    "housing": "Housing",
    "health": "Health",
    "medical": "Health",
    "fees": "Fees & Transfers",
    "transfers": "Fees & Transfers",
    "restaurant": "Food",
    "takeout": "Food",
    "take out": "Food",
    "clothes": "Shopping",
    "clothing": "Shopping",
    "streaming": "Subscriptions",
    "doctor": "Health",
    "gym": "Gym",
    "fitness": "Gym",
    "getting around": "Transport",
    "rides": "Transport",
    "other spending": "Other",
    "rideshare": "Transport",
    "commute": "Transport",
    "commuting": "Transport",
    "fun stuff": "Entertainment",
    "on fun": "Entertainment",
    "for fun": "Entertainment",
    "fun spending": "Entertainment",
    "of stuff": "Shopping",
    "buy stuff": "Shopping",
    "bought stuff": "Shopping",
    "buying stuff": "Shopping",
    "having fun": "Entertainment",
    "pharmacy": "Health",
    "gas bill": "Bills & Utilities",
    "electric bill": "Bills & Utilities",
    "phone bill": "Bills & Utilities",
    "other stuff": "Other",
    "other things": "Other",
    "other category": "Other",
    "misc": "Other",
    "miscellaneous": "Other",
}
# Narrower things people ask about that the app files under a broader category; answers
# say so ("Coffee isn't tracked separately; it's part of Food").
_APPROX_TERMS = {
    "whole foods": "Food",
    "coffee": "Food",
    "cafe": "Food",
    "lunch": "Food",
    "lunches": "Food",
    "dinner": "Food",
    "dinners": "Food",
    "snacks": "Food",
    "drinks": "Food",
    "starbucks": "Food",
    "doordash": "Food",
    "uber eats": "Food",
    "ubereats": "Food",
    "grubhub": "Food",
    "uber": "Transport",
    "lyft": "Transport",
    "taxi": "Transport",
    "taxis": "Transport",
    "gas": "Transport",
    "fuel": "Transport",
    "parking": "Transport",
    "subway": "Transport",
    "metro": "Transport",
    "train": "Transport",
    "travel": "Transport",
    "flights": "Transport",
    "games": "Entertainment",
    "gaming": "Entertainment",
    "video games": "Entertainment",
    "flight": "Transport",
    "airfare": "Transport",
    "bubble tea": "Food",
    "boba": "Food",
    "milk tea": "Food",
    "amazon": "Shopping",
    "shoes": "Shopping",
}


def _known_categories(summary):
    names = set()
    if isinstance(summary, dict):
        index = summary.get("category_index")
        if isinstance(index, dict):
            names.update(str(k) for k in index)
        for row in (summary.get("month_index") or {}).values():
            if isinstance(row, dict) and isinstance(row.get("categories"), dict):
                names.update(str(k) for k in row["categories"])
    return names


def _approx_pattern(word):
    # "gas bill" is a utility bill, not fuel.
    tail = r"(?! bill)" if word == "gas" else (r"(?! eats)" if word == "uber" else "")
    return r"\b" + re.escape(word) + r"\b" + tail


def _approx_term(text):
    """The narrower word that was mapped to a category ("coffee"), if any."""
    for word in sorted(_APPROX_TERMS, key=len, reverse=True):
        if re.search(_approx_pattern(word), text):
            return word
    return ""


def _categories_in(text, summary, include_approx=True):
    """Categories named in text, in the order written."""
    found = []
    if include_approx:
        for word, name in _APPROX_TERMS.items():
            match = re.search(_approx_pattern(word), text)
            if match:
                found.append((match.start(), name))
    for name in _known_categories(summary):
        # "other" is too common a word ("other months") to read as the Other category.
        if name.lower() == "other":
            if re.search(r"\b(my other|other category|other spending|other expenses)\b", text):
                found.append((text.index("other"), name))
            continue
        match = re.search(r"\b" + re.escape(name.lower()) + r"\b", text)
        if match:
            found.append((match.start(), name))
    for word, name in _CATEGORY_SYNONYMS.items():
        match = re.search(r"\b" + re.escape(word) + r"\b", text)
        if match:
            found.append((match.start(), name))
    ordered = []
    for _, name in sorted(found):
        if name.lower() not in (n.lower() for n in ordered):
            ordered.append(name)
    return ordered


def _category_in(text, summary, include_approx=True):
    names = _categories_in(text, summary, include_approx=include_approx)
    return names[0] if names else ""


_EXCLUDE_RE = re.compile(
    r"\b(not counting|not including|excluding|except|without|apart from|other than)\s+"
)


def _category_month_amount(text, summary, scope):
    """ "How much did I spend on food in October?": one category's spend for one month,
    defaulting to the selected month."""
    if not _AMOUNT_ASK_RE.search(text) or _ADVICE_RE.search(text):
        return None
    if _amount_metric(text) != "expenses":
        return None
    categories = _categories_in(text, summary)
    if not categories:
        return None
    if re.search(
        r"\b(last|past|previous) (\d{1,2}|two|three|four|five|six|few) months\b|"
        r"\bover (the )?(past|last) (few )?months\b|\bsince\b|\bq[1-4]\b|\bquarter\b|"
        r"\bhalf of\b|\b(summer|spring|fall|autumn|winter)\b|"
        r"\bfrom [a-z]+ (to|through|until|till) [a-z]+\b|\bbetween [a-z]+ and [a-z]+\b",
        text,
    ) and (len(_named_month_keys(text, summary)) != 1 or "since" in text):
        return None  # a span of months; the fallback lists them
    year_spec = _year_amount_spec(text, summary, scope, "expenses", categories)
    if year_spec is not None:
        return year_spec
    if re.search(r"\b(last week|this week|past week|last 7 days|past 7 days)\b", text):
        return QuerySpec(
            task_type="data_pointer",
            period_key=selected_month_key(summary),
            scope=scope,
            category=categories[0],
            reason_mode="category_week",
        )
    exclude = _EXCLUDE_RE.search(text)
    versus = len(categories) == 2 and re.search(r"\b(vs|versus|or|compared? to)\b", text)
    if "this month" in text or "current month" in text:
        month_key = selected_month_key(summary)
    elif "last month" in text:
        month_key = previous_month_key(summary)
    else:
        month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
    return QuerySpec(
        task_type="category_spending",
        metric="expenses",
        period_type="month",
        period_key=month_key,
        scope=scope,
        category=",".join(categories),
        reason_mode="exclude" if exclude else ("versus" if versus else ""),
        compare_to=_approx_term(text),
    )


_WHAT_IF_RE = re.compile(r"\b(what if|if i|if we|suppose)\b")
# "%" is stripped by the normalizer above, so "by 20%" arrives as "by 20".
_CUT_PERCENT_RE = re.compile(
    r"\b(cut|reduce|lower|trim)\b.*?\bby\s+(\d{1,3})\b(?!\s+dollars)"
    r"|\b(?:spent|spend|spending)\s+(\d{1,3})\s+percent\s+less\b"
)
_CUT_DOLLARS_RE = re.compile(
    r"\b(?:cut|reduce|lower|trim)\b.*?\bby\s+(\d{1,6})\s+dollars\b"
    r"|\b(?:spent|spend|spending)\s+(\d{1,6})\s+dollars\s+less\b"
)
_CANCEL_RE = re.compile(
    r"\b(cancel|stop|stopped|drop|quit|end)\s+(?:paying for\s+|my\s+)?([a-z0-9][a-z0-9 .*]{1,40}?)(?:\s*,|\s+how\b|\s+what\b|\s+would\b|$)"
)


_RATE_RE = re.compile(
    r"\b(\d+(?:\.\d+)?)\s+(?:dollars?\s+)?(?:less|fewer)\b.*?\b(?:every|per|a|each)\s+"
    r"(day|week|month)\b"
)


# "every week 50 less" (word order from Chinese "每周少花50").
_RATE_FIRST_RE = re.compile(
    r"\b(?:every|per|a|each)\s+(day|week|month)\b.*?\b(\d+(?:\.\d+)?)\s+(?:less|fewer)\b"
)


def _rate_parts(rate):
    """(amount, unit) from either rate pattern."""
    first, second = rate.group(1), rate.group(2)
    return (second, first) if first in {"day", "week", "month"} else (first, second)


def _what_if_spec(text, summary, scope):
    """Savings what-ifs the code can price exactly instead of leaving the math to the model."""
    rate = _RATE_RE.search(text) or _RATE_FIRST_RE.search(text)
    if rate and re.search(r"\b(save|saving|savings)\b", text):
        horizon = "year"
        if re.search(r"\b(a|per|each|every) month\b", text) and not re.search(r"\byear\b", text):
            horizon = "month"
        amount, unit = _rate_parts(rate)
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type=unit,
            period_key=amount,
            scope=scope,
            reason_mode="rate_math",
            compare_to=horizon,
        )
    saved = re.search(
        r"\bsav(?:e|ed|ing)\s+(\d{1,6})\s+(?:dollars\s+)?(?:every|a|per|each)\s+(day|week|month)\b",
        text,
    )
    totals_ask = re.search(
        r"\bhow much (would|will|could|do) i (have|save|end up)\b|\bend up with\b|"
        r"\bfor (a|one|\d{1,2}) (year|years|months)\b",
        text,
    )
    if saved and totals_ask:
        months = re.search(r"\bfor\s+(\d{1,2})\s+months\b", text)
        years = re.search(r"\bfor\s+(\d{1,2})\s+years\b", text)
        horizon = "year"
        if months:
            horizon = f"{months.group(1)} months"
        elif years:
            horizon = f"{years.group(1)} years"
        return QuerySpec(
            task_type="what_if",
            metric="net",
            period_type=saved.group(2),
            period_key=saved.group(1),
            scope=scope,
            reason_mode="rate_math",
            compare_to=horizon,
            category="save",
        )
    if (
        not _WHAT_IF_RE.search(text)
        and not re.search(r"\b\d{1,3} percent less\b", text)
        and not re.search(r"\b(halve|halving|halved)\b", text)
        and not re.search(
            r"\b(would|could) i save\b|\bby (cutting|reducing|lowering|trimming)\b", text
        )
    ):
        return None
    if re.search(r"\b(halve|halving|halved)\b", text) or re.search(
        r"\b(cut|cutting|reduce|reducing|lower|lowering|trim|trimming)\b.*\b(in|by) half\b", text
    ):
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key="50",
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="cut_percent",
        )
    cap = re.search(r"\bonly (?:spent|spend|spending) (\d{1,6})\b", text) or re.search(
        r"\b(?:cut|reduce|lower|bring|keep|limit|cap)\b.*?\b(?:to|at|under) (\d{1,6}) dollars\b",
        text,
    )
    if cap and _category_in(text, summary):
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key=cap.group(1),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="cap_amount",
        )
    dollars = _CUT_DOLLARS_RE.search(text)
    monthly = re.search(r"\b(a|per|each|every) month\b|\bmonthly\b", text)
    weekly = re.search(r"\b(a|per|each|every) week\b|\bweekly\b", text)
    if dollars and weekly and _category_in(text, summary):
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key=dollars.group(1) or dollars.group(2),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="cut_dollars",
            compare_to="week",
        )
    if dollars and (not _RATE_RE.search(text) or monthly):
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key=dollars.group(1) or dollars.group(2),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="cut_dollars",
        )
    half_as = re.search(
        r"\b(spend|spent|spending) half as much\b|\b(halving|halve|halved)\b|"
        r"\bcut [a-z ]{0,25}in half\b|\bby half\b",
        text,
    )
    if half_as and _category_in(text, summary, include_approx=False):
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key="50",
            scope=scope,
            category=_category_in(text, summary, include_approx=False),
            reason_mode="cut_percent",
        )
    whole = re.search(
        r"\b(cut|cutting|drop|dropped|dropping|stop|stopped|stopping|eliminate|eliminated|remove|"
        r"removed|quit|cut out|got rid of|get rid of|ditch|ditched)\b.*\b(completely|entirely|"
        r"altogether|totally|for good)\b|\b(got|get) rid of\b|"
        r"\b(didn t|did not|don t|do not|wouldn t) spend (anything|any money|a dime) on\b|"
        r"\bspen[dt] nothing on\b|\bno (more )?spending on\b",
        text,
    )
    if whole and _category_in(text, summary, include_approx=False):
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key="100",
            scope=scope,
            category=_category_in(text, summary, include_approx=False),
            reason_mode="cut_percent",
        )
    fraction = re.search(
        r"\b(cut|reduce|lower|trim)\b.*?\bby (a|one) (third|quarter|fifth)\b", text
    )
    if fraction and _category_in(text, summary, include_approx=False):
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key={"third": "33", "quarter": "25", "fifth": "20"}[fraction.group(3)],
            scope=scope,
            category=_category_in(text, summary, include_approx=False),
            reason_mode="cut_percent",
        )
    bare_cut = re.search(
        r"\b(cut|cutting|reduce|reducing|lower|lowering|trim|trimming)\b [a-z ]{1,25}?"
        r"\b(\d{1,3}) percent\b",
        text,
    )
    if bare_cut and not _CUT_PERCENT_RE.search(text) and _category_in(text, summary):
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key=bare_cut.group(2),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="cut_percent",
        )
    cut = _CUT_PERCENT_RE.search(text)
    if cut:
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key=cut.group(2) or cut.group(3),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="cut_percent",
        )
    cancel = _CANCEL_RE.search(text) or re.search(
        r"\b(don t|didn t|do not|not|stop|stopped|quit|quitting|gave up|give up) "
        r"(buy|buying|get|getting)\s+([a-z][a-z ]{1,30})",
        text,
    )
    if (
        cancel
        and _approx_term(cancel.group(cancel.lastindex))
        and not _category_in(cancel.group(cancel.lastindex), summary, include_approx=False)
    ):
        return QuerySpec(
            task_type="data_pointer",
            period_key=selected_month_key(summary),
            scope=scope,
            reason_mode="approx_cut",
            category=_approx_term(cancel.group(cancel.lastindex)),
            compare_to=_category_in(cancel.group(cancel.lastindex), summary) or "",
        )
    if cancel and _category_in(cancel.group(2), summary, include_approx=False):
        # "stop eating out for a month" is cutting a category, not a subscription.
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            period_type="unknown",
            period_key="100",
            scope=scope,
            category=_category_in(cancel.group(2), summary, include_approx=False),
            reason_mode="cut_percent",
        )
    if cancel:
        return QuerySpec(
            task_type="what_if",
            metric="expenses",
            scope=scope,
            category=re.sub(r"\s+(and|&)\s+", ",", cancel.group(2).strip()),
            reason_mode="cancel_merchant",
        )
    return None


_OVERVIEW_RE = re.compile(
    r"\b(how am i doing|how are my finances|how s my month|how is my month|how broke|"
    r"am i broke|overview|summary of my (month|spending|finances)|quick summary|summary|"
    r"recap|rundown|sum up|summarize|how does (this|the) month look|how s this month looking|"
    r"how is this month looking|how am i tracking|"
    r"(?:was|is) (?:[a-z]+ )?(?:a )?(?:good|bad|ok|okay|decent|rough) month|"
    r"how (?:was|did) (?:last month|this month|january|february|march|april|may|june|july|"
    r"august|september|october|november|december)(?: go)?$)\b"
)
_OTHER_PERSON_RE = re.compile(
    r"\b(?:how much|what) did (?!i\b|we\b|you\b)(my [a-z]+|[a-z]+) (spend|spent|earn|make)\b"
)
_BALANCE_RE = re.compile(
    r"\b(how much money do i have|my balance|account balance|balances|net worth|"
    r"how much is in my|how much (money )?is (in|on) (all )?(my|the)|"
    r"money (do i have )?in (all )?my accounts|how much cash (do i have|have i got)|"
    r"how much (money )?do i have (in|on|saved)|"
    r"what(?: is| s|s)? in (my|the) (savings|checking|bank|account)|"
    r"(bank|checking|savings|current) balance)\b"
)
_INVEST_RE = re.compile(
    r"\b(stocks?|crypto|bitcoin|ethereum|etfs?|shares|invest|investing|investment)\b"
)
_KEYBOARD_MASH_RE = re.compile(r"[bcdfghjklmnpqrstvwxz]{5,}")
_FORECAST_RE = re.compile(
    r"\b(will i|going to|gonna|expect to|likely)\b.*\b(spend|spent)\b|"
    r"\b(spend|spending)\b.*\bnext month\b|\bwill my spending be\b"
)


_SMALL_TALK_WORDS = set(
    """
    hi hello hey yo hiya good morning afternoon evening night goodnight thanks thank you thx ty ok okay cool
    great nice got it bye goodbye there so much a lot alright perfect awesome cheers for now
    """.split()
)


def _boundary_spec(text, scope):
    """Asks that are outside what this assistant should answer from the user's data."""
    capabilities = re.search(
        r"\b(what can you do|what do you do|how can you help|what can i ask|help me use|"
        r"what can you help( me)? with|what are you able to do|how do you work)\b",
        text,
    )
    if capabilities or text in {"help", "help me"}:
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="capabilities")
    if re.search(r"\b(add|connect|link) (a |another |my |new )?(bank|account|card)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="add_bank")
    if re.search(
        r"\b(before|after|since|until|till) (my )?(pay ?day|paycheck|payday)\b|"
        r"\b(before|after|since) i (get|got) paid\b",
        text,
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="payday")
    if re.search(
        r"\b(recurring|repeating|repeat|fixed) (expenses?|charges?|payments?|bills?|costs?)\b", text
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="subscriptions")
    if re.search(
        r"\b(can|could|would|will) you (please )?(transfers?|send|move|wire|pay|deposit|"
        r"withdraw)\b|^(please )?(transfers?|send|move|wire) (\d|my |the |some |money)|"
        r"^(please )?(withdraw|deposit)\b",
        text,
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="move_money")
    if re.search(
        r"\b(can|could|would|will) you (please )?(cancel|unsubscribe|pause|stop)\b|"
        r"^(please )?(cancel|unsubscribe)\b",
        text,
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="cancel")
    if re.search(r"\binterest\b", text) and not re.search(r"\binterest(ing|ed)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="interest")
    if re.search(
        r"\b(owe|owed|owing) on (my |the )?(credit )?card\b|\bhow much do i owe\b|"
        r"\b(card|statement) balance\b|\bminimum payment\b|\bbalance (on|of|in|for) (my|the)\b|"
        r"\bavailable credit\b|\bcredit limit\b|\bhow much credit\b",
        text,
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="balance")
    last_one = re.search(
        r"\b(when was|when did i (last )?(pay for|pay|go to|buy from|use|take))( my| the)? "
        r"(last |latest )?"
        r"([a-z][a-z0-9 .*']{1,25}?)( ride| trip| order| charge| purchase| visit| payment)?$",
        text,
    )
    if last_one and not re.search(r"\b(paid|payday|paycheck|income)\b", last_one.group(6)):
        name = re.sub(r"^(my|the) ", "", last_one.group(6)).strip()
        if len(name) >= 3 and not _GENERIC_NAME_RE.match(name):
            return QuerySpec(
                task_type="data_pointer", scope=scope, reason_mode="merchant", category=name
            )
    visited = re.search(
        r"\b(have i been to|did i go to|have i gone to|did i visit|have i visited) "
        r"([a-z][a-z0-9 .*']{1,25}?)( lately| recently| this (week|month))?$",
        text,
    )
    if visited and not _GENERIC_NAME_RE.match(visited.group(2)):
        return QuerySpec(
            task_type="data_pointer", scope=scope, reason_mode="merchant", category=visited.group(2)
        )
    charged = re.search(
        r"\b(?:did|has|have) ([a-z][a-z0-9 .*']{1,20}?) (?:charge|charged|bill|billed) me\b|"
        # "is netflix still charging me"
        r"\b(?:is|are|does|do) ([a-z][a-z0-9 .*']{1,20}?) still (?:charging|billing|charge|bill) me\b",
        text,
    )
    name = charged and (charged.group(1) or charged.group(2))
    if name and not _GENERIC_NAME_RE.match(name):
        return QuerySpec(
            task_type="data_pointer", scope=scope, reason_mode="merchant", category=name
        )
    any_charge = re.search(
        r"\bany ([a-z][a-z0-9 .*']{2,25}?) (charges?|payments?|transactions?|purchases?|bills?)\b",
        text,
    )
    if (
        any_charge
        and not _GENERIC_NAME_RE.match(any_charge.group(1))
        and not re.search(
            r"\b(card|credit|refund|interest|late|bank|atm|foreign)\b", any_charge.group(1)
        )
    ):
        return QuerySpec(
            task_type="data_pointer",
            scope=scope,
            reason_mode="merchant",
            category=any_charge.group(1),
        )
    item = re.search(r"\b(spend|spent|pay|paid) (on|for) my (new )?([a-z][a-z ]{1,25}?)$", text)
    if (
        item
        and not re.search(
            r"\b(trip|vacation|holiday|birthday|christmas|wedding|party|honeymoon|anniversary)\b",
            item.group(4),
        )
        and (
            item.group(3)
            or (
                len(item.group(4).split()) > 1
                and not re.search(r"\b(in|on|last|this|during|for|since|from|of)\b", item.group(4))
            )
        )
    ):
        # "my new laptop", "my car repair": one purchase, not a merchant or category
        return QuerySpec(
            task_type="data_pointer",
            scope=scope,
            reason_mode="find_purchase",
            category=re.sub(r"\s+(last|this|in|during) [a-z]+$", "", item.group(4)).strip(),
        )
    if re.search(
        r"\bwho (did i|have i|do i) (pay|paid|spend|spent)\b|\bwhich (merchant|store|shop|company)",
        text,
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="top_payee")
    if re.search(r"\b(1[3-9]|[2-9]\d)(th|st|nd|rd) month\b|\bmonth (1[3-9]|[2-9]\d)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="no_such_month")
    if re.search(
        r"\b(did i spend|have i spent|i spent|spend on|spent on|cost me|cost)\b.*"
        r"\b(trip|vacation|holiday|holidays|birthday|christmas|wedding|party|gifts?|"
        r"anniversary|thanksgiving|black friday|date night|honeymoon|graduation|move|moving|"
        r"halloween|easter|new year s|new years|valentine s day|valentines day|spring break)\b",
        text,
    ) and not re.search(r"\b(afford|save|saving|budget|plan|next|upcoming|future)\b", text):
        event = re.search(
            r"\b(trip|vacation|holiday|holidays|birthday|christmas|wedding|party|gifts?|"
            r"anniversary|thanksgiving|black friday|date night|honeymoon|graduation|move|moving|"
            r"halloween|easter|new year s|new years|valentine s day|valentines day|spring break)\b",
            text,
        ).group(1)
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="trip", category=event)
    if re.search(r"\b(credit score|credit report|credit rating|fico)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="credit_score")
    if re.search(r"\b(tax|taxes|tax refund|withholding|withheld)\b", text) and not re.search(
        r"\b(after|before|pre|post) tax(es)?\b|\btax free\b", text
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="taxes")
    if re.search(
        r"\b(paid|pay|pays|sent|send) me back\b|\bwho (paid|sent) me\b|\b(owes?|owed) me\b|"
        r"\b(did|has|have) (my |the )?[a-z]+ (paid|sent|pay|send) me\b",
        text,
    ) and not re.search(r"\b(job|work|employer|company|boss|salary|paycheck)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="payer")
    privacy = re.search(
        r"\b(private|privacy|secure|security|safe|who can see my data|my data stored)\b", text
    )
    if privacy and re.search(r"\b(data|info|information|account|accounts)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="privacy")
    words = text.split()
    if (
        (
            re.match(r"^(thanks|thank you|thank u|cheers|appreciate it)\b", text)
            or re.search(r"\b(thanks|thank you|thx|ty)$", text)
            or re.search(
                r"\b(thanks|thank you) (for (the|your|all the) help|so much|again)\b", text
            )
            or re.match(r"^that(?:'| )?s (all|it)( for (now|today))?\b", text)
            or re.search(r"\b(appreciate it|much appreciated|thanks a lot|thank you)\b", text)
            or re.match(r"^(i )?(really )?appreciate\b", text)
            or re.search(
                r"\b(that|this|it) (really )?(helps|helped|was helpful|is helpful|makes sense)\b|"
                r"\bthat(?:'| )?s (an? )?(really |very |super )?(helpful|perfect|great|awesome|interesting|"
                r"good to know|cool)\b|^(good to know|interesting|noted)\b|"
                r"^(very |super |really )?helpful\b|"
                r"\b(you(?:'| )?re|you are) (awesome|great|amazing|the best|a lifesaver)\b|"
                r"^(you rock|great job|good job|well done|nice work|love it|love this)\b",
                text,
            )
        )
        and len(words) <= 8
        and not re.search(r"\b(how|what|which|when|why|can|could|show|tell|but)\b", text)
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="thanks")
    if words and len(words) <= 5 and all(w in _SMALL_TALK_WORDS for w in words):
        thanks_words = {
            "thanks",
            "thank",
            "thx",
            "ty",
            "ok",
            "okay",
            "cool",
            "great",
            "nice",
            "perfect",
            "awesome",
            "alright",
            "cheers",
        }
        thanks = any(w in thanks_words for w in words) or "got it" in text
        if "bye" in words or "goodbye" in words or re.search(r"\bgood ?night\b", text):
            mode = "bye"
        else:
            mode = "thanks" if thanks else "hello"
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode=mode)
    other = _OTHER_PERSON_RE.search(text)
    if other:
        return QuerySpec(
            task_type="data_pointer",
            scope=scope,
            reason_mode="other_person",
            category=other.group(1),
        )
    if re.search(
        r"\b(approve|authorize|send|wire|move)\b.*\b(transfers?|money|payments?|funds)\b"
        r"|\b(make|do) (a|the) (transfers?|payments?)\b|\bpay my\b|"
        r"\b(can|could|would|will) you (please )?(transfer|send|move|wire|pay|deposit|withdraw)\b|"
        r"^(please )?(transfer|send|move|wire) \d",
        text,
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="move_money")
    if _BALANCE_RE.search(text) and not re.search(r"\b(left|remaining)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="balance")
    if _INVEST_RE.search(text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="investing")
    words = re.findall(r"[a-z]+", text)
    if len(words) == 1 and _KEYBOARD_MASH_RE.search(words[0]):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="unclear")
    if re.search(r"\bnext week\b", text) and re.search(
        r"\b(spend|spending|spent|expenses|cost)\b", text
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="forecast_week")
    if re.search(
        r"\b(will i|going to|gonna|expect to)\b.*\b(earn|make|get paid)\b", text
    ) and re.search(r"\bnext month\b", text):
        return QuerySpec(
            task_type="data_pointer", scope=scope, reason_mode="forecast", compare_to="income"
        )
    if _FORECAST_RE.search(text) and re.search(
        r"\b(this year|the year|year end|end of (the )?year|in total this year)\b", text
    ):
        return QuerySpec(
            task_type="data_pointer",
            period_type="year",
            scope=scope,
            reason_mode="forecast_year",
        )
    if _FORECAST_RE.search(text) and not re.search(r"\b(this month|end of (the )?month)\b", text):
        named = [
            w for w, _ in _CATEGORY_SYNONYMS.items() if re.search(rf"\b{re.escape(w)}\b", text)
        ]
        return QuerySpec(
            task_type="data_pointer",
            scope=scope,
            reason_mode="forecast",
            category=_CATEGORY_SYNONYMS[named[0]] if named else "",
        )
    return None


_BIGGEST_PURCHASE_RE = re.compile(
    r"\b(biggest|largest|most expensive|highest|top|priciest|costliest)\s+(?:single )?"
    r"(thing|item)s? i (bought|purchased|got|paid for|spent (?:money )?on)\b()|"
    r"\b(biggest|largest|most expensive|highest|top|priciest|costliest)\s+([a-z]+\s+)?"
    r"(purchase|transaction|expense|charge|buy)s?\b(?!\s+(categor|types?|areas?))|"
    # "did I have any big purchases last week"
    r"\bany (big|large|huge|major|expensive)\s+()()(purchase|transaction|expense|charge)s\b"
)
_MERCHANT_SPEND_RE = re.compile(
    r"\b(spend|spent|pay|paid)\s+(at|to|on|for)\s+([a-z][a-z0-9 .*]{1,30})"
)
# "spend on average per day", "pay for things": words that aren't a merchant name.
_GENERIC_NAME_RE = re.compile(
    r"(average|avg|things|stuff|everything|anything|what|it|that|this|them|an?|myself|me|"
    r"day|week|month|monthly|weekly|yearly|annual|total|largest|biggest|smallest|highest|"
    r"lowest|most|least|recent|latest|monday|tuesday|wednesday|thursday|"
    r"friday|saturday|sunday|weekdays?|weekends?|big|large|huge|major|small|expensive|"
    r"unusual|strange|weird|new|online|any)\b"
)
_SUBSCRIPTION_LIST_RE = re.compile(
    r"\b(what|which|list|show)\b.*\bsubscriptions\b|\bsubscriptions\b.*\bpaying\b"
)
_BUDGET_STATUS_RE = re.compile(r"\bbudgets?\b")


def _outside_summary_spec(text, summary, scope):
    """Asks the chat summary cannot answer in full; say where to look instead of
    asking the user for a metric they already gave."""
    biggest = _BIGGEST_PURCHASE_RE.search(text)
    if biggest:
        return QuerySpec(
            task_type="data_pointer",
            period_key=str(_selected_year(summary))
            if re.search(r"\b(this year|so far this year|year to date)\b", text)
            else _period_for(text, summary),
            scope=scope,
            reason_mode="biggest_purchase",
            category=_category_in(text, summary),
            # "my biggest expenses" asks for several, so list the top categories.
            compare_to="several" if biggest.group(0).endswith("s") else "",
        )
    merchant = _MERCHANT_SPEND_RE.search(text) or re.search(
        r"\b(buy|bought|purchase|purchased|shop|shopped) (anything |something |stuff )?"
        r"(at|from)\s+([a-z][a-z0-9 .*]{1,30})|"
        r"\b(charged|billed) (by|from)\s+([a-z][a-z0-9 .*]{1,30})|"
        r"\bcharges? (from|by)\s+([a-z][a-z0-9 .*]{1,30})",
        text,
    )
    if merchant and merchant.re is not _MERCHANT_SPEND_RE:
        merchant = re.search(r"(at|from|by)\s+()([a-z][a-z0-9 .*]{1,30})", merchant.group(0))
    if merchant and (
        _day_key(merchant.group(3)) or re.match(r"the \d{1,2}(st|nd|rd|th)\b", merchant.group(3))
    ):
        merchant = None  # "spend on oct 18" and "spend on the 14th" are dates
    if merchant and not _category_in(text, summary):
        name = re.sub(
            r"\b(this|last|in|during|each|every|a month|per|monthly|recently|lately|today|"
            r"yesterday)\b.*$",
            "",
            merchant.group(3),
        ).strip()
        if len(name) >= 3 and not _GENERIC_NAME_RE.match(name):
            return QuerySpec(
                task_type="data_pointer", scope=scope, reason_mode="merchant", category=name
            )
    if _SUBSCRIPTION_LIST_RE.search(text) and not _AMOUNT_ASK_RE.search(text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="subscriptions")
    if (
        _BUDGET_STATUS_RE.search(text)
        and not _ADVICE_RE.search(text)
        and not re.search(r"\bshould\b", text)
        and not re.search(r"\b(portion|share|percent|percentage|how much of)\b", text)
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="budget_status")
    return None


_COMPARE_WORD_RE = re.compile(
    r"\b(than|vs|versus|compare|compared|comparison|worse|better|difference|and|or|higher|"
    r"lower)\b"
)


def _named_month_keys(text, summary):
    """Month keys for the month names in text, in the order written."""
    anchor = (summary or {}).get("time_anchor") if isinstance(summary, dict) else None
    year = (anchor or {}).get("selected_year") if isinstance(anchor, dict) else None
    if not year:
        year = int(selected_month_key(summary)[:4])
    explicit_year = re.search(r"\b(20\d{2})\b", text)
    if explicit_year:
        year = int(explicit_year.group(1))
    elif re.search(r"\blast year\b", text):
        year = int(year) - 1  # "october last year"
    found = [(m.start(), m.group(1)) for m in re.finditer(r"\b(20\d{2}-\d{2})\b", text)]
    if not found:
        found = [(pos, f"{int(year)}-{num:02d}") for pos, num in month_mentions(text)]
        # "oct 18" names a day, not a month.
        found = [(pos, key) for pos, key in found if not _MONTH_DAY_RE.match(text[pos:])]
    keys = []
    for _, key in sorted(found):
        if key not in keys:
            keys.append(key)
    return keys


def _named_month_comparison(text, summary, scope):
    """ "is october worse than september", "compare food spending in august and
    september": two named months, optionally for one category."""
    # "was september lower than july" compares; "how do I lower my spending" asks for advice
    advice = _ADVICE_RE.search(text) and not re.search(r"\blower\b[a-z ]{0,30}\bthan\b", text)
    if not _COMPARE_WORD_RE.search(text) or advice:
        return None
    keys = _named_month_keys(text, summary)
    if len(keys) < 2 or len(keys) > 6:
        return None
    if len(keys) > 2 and re.search(r"\b(from|between)\b.*\b(to|through|until)\b", text):
        return None
    sum_ask = re.search(r"\b(in total|total|combined|altogether|together)\b", text) or (
        # "how much did I spend in july and august" wants both amounts, not a verdict.
        re.search(r"\bhow much\b", text)
        and not re.search(
            r"\b(than|vs|versus|compare|compared|comparison|worse|better|difference|more|less|"
            r"higher|lower|change|changed)\b",
            text,
        )
    )
    categories = _categories_in(text, summary)
    if sum_ask and len(categories) <= 1:
        return QuerySpec(
            task_type="amount_lookup",
            metric="income" if _amount_metric(text) == "income" else "expenses",
            period_type="month_range",
            period_key=",".join(sorted(keys)),
            scope=scope,
            category=categories[0] if categories else "",
        )
    if re.search(r"\b(biggest|top|largest|highest)\b.*\bcategor", text):
        return QuerySpec(
            task_type="top_category_lookup",
            metric="top_category",
            period_type="month_list",
            period_key=",".join(keys),
            scope=scope,
        )
    categories = _categories_in(text, summary)
    metric = _amount_metric(text)
    return QuerySpec(
        task_type="compare_periods",
        metric=metric if metric in {"income", "net"} and not categories else "expenses",
        period_type="month_range",
        period_key=",".join(keys),
        scope=scope,
        category=",".join(categories),
    )


def _earn_versus_spend(text, summary, scope):
    """ "Did I earn more than I spent this month?" is a net cash flow question."""
    if not re.search(r"\b(earn|earned|make|made|income)\b", text):
        return None
    if not re.search(r"\b(spend|spent|spending|expenses?)\b", text):
        return None
    if not re.search(r"\b(more|less|than)\b", text):
        return None
    if "last month" in text:
        month_key = previous_month_key(summary)
    else:
        month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
    # "am I spending more than I earn" is answered from the spending side.
    spend_at = re.search(r"\b(spend|spent|spending|expenses?)\b", text).start()
    earn_at = re.search(r"\b(earn|earned|make|made|income)\b", text).start()
    year_spec = _year_amount_spec(text, summary, scope, "net", [])
    if year_spec is not None and not _named_month_keys(text, summary):
        return dataclasses.replace(
            year_spec,
            reason_mode="earn_vs_spend",
            compare_to="spend_first" if spend_at < earn_at else "",
        )
    return QuerySpec(
        task_type="amount_lookup",
        metric="net",
        period_type="month",
        period_key=month_key,
        scope=scope,
        reason_mode="earn_vs_spend",
        compare_to="spend_first" if spend_at < earn_at else "",
    )


_TOO_MUCH_RE = re.compile(
    r"\b(too much|a lot|overspend|overspent|overspending|over spending|"
    r"(?:more|higher|less|lower|faster|slower|quicker)(?: [a-z]+){0,5} than "
    r"(?:my )?(?:usual|normal|average|typical)|"
    r"(?:more|less) than i (?:usually|normally|typically)(?: do| spend)?|"
    r"(?:above|below) (?:normal|usual)|normal for|typical for|is my spending normal|"
    r"reckless|careless|out of control|under control|in check|spending like crazy|going overboard|"
    r"spending (wisely|well|smartly|responsibly|sensibly)|overdoing|overdo it|out of hand|"
    r"(?:is|was) (?:my|this month s) (?:[a-z]+ )?(?:spending|expenses?) (?:this month |so far |"
    r"this month so far )?(?:normal|ok|okay|typical|usual|healthy|reasonable|fine|"
    r"high|too high|low|a lot)|"
    r"on track|on pace|at this rate|at this pace|at this point|end up spending|"
    r"(?:is|was) my spending (?:ok|okay|typical|usual|healthy|reasonable|fine|normal)|"
    r"(?:compared? (?:to|with)|vs|versus) (?:my )?(?:average|usual|normal)|"
    r"(?:over|above|under|below) (?:my )?(?:average|usual|normal)|"
    r"within (?:my )?(?:average|usual|normal))\b"
)


def _pace_check(text, summary, scope):
    """ "Did I spend too much on eating out?": this month against the user's usual."""
    forecast = (
        _FORECAST_RE.search(text) or re.search(r"\b(outlook|projection|projected|forecast)\b", text)
    ) and re.search(r"\b(this month|end of (the )?month)\b", text)
    over_amount = re.search(
        r"\b(will|am|going to|gonna) (i )?(go|be|end up|going to go|going to be|on track to go|"
        r"stay|keep it|remain)? ?"
        r"(over|above|under|below) (?P<amount>\d{2,6})( dollars)?\b|"
        r"\b(will|am) i (going to |gonna )?spend (more than|less than|over|under|above|below) "
        r"(?P<amount2>\d{2,6})\b",
        text,
    )
    if over_amount:
        return QuerySpec(
            task_type="pace_check",
            metric="expenses",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
            category=_category_in(text, summary),
            compare_to=(
                f"amount:{over_amount.group('amount') or over_amount.group('amount2')}:"
                + (
                    "under"
                    if re.search(r"\b(under|below|less than)\b", over_amount.group(0))
                    else "over"
                )
            ),
        )
    if not _TOO_MUCH_RE.search(text) and not forecast:
        return None
    if re.search(r"\b(how do i|how can i|how to|how should i|tips|stop|avoid)\b", text):
        return None  # "how do I stop overspending" asks for advice
    if re.search(r"\bbudgets?\b", text):
        return None  # budget limits aren't in the chat data; the budget pointer answers
    if re.search(r"\b(which|what) categor", text):
        return None  # "which category am I overspending in": the hotspot rule answers
    vs_last = re.search(
        r"\b(less|more|under|over|below|above|lower|higher|cheaper)\b.*\blast month\b", text
    )
    if vs_last and re.search(r"\b(on track|on pace|going to|gonna)\b", text):
        return QuerySpec(
            task_type="pace_check",
            metric="expenses",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
            category=_category_in(text, summary),
            compare_to="last_month",
        )
    vs_usual = forecast or re.search(
        r"\b(compared? (to|with)|vs|versus|over|above|under|below) (my )?(average|usual|normal)\b|"
        r"\bon track\b|"
        r"\bat this (rate|pace)\b|\bend up spending\b",
        text,
    )
    if (
        not vs_usual
        and not re.search(
            r"\b(spend|spent|spending|overspend|overspent|overspending|blow|blew|cash|money|"
            r"expenses?)\b",
            text,
        )
        and not _category_in(text, summary)
    ):
        return None
    if "last month" in text:
        month_key = previous_month_key(summary)
    else:
        month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
    return QuerySpec(
        task_type="pace_check",
        metric="expenses",
        period_type="month",
        period_key=month_key,
        scope=scope,
        category=_category_in(text, summary),
    )


def asks_transaction_list(text):
    """True when the message asks to see transactions rather than a total."""
    return bool(_TRANSACTION_LIST_RE.search(text or ""))


def _transaction_list_month(text, summary):
    """YYYY-MM the user wants transactions from, or "" for just the latest ones."""
    if "this month" in text or "current month" in text:
        return selected_month_key(summary)
    if "last month" in text:
        return previous_month_key(summary)
    anchor = (summary or {}).get("time_anchor") if isinstance(summary, dict) else None
    default_year = (anchor or {}).get("selected_year") if isinstance(anchor, dict) else None
    if not default_year:
        default_year = int(selected_month_key(summary)[:4])
    if re.search(r"\blast year\b", text) and not re.search(r"\b20\d{2}\b", text):
        default_year = int(default_year) - 1  # "october last year"
    return extract_specific_month_key(text, default_year)


def _normalize(message):
    text = fix_typos(clamp_str(message or "", 4000))
    text = re.sub(r"\b(last|previous|prior|past)\s+mo\b", r"\1 month", text)
    text = re.sub(r"\b(previous|prior|past)\s+month\b", "last month", text)
    text = re.sub(r"\blst\b", "last", text)
    text = re.sub(r"\b(last|past|this) fortnight\b", "past 2 weeks", text)
    text = re.sub(
        r"\b(more|less|better|worse|higher|lower|bigger|smaller) then\b", r"\1 than", text
    )
    text = re.sub(r"\bspeding\b", "spending", text)
    text = re.sub(r"\bspendng\b", "spending", text)
    text = re.sub(r"\bcategry\b", "category", text)
    text = re.sub(r"\bcatgeory\b", "category", text)
    text = re.sub(r"\btransections\b", "transactions", text)
    text = re.sub(r"\btransacations\b", "transactions", text)
    text = re.sub(r"\bpls\b", "please", text)
    # "the 2nd quarter" is Q2, not the 2nd of the month
    for number, words in ((1, "first|1st"), (2, "second|2nd"), (3, "third|3rd"), (4, "fourth|4th")):
        text = re.sub(rf"\b(the )?({words}) quarter\b", f"q{number}", text)
    # "what did I spend in month 2": the second month of the year
    text = re.sub(
        r"\b(in|for|during) month (1[0-2]|[1-9])\b",
        lambda m: f"{m.group(1)} {calendar.month_name[int(m.group(2))].lower()}",
        text,
    )
    text = re.sub(r"\bthx\b", "thanks", text)
    text = re.sub(r"\bwanna\b", "want to", text)
    text = re.sub(r"\bgonna\b", "going to", text)
    text = re.sub(r"\bur\b", "your", text)
    text = re.sub(r"\bu\b", "you", text)
    text = re.sub(r"\b(mnth|mth)\b", "month", text)
    text = re.sub(r"\bspnd\b", "spend", text)
    text = re.sub(r"\bthis\s+mo\b", "this month", text)
    text = re.sub(r"\bcurrent\s+mo\b", "current month", text)
    text = re.sub(r"\bthis\s+yr\b", "this year", text)
    text = re.sub(r"\b(previous|prior)\s+year\b", "last year", text)
    # Keep what "$" and "%" meant before punctuation goes: "$200" vs "20%".
    text = re.sub(
        r"\$\s?(\d[\d,]*(?:\.\d+)?)", lambda m: m.group(1).replace(",", "") + " dollars", text
    )
    text = re.sub(r"(\d)\s*%", r"\1 percent", text)
    # Remove noisy punctuation/emojis while preserving date separators.
    text = re.sub(r"[^a-z0-9\s\-/#]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def credit_card_scope(summary):
    """True when the chat is scoped to one credit card account. Money into a card is
    payments and refunds, so income, net cash flow and savings don't apply to it."""
    if not isinstance(summary, dict) or summary.get("scope") != "single_account":
        return False
    account_type = str(summary.get("account_type", "") or "").lower()
    if account_type:
        return account_type == "credit"
    # Older app builds send no account type; fall back to the account's name.
    return bool(re.search(r"\bcredit\b", str(summary.get("scope_label", "")), re.I))


_INCOME_TASKS = {
    "affordability",
    "saving_target",
    "goal_time",
    "month_outlook",
    "extra_spend",
}


def _has_spending(summary, category):
    """True when any month in the summary has spending in this category."""
    if not isinstance(summary, dict):
        return True
    rows = (summary.get("month_index") or {}).values()
    with_categories = [
        r for r in rows if isinstance(r, dict) and isinstance(r.get("categories"), dict)
    ]
    if not with_categories:
        return True  # older app builds send no per-month categories
    wanted = category.lower()
    return any(
        float(v or 0) > 0
        for row in with_categories
        for k, v in row["categories"].items()
        if str(k).lower() == wanted
    )


def _scope_guard(spec, summary):
    """Answers the selected account can't give: a category it never spends on, and
    income or savings on a credit card."""
    if spec.task_type in {"data_pointer", "general"}:
        return spec
    canonical = {n.lower() for n in _CATEGORY_SYNONYMS.values()} | {
        n.lower() for n in _APPROX_TERMS.values()
    }
    for name in [n.strip() for n in (spec.category or "").split(",") if n.strip()]:
        if name.lower() in canonical and not _has_spending(summary, name):
            return QuerySpec(
                task_type="data_pointer",
                scope=spec.scope,
                reason_mode="absent_category",
                category=name,
            )
    if credit_card_scope(summary) and (
        # Overviews drop income themselves; "save $300 a month" is plain arithmetic.
        (
            spec.metric in {"income", "net", "both"}
            and spec.task_type not in {"month_overview", "what_if"}
        )
        or spec.task_type in _INCOME_TASKS
        or spec.reason_mode in {"savings_rate", "share_of_income", "rule_of_thumb", "capacity"}
    ):
        return QuerySpec(task_type="data_pointer", scope=spec.scope, reason_mode="card_income")
    return spec


_ASKED_LESS_RE = re.compile(
    r"\b(cheaper|less|lower|smaller|drop|dropped|decrease|decreased|go down|gone down|went down|"
    r"going down|fall|fell|shrink|shrank|decline|declined)\b"
)
_ASKED_MORE_RE = re.compile(
    r"\b(more expensive|pricier|more|higher|bigger|increase|increased|go up|gone up|went up|"
    r"going up|rise|rose|risen|grow|grew|grown|climb|climbed)\b"
)
_CHANGE_RE = re.compile(
    r"\b(change|changed|changes|differ|different|difference|go(ne)? (up|down)|"
    r"went (up|down)|drop|dropped|increased?|decreased?|rise|rose|risen|fall|fell|grow|grew|"
    r"grown|shrink|shrank|climb|climbed|decline|declined|double|doubled|triple|tripled)\b"
)
_SPAN_EDGE = r"(?:(?:the )?(?:start|beginning|end|middle) of |early |late |mid )?"
_SPAN_RE = re.compile(
    rf"\b(?:from|between) {_SPAN_EDGE}([a-z]+(?: 20\d{{2}})?|20\d{{2}}-\d{{2}}) "
    rf"(?:to|through|thru|until|and) {_SPAN_EDGE}([a-z]+(?: 20\d{{2}})?|20\d{{2}}-\d{{2}})\b"
)


def _span_keys(text, summary):
    """ "from november to february" as (start, end) month keys, or None."""
    span = _SPAN_RE.search(text)
    if not span:
        return None
    if span.group(2) in {"now", "today", "date", "present"}:
        # "from july to now": to the running month
        start = _named_month_keys(f"from {span.group(1)}", summary)
        if len(start) != 1:
            return None
        return start[0], date_cls.today().strftime("%Y-%m")
    keys = _named_month_keys(f"from {span.group(1)} to {span.group(2)}", summary)
    if len(keys) != 2:
        return None
    start, end = keys
    first_year = re.search(r"20\d{2}", span.group(1))
    last_year = re.search(r"20\d{2}", span.group(2))
    if first_year:
        start = f"{first_year.group(0)}{start[4:]}"
    if last_year:
        end = f"{last_year.group(0)}{end[4:]}"
    if start > end and not first_year:
        start = f"{int(start[:4]) - 1}{start[4:]}"  # "from november to february"
    elif start > end and not last_year:
        end = f"{int(end[:4]) + 1}{end[4:]}"  # "from december 2025 to march"
    return min(start, end), max(start, end)


def _changed(text):
    return bool(
        _CHANGE_RE.search(text) or re.search(r"\b(improved?|worse|worsened|better)\b", text)
    )


def _span_change(asked, spec, summary, history=None):
    """ "did my food spending go up from july to september": September against July,
    not the three months added up. A short follow-up ("and income?", "and from june to
    september?") keeps the previous question's span or its change ask."""
    prev = ""
    if history and len(asked.split()) <= 7:
        prev = _normalize(_last_user_text(history) or "")
    source = asked
    if not _SPAN_RE.search(asked):
        if not (
            prev
            and _SPAN_RE.search(prev)
            and _FOLLOWUP_CUE_RE.match(asked)
            and not _PERIOD_WORDS_RE.search(asked)
            and not re.search(r"\b(total|altogether|combined|in all)\b", asked)
        ):
            return None
        source = prev
    if _changed(asked):
        lead_text = asked
    elif prev and _changed(prev) and (source == prev or _FOLLOWUP_CUE_RE.match(asked)):
        lead_text = prev
    else:
        return None
    card_income = spec.task_type == "data_pointer" and spec.reason_mode == "card_income"
    saving = re.search(r"\b(savings|saved|saving)\b", asked) and _SAVING_RE.search(asked)
    named_metric = _amount_metric(asked) in {"income", "net", "expenses"} or saving
    if not card_income and spec.task_type not in {
        "amount_lookup",
        "compare_periods",
        "spending_trend",
        "category_spending",
    }:
        if not (spec.task_type in {"general", "derived_metric"} and named_metric):
            return None
    keys = _span_keys(source, summary)
    if not keys:
        return None
    earlier, later = keys
    if earlier == later:
        return None
    categories = [c for c in (spec.category or "").split(",") if c]
    if len(categories) > 1:
        return None
    metric = spec.metric if spec.metric in {"income", "net"} else "expenses"
    if metric == "expenses" and _amount_metric(asked) in {"income", "net"}:
        metric = _amount_metric(asked)  # "has my net cash flow gone down from may to august"
    if saving and not categories:
        metric = "net"  # "how did my savings change from june to august"
    if card_income or (credit_card_scope(summary) and metric in {"income", "net"}):
        # A card has no income: say what came in over the span instead.
        return _scope_guard(
            QuerySpec(
                task_type="amount_lookup",
                metric="income",
                period_type="month_range",
                period_key=",".join(_months_between(earlier, later)),
                scope=spec.scope,
            ),
            summary,
        )
    compare = QuerySpec(
        task_type="compare_periods",
        metric="expenses" if categories else metric,
        period_type="month_range",
        period_key=f"{later},{earlier}",
        scope=spec.scope,
        category=",".join(categories),
    )
    # "from july to september, did it go up": a yes-or-no question after the span
    span = _SPAN_RE.search(lead_text)
    lead = re.sub(rf"^{re.escape(span.group(0))},? ", "", lead_text) if span else lead_text
    compare = _asked_direction(lead, compare)
    better = re.search(r"\b(better|improved?)\b|\b(worse|worsened)\b", lead)
    if (
        not compare.compare_to
        and better
        and compare.metric in {"income", "net"}
        and re.match(r"^(was|is|were|did|has|have)\b", lead)
    ):
        # "did my net cash flow get better": higher is better for income and savings
        compare = dataclasses.replace(
            compare, compare_to="asked_more" if better.group(1) else "asked_less"
        )
    return _scope_guard(compare, summary)


_TOP_CATEGORY_ASK_RE = re.compile(
    r"\b(spend|spent) (the )?most (money )?on\b|\b(top|biggest|largest|main) (spending )?"
    r"categor(y|ies)\b|\bmost (of )?(my )?money (go|went)\b|\bwhere did (most of )?my money go\b|"
    r"\b(biggest|largest|main|top) (expenses|costs)\b"
)


def _quarter_extreme(asked, spec, summary):
    """ "which quarter did I spend the most in", "which season": each one summed."""
    which = re.search(r"\b(which|what) (quarter|season)\b", asked)
    if not which:
        return None
    metric = _amount_metric(asked)
    if metric not in {"income", "net"}:
        metric = "expenses"
    if _SAVING_RE.search(asked):
        metric = "net"
    categories = _categories_in(asked, summary)
    lowest = re.search(r"\b(least|lowest|cheapest|less|smallest|fewest)\b", asked)
    return _scope_guard(
        QuerySpec(
            task_type="month_extreme",
            metric="expenses" if categories else metric,
            period_type="quarters_of_year" if which.group(2) == "quarter" else "seasons_of_year",
            period_key=str(_selected_year(summary)),
            scope=spec.scope,
            reason_mode="lowest" if lowest else "highest",
            category=categories[0] if len(categories) == 1 else "",
        ),
        summary,
    )


def _within_group(asked, spec, summary):
    """ "which month in q2 was the most expensive", "top category in q3", "my most
    expensive month this summer": the months of that quarter, half or season."""
    if spec.task_type == "spending_trend" and spec.reason_mode in {
        "volatility",
        "average",
        "trend",
    }:
        months = _month_range_spec(asked, summary)
        if months and not _named_month_keys(asked, summary):
            current = date_cls.today().strftime("%Y-%m")
            done = [k for k in months.split(",") if k < current]
            if spec.reason_mode == "trend" and current in months and len(done) < 2 and done:
                # "is my spending going down this fall": this month (at its pace) vs the last
                compare = QuerySpec(
                    task_type="compare_periods",
                    metric=spec.metric,
                    period_type="month_range",
                    period_key=f"{current},{done[-1]}",
                    scope=spec.scope,
                    category=spec.category,
                )
                return _asked_direction(asked, compare)
            # "was my income steady over the summer": those months, not every month
            return dataclasses.replace(spec, period_type="month_range", period_key=months)
    card_income = (
        spec.task_type == "data_pointer"
        and spec.reason_mode == "card_income"
        and spec.period_type == "month"
    )
    grouped = (
        (spec.task_type == "amount_lookup" and spec.period_type == "month")
        or (spec.task_type == "derived_metric" and spec.reason_mode == "savings_rate")
        or (spec.task_type == "category_spending" and spec.period_type == "month")
        or card_income
    )
    if grouped:
        if _named_month_keys(asked, summary) or _changed(asked):
            return None  # "in july" wins over a season word; "did it fall" isn't autumn
        months = _month_range_spec(asked, summary)
        if (
            not months
            and spec.task_type == "category_spending"
            and spec.reason_mode in {"versus", "share", "share_of_income"}
            and re.search(r"\b(so far )?this year\b", asked)
            and isinstance(summary, dict)
        ):
            # "more on shopping or entertainment this year": the year's months
            year = str(_selected_year(summary))
            months = ",".join(
                sorted(
                    k for k in (summary.get("month_index") or {}) if str(k).startswith(f"{year}-")
                )
            )
        if not months:
            return None
        if card_income:
            return dataclasses.replace(spec, period_key=months)
        return _net_sign(
            asked, dataclasses.replace(spec, period_type="month_range", period_key=months)
        )
    if spec.task_type not in {"month_extreme", "top_category_lookup"}:
        return None
    if spec.period_type not in {"year", "month"}:
        return None
    mode = spec.reason_mode or ""
    if spec.task_type == "top_category_lookup" and mode and not mode.startswith(("top:", "rank:")):
        return None  # "is food my top category this summer" stays a single-month check
    months = _month_range_spec(asked, summary)
    if not months:
        return None
    return dataclasses.replace(spec, period_type="month_range", period_key=months)


_SERIES_RE = re.compile(
    r"\b(each|every|per|by) month\b|\bmonth by month\b|\bmonthly (spending|income|expenses|"
    r"totals?|breakdown|savings|net cash flow)\b|\b(show|list|break down)( me)? (my )?monthly\b"
)


def _span_series(asked, spec, summary, history=None):
    """ "how much did I spend each month between july and september", "show my monthly
    spending from march to june": one line per month, not an average or one total."""
    if not _SERIES_RE.search(asked) or re.search(
        r"\b(average|avg|on average|typical|typically|usual|usually|normal|normally|roughly|"
        r"trend|trending|going)\b",
        asked,
    ):
        return None
    card_income = spec.task_type == "data_pointer" and spec.reason_mode == "card_income"
    if not card_income and spec.task_type not in {
        "amount_lookup",
        "spending_trend",
        "compare_periods",
        "category_spending",
    }:
        return None
    keys = _span_keys(asked, summary)
    months = ",".join(_months_between(*keys)) if keys else _month_range_spec(asked, summary)
    listing = re.search(r"\bby month\b|\bmonth by month\b|\b(show|list|break down)\b", asked)
    this_year = re.sub(r"\b(so far )?this year\b|\bin 20\d{2}\b", " ", asked)
    if (
        not months
        and listing
        and not _PERIOD_WORDS_RE.search(this_year)
        and isinstance(summary, dict)
    ):
        # "show me income by month": every month of the year so far
        index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        year = str(_selected_year(summary))
        mine = sorted(k for k in index if str(k).startswith(f"{year}-"))
        months = ",".join(mine)
    if not months:
        return None
    if card_income:
        return dataclasses.replace(spec, period_type="month", period_key=months)
    categories = [c for c in (spec.category or "").split(",") if c]
    metric = spec.metric if spec.metric in {"income", "net"} else "expenses"
    if metric == "expenses" and _amount_metric(asked) in {"income", "net"}:
        metric = _amount_metric(asked)
    if _SAVING_RE.search(asked) and not categories:
        metric = "net"
    return _scope_guard(
        QuerySpec(
            task_type="compare_periods",
            metric="expenses" if categories else metric,
            period_type="month_range",
            period_key=months,
            scope=spec.scope,
            category=",".join(categories),
            reason_mode="series",
        ),
        summary,
    )


def _spend_allowance(asked, spec, summary):
    """ "how much can I spend per day for the rest of october to stay under $2000" """
    match = re.search(
        r"\bhow much (?:more )?(?:can|could|should) i (?:still )?spend\b.*?\b(?:stay|keep it|"
        r"remain|be|keep|end) (?:under|below|within|at or under) (\d{2,7})\b",
        asked,
    )
    if not match:
        return None
    categories = _categories_in(asked, summary)
    return _scope_guard(
        QuerySpec(
            task_type="pace_check",
            metric="expenses",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=spec.scope if spec.scope != "unknown" else "all_accounts",
            category=categories[0] if len(categories) == 1 else "",
            compare_to=f"allowance:{match.group(1)}",
        ),
        summary,
    )


def _fastest_category(asked, spec, summary):
    """ "which category is growing the fastest": the last full month against two before."""
    if not re.search(r"\b(which|what) categor(y|ies)\b", asked) or not re.search(
        r"\b(growing|rising|increasing|going up|shrinking|falling|dropping|going down)\b", asked
    ):
        return None
    if _named_month_keys(asked, summary):
        return None
    last_full = _months_back(date_cls.today().strftime("%Y-%m"), 1)
    falling = re.search(r"\b(shrinking|falling|dropping|going down)\b", asked)
    return QuerySpec(
        task_type="category_change",
        metric="expenses",
        period_type="month_range",
        period_key=f"{_months_back(last_full, 2)},{last_full}",
        scope=spec.scope,
        reason_mode="down" if falling else "up",
    )


def _year_trend(asked, spec, summary):
    """ "how did my health spending change over the year": the year's months as a trend."""
    if not (
        _changed(asked)
        and re.search(r"\b(over|during|through(out)?) the (whole )?year\b|\bthis year\b", asked)
    ):
        return None
    if spec.task_type not in {"amount_lookup", "category_spending"} or spec.period_type != "year":
        return None
    if spec.metric not in {"expenses", "income", "net"} and not spec.category:
        return None
    return QuerySpec(
        task_type="spending_trend",
        metric=spec.metric if spec.metric in {"income", "net"} else "expenses",
        period_type="year",
        period_key=spec.period_key,
        scope=spec.scope,
        reason_mode="trend",
        category=spec.category,
    )


def _week_of(asked, spec, summary):
    """ "my expenses in the week of october 5": that day and the six after it."""
    week = re.search(
        r"\bweek of ((?:the )?[a-z]+ \d{1,2}(?:st|nd|rd|th)?|20\d{2}-\d{2}-\d{2})\b", asked
    )
    if not week:
        return None
    day = _day_key(f"on {week.group(1)}", _selected_year(summary))
    if not day:
        return None
    start = date_cls.fromisoformat(day)
    return QuerySpec(
        task_type="day_span",
        metric="expenses",
        period_type="days",
        period_key=f"{start.isoformat()},{(start + timedelta(days=6)).isoformat()}",
        scope=spec.scope if spec.scope != "unknown" else "all_accounts",
    )


def _up_or_down_in(asked, spec, summary):
    """ "did my spending go up or down in september", "did it drop in september":
    September against August."""
    either = re.search(
        r"\b(go|went|gone) (up or down|down or up)\b|\b(increase|rise) or (decrease|fall|drop)\b",
        asked,
    )
    if not either and not (
        _changed(asked)
        and re.search(r"\bin ([a-z]+)\b", asked)
        and not re.search(r"\b(from|between|since|than|compared?|vs|versus)\b", asked)
        and spec.task_type in {"amount_lookup", "category_spending", "explain"}
        and not re.match(r"^(why|how come|what)\b", asked)
    ):
        return None
    keys = _named_month_keys(asked, summary)
    if len(keys) != 1 or re.search(r"\bsince\b", asked):
        return None
    categories = [c for c in (spec.category or "").split(",") if c]
    if len(categories) > 1:
        return None
    metric = _amount_metric(asked)
    compare = QuerySpec(
        task_type="compare_periods",
        metric="expenses" if categories or metric not in {"income", "net"} else metric,
        period_type="month_range",
        period_key=f"{keys[0]},{_months_back(keys[0], 1)}",
        scope=spec.scope,
        category=",".join(categories),
    )
    return _scope_guard(compare if either else _asked_direction(asked, compare), summary)


_WEEK_WORDS_RE = re.compile(
    r"\b(last week|this week|past week|last 7 days|past 7 days)\b|"
    r"\b(?:last|past) (\d{1,2}|two|three|four) (days|weeks)\b"
)


def _week_by_category(asked, spec, summary):
    """ "did I spend anything on entertainment this week", "what did I spend the most on
    last week": chat has category totals by month only."""
    week = _WEEK_WORDS_RE.search(asked)
    if not week or _named_month_keys(asked, summary):
        return None
    days = ""
    if week.group(2):
        count = int(week.group(2)) if week.group(2).isdigit() else _NUMBER_WORDS[week.group(2)]
        days = str(count * 7 if week.group(3) == "weeks" else count)
    categories = [c for c in (spec.category or "").split(",") if c] or (
        _categories_in(asked, summary) if spec.task_type == "day_span" else []
    )
    if spec.task_type in {"category_spending", "day_span"} and len(categories) == 1:
        return QuerySpec(
            task_type="data_pointer",
            period_key=selected_month_key(summary),
            scope=spec.scope,
            category=categories[0],
            reason_mode="category_week",
            compare_to=days,
        )
    if _TOP_CATEGORY_ASK_RE.search(asked) and spec.task_type in {
        "amount_lookup",
        "top_category_lookup",
        "day_span",
    }:
        return QuerySpec(
            task_type="data_pointer",
            period_key=selected_month_key(summary),
            scope=spec.scope,
            reason_mode="category_week",
        )
    return None


def _saving_enough(asked, spec, summary):
    """ "am I saving enough": the savings rate of the recent full months, judged."""
    if not re.search(r"\b(am i|are we|have i been) sav(ing|e) enough\b|\bsaving enough\b", asked):
        return None
    index = summary.get("month_index") if isinstance(summary, dict) else None
    current = date_cls.today().strftime("%Y-%m")
    recent = sorted(k for k in (index or {}) if k < current)[-3:]
    if not recent:
        return None
    return _scope_guard(
        QuerySpec(
            task_type="derived_metric",
            metric="net",
            period_type="month_range",
            period_key=",".join(recent),
            scope=spec.scope if spec.scope != "unknown" else "all_accounts",
            reason_mode="savings_rate",
            compare_to="good",
        ),
        summary,
    )


def _week_before_last(asked, spec, summary):
    """ "how much did I spend the week before last": 8 to 14 days ago."""
    if not re.search(r"\b(the )?week before last\b|\btwo weeks ago\b|\b2 weeks ago\b", asked):
        return None
    today = date_cls.today()
    return QuerySpec(
        task_type="day_span",
        metric="expenses",
        period_type="days",
        period_key=f"{(today - timedelta(days=13)).isoformat()},{(today - timedelta(days=7)).isoformat()}",
        scope=spec.scope if spec.scope != "unknown" else "all_accounts",
    )


def _month_halves(asked, spec, summary):
    """ "was my spending higher in the first or second half of september" """
    if not re.search(r"\bfirst\b.*\bsecond half\b|\bsecond\b.*\bfirst half\b", asked):
        return None
    month = re.search(r"\bhalf of ([a-z]+)\b", asked)
    keys = _named_month_keys(month.group(0), summary) if month else []
    if not keys and re.search(r"\b(this|last) month\b", asked):
        keys = [
            previous_month_key(summary) if "last month" in asked else selected_month_key(summary)
        ]
    if len(keys) != 1:
        return None
    return QuerySpec(
        task_type="week_compare",
        metric="expenses",
        scope=spec.scope if spec.scope != "unknown" else "all_accounts",
        reason_mode="halves",
        period_key=keys[0],
    )


def _good_month(asked, spec, summary):
    """ "was september a good month for my finances": its net cash flow, judged."""
    match = re.search(
        r"\b(?:was|is) ([a-z]+|this month|last month) a (good|bad|ok|okay|decent) month\b", asked
    )
    if not match:
        return None
    if match.group(1) == "this month":
        keys = [selected_month_key(summary)]
    elif match.group(1) == "last month":
        keys = [previous_month_key(summary)]
    else:
        keys = _named_month_keys(f"in {match.group(1)}", summary)
    if len(keys) != 1:
        return None
    return _scope_guard(
        QuerySpec(
            task_type="amount_lookup",
            metric="net",
            period_type="month",
            period_key=keys[0],
            scope=spec.scope if spec.scope != "unknown" else "all_accounts",
            reason_mode="earn_vs_spend",
            compare_to="judge",
        ),
        summary,
    )


def _months_saved(asked, spec, summary):
    """ "how many months this year did I save money": months where income beat spending."""
    if not re.search(r"\b(how many|which) months\b", asked) or not _SAVING_RE.search(asked):
        return None
    return _scope_guard(
        QuerySpec(
            task_type="count_months",
            metric="net",
            period_type="year",
            period_key=str(_selected_year(summary)),
            scope=spec.scope if spec.scope != "unknown" else "all_accounts",
            reason_mode="over",
            compare_to="0",
        ),
        summary,
    )


def _week_vs_usual(asked, spec, summary):
    """ "is my spending this week normal": the last 7 days against a usual week."""
    if not re.search(r"\b(this|last|past) week\b|\blast 7 days\b", asked) or not re.search(
        r"\b(normal|usual|typical|a lot|too much|high|low|ok|okay)\b", asked
    ):
        return None
    if [c for c in (spec.category or "").split(",") if c] or _categories_in(asked, summary):
        return None
    return QuerySpec(
        task_type="week_compare",
        metric="expenses",
        scope=spec.scope if spec.scope != "unknown" else "all_accounts",
        reason_mode="usual",
    )


def _this_month_versus(asked, spec, summary):
    """ "is my spending this month higher than in july": this month against July."""
    if spec.task_type not in {"amount_lookup", "category_spending"}:
        return None
    if not re.search(r"\b(this|current) month\b", asked) or not re.search(
        r"\b(than|vs|versus|compared?|comparison)\b", asked
    ):
        return None
    current = selected_month_key(summary)
    others = [k for k in _named_month_keys(asked, summary) if k != current]
    if len(others) != 1:
        return None
    categories = [c for c in (spec.category or "").split(",") if c]
    if len(categories) > 1:
        return None
    compare = QuerySpec(
        task_type="compare_periods",
        metric="expenses" if categories else spec.metric,
        period_type="month_range",
        period_key=f"{current},{others[0]}",
        scope=spec.scope,
        category=",".join(categories),
    )
    return _scope_guard(_asked_direction(asked, compare), summary)


def _net_sign(asked, spec):
    """ "was my net cash flow positive between april and june": a yes or no."""
    sign = re.search(
        r"\b(positive|in the green|saved?|save money|(?:earn|earned|made|make) more than i "
        r"(?:spend|spent))\b|\b(negative|in the red|spen[dt] more than i (?:earn|earned|made|make))\b",
        asked,
    )
    if spec.metric == "net" and sign and re.match(r"^(was|is|were|did|have|has)\b", asked):
        return dataclasses.replace(spec, compare_to="positive" if sign.group(1) else "negative")
    return spec


_TOP_MONTHS_RE = re.compile(
    r"\b(?:top|biggest|highest|most expensive|largest|worst)\s+(\d|two|three|four|five|six)"
    r"\s+months\b|\b(\d|two|three|four|five|six)\s+(?:biggest|most expensive|highest|largest|"
    r"worst|priciest)\s+months\b|\b(\d|two|three|four|five|six)\s+(cheapest|lowest|smallest)"
    r"\s+months\b"
)


def _biggest_monthly(asked, spec, summary):
    """ "what's my biggest monthly expense": the category with the highest monthly average."""
    if not re.search(
        r"\b(biggest|largest|main|top|highest) monthly (expense|cost|bill|spending)s?\b", asked
    ):
        return None
    index = summary.get("month_index") if isinstance(summary, dict) else None
    current = date_cls.today().strftime("%Y-%m")
    recent = sorted(k for k in (index or {}) if k < current)[-3:]
    if not recent:
        return None
    return _scope_guard(
        QuerySpec(
            task_type="top_category_lookup",
            metric="top_category",
            period_type="month_range",
            period_key=",".join(recent),
            scope=spec.scope if spec.scope != "unknown" else "all_accounts",
            reason_mode="avg",
        ),
        summary,
    )


def _top_months(asked, spec, summary):
    """ "what were my three biggest months this year" """
    match = _TOP_MONTHS_RE.search(asked)
    if not match:
        return None
    raw = match.group(1) or match.group(2) or match.group(3)
    n = int(raw) if raw.isdigit() else _NUMBER_WORDS[raw]
    metric = _amount_metric(asked)
    categories = _categories_in(asked, summary)
    return _scope_guard(
        QuerySpec(
            task_type="month_extreme",
            metric="expenses" if categories or metric not in {"income", "net"} else metric,
            period_type="year",
            period_key=str(_selected_year(summary)),
            scope=spec.scope,
            reason_mode=f"{'bottom' if match.group(3) else 'top'}:{n}",
            category=categories[0] if len(categories) == 1 else "",
        ),
        summary,
    )


def _span_period(asked, spec, summary, history=None):
    """Questions about a span of months that were read as one month or the whole year:
    "cheapest month between april and september", "average between may and august",
    "what did I spend the most on between june and august", "saved from may to july".
    A short follow-up ("how about food?", "how much is that per month?") keeps the
    previous question's span."""
    keys = _span_keys(asked, summary)
    if not keys and history and len(asked.split()) <= 7 and not _PERIOD_WORDS_RE.search(asked):
        if _FOLLOWUP_CUE_RE.match(asked) or re.search(r"\b(that|this|it|those)\b", asked):
            keys = _span_keys(_normalize(_last_user_text(history) or ""), summary)
    if not keys:
        return None
    months = ",".join(_months_between(*keys))
    if _TOP_CATEGORY_ASK_RE.search(asked) and spec.task_type in {
        "compare_periods",
        "top_category_lookup",
        "amount_lookup",
    }:
        return _scope_guard(
            QuerySpec(
                task_type="top_category_lookup",
                metric="expenses",
                period_type="month_range",
                period_key=months,
                scope=spec.scope,
            ),
            summary,
        )
    if spec.task_type == "month_extreme" and "," not in (spec.category or ""):
        return dataclasses.replace(spec, period_type="month_range", period_key=months)
    if spec.task_type == "spending_trend" and spec.reason_mode in {"average", "trend", "per_week"}:
        return dataclasses.replace(spec, period_type="month_range", period_key=months)
    if spec.task_type == "category_spending" and spec.period_type == "month" and spec.category:
        # "food from the start of june to the end of august": each month and the total
        return QuerySpec(
            task_type="compare_periods",
            metric="expenses",
            period_type="month_range",
            period_key=months,
            scope=spec.scope,
            category=spec.category,
            reason_mode="series",
        )
    if spec.task_type == "amount_lookup" and spec.period_type in {"month", "month_range"}:
        return _net_sign(
            asked, dataclasses.replace(spec, period_type="month_range", period_key=months)
        )
    if spec.task_type == "data_pointer" and spec.reason_mode == "card_income":
        return dataclasses.replace(spec, period_type="month", period_key=months)
    return None


def _since_trend(asked, spec, summary):
    """ "has my food spending gone up since may": the months from May on, as a trend."""
    since = re.search(r"\bsince (?:the (?:start|beginning) of )?([a-z]+)\b", asked)
    after = re.search(r"\bafter ([a-z]+)\b", asked)
    if not since and after and _changed(asked):
        since = re.search(r"since ([a-z]+)", f"since {after.group(1)}")  # "did it drop after june"
    if since and spec.task_type == "data_pointer" and spec.reason_mode == "card_income":
        months = _since_months(since.group(0), summary)
        return dataclasses.replace(spec, period_key=months) if months else None
    average = spec.task_type == "spending_trend" and spec.reason_mode in {
        "average",
        "per_week",
        "per_year",
        "volatility",
    }
    changed = _changed(asked) or re.search(
        r"\b(trend|trending|going (up|down)|stayed the same|stay the same|stable|steady|flat|"
        r"consistent)\b",
        asked,
    )
    if not since or not (changed or average):
        return None
    if spec.task_type not in {
        "spending_trend",
        "compare_periods",
        "amount_lookup",
        "category_spending",
    }:
        return None
    start = _named_month_keys(since.group(0), summary)  # "since may", not "may" alone
    if not start and _month_range_spec(since.group(1), summary):
        start = [_month_range_spec(since.group(1), summary).split(",")[0]]  # "since spring"
    if len(start) != 1:
        return None
    last_full = _months_back(date_cls.today().strftime("%Y-%m"), 1)
    if start[0] >= last_full:
        return None
    categories = [c for c in (spec.category or "").split(",") if c]
    if len(categories) > 1:
        return None
    metric = spec.metric if spec.metric in {"income", "net"} else "expenses"
    if metric == "expenses" and _amount_metric(asked) in {"income", "net"}:
        metric = _amount_metric(asked)
    months = _months_between(start[0], last_full)
    if not average and len(months) < 3:
        # "has my food spending dropped since august": too few full months for a trend,
        # so this month (at its pace) against August.
        compare = QuerySpec(
            task_type="compare_periods",
            metric="expenses" if categories else metric,
            period_type="month_range",
            period_key=f"{date_cls.today().strftime('%Y-%m')},{start[0]}",
            scope=spec.scope,
            category=",".join(categories),
        )
        return _scope_guard(_asked_direction(asked, compare), summary)
    return _scope_guard(
        QuerySpec(
            task_type="spending_trend",
            metric="expenses" if categories else metric,
            period_type="month_range",
            period_key=",".join(months),
            scope=spec.scope,
            reason_mode=spec.reason_mode if average else "trend",
            category=",".join(categories),
        ),
        summary,
    )


_QUARTER_MENTION_RE = re.compile(
    r"\bq([1-4])(?: (20\d{2}))?\b|\b(first|second|third|fourth) quarter(?: of (20\d{2}))?\b|"
    # "the first half of the year or the second half", not "the second half of summer"
    r"\b(first|second) half\b(?: of (?:the year|this year|(20\d{2})))?(?! of)|"
    r"\b(spring|summer|fall|autumn|winter)\b(?: (20\d{2}))?"
)
_SEASON_NUMBERS = {"spring": 1, "summer": 2, "fall": 3, "autumn": 3, "winter": 4}
_SAVING_RE = re.compile(r"\b(savings|saved|save|saving)\b(?! (account|goal|rate))")


def group_months(label):
    """ "2026-Q3", "2026-H1", "2026-S2" (summer) as their month keys."""
    year, kind, part = int(label[:4]), label[5], int(label[6:])
    if kind == "S":
        start = 3 * part  # spring 3, summer 6, fall 9, winter 12 of the year before
        if part == 4:
            return [f"{year - 1}-12", f"{year}-01", f"{year}-02"]
        return [f"{year}-{m:02d}" for m in range(start, start + 3)]
    size = 6 if kind == "H" else 3
    return [f"{year}-{m:02d}" for m in range(size * part - size + 1, size * part + 1)]


def _group_mentions(asked, summary):
    found = []
    current = selected_month_key(summary)
    this_q = f"{current[:4]}-Q{(int(current[5:]) - 1) // 3 + 1}"
    last_q = (
        f"{int(current[:4]) - 1}-Q4"
        if this_q.endswith("Q1")
        else f"{this_q[:6]}{int(this_q[6]) - 1}"
    )
    relative = [
        (m.start(), this_q if m.group(1) in {"this", "current"} else last_q)
        for m in re.finditer(r"\b(this|current|last|previous) quarter\b", asked)
    ]
    for pos, label in sorted(relative):
        if label not in found:
            found.append(label)
    if relative:
        return found
    for m in _QUARTER_MENTION_RE.finditer(asked):
        year = m.group(2) or m.group(4) or m.group(6) or m.group(8) or str(_selected_year(summary))
        if m.group(7):
            label = f"{year}-S{_SEASON_NUMBERS[m.group(7)]}"
        elif m.group(5):
            label = f"{year}-H{1 if m.group(5) == 'first' else 2}"
        else:
            label = f"{year}-Q{int(m.group(1)) if m.group(1) else _QUARTER_WORDS[m.group(3)]}"
        if label not in found:
            found.append(label)
    return found


def _quarter_compare(asked, spec, summary):
    """ "did I earn more in q2 or q3", "summer compared to spring": two quarters, halves or
    seasons, each summed over its months."""
    found = _group_mentions(asked, summary)
    if (
        len(found) == 1
        and found[0][5] == "Q"
        and re.match(r"^(was|is|were|did)\b", asked)
        and re.search(r"\b(higher|lower|more|less|better|worse|bigger|smaller)\b", asked)
        and not re.search(r"\bthan\b", asked)
    ):
        # "was my income higher in q3": Q3 against the quarter before it
        year, part = int(found[0][:4]), int(found[0][-1])
        found.append(f"{year - 1}-Q4" if part == 1 else f"{year}-Q{part - 1}")
        asked = f"{asked} than"
    if len(found) != 2 or found[0][5] != found[1][5]:
        return None  # one of them, or a quarter against a half
    if (
        not re.search(
            r"\b(or|than|vs|versus|compare|compared|comparison|difference|more|less|higher|"
            r"lower|change|changed|total|combined|altogether|together|in all)\b",
            asked,
        )
        and not (re.search(r"\bhow much\b", asked) and re.search(r"\band\b", asked))
        and not _changed(asked)
    ):
        return None
    if spec.task_type == "category_change" or re.search(
        r"\bcategor(y|ies)\b.*\b(grew|rose|increased|went up|dropped|fell|changed)\b", asked
    ):
        # "which category grew the most between spring and summer"
        earlier, later = sorted(found, key=lambda label: group_months(label)[0])
        falling = re.search(r"\b(dropped|fell|decreased?|went down|shrank|drop|decrease)\b", asked)
        changed = re.search(r"\bchanged? the most\b|\bbiggest change\b", asked)
        return QuerySpec(
            task_type="category_change",
            metric="expenses",
            period_type="quarters",
            period_key=f"{earlier},{later}",
            scope=spec.scope,
            reason_mode="any" if changed else ("down" if falling else "up"),
        )
    metric = _amount_metric(asked)
    categories = _categories_in(asked, summary)
    if len(categories) > 1:
        return None
    if metric not in {"income", "net"}:
        metric = "expenses"
    if _SAVING_RE.search(asked) and not categories:
        metric = "net"  # "did I save more in q3 than in q2"
    if re.search(r"\b(total|combined|altogether|together|in all)\b", asked):
        months = sorted(k for label in found for k in group_months(label))
        if len(months) != len(_months_between(months[0], months[-1])):
            return None  # "q1 and q3 combined" isn't one span
        if categories:
            return _scope_guard(
                QuerySpec(
                    task_type="compare_periods",
                    metric="expenses",
                    period_type="month_range",
                    period_key=",".join(months),
                    scope=spec.scope,
                    category=categories[0],
                    reason_mode="series",
                ),
                summary,
            )
        return _scope_guard(
            QuerySpec(
                task_type="amount_lookup",
                metric=metric,
                period_type="month_range",
                period_key=",".join(months),
                scope=spec.scope,
            ),
            summary,
        )
    if credit_card_scope(summary) and metric in {"income", "net"} and not categories:
        # A card has no income: say what came in over those months instead.
        months = sorted(k for label in found for k in group_months(label))
        return _scope_guard(
            QuerySpec(
                task_type="amount_lookup",
                metric="income",
                period_type="month_range",
                period_key=",".join(_months_between(months[0], months[-1])),
                scope=spec.scope,
            ),
            summary,
        )
    first, second = found
    if not re.search(r"\bthan\b", asked):
        # "q2 or q3", "compare q2 and q3", "from summer to fall": later first
        first, second = sorted(found, key=lambda label: group_months(label)[0], reverse=True)
    compare_to = ""
    if re.search(r"\bor\b", asked):
        lower = re.search(r"\b(less|lower|cheaper|smaller)\b", asked)
        compare_to = "which_lower" if lower else "which"
    spec = QuerySpec(
        task_type="compare_periods",
        metric="expenses" if categories else metric,
        period_type="quarters",
        period_key=f"{first},{second}",
        scope=spec.scope,
        category=",".join(categories),
        compare_to=compare_to,
    )
    if not compare_to:
        spec = _asked_direction(asked, spec)
    if re.search(r"\b(going to|gonna|will|on track|on pace|end up|projected?)\b", asked):
        # a quarter still running is projected to its end
        spec = dataclasses.replace(spec, reason_mode="projected")
    return _scope_guard(spec, summary)


def _asked_direction(message, spec):
    """ "Was June cheaper than May?" is a yes-or-no question about the first month."""
    text = _normalize(message)
    if (
        spec.task_type != "compare_periods"
        or spec.compare_to
        or len(spec.period_key.split(",")) != 2
    ):
        return spec
    if not re.match(r"^(was|is|were|did|has|have|will|would|does|do|am)\b", text) or re.search(
        r"\bor\b", text
    ):
        return spec
    times = re.search(r"\b(double|doubled|twice|triple|tripled|three times)\b", text)
    if times:
        # "was it more than double": at least twice as much, not just more
        triple = times.group(1) in {"triple", "tripled", "three times"}
        return dataclasses.replace(spec, compare_to="asked_triple" if triple else "asked_double")
    if spec.metric in {"income", "net"} and not spec.category:
        # "was my net cash flow better in q3 than q2": higher is better for these
        better = re.search(r"\b(better|improved?)\b|\b(worse|worsened)\b", text)
        if better:
            return dataclasses.replace(
                spec, compare_to="asked_more" if better.group(1) else "asked_less"
            )
    less = _ASKED_LESS_RE.search(text) and not re.search(r"\bmore expensive\b", text)
    more = _ASKED_MORE_RE.search(text)
    if bool(less) == bool(more):
        return spec
    return dataclasses.replace(spec, compare_to="asked_less" if less else "asked_more")


_WHEN_EXTREME_RE = re.compile(
    r"^when (was|were) (my |the )?([a-z ]{0,30}?)(highest|lowest|biggest|smallest|largest|"
    r"heaviest|lightest)( ever| this year)?$"
)


_WILL_SPEND_MORE_RE = re.compile(
    r"^(?:will i|am i going to|am i gonna|do i expect to) (?:end up )?spend(?:ing)? (more|less) "
    r"(?:this month|in total this month) than (?:in |i did in |i did )?(.+)$"
)


_EXTREME_MONTH_RE = re.compile(
    r"^(?:what|which) (?:was|is|s|were) (?:my |the )?(highest|lowest|biggest|smallest|most expensive|"
    r"cheapest|priciest)[ -]spending month\b(.*)$"
)
_MOST_IN_A_MONTH_RE = re.compile(
    r"^what(?: s| is| was)? the (most|least|highest|lowest) (?:i ve |i have |i )?(?:ever )?"
    r"(?:spent|spend) (on [a-z ]+? )?in (?:a|one|any|a single) month\b(.*)$"
)
_LEFT_WITH_RE = re.compile(
    r"^how much (?:was i left with|did i have left(?: over)?|did i end up with|was left over|"
    r"was left|did i keep)(?: after (?:expenses|spending|bills))?(?: in| for| during) (.+)$"
)
_CHANGE_LAST_MONTH_RE = re.compile(
    r"^(did|has) my ([a-z ]{0,20}?(?:income|spending|expenses|earnings|pay)) "
    r"(drop|go up|go down|fall|rise|increase|decrease|dip|jump|climb)( last month)$"
)


def _canonical_wording(message, summary):
    """Everyday wordings for asks the parser knows under another wording."""
    text = _normalize(message)
    extreme = _EXTREME_MONTH_RE.match(text)
    if extreme:
        # "what was my lowest-spending month"
        most = extreme.group(1) in {"highest", "biggest", "most expensive", "priciest"}
        return f"which month did i spend the {'most' if most else 'least'}{extreme.group(2)}"
    in_a_month = _MOST_IN_A_MONTH_RE.match(text)
    if in_a_month:
        # "what's the least I've spent on shopping in a month"
        most = in_a_month.group(1) in {"most", "highest"}
        on = f" {in_a_month.group(2).strip()}" if in_a_month.group(2) else ""
        return f"which month did i spend the {'most' if most else 'least'}{on}{in_a_month.group(3)}"
    left = _LEFT_WITH_RE.match(text)
    if left:
        # "how much was I left with after expenses in August" is that month's net
        return f"what was my net cash flow in {left.group(1)}"
    change = _CHANGE_LAST_MONTH_RE.match(text)
    if change and isinstance(summary, dict):
        # "did my income drop last month": last month against the month before
        prev = previous_month_key(summary)
        name = calendar.month_name[int(prev[5:])].lower()
        return f"{change.group(1)} my {change.group(2)} {change.group(3)} in {name} {prev[:4]}"
    return message


def parse_query_v2(message, summary, history=None):
    message = _canonical_wording(message, summary)
    when = _WHEN_EXTREME_RE.match(_normalize(message))
    if when:
        # "when was my shopping spending highest" names a month, like "which month..."
        message = f"which month was my {when.group(3).strip()} {when.group(4)}{when.group(5) or ''}"
    will_more = _WILL_SPEND_MORE_RE.match(_normalize(message))
    if will_more:
        # "will I spend more this month than last month" compares this month's pace
        message = f"will this month cost {will_more.group(1)} than {will_more.group(2)}"
    season = re.search(r"\blast (summer|spring|fall|autumn|winter)\b", _normalize(message))
    previous = _normalize(_last_user_text(history) or "") if history else ""
    if season and re.search(rf"\bthis {season.group(1)}\b", previous):
        # "and last summer?" after "...this summer": the year before
        year = _selected_year(summary) - 1
        message = re.sub(
            rf"\blast {season.group(1)}\b", f"{season.group(1)} {year}", _normalize(message)
        )
    spec = _scope_guard(_parse_query(message, summary, history), summary)
    spec = _asked_direction(message, spec)
    asked = _normalize(message)
    if history and len(asked.split()) <= 7:
        # "and for shopping?" after "which season did I spend the most in?"
        merged = _resolve_followup(asked, summary, history)
        if isinstance(merged, str) and merged:
            asked = merged
    last_same = re.search(r"\blast ([a-z]+)\b", asked)
    if (
        last_same
        and MONTH_NAME_TO_NUM.get(last_same.group(1))
        and isinstance(summary, dict)
        and f"{MONTH_NAME_TO_NUM[last_same.group(1)]:02d}" == selected_month_key(summary)[5:]
        and re.search(rf"\bthis {last_same.group(1)}\b", asked)
    ):
        # "this october than last october": a year back, before the data starts
        prior = f"{int(selected_month_key(summary)[:4]) - 1}{selected_month_key(summary)[4:]}"
        return QuerySpec(
            task_type="amount_lookup",
            metric="expenses",
            period_type="month",
            period_key=prior,
            scope=spec.scope,
        )
    for rule in (
        _spend_allowance,
        _biggest_monthly,
        _top_months,
        _quarter_extreme,
        _quarter_compare,
        _since_trend,
        _fastest_category,
        _year_trend,
        _week_of,
        _up_or_down_in,
        _week_by_category,
        _saving_enough,
        _week_before_last,
        _month_halves,
        _good_month,
        _months_saved,
        _week_vs_usual,
    ):
        found = rule(asked, spec, summary)
        if found:
            return found
    found = (
        _span_series(asked, spec, summary, history)
        or _span_change(asked, spec, summary, history)
        or _span_period(asked, spec, summary, history)
        or _within_group(asked, spec, summary)
        or _this_month_versus(asked, spec, summary)
    )
    if found:
        return found
    if (
        spec.task_type == "compare_periods"
        and spec.metric in {"income", "net", "expenses"}
        and not spec.compare_to
        and "," not in (spec.category or "")
        and spec.period_type == "month_range"
        and len(spec.period_key.split(",")) == 2
        and re.search(r"\bor\b", asked)
        and (
            spec.metric != "expenses"
            or re.search(r"\b(which|what)\b", asked)
            or re.match(r"^(did|was|were|is)\b.*\b(more|less|higher|lower)\b", asked)
        )
    ):
        # "was I better off in august or september": name the month, not just the gap
        which = "which_lower" if re.search(r"\b(less|lower|smaller|cheaper)\b", asked) else "which"
        if spec.metric != "expenses" and re.search(r"\bbetter\b", asked):
            which = "which_better"
        elif spec.metric != "expenses" and re.search(r"\bworse\b", asked):
            which = "which_worse"
        return dataclasses.replace(spec, compare_to=which)
    keys = [k for k in spec.period_key.split(",") if k]
    with_history = asked
    if history and len(asked.split()) <= 7:
        with_history += " " + _normalize(_last_user_text(history))  # "what about income?"
    if (
        spec.task_type == "amount_lookup"
        and spec.period_type == "month_range"
        and len(keys) == 2
        and _CHANGE_RE.search(with_history)
    ):
        # "did my spending go down from august to september": the later month vs the earlier
        earlier, later = sorted(keys)
        spec = dataclasses.replace(
            spec, task_type="compare_periods", period_key=f"{later},{earlier}"
        )
        spec = _asked_direction(message, spec)
    elif (
        spec.task_type == "amount_lookup"
        and spec.period_type == "month_range"
        and len(keys) == 2
        and re.search(
            r"\bbetween [a-z]+ and [a-z]+\b|\bfrom [a-z]+ (to|through|until) [a-z]+\b", asked
        )
    ):
        spec = dataclasses.replace(spec, period_key=",".join(_months_between(*sorted(keys))))
    single = isinstance(summary, dict) and summary.get("scope") == "single_account"
    if single and spec.task_type == "general" and asks_for_advice(message):
        # "how can I reduce my shopping" on an account with no shopping.
        for name in _categories_in(_normalize(message), summary, include_approx=False):
            if not _has_spending(summary, name):
                return QuerySpec(
                    task_type="data_pointer",
                    scope=spec.scope,
                    reason_mode="absent_category",
                    category=name,
                )
    return spec


def _parse_query(message, summary, history=None):
    text = _normalize(message)
    if not text:
        return QuerySpec()

    followup = _resolve_followup(text, summary, history)
    if isinstance(followup, QuerySpec):
        return followup
    if followup:
        text = followup

    scope = "unknown"
    if isinstance(summary, dict):
        scope = clamp_str(summary.get("scope", ""), 32) or "unknown"

    has_spending = (
        ("spending" in text) or ("expenses" in text) or bool(re.search(r"\bspend(ing)?\b", text))
    )
    has_change = any(
        token in text
        for token in (
            "increase",
            "increased",
            "up",
            "grew",
            "grow",
            "rose",
            "rise",
            "changed",
            "change",
            "higher",
            "lower",
            "decrease",
            "decreased",
            "down",
        )
    )
    has_cause = any(
        token in text
        for token in ("why", "caused", "cause", "what changed", "what drove", "how come", "reason")
    )
    glossary = _glossary_spec(text, summary, scope)
    if glossary is not None:
        return glossary

    boundary = _boundary_spec(text, scope)
    if boundary is not None:
        return boundary

    for builder in (
        _special_asks_spec,
        _same_category_terms,
        _chat_action_spec,
        _peer_compare_spec,
        _amount_judgement_spec,
        _derived_metric_spec,
    ):
        spec = builder(text, summary, scope)
        if spec is not None:
            return spec

    if _OVERVIEW_RE.search(text) and not _ADVICE_RE.search(text):
        return QuerySpec(
            task_type="month_overview",
            metric="net",
            period_type="month",
            period_key=_period_for(text, summary),
            scope=scope,
        )

    what_if = _what_if_spec(text, summary, scope)
    if what_if is not None:
        return what_if

    pace = _pace_check(text, summary, scope)
    if pace is not None:
        return pace

    asked = bool(re.search(r"[?？吗呢]|多少|什么|哪|几", str(message or "")))
    asked = asked or bool(re.search(r"\b(how much|how many|what|which|when|why|how)\b", text))
    if not asked and _STATEMENT_RE.match(text) and not _QUESTION_START_RE.match(text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="statement")

    for builder in (
        _app_info_spec,
        _saving_target_spec,
        _month_outlook_spec,
        _no_spend_days_spec,
        _day_span_spec,
        _per_week_spec,
        _category_share_spec,
        _invalid_date_spec,
        _count_months_spec,
        _threshold_spec,
        _savings_lever_spec,
        _percent_of_spec,
        _why_month_spec,
        _budget_plan_spec,
        _by_category_spec,
        _each_month_spec,
        _all_time_spec,
        _goal_time_spec,
        _extra_spend_spec,
        _counterfactual_spec,
        _net_vs_last_month_spec,
        _did_i_save_spec,
        _on_track_spec,
        _explain_month_spec,
        _week_compare_spec,
        _savings_goal_spec,
        _affordability_spec,
        _budget_suggestion_spec,
        _category_versus_spec,
        _category_vs_last_month_spec,
        _month_extreme_spec,
        _hotspot_spec,
        _average_or_trend_spec,
        _category_growth_spec,
        _category_rank_spec,
    ):
        spec = builder(text, summary, scope)
        if spec is not None:
            return spec

    if "last month" in text and re.search(r"\b(2|two) months ago\b|\bmonth before\b", text):
        prev = previous_month_key(summary)
        return QuerySpec(
            task_type="compare_periods",
            metric="expenses",
            period_type="month_range",
            period_key=f"{prev},{_months_back(prev, 1)}",
            scope=scope,
            category=_category_in(text, summary),
        )

    # "Did I spend more this month than last month?" is a comparison, not a "why".
    if (
        re.search(r"\b(this|current) month\b", text)
        and "last month" in text
        and re.search(r"\b(than|vs|versus|compared?|comparison)\b", text)
        and not has_cause
    ):
        return QuerySpec(
            task_type="compare_periods",
            metric="expenses",
            period_type="month_range",
            period_key=f"{selected_month_key(summary)},{previous_month_key(summary)}",
            scope=scope,
        )

    earn_vs_spend = _earn_versus_spend(text, summary, scope)
    if earn_vs_spend is not None:
        return earn_vs_spend

    named_comparison = _named_month_comparison(text, summary, scope)
    if named_comparison is not None:
        return named_comparison

    if has_spending and "last month" in text and (has_change or has_cause):
        return QuerySpec(
            task_type="explain",
            metric="expenses",
            period_type="month",
            period_key=previous_month_key(summary),
            scope=scope,
            reason_mode="spending_change",
        )

    compare_like = (
        ("compare" in text)
        or (" vs " in text)
        or ("versus" in text)
        or ("difference" in text)
        or ("month over month" in text)
        or ("month-over-month" in text)
        or bool(re.search(r"\bmom\b", text))
        or bool(re.search(r"\bbetween\s+20\d{2}-\d{2}\s+and\s+20\d{2}-\d{2}\b", text))
        or bool(re.search(r"\bfrom\s+20\d{2}-\d{2}\s+to\s+20\d{2}-\d{2}\b", text))
    )
    if compare_like:
        month_keys = re.findall(r"\b20\d{2}-\d{2}\b", text)
        if len(month_keys) >= 2:
            return QuerySpec(
                task_type="compare_periods",
                metric="expenses",
                period_type="month_range",
                period_key=f"{month_keys[0]},{month_keys[1]}",
                scope=scope,
            )
        years = re.findall(r"\b20\d{2}\b", text)
        if len(years) >= 2:
            return QuerySpec(
                task_type="compare_periods",
                metric="expenses",
                period_type="year",
                period_key=f"{years[0]},{years[1]}",
                scope=scope,
            )

    has_top_category_phrase = any(
        token in text
        for token in (
            "top category",
            "highest category",
            "most category",
            "top spend category",
            "spend most on",
            "spent most on",
            "spend the most on",
            "spent the most on",
            "spending the most on",
            "#1 spend category",
        )
    )
    has_category_rank_pattern = bool(
        re.search(
            r"\b(highest|top|biggest|largest|most)\b.*\b(category|categories)\b",
            text,
        )
    ) or bool(
        re.search(
            r"\b(category|categories)\b.*\b(highest|top|biggest|largest|most)\b",
            text,
        )
    )
    if has_top_category_phrase or has_category_rank_pattern:
        if "last month" in text:
            return QuerySpec(
                task_type="top_category_lookup",
                metric="top_category",
                period_type="month",
                period_key=previous_month_key(summary),
                scope=scope,
            )
        if re.search(r"\b(this year|year|annual|yearly|20\d{2}|all time|overall)\b", text):
            return QuerySpec(
                task_type="top_category_lookup",
                metric="top_category",
                period_type="unknown",
                period_key="",
                scope=scope,
            )
        # No period named: answer for the month the user is looking at, not the whole year.
        return QuerySpec(
            task_type="top_category_lookup",
            metric="top_category",
            period_type="month",
            period_key=_transaction_list_month(text, summary) or selected_month_key(summary),
            scope=scope,
            reason_mode="top:5" if re.search(r"\bcategories\b", text) else "",
        )

    has_recent_tx_phrase = any(
        token in text
        for token in (
            "recent transactions",
            "latest transactions",
            "recent activity",
            "latest activity",
            "latest tx",
            "recent tx",
            "recent purchases",
            "last few transactions",
        )
    )
    has_recent_spend_pattern = (
        bool(re.search(r"\bwhat did i spend on recently\b", text))
        or bool(re.search(r"\bshow my last few transactions\b", text))
        or bool(re.search(r"\b(recent|latest) [a-z]+ (purchases|transactions|charges)\b", text))
    )
    if (
        has_recent_tx_phrase or has_recent_spend_pattern or asks_transaction_list(text)
    ) and _category_in(text, summary):
        return QuerySpec(
            task_type="recent_transactions",
            metric="expenses",
            period_type="category",
            period_key=_transaction_list_month(text, summary) or selected_month_key(summary),
            scope=scope,
            category=_category_in(text, summary),
        )
    if has_recent_tx_phrase or has_recent_spend_pattern or asks_transaction_list(text):
        day_key = _day_key(text, _selected_year(summary))
        if day_key:
            return QuerySpec(
                task_type="recent_transactions",
                metric="expenses",
                period_type="day",
                period_key=day_key,
                scope=scope,
            )
        month_key = _transaction_list_month(text, summary)
        if month_key:
            return QuerySpec(
                task_type="recent_transactions",
                metric="expenses",
                period_type="month",
                period_key=month_key,
                scope=scope,
            )
        return QuerySpec(
            task_type="recent_transactions",
            metric="expenses",
            period_type="rolling_days",
            period_key="rolling_7d",
            scope=scope,
        )

    category_amount = _category_month_amount(text, summary, scope)
    if category_amount is not None:
        return category_amount

    outside = _outside_summary_spec(text, summary, scope)
    if outside is not None:
        return outside

    relative_amount = _relative_month_amount(text, summary, scope)
    if relative_amount is not None:
        return relative_amount

    asks_advice = bool(_ADVICE_RE.search(text))
    if (
        ("this month" in text or "current month" in text)
        and ("spending" in text or "expenses" in text)
        and not asks_advice
    ):
        return QuerySpec(
            task_type="amount_lookup",
            metric="expenses",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
        )
    if (
        "last year" in text
        and ("spending" in text or "expenses" in text)
        and not asks_advice
        and not _named_month_keys(text, summary)
    ):
        return QuerySpec(
            task_type="amount_lookup",
            metric="expenses",
            period_type="year",
            period_key=str(
                int((summary or {}).get("time_anchor", {}).get("selected_year", 0) or 0) - 1
            )
            if isinstance(summary, dict)
            else "",
            scope=scope,
        )

    fallback = _slot_fallback(text, summary, scope)
    if fallback is not None:
        return fallback

    return QuerySpec()


# ── Follow-ups ───────────────────────────────────────────────────────────

_FOLLOWUP_CUE_RE = re.compile(r"^(and|what about|how about|same for|and for|also|ok and|then)\b\s*")
_WHY_ONLY_RE = re.compile(
    r"^(but )?(why|how come)( is that| is it| was it| did that happen| so)?"
    r"( so)?( high| low| much| little| big)?$|"
    r"^(why|how come|what caused|what explains) (the|that|this) "
    r"(jump|spike|increase|rise|drop|dip|decrease|change|difference)$|"
    r"^(why|how come) did (it|that|this|spending|my spending) "
    r"(go up|go down|increase|decrease|rise|drop|jump|change|fall)$|"
    r"^what (drove|caused|explains|is behind|was behind) (that|this|it)$"
)
_PERIOD_WORDS_RE = re.compile(
    r"\b(this month|current month|last month|this year|last year|today|yesterday|"
    r"(\d{1,2}|one|two|three|four|five|six) months? ago|last \d{1,3} days|"
    r"20\d{2}(-\d{2})?|jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|"
    r"aug|august|sep|sept|september|oct|october|nov|november|dec|december|q[1-4]|"
    r"(first|second|third|fourth) quarter|(first|second) half|summer|spring|fall|autumn|winter)\b"
)


def _last_user_text(history):
    for turn in reversed(history or []):
        if isinstance(turn, dict) and turn.get("role") == "user" and turn.get("text"):
            return str(turn["text"])
    return ""


def _extreme_month(spec, summary):
    """The month a "which month did I spend the most" answer named: the year's highest
    (or lowest) finished month."""
    month_index = summary.get("month_index") if isinstance(summary, dict) else None
    if not isinstance(month_index, dict):
        return ""
    current = selected_month_key(summary)
    totals = {}
    for key, row in month_index.items():
        if not str(key).startswith(f"{spec.period_key}-") or key >= current:
            continue
        if not isinstance(row, dict):
            continue
        if spec.category:
            cats = row.get("categories") if isinstance(row.get("categories"), dict) else {}
            totals[key] = float(cats.get(spec.category, 0) or 0)
        else:
            totals[key] = float(row.get("expenses", 0) or 0)
    if not totals:
        return ""
    pick = min if spec.reason_mode == "lowest" else max
    return pick(totals, key=totals.get)


def _resolve_followup(text, summary, history):
    """Short follow-ups ("and last month?", "what about transport?", "why?") borrow what
    they leave out from the previous question. Returns a QuerySpec, merged text, or None."""
    previous = _last_user_text(history)
    if not previous or len(text.split()) > 7:
        return None
    prev_text = _normalize(previous)
    compare_before = _compare_months_followup(text, summary, history)
    if compare_before is not None:
        return compare_before
    about_previous = _followup_about_previous(text, previous, summary)
    if about_previous is not None:
        return about_previous
    if re.match(
        r"^(by )?how much( more| less| higher| lower)?( was it| is it| did it| exactly)?$|"
        r"^how (big|large) (was|is) the (difference|gap|change)$|^what( s|was| is) the "
        r"(difference|gap)$",
        text,
    ):
        # "by how much?" after a yes-or-no comparison: the same comparison, with its amounts.
        prev_spec = parse_query_v2(previous, summary)
        if prev_spec.task_type == "compare_periods":
            if prev_spec.compare_to in {"asked_less", "asked_more"}:
                prev_spec = dataclasses.replace(prev_spec, compare_to="")
            return prev_spec
    flip = re.match(
        r"^(and |what about |how about )?(the )?(lowest|least|smallest|cheapest|highest|most|"
        r"biggest|largest)( one| month| quarter| season| category)?$",
        text,
    )
    if flip:
        # "what about the lowest?" after "which quarter did I spend the most in?"
        low = flip.group(3) in {"lowest", "least", "smallest", "cheapest"}
        swaps = (
            {"most": "least", "highest": "lowest", "biggest": "smallest", "largest": "smallest"}
            if low
            else {
                "least": "most",
                "lowest": "highest",
                "smallest": "biggest",
                "cheapest": "most expensive",
            }
        )
        swapped = re.sub(r"\b(" + "|".join(swaps) + r")\b", lambda m: swaps[m.group(1)], prev_text)
        if swapped != prev_text:
            return parse_query_v2(swapped, summary)
    if _WHY_ONLY_RE.match(text):
        prev_spec = _parse_query(previous, summary)
        month = ""
        if prev_spec.period_type in {"month", "month_range"} and prev_spec.period_key:
            month = prev_spec.period_key.split(",")[0]
        compared = parse_query_v2(previous, summary)
        pair = (compared.period_key or "").split(",")
        if (
            compared.task_type == "compare_periods"
            and compared.period_type == "month_range"
            and len(pair) == 2
        ):
            # "why?" after "did my spending go down from july to september": September
            # against July, not September against the month before it.
            month = compared.period_key
        if prev_spec.task_type == "month_extreme" and prev_spec.metric == "expenses":
            month = _extreme_month(prev_spec, summary)
        if prev_spec.task_type == "count_months" and prev_spec.metric == "expenses":
            # "why?" after "was there any month over $3200": the highest (or lowest) month
            over = prev_spec.reason_mode in {"over", "more than", "above"}
            month = _extreme_month(
                QuerySpec(
                    task_type="month_extreme",
                    period_key=str(_selected_year(summary)),
                    reason_mode="highest" if over else "lowest",
                    category=prev_spec.category,
                ),
                summary,
            )
        if not month:
            return None
        return QuerySpec(
            task_type="explain",
            metric="expenses",
            period_type="month",
            period_key=month,
            scope=prev_spec.scope,
            reason_mode="spending_change",
            category=prev_spec.category,
        )
    cue = _FOLLOWUP_CUE_RE.match(text)
    if cue and re.search(r"\b(savings|saved)\b", text):
        text = re.sub(r"\b(savings|saved)\b", "net cash flow", text)
    has_period = bool(_PERIOD_WORDS_RE.search(text))
    has_category = bool(_categories_in(text, summary))
    metric_only = bool(cue) and bool(_amount_metric(text)) and not (has_period or has_category)
    if not cue and not (has_period or has_category):
        return None
    if (_amount_metric(text) or _AMOUNT_ASK_RE.search(text)) and not metric_only:
        return None
    current = _FOLLOWUP_CUE_RE.sub("", text)
    merged = prev_text
    if metric_only:
        # "and income?" after "how much did I spend in july": swap the metric.
        merged = re.sub(
            r"\b(spend|spent|spending|expenses?|income|earn|earned|net|cash flow|make|made|"
            r"save|saved|saving|savings)\b",
            " ",
            merged,
        )
    if has_period:
        merged = _PERIOD_WORDS_RE.sub(" ", merged)
    if has_category:
        for name in _categories_in(merged, summary):
            merged = re.sub(r"\b" + re.escape(name.lower()) + r"\b", " ", merged)
        for word, name in _CATEGORY_SYNONYMS.items():
            merged = re.sub(r"\b" + re.escape(word) + r"\b", " ", merged)
    return re.sub(r"\s+", " ", f"{merged} {current}").strip()


# ── Broader amount asks ──────────────────────────────────────────────────

_ROLLING_RE = re.compile(
    r"\b(?:last|past|previous)\s+(7|30|90)\s+days\b|\b(?:last|past|this) (week)\b"
)
_HALF_RE = re.compile(r"\b(first|second) half of (?:(?:the |this )?year|20\d{2})\b")
_QUARTER_RE = re.compile(r"\bq([1-4])\b|\b(first|second|third|fourth) quarter\b")
_QUARTER_WORDS = {"first": 1, "second": 2, "third": 3, "fourth": 4}


def _selected_year(summary):
    anchor = (summary or {}).get("time_anchor") if isinstance(summary, dict) else None
    year = (anchor or {}).get("selected_year") if isinstance(anchor, dict) else None
    return int(year) if year else int(selected_month_key(summary)[:4])


def _month_range_spec(text, summary):
    """Half-years and quarters as comma-joined month keys."""
    year = _selected_year(summary)
    explicit = re.search(r"\b(20\d{2})\b", text)
    if explicit:
        year = int(explicit.group(1))
    season = re.search(r"\b(summer|spring|fall|autumn|winter)\b", text)
    if season:
        starts = {"spring": 3, "summer": 6, "fall": 9, "autumn": 9, "winter": 12}
        start = starts[season.group(1)]
        months = [(start + i - 1) % 12 + 1 for i in range(3)]
        return ",".join(
            f"{year - 1 if (start == 12 and m == 12) else year}-{m:02d}" for m in months
        )
    relative = re.search(r"\b(last|previous|this|current) quarter\b", text)
    if relative:
        current = selected_month_key(summary)
        cur_q = (int(current[5:]) - 1) // 3
        q_year = int(current[:4])
        if relative.group(1) in {"last", "previous"}:
            cur_q -= 1
            if cur_q < 0:
                cur_q, q_year = 3, q_year - 1
        start = cur_q * 3 + 1
        return ",".join(f"{q_year}-{m:02d}" for m in range(start, start + 3))
    half = _HALF_RE.search(text)
    if half:
        start = 1 if half.group(1) == "first" else 7
        return ",".join(f"{year}-{m:02d}" for m in range(start, start + 6))
    quarter = _QUARTER_RE.search(text)
    if quarter:
        q = int(quarter.group(1)) if quarter.group(1) else _QUARTER_WORDS[quarter.group(2)]
        start = (q - 1) * 3 + 1
        return ",".join(f"{year}-{m:02d}" for m in range(start, start + 3))
    return ""


# "my rent is due next week", "I got paid today": statements, not requests for a number.
_STATEMENT_RE = re.compile(
    r"^(i|i m|im|my|the|our|we)\b.*\b(is|was|are|were|got|have|had|need|am|m|will|did)\b"
)
_QUESTION_START_RE = re.compile(
    r"^(how|what|which|when|where|who|did|do|does|is|are|was|were|can|could|should|show|"
    r"list|tell|give)\b"
)


def _slot_fallback(text, summary, scope):
    """Last resort before the model: the question names a metric or a category, so
    answer that for the period it names, or for the selected month."""
    if _ADVICE_RE.search(text) or re.search(r"\b(why|how come|what if|should)\b", text):
        return None

    if re.search(r"\b(which|what) (month|day|week)\b|\bwhen did\b", text):
        return None
    metric = _amount_metric(text)
    categories = _categories_in(text, summary)
    if not metric and not categories:
        return None
    future_year = re.search(r"\b(?:year|in|for|during)\s+(\d{4})\b", text)
    if future_year and int(future_year.group(1)) > date_cls.today().year:
        return QuerySpec(
            task_type="data_pointer",
            scope=scope,
            reason_mode="future_period",
            period_key=future_year.group(1),
        )
    rolling = _ROLLING_RE.search(text)
    if rolling and not categories:
        days = rolling.group(1) or "7"
        return QuerySpec(
            task_type="amount_lookup",
            metric=metric if metric in {"income", "expenses"} else "expenses",
            period_type="rolling_days",
            period_key=f"rolling_{days}d",
            scope=scope,
        )
    since = re.search(r"\bsince (?:the (?:start|beginning) of )?([a-z]+)\b", text)
    since_keys = _named_month_keys(since.group(1), summary) if since else []
    if since_keys and categories:
        # "shopping since august": each month to now, with the total.
        return QuerySpec(
            task_type="compare_periods",
            metric="expenses",
            period_type="month_range",
            period_key=",".join(_months_between(since_keys[0], selected_month_key(summary))),
            scope=scope,
            category=",".join(categories),
            reason_mode="series",
        )
    if since_keys and not categories:
        return QuerySpec(
            task_type="amount_lookup",
            metric=metric if metric in {"income", "expenses", "net"} else "expenses",
            period_type="month_range",
            period_key=",".join(_months_between(since_keys[0], selected_month_key(summary))),
            scope=scope,
        )
    last_n = re.search(
        r"\b(?:last|past|previous)\s+(\d{1,2}|two|three|four|five|six)\s+months\b", text
    )
    if last_n:
        raw = last_n.group(1)
        count = max(2, min(12, int(raw) if raw.isdigit() else _NUMBER_WORDS[raw]))
        start = _months_back(selected_month_key(summary), count)
        end = _months_back(selected_month_key(summary), 1)
        return QuerySpec(
            task_type="compare_periods",
            metric=metric if metric in {"income", "net"} else "expenses",
            period_type="month_range",
            period_key=",".join(_months_between(start, end)),
            scope=scope,
            category=",".join(categories),
            reason_mode="series",
        )
    month_range = _month_range_spec(text, summary)
    span = re.search(r"\b(from|between)\b.*\b(to|through|thru|and|until)\b", text)
    keys = _named_month_keys(text, summary)
    if not month_range and span and len(keys) == 2:
        start, end = sorted(keys)
        month_range = ",".join(_months_between(start, end))
    if month_range and categories:
        return QuerySpec(
            task_type="compare_periods",
            metric="expenses",
            period_type="month_range",
            period_key=month_range,
            scope=scope,
            category=",".join(categories),
            reason_mode="series",
        )
    if month_range and not categories:
        return QuerySpec(
            task_type="amount_lookup",
            metric=metric if metric in {"income", "expenses", "net"} else "expenses",
            period_type="month_range",
            period_key=month_range,
            scope=scope,
        )
    year_spec = _year_amount_spec(text, summary, scope, metric, categories)
    if year_spec is not None:
        return year_spec
    # Other whole-year asks are answered by the older amount rules; don't shrink them.
    names_year = re.search(r"\b20\d{2}\b", text) and not re.search(r"\b20\d{2}-\d{2}\b", text)
    named_months = _named_month_keys(text, summary)
    if (
        re.search(r"\b(this year|year to date|ytd)\b", text)
        or ("last year" in text and not named_months)
        or (names_year and not named_months)
    ):
        return None
    if len(categories) == 2 and re.search(r"\b(vs|versus|or|compared? to)\b", text):
        if "last month" in text:
            month_key = previous_month_key(summary)
        else:
            month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
        return QuerySpec(
            task_type="category_spending",
            metric="expenses",
            period_type="month",
            period_key=month_key,
            scope=scope,
            category=",".join(categories),
            reason_mode="versus",
        )
    if categories and metric in {"", "expenses"}:
        if "last month" in text:
            month_key = previous_month_key(summary)
        elif _MONTHS_AGO_RE.search(text):
            raw = _MONTHS_AGO_RE.search(text).group(1)
            count = int(raw) if raw.isdigit() else _NUMBER_WORDS[raw]
            month_key = _months_back(selected_month_key(summary), count)
        else:
            month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
        return QuerySpec(
            task_type="category_spending",
            metric="expenses",
            period_type="month",
            period_key=month_key,
            scope=scope,
            category=",".join(categories),
            reason_mode="exclude" if _EXCLUDE_RE.search(text) else "",
            compare_to=_approx_term(text),
        )
    spec = _relative_month_amount(f"how much {text}", summary, scope)
    if spec is not None:
        return spec
    return QuerySpec(
        task_type="amount_lookup",
        metric=metric or "expenses",
        period_type="month",
        period_key=selected_month_key(summary),
        scope=scope,
    )


# ── Rankings, growth, averages, trends, hotspots ─────────────────────────

_ORDINALS = {"second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "fifth": 5}
_RANK_RE = re.compile(
    r"\b(second|2nd|third|3rd|fourth|4th|fifth)\s+(biggest|largest|highest|top)\b|"
    r"\b(number (one|1|two|2|three|3)|no (1|2|3)|#(1|2|3))\s+(spending |expense )?categor"
)
_TOP_N_RE = re.compile(
    r"\btop\s+(2|3|4|5|two|three|four|five)\s+(?:[a-z]+\s+)?categor|"
    r"\b(2|3|4|5|two|three|four|five)\s+(?:biggest|largest|top|highest)\s+(?:[a-z]+\s+)?categor|"
    # "which two categories cost me the most"
    r"\b(?:which|what) (2|3|4|5|two|three|four|five) categories\b(?=.*\b(most|biggest|highest)\b)"
)
_GROWTH_RE = re.compile(
    r"\b(grew|grow|increased?|rose|went up|jumped|climbed|dropped|fell|decreased?|went down|"
    r"shrank)\b.*\bmost\b|\b(biggest|largest)\s+(increase|jump|rise|drop|decrease)\b"
)
_AVERAGE_RE = re.compile(
    r"\b(average|avg|typical|typically|usual|usually|normally|generally|per month|each month|"
    r"monthly|normal month)\b"
)
_TREND_RE = re.compile(
    r"\b(trend|trending|going up or down|up or down|getting better|getting worse|"
    r"increasing or decreasing|over time|lately|these days|volatile|volatility|consistent|"
    r"stable|steady|fluctuat[a-z]*|"
    r"changed over|over the (past|last) (few )?months|am i improving|getting better or worse|"
    r"getting (more expensive|pricier|cheaper|bigger|smaller)|"
    r"(is|are) [a-z ]{0,30}(changing|improving|worsening)|"
    r"(is|are) [a-z ]{0,30}(going up|going down|increasing|decreasing|rising|falling|growing|"
    r"shrinking)|"
    r"(has|have) [a-z ]{0,30}(gone up|gone down|increased|decreased|dropped|risen|grown|changed)|"
    r"been (increasing|"
    r"decreasing|rising|falling|going up|going down|growing|shrinking))\b"
)
_HOTSPOT_RE = re.compile(
    r"\b(wasting|waste|where (is|does|did|s) (most of |all )?my money (go|going|went)|"
    r"money leaks?|biggest leaks?|where am i overspending|where am i spending (the )?most|"
    r"where (can|could|should) i (cut|save|trim|spend less|reduce)|"
    r"eating (up )?(most of )?my (money|budget|income|paycheck)|money drains?|biggest drain|"
    r"taking up (most of )?my (money|budget|spending|income)|"
    r"(which|what) categor(y|ies) (am i|are) (overspending|over spending|spending too much)|"
    r"unusual|out of the ordinary|anomal[a-z]*|spikes?|unexpected)\b"
)


def _category_rank_spec(text, summary, scope):
    rank = _RANK_RE.search(text)
    top_n = _TOP_N_RE.search(text)
    smallest = re.search(
        r"\b(smallest|lowest|least|cheapest) (expensive |costly )?(spending |expense )?category\b",
        text,
    ) or (
        re.search(r"\b(which|what) categor(y|ies)\b.*\b(the )?(least|lowest|smallest)\b", text)
        and not re.search(r"\bat least\b", text)
    )
    ever = re.search(r"\b(ever|all time|of all time|overall)\b", text)
    if ever and re.search(r"\b(biggest|largest|top|highest)\b.*\bcategor", text):
        return QuerySpec(
            task_type="top_category_lookup",
            metric="top_category",
            period_type="all",
            scope=scope,
            reason_mode="ever",
        )
    if not rank and not top_n and not smallest:
        return None
    if smallest:
        mode = "rank:last"
    elif rank:
        if rank.group(1):
            mode = f"rank:{_ORDINALS[rank.group(1)]}"
        else:
            spoken = rank.group(4) or rank.group(5) or rank.group(6)
            mode = f"rank:{ {'one': 1, 'two': 2, 'three': 3}.get(spoken, spoken) }"
    else:
        raw = top_n.group(1) or top_n.group(2) or top_n.group(3)
        mode = f"top:{int(raw) if raw.isdigit() else _NUMBER_WORDS[raw]}"
    if re.search(r"\b(this year|so far this year|year to date)\b", text) and (
        mode.startswith("top:") or re.match(r"^rank:\d$", mode)
    ):
        return QuerySpec(
            task_type="top_category_lookup",
            metric="top_category",
            period_type="year",
            period_key=str(_selected_year(summary)),
            scope=scope,
            reason_mode=mode,
        )
    if "last month" in text:
        month_key = previous_month_key(summary)
    else:
        month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
    claim = ""
    if mode == "rank:last" and re.match(r"^(is|are|was)\b", text):
        claim = _category_in(text, summary)  # "is entertainment my smallest category"
    return QuerySpec(
        task_type="top_category_lookup",
        metric="top_category",
        period_type="month",
        period_key=month_key,
        scope=scope,
        reason_mode=mode,
        category=claim,
    )


def _category_growth_spec(text, summary, scope):
    changed = re.search(r"\bchanged? the most\b|\bbiggest change\b", text)
    if not (_GROWTH_RE.search(text) or changed) or not (
        re.search(r"\bcategor", text)
        or (re.search(r"\bbiggest change\b", text) and not _amount_metric(text))
    ):
        return None
    keys = _named_month_keys(text, summary)
    if len(keys) == 2:
        left, right = keys
    elif len(keys) == 1 and re.search(r"\bsince\b", text):
        left, right = keys[0], selected_month_key(summary)  # "since august": august to now
    elif len(keys) == 1:
        left, right = _months_back(keys[0], 1), keys[0]  # "in july": june to july
    else:
        left, right = previous_month_key(summary), selected_month_key(summary)
    falling = re.search(r"\b(dropped|fell|decreased?|went down|shrank|drop|decrease)\b", text)
    return QuerySpec(
        task_type="category_change",
        metric="expenses",
        period_type="month_range",
        period_key=f"{left},{right}",
        scope=scope,
        reason_mode="any" if changed else ("down" if falling else "up"),
    )


def _average_or_trend_spec(text, summary, scope):
    if re.search(
        r"\b(spending habits|money habits|my habits|spending patterns?|something interesting|"
        r"interesting|insights?|fun fact)\b",
        text,
    ) and not (_ADVICE_RE.search(text)):
        return QuerySpec(
            task_type="spending_trend",
            metric="expenses",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
            reason_mode="habits",
        )
    if _ADVICE_RE.search(text):
        return None
    if re.search(r"\b(compared? (to|with)|vs|versus) (my )?(average|usual|normal)\b", text):
        return None
    trend = _TREND_RE.search(text)
    average = _AVERAGE_RE.search(text) and (
        _amount_metric(text) or re.search(r"\b(how much|what)\b", text)
    )
    if not trend and not average:
        return None
    year_average = re.search(r"\b(this year|so far this year)\b", text)
    metric = _amount_metric(text) if _amount_metric(text) in {"income", "net"} else "expenses"
    if re.search(r"\bsavings\b", text) and not re.search(r"\bsavings (account|rate)\b", text):
        metric = "net"  # "average monthly savings" is income minus spending
    return QuerySpec(
        task_type="spending_trend",
        metric=metric,
        period_type="year" if year_average else "month",
        period_key=str(_selected_year(summary)) if year_average else selected_month_key(summary),
        scope=scope,
        category=_category_in(text, summary),
        reason_mode=(
            "volatility"
            if re.search(
                r"\b(volatile|volatility|consistent|month to month|stable|steady|fluctuat[a-z]*)\b",
                text,
            )
            else ("trend" if trend else "average")
        ),
    )


def _month_extreme_spec(text, summary, scope):
    """ "Which month did I spend the most this year?" """
    named = re.search(
        r"\b(cheapest|most expensive|priciest|biggest|highest|lowest|worst|best)\s+"
        r"(spending\s+|income\s+|earning\s+)?month\b",
        text,
    )
    saving_month = re.search(
        r"\b(best|worst) month for sav(ing|ings)\b|\bmonth (did )?i (save|saved) the (most|least)\b",
        text,
    )
    if saving_month:
        return QuerySpec(
            task_type="month_extreme",
            metric="net",
            period_type="year",
            period_key=str(_selected_year(summary)),
            scope=scope,
            reason_mode="lowest" if re.search(r"\b(worst|least)\b", text) else "highest",
        )
    peak = re.search(r"\b(peak|peaked|max out|maxed out|highest point)\b", text)
    when = re.search(r"\bwhen did i (spend|earn|make) (the )?(most|least)\b", text) or re.search(
        r"\b(most|least) i (ve |have )?(spent|earned|made) in (a|one) (single )?month\b", text
    )
    if not re.search(r"\b(which|what) month\b", text) and not named and not peak and not when:
        return None
    lowest = re.search(r"\b(least|lowest|smallest|cheapest|best)\b", text)
    most = re.search(r"\b(most|highest|biggest|largest|worst|priciest|costliest)\b", text)
    if not lowest and not peak and not most:
        return None
    return QuerySpec(
        task_type="month_extreme",
        metric="income" if _amount_metric(text) == "income" else "expenses",
        period_type="year",
        period_key=str(_selected_year(summary)),
        scope=scope,
        category=_category_in(text, summary),
        reason_mode="lowest" if lowest else "highest",
        compare_to=(_named_month_keys(text, summary) or [""])[0]
        if peak or re.match(r"^(was|is)\b", text)
        else "",
    )


_SAVINGS_GOAL_RE = re.compile(r"\bsave\s+(?:about\s+|around\s+)?(\d{2,6})\b")


def _savings_goal_spec(text, summary, scope):
    """ "I want to save $500 next month, how?" -> which cuts reach that amount."""
    goal = _SAVINGS_GOAL_RE.search(text)
    if not goal or re.search(r"\b(year|annually|yearly)\b", text):
        return None
    if re.search(r"\bthis month\b", text) and re.search(r"\b(can|could|will) i\b", text):
        # This month is partly over: answer from what's already in and out.
        return QuerySpec(
            task_type="month_outlook",
            metric="net",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
            compare_to=goal.group(1),
        )
    return QuerySpec(
        task_type="savings_goal",
        metric="expenses",
        period_type="month",
        period_key=goal.group(1),
        scope=scope,
    )


def _hotspot_spec(text, summary, scope):
    if not _HOTSPOT_RE.search(text):
        return None
    if re.search(
        r"\bmy money (go|going|went)\b|\bspending (the )?most\b|\beating (up )?(most of )?my\b|"
        r"\bmoney drains?\b|\bbiggest drain\b|\btaking up (most of )?my\b",
        text,
    ):
        # "where does my money go" asks for the biggest categories, not unusual ones.
        return QuerySpec(
            task_type="top_category_lookup",
            metric="top_category",
            period_type="month",
            period_key=_period_for(text, summary),
            scope=scope,
            reason_mode="top:5",
        )
    return QuerySpec(
        task_type="hotspots",
        metric="expenses",
        period_type="month",
        period_key=selected_month_key(summary),
        scope=scope,
    )


# ── Years, spans, category vs last month, affordability, budgets ─────────


def _months_between(start, end):
    keys = []
    year, month = (int(x) for x in start.split("-"))
    while f"{year}-{month:02d}" <= end and len(keys) < 24:
        keys.append(f"{year}-{month:02d}")
        month += 1
        if month > 12:
            month, year = 1, year + 1
    return keys


def _year_amount_spec(text, summary, scope, metric, categories):
    """ "how much have I earned so far this year", "health costs this year"."""
    if re.search(
        r"\b(this year|so far this year|year to date|ytd|for the year|the year|"
        r"(whole|entire|full) year)\b",
        text,
    ):
        year = _selected_year(summary)
    elif re.search(r"\blast year\b", text):
        if _named_month_keys(text, summary):
            return None  # "march last year" is one month
        year = _selected_year(summary) - 1
    else:
        explicit = re.search(r"\b(20\d{2})\b", text)
        has_month = re.search(r"\b20\d{2}-\d{2}\b", text) or _named_month_keys(text, summary)
        if not explicit or has_month:
            return None
        year = int(explicit.group(1))
    term = _approx_term(text) if len(categories) == 1 else ""
    return QuerySpec(
        task_type="amount_lookup",
        metric=metric if metric in {"income", "net", "both"} else "expenses",
        period_type="year",
        period_key=str(year),
        scope=scope,
        category=",".join(categories),
        # "travel this year": say it's counted under Transport
        compare_to=term if term and _APPROX_TERMS.get(term) == categories[0] else "",
    )


_UP_DOWN_RE = re.compile(
    r"\b(higher|lower|more|less|go up|go down|went up|went down|up or down|increase|"
    r"increased|decrease|decreased|rise|rose|drop|dropped)\b"
)


def _same_category_terms(text, summary, scope):
    """ "groceries vs eating out": two words that both land in one category."""
    if not re.search(r"\b(vs|versus|or|compared? (to|with))\b", text):
        return None
    # A category's own name ("food and drinks") isn't a second word for it.
    known = {name.lower() for name in _known_categories(summary)}
    found = []
    for word, name in list(_CATEGORY_SYNONYMS.items()) + list(_APPROX_TERMS.items()):
        match = re.search(_approx_pattern(word), text)
        if (
            match
            and word not in known
            and not any(match.start() < end and start < match.end() for start, end, _, _ in found)
        ):
            found.append((match.start(), match.end(), word, name))
    found.sort()
    for i, (_, _, word, name) in enumerate(found):
        for _, _, other, other_name in found[i + 1 :]:
            if other_name == name and other != word:
                return QuerySpec(
                    task_type="data_pointer",
                    period_type="month",
                    period_key=_period_for(text, summary),
                    scope=scope,
                    category=name,
                    reason_mode="same_category",
                    compare_to=f"{word}|{other}",
                )
    return None


def _category_versus_spec(text, summary, scope):
    """ "have I spent more on food or transport this month": two categories in one month."""
    categories = _categories_in(text, summary)
    if len(categories) != 2:
        return None
    if not re.search(r"\b(more|less|most|least|bigger|higher|lower)\b", text):
        return None
    if not re.search(r"\b(or|vs|versus|than|compared? (to|with))\b", text):
        return None
    if re.search(r"\b(than|vs|versus|compared? (to|with)|from|since) (last month|my )", text):
        return None  # a change over time, not one category against the other
    return QuerySpec(
        task_type="category_spending",
        metric="expenses",
        period_type="month",
        period_key=_period_for(text, summary),
        scope=scope,
        category=",".join(categories),
        reason_mode="versus",
    )


def _category_vs_last_month_spec(text, summary, scope):
    """ "is shopping higher than last month", "did food go up or down this month"."""
    categories = _categories_in(text, summary)
    if not categories and re.search(
        r"\b(spend|spent|spending)\b.*\b(more|less|higher|lower) than last month\b|"
        r"\b(more|less|higher|lower) than last month\b.*\b(spend|spent|spending)\b|"
        r"\bthis month\b.*\b(stack|stacks|measure|measures|compare|compares) up\b.*\blast month\b|"
        r"\b(spend|spent|spending)\b.*\b(go|goes|went|gone|come|came) (up|down)\b.*"
        r"\b(compared? (to|with)|than|from|vs|versus) last month\b|"
        r"^(did|have|am|was|were|do) i (spend|spent|spending|been spending) (more|less)"
        r"( money)? this month$",
        text,
    ):
        return QuerySpec(
            task_type="compare_periods",
            metric="expenses",
            period_type="month_range",
            period_key=f"{selected_month_key(summary)},{previous_month_key(summary)}",
            scope=scope,
        )
    since = re.search(r"\bsince\b", text) and _named_month_keys(text, summary)
    if categories and since and re.search(r"\b(worse|better|more|less|up|down|changed?)\b", text):
        return QuerySpec(
            task_type="compare_periods",
            metric="expenses",
            period_type="month_range",
            period_key=f"{selected_month_key(summary)},{_named_month_keys(text, summary)[0]}",
            scope=scope,
            category=",".join(categories),
        )
    vs_words = re.search(r"\bthis month (vs|versus|compared to|and) last month\b", text)
    if not categories or re.search(r"\bbeen\b", text):
        return None
    if not _UP_DOWN_RE.search(text) and not vs_words and not re.search(r"\bcompar", text):
        return None
    if not re.search(
        r"\b(this month|than last month|vs last month|from last month|"
        r"(compared?|comparing) (to|with) last month)\b",
        text,
    ):
        return None
    return QuerySpec(
        task_type="compare_periods",
        metric="expenses",
        period_type="month_range",
        period_key=f"{selected_month_key(summary)},{previous_month_key(summary)}",
        scope=scope,
        category=",".join(categories),
    )


def _affordability_spec(text, summary, scope):
    """ "can I afford a $1000 vacation next month?" """
    match = re.search(r"\bafford\b.*?\b(\d{2,7})\b", text)
    if match and re.search(r"\b(this week|this month|today|tonight|this weekend)\b", text):
        return QuerySpec(
            task_type="extra_spend",
            metric="net",
            period_type="month",
            period_key=match.group(1),
            scope=scope,
            compare_to=selected_month_key(summary),
        )
    if not match:
        if re.search(r"\b(can|could) i afford\b", text) and not re.search(r"\d", text):
            return QuerySpec(
                task_type="affordability", metric="net", period_type="month", scope=scope
            )
        return None
    return QuerySpec(
        task_type="affordability",
        metric="net",
        period_type="month",
        period_key=match.group(1),
        scope=scope,
    )


def _budget_suggestion_spec(text, summary, scope):
    """ "how much should I budget for food?" """
    if not re.search(r"\b(budget|set aside|allow|spend)\b", text):
        return None
    if not re.search(
        r"\bhow much should i\b|\bwhat should my\b.*\bbudget\b|\bgood budget\b|"
        r"\b(realistic|reasonable|sensible|good|sane) ([a-z]+ )?budget\b|"
        r"\b(suggest|recommend|set|give me|make|create|come up with) (me )?(a |an )?"
        r"([a-z]+ ){0,2}budget\b",
        text,
    ):
        return None
    category = _category_in(text, summary)
    return QuerySpec(
        task_type="budget_suggestion",
        metric="expenses",
        period_type="month",
        period_key=selected_month_key(summary),
        scope=scope,
        category=category,
    )


def _compare_months_followup(text, summary, history):
    """ "compared to the month before?" after a question about one month."""
    if not re.match(
        r"^(compared? (to|with)|vs|versus|how about) (the )?"
        r"(month before|previous month|prior month|month prior)\b",
        text,
    ):
        return None
    previous = _last_user_text(history)
    if not previous:
        return None
    prev_spec = _parse_query(previous, summary)
    if prev_spec.period_type != "month" or not prev_spec.period_key:
        return None
    month = prev_spec.period_key
    return QuerySpec(
        task_type="compare_periods",
        metric="expenses",
        period_type="month_range",
        period_key=f"{month},{_months_back(month, 1)}",
        scope=prev_spec.scope,
        category=prev_spec.category.split(",")[0] if prev_spec.category else "",
    )


# ── Meaning questions, chat actions, judgements, derived metrics ─────────

_GLOSSARY_TERMS = [
    ("net worth", "net_worth"),
    ("cash flow", "cash_flow"),
    ("fees and transfers", "fees_transfers"),
    ("fees transfers", "fees_transfers"),
    ("savings rate", "savings_rate"),
    ("budget", "budget"),
    ("income", "income"),
    ("expenses", "expenses"),
    ("other", "other"),
    ("subscriptions", "subscriptions"),
]
_MEANING_RE = re.compile(
    r"\b(what does|what do|what is|what s|whats|define|meaning of|mean|means|"
    r"difference between|how is|how are|explain)\b"
)


def _glossary_spec(text, summary, scope):
    """ "what does Fees & Transfers mean?", "why is my net worth negative?" """
    if re.search(r"\bdifference between my\b", text) and _amount_metric(text) == "both":
        # "the difference between my income and spending this month" is a number.
        year_spec = _year_amount_spec(text, summary, scope, "both", [])
        if year_spec is not None:
            return year_spec
        return QuerySpec(
            task_type="amount_lookup",
            metric="both",
            period_type="month",
            period_key=_period_for(text, summary),
            scope=scope,
        )
    why_negative = re.search(r"\bwhy is my net worth (negative|so low|below zero)\b", text)
    asks_meaning = re.search(
        r"\b(mean|means|meaning|define|difference between|calculated|computed|work)\b", text
    )
    if not why_negative and not (asks_meaning and _MEANING_RE.search(text)):
        return None
    text_amp = text.replace("&", " and ")
    for phrase, key in _GLOSSARY_TERMS:
        if re.search(r"\b" + phrase + r"\b", text_amp):
            if why_negative:
                key = "net_worth_negative"
            elif key == "income" and re.search(r"\bcash flow\b", text_amp):
                key = "income_vs_cash_flow"
            return QuerySpec(task_type="data_pointer", scope=scope, reason_mode=f"define:{key}")
    return None


_ACTION_RE = re.compile(
    r"^(please )?(set|change|update|create|add|make|export|download|email|send|remind|"
    r"delete|remove|erase|categorize|recategorize|rename|mark|cancel my|turn on|turn off)\b"
    r"|\b(can you|could you|please)\b.*\b(set|change|export|download|remind|delete|"
    r"categorize|update|create)\b"
    r"|\bshow me a (chart|graph|plot)\b|\b(chart|graph|plot) of\b"
    r"|\bset (a |my |the )?budget\b"
)


_INJECTION_RE = re.compile(
    r"\b(ignore|disregard|forget|override) (all |your |the |any |previous |prior |above )*"
    r"(rules|instructions|prompt|prompts|guidelines)\b|\bsystem prompt\b|\bapi key\b|"
    r"\bdeveloper mode\b|\bjailbreak\b|\byou are now\b"
)


def _special_asks_spec(text, summary, scope):
    """Why income moved, and attempts to change the assistant's rules."""
    what_on = re.match(
        r"^what did i (spend( my)?( money)? on|buy|purchase)( on)? (yesterday|today)$", text
    )
    if what_on:
        return QuerySpec(
            task_type="recent_transactions",
            metric="expenses",
            period_type="day",
            period_key=_day_key(what_on.group(5)),
            scope=scope,
        )
    if _INJECTION_RE.search(text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="injection")
    if re.search(r"\b(which|what) month\b.*\b(save|saved)\b.*\b(most|least)\b", text):
        return QuerySpec(
            task_type="month_extreme",
            metric="net",
            period_type="year",
            period_key=str(_selected_year(summary)),
            scope=scope,
            reason_mode="lowest" if "least" in text else "highest",
        )
    costs = re.search(
        r"\b(?:what|how much) (?:does|do) (?:my |the )?([a-z][a-z0-9 .*']{2,30}?) cost( me)?\b|"
        r"\bhow much (?:is|are) (?:my |the )?([a-z][a-z0-9 .*']{2,30}?) costing\b",
        text,
    )
    item = (costs.group(1) or costs.group(3)) if costs else ""
    if (
        item
        and not _category_in(item, summary, include_approx=False)
        and not re.match(r"(that|this|it|everything|all|living|life|an?)\b", item)
    ):
        return QuerySpec(
            task_type="data_pointer", scope=scope, reason_mode="merchant", category=item
        )
    sub = re.search(
        r"\bhow much is (my|the) ([a-z][a-z0-9 .*]{2,30}?) (subscription|membership)\b", text
    )
    if (
        sub
        and not _category_in(sub.group(2), summary, include_approx=False)
        and not _GENERIC_NAME_RE.match(sub.group(2))
    ):
        return QuerySpec(
            task_type="data_pointer", scope=scope, reason_mode="merchant", category=sub.group(2)
        )
    if (
        re.search(r"\bincome\b", text)
        and re.search(r"\b(spending|expenses|spend)\b", text)
        and re.search(r"\b(compare|compares|compared|vs|versus|against)\b", text)
        and len(_named_month_keys(text, summary)) < 2
        and "last month" not in text
    ):
        year_spec = _year_amount_spec(text, summary, scope, "both", [])
        if year_spec is not None:
            return year_spec
        return QuerySpec(
            task_type="amount_lookup",
            metric="both",
            period_type="month",
            period_key=_period_for(text, summary),
            scope=scope,
        )
    charge = re.search(r"\b(?:the|my) ([a-z][a-z0-9 .*]{2,30}?) (charge|bill|subscription)\b", text)
    if charge:
        # "my last spotify charge" names spotify
        charge = re.search(
            r"\b(?:the|my) (?:last |latest |most recent |recent )?([a-z][a-z0-9 .*]{2,30}?) "
            r"(charge|bill|subscription)\b",
            text,
        )
    if (
        charge
        and not _category_in(charge.group(1), summary)
        and not re.search(r"\b(card|credit|phone|gas|electric|water|internet)\b", charge.group(1))
        and not _GENERIC_NAME_RE.match(charge.group(1))
    ):
        return QuerySpec(
            task_type="data_pointer", scope=scope, reason_mode="merchant", category=charge.group(1)
        )
    pay_for = re.search(
        r"\bhow much do i (?:pay|spend) (?:for|on) ([a-z][a-z0-9 .*]{1,30})|"
        r"\b(?:how much (?:have|did|do) i|^(?:have|did) i) (?:paid|pay) (?:to |for )?"
        r"([a-z][a-z0-9 .*]{1,30})",
        text,
    )
    if (
        pay_for
        and not _category_in(text, summary, include_approx=pay_for.group(2) is None)
        and not re.search(r"\bcards?\b", text)
    ):
        # "how much do I pay for spotify each month" names a merchant, not a category.
        name = re.sub(
            r"\b(this|last|in|during|each|every|a month|per|monthly|on average|so far|"
            r"overall|in total|total|yesterday|today|recently|lately|since|from|between|"
            r"over|back)\b.*$",
            "",
            pay_for.group(1) or pay_for.group(2),
        ).strip()
        name = re.sub(r"^(my|the) ", "", name)
        if len(name) >= 3 and not _GENERIC_NAME_RE.match(name):
            return QuerySpec(
                task_type="data_pointer", scope=scope, reason_mode="merchant", category=name
            )
    if (
        re.search(r"\b(saving|saved|savings)\b", text)
        and re.search(
            r"\b(lately|recently|more or less|over time|trend|improving|getting (better|worse))\b",
            text,
        )
        and not re.search(r"\b(how (can|do|should) i|tips?|ways? to|help me)\b", text)
    ):
        # "have I been saving more or less lately" is the trend of income minus spending.
        return QuerySpec(
            task_type="spending_trend",
            metric="net",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
            reason_mode="trend",
        )
    is_top = re.match(
        r"^(?:is|was) (.+?) (?:my|the) (?:biggest|largest|top|main|highest) "
        r"(?:expense|category|spending|cost)\b",
        text,
    )
    if is_top and _category_in(is_top.group(1), summary):
        return QuerySpec(
            task_type="top_category_lookup",
            metric="top_category",
            period_type="month",
            period_key=_period_for(text, summary),
            scope=scope,
            category=_category_in(is_top.group(1), summary),
            reason_mode="is_top",
        )
    if re.search(r"\brefunds?\b|\brefunded\b", text) and (
        _AMOUNT_ASK_RE.search(text) or re.search(r"\b(did|have|any|get|got)\b", text)
    ):
        return QuerySpec(
            task_type="data_pointer",
            period_type="month",
            period_key=_period_for(text, summary),
            scope=scope,
            reason_mode="refunds",
        )
    if (
        re.search(r"\bincome\b", text)
        and re.search(r"\b(why|low|lower|high|higher|drop|dropped|down|so little)\b", text)
        and not re.search(
            r"\b(spend|spent|spending|expenses?|going up|going down|trend|trending|lately|than|or|"
            r"vs|versus|compared?)\b",
            text,
        )
        and len(_named_month_keys(text, summary)) < 2
    ):
        return QuerySpec(
            task_type="amount_lookup",
            metric="income",
            period_type="month",
            period_key=_period_for(text, summary),
            scope=scope,
            reason_mode="income_vs_usual",
        )
    return None


def _chat_action_spec(text, summary, scope):
    """Requests to change data or the app: chat can only read."""
    if not _ACTION_RE.search(text):
        return None
    if re.search(r"\b(chart|graph|plot)\b", text):
        mode = "action:chart"
    elif re.search(r"\bbudget\b", text):
        mode = "action:budget"
    elif re.search(r"\b(export|download|email)\b", text):
        mode = "action:export"
    elif re.search(r"\bremind", text):
        mode = "action:remind"
    elif re.search(r"\b(categorize|recategorize|category)\b", text):
        mode = "action:categorize"
    elif re.search(r"\b(delete|remove|erase)\b", text):
        mode = "action:delete"
    else:
        mode = "action:other"
    return QuerySpec(task_type="data_pointer", scope=scope, reason_mode=mode)


def _peer_compare_spec(text, summary, scope):
    if not re.search(
        r"\b(people my age|most people|other people|average person|others|everyone else|"
        r"people like me|national average|typical person)\b",
        text,
    ):
        return None
    return QuerySpec(
        task_type="data_pointer",
        scope=scope,
        reason_mode="peers",
        category=_category_in(text, summary),
    )


def _amount_judgement_spec(text, summary, scope):
    """ "is $500 a month on food a lot?", "is it bad that I spent $120 on sushi?" """
    if not re.search(
        r"\b(a lot|too much|expensive|reasonable|normal|high|bad|okay|ok|fine)\b", text
    ):
        return None
    if not re.search(r"\b(is|was|are|am)\b", text):
        return None
    amount = re.search(r"\b(\d{1,6}(?:\.\d+)?)\b", text)
    if not amount:
        return None
    monthly = bool(re.search(r"\b(a|per|each|every) month\b|\bmonthly\b", text))
    weekly = bool(re.search(r"\b(a|per|each|every) week\b|\bweekly\b", text))
    daily = bool(re.search(r"\b(a|per|each|every) day\b|\bdaily\b", text))
    return QuerySpec(
        task_type="amount_judgement",
        metric="expenses",
        period_type="month" if monthly else ("week" if weekly else ("day" if daily else "single")),
        period_key=amount.group(1),
        scope=scope,
        category=_category_in(text, summary) or "",
        # "$50 a week on coffee": coffee is only part of Food, so the reply says so
        compare_to=_approx_term(text) if not _category_in(text, summary, False) else "",
    )


def _derived_metric_spec(text, summary, scope):
    """Counts, rates and averages the summary can compute: transaction counts, savings
    rate, spend per day, biggest day, weekends."""
    mode = ""
    if re.search(r"\b(per|each|average|avg) (transaction|purchase|charge)\b", text):
        mode = "per_tx"
    elif re.search(
        r"\bhow many (transactions|purchases|charges)\b|\bnumber of transactions\b|"
        r"\bhow many times did i (buy|shop|spend|pay|purchase)\b",
        text,
    ):
        mode = "tx_count"
        day = _day_key(text, _selected_year(summary))
        if day:
            return QuerySpec(
                task_type="amount_lookup",
                metric="expenses",
                period_type="day",
                period_key=day,
                scope=scope,
            )
        recent = re.search(r"\b(last|past) (\d{1,2}) days\b", text)
        if re.search(r"\b(last|past|this) week\b", text) or recent:
            # daily totals carry counts, so a week's purchases can be counted
            today = date_cls.today()
            back = int(recent.group(2)) - 1 if recent else 6
            return QuerySpec(
                task_type="day_span",
                metric="expenses",
                period_type="days",
                period_key=f"{(today - timedelta(days=back)).isoformat()},{today.isoformat()}",
                scope=scope,
            )
        if _category_in(text, summary):
            return QuerySpec(
                task_type="data_pointer",
                period_type="month",
                period_key=_period_for(text, summary),
                scope=scope,
                category=_category_in(text, summary),
                reason_mode="category_count",
            )
    elif re.search(
        r"\bsavings? rate\b|\bpercent(age)? of (my )?income\b|\bwhat percent\b|"
        r"\b(share|portion|fraction|part|how much) of (my )?income\b",
        text,
    ) and not _category_in(text, summary):
        if re.search(r"\bsav(e|ed|ing) \d+ percent\b", text):
            return None  # "if I saved 10% of my income" is a saving target
        mode = "savings_rate"
    elif re.search(r"\bmost (i ve |i have |i )?(spent|spend) in (one|a single|a|1) day\b", text):
        mode = "top_day"
    elif re.search(r"\b(per day|a day|daily|each day)\b", text) and _amount_metric(text):
        mode = "per_day"
    elif re.search(
        r"\b(which|what) (week)?day of the week\b|\bwhich weekday\b|\bwhat weekday\b|"
        r"\bday of (the )?week\b",
        text,
    ):
        mode = "weekday"
    elif (
        re.search(r"\b(which|what) day\b", text) and re.search(r"\b(most|highest|biggest)\b", text)
    ) or re.search(
        r"\b(most expensive|biggest|priciest|highest|worst) (spending )?day\b|"
        r"\bmost (i ve |i have |i )?(spent|spend) in (one|a single|a|1) day\b",
        text,
    ):
        mode = "top_day"
    elif re.search(r"\b(which|what) week\b", text) and re.search(
        r"\b(most|highest|biggest|least|lowest)\b", text
    ):
        mode = "low_week" if re.search(r"\b(least|lowest)\b", text) else "top_week"
    elif (
        re.search(r"\b(each|every|by) week\b|\bweek by week\b", text)
        and not re.search(r"\b(average|avg|typical|typically|usually|normally)\b", text)
        and (re.search(r"\b(this|last) month\b", text) or _named_month_keys(text, summary))
    ):
        mode = "weeks"  # "how much did I spend each week this month"
    elif re.search(r"\bweekends?\b", text) and not _last_weekend_asked(text):
        mode = "weekends"
        if "last month" in text or _named_month_keys(text, summary):
            return QuerySpec(
                task_type="derived_metric",
                metric="expenses",
                period_type="month",
                period_key=previous_month_key(summary)
                if "last month" in text
                else _named_month_keys(text, summary)[0],
                scope=scope,
                reason_mode=mode,
                compare_to="in_month",
            )
    elif re.search(r"\bsubscriptions?\b.*\b(forgot|forgotten|unused|don t use|dont use)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="subscriptions")
    elif re.search(r"\bwhen did i spend (the )?(most|least)\b", text):
        return None  # which month: the month-extreme rule answers
    elif re.search(r"\bwhen did i (last )?(buy|pay|purchase|spend|get)\b", text):
        thing = re.sub(
            r"^.*\bwhen did i (last )?(buy|pay for|pay|purchase|spend on|get)\s*", "", text
        )
        at = re.match(
            r"(?:something|anything|stuff )?\s*(?:at|from) ([a-z][a-z0-9 .*']{1,25})$", thing
        )
        if at:
            # "when did I last buy something at starbucks": the merchant's latest charge
            return QuerySpec(
                task_type="data_pointer", scope=scope, reason_mode="merchant", category=at.group(1)
            )
        return QuerySpec(
            task_type="data_pointer", scope=scope, reason_mode="find_purchase", category=thing
        )
    if not mode:
        return None
    if mode in {"savings_rate", "per_day"} and re.search(
        r"\b(this year|so far this year|for the year)\b", text
    ):
        return QuerySpec(
            task_type="derived_metric",
            metric="expenses",
            period_type="year",
            period_key=str(_selected_year(summary)),
            scope=scope,
            reason_mode=mode,
        )
    if "last month" in text:
        month_key = previous_month_key(summary)
    else:
        month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
    return QuerySpec(
        task_type="derived_metric",
        metric="expenses",
        period_type="month",
        period_key=month_key,
        scope=scope,
        reason_mode=mode,
        category=_category_in(text, summary) if mode in {"per_day", "per_tx"} else "",
        compare_to="good" if re.search(r"\b(good|healthy|ideal)\b", text) else "",
    )


# ── Goals, counterfactuals, pace against last month, weeks ───────────────


def _goal_time_spec(text, summary, scope):
    """ "how long would it take to save $5000?" """
    match = re.search(r"\bhow long\b.*\bsave\s+(?:about\s+)?(\d{2,7})\b", text)
    if not match:
        match = re.search(r"\bsave\s+(?:about\s+)?(\d{2,7})\b.*\bhow long\b", text)
    how_much = None
    if not match:
        # "how much should I save to reach $5000" with no deadline: time it, and price a year.
        how_much = re.search(
            r"\bhow much (?:should|do) i (?:save|set aside|put away)\b.*?"
            r"\b(?:reach|get to|hit|have|save)\s+(?:about\s+)?(\d{2,7})\b",
            text,
        )
        if not how_much or re.search(
            r"\b(by|before|in|within)\b.*\b(month|months|year|years|"
            r"december|weeks?)\b",
            text,
        ):
            return None
        match = how_much
    return QuerySpec(
        task_type="goal_time",
        metric="net",
        period_type="month",
        period_key=match.group(1),
        scope=scope,
        reason_mode="how_much" if how_much else "",
    )


def _extra_spend_spec(text, summary, scope):
    """ "can I spend $200 more on food this month and still be okay?" """
    match = re.search(
        r"\bspend (?:an extra |another )?(\d{2,6}) (?:dollars )?(?:more|extra)\b", text
    )
    if not match:
        return None
    return QuerySpec(
        task_type="extra_spend",
        metric="net",
        period_type="month",
        period_key=match.group(1),
        scope=scope,
        compare_to=selected_month_key(summary),
    )


def _counterfactual_spec(text, summary, scope):
    """ "if I had skipped shopping in august how much would I have saved" """
    if not re.search(r"\b(skipped|had skipped|hadn t|had not|didn t buy|not bought)\b", text):
        return None
    category = _category_in(text, summary)
    if not category:
        return None
    if "last month" in text:
        month_key = previous_month_key(summary)
    else:
        month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
    return QuerySpec(
        task_type="category_spending",
        metric="expenses",
        period_type="month",
        period_key=month_key,
        scope=scope,
        category=category,
        reason_mode="counterfactual",
    )


def _net_vs_last_month_spec(text, summary, scope):
    """ "am I doing better than last month", "did I save more this month than last month",
    "did I make more than last month": income or net cash flow, this month against last."""
    went = re.search(
        r"\b(income|paycheck|pay|salary)\b.*\b(go|gone|went|goes) (up|down)\b|"
        r"\b(income|paycheck|salary)\b.*\b(increase|decrease|rise|drop|change|changed)\b",
        text,
    )
    if went and "this month" in text and not _named_month_keys(text, summary):
        return QuerySpec(
            task_type="compare_periods",
            metric="income",
            period_type="month_range",
            period_key=f"{selected_month_key(summary)},{previous_month_key(summary)}",
            scope=scope,
        )
    if not re.search(r"\b(than|vs|versus|compared? (to|with)|and) last month\b", text):
        return None
    if _categories_in(text, summary):
        return None
    if re.search(
        r"\b(doing (better|worse)|better off|worse off)\b|\b(save|saved|saving) (more|less)\b", text
    ):
        metric = "net"
    else:
        metric = _amount_metric(text)
        if metric not in {"income", "net"}:
            return None
    return QuerySpec(
        task_type="compare_periods",
        metric=metric,
        period_type="month_range",
        period_key=f"{selected_month_key(summary)},{previous_month_key(summary)}",
        scope=scope,
    )


def _did_i_save_spec(text, summary, scope):
    """ "did i save anything in september" is the month's net cash flow."""
    if re.search(
        r"\b(lose|lost|losing) money\b|\bin the (red|black)\b|\bbreak even\b|"
        r"\bend [a-z ]{0,20}with more money\b|\bcome out ahead\b|"
        r"^(did|have|am|was|were) i (make|making|made|earn|earning) money\b(?! (from|on|with|off))|"
        r"^(did|was|were|is|am|do|have) [a-z ]{0,20}\b(positive|negative) (net )?cash ?flow\b|"
        r"^(was|is|were) (my )?(net )?cash ?flow (positive|negative)\b",
        text,
    ):
        # "did I lose money" asks whether spending beat income.
        period_type = "month"
        year = re.search(
            r"\b(this|last) year\b|\b(?:in|for) (20\d{2})\b(?!-)|\byear to date\b|\bytd\b", text
        )
        if year:
            key = year.group(2) or str(_selected_year(summary) - (year.group(1) == "last"))
            month_key, period_type = key, "year"
        elif "last month" in text:
            month_key = previous_month_key(summary)
        else:
            month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
        return QuerySpec(
            task_type="amount_lookup",
            metric="net",
            period_type=period_type,
            period_key=month_key,
            scope=scope,
            reason_mode="earn_vs_spend",
            compare_to=(
                "break_even"
                if "break even" in text
                else (
                    ""
                    if re.search(
                        r"\bin the black\b|\bmore money\b|\bahead\b|\bpositive\b|"
                        r"\b(make|making|made|earn|earning) money\b",
                        text,
                    )
                    else "spend_first"
                )
            ),
        )
    if not re.search(
        r"\b(did i save|have i saved|did i manage to save|how much did i save)\b|"
        r"^am i (actually |even )?saving( any)?( money| anything)?( this month)?$",
        text,
    ):
        return None
    if not _named_month_keys(text, summary) and "month" not in text:
        year_spec = _year_amount_spec(text, summary, scope, "net", [])
        if year_spec:
            return year_spec  # "how much have I saved this year"
    if "last month" in text:
        month_key = previous_month_key(summary)
    else:
        month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
    return QuerySpec(
        task_type="amount_lookup",
        metric="net",
        period_type="month",
        period_key=month_key,
        scope=scope,
        # "how much have I saved" wants the amount; "did I save" also gets a yes or no.
        reason_mode="" if "how much" in text else "earn_vs_spend",
    )


def _on_track_spec(text, summary, scope):
    """ "am i on track to spend less than last month" """
    if not re.search(r"\b(on track|on pace|going to|gonna)\b", text):
        return None
    if not re.search(r"\b(less|more|under|over|below|above)\b.*\blast month\b", text):
        return None
    return QuerySpec(
        task_type="pace_check",
        metric="expenses",
        period_type="month",
        period_key=selected_month_key(summary),
        scope=scope,
        category=_category_in(text, summary),
        compare_to="last_month",
    )


def _explain_month_spec(text, summary, scope):
    """ "explain my spending this month" -> what changed against the month before."""
    if not re.search(r"\b(explain|break down|breakdown|analy[sz]e|walk me through)\b", text):
        return None
    if not re.search(r"\b(spending|expenses|spend|month|money)\b", text):
        return None
    if "last month" in text:
        month_key = previous_month_key(summary)
    else:
        month_key = _transaction_list_month(text, summary) or selected_month_key(summary)
    return QuerySpec(
        task_type="explain",
        metric="expenses",
        period_type="month",
        period_key=month_key,
        scope=scope,
        reason_mode="spending_change",
    )


def _week_compare_spec(text, summary, scope):
    """ "this week vs last week", "the last 30 days than the 30 days before", "the same
    time last month": from daily totals."""
    if re.search(
        r"\bsame (time|point|period|day) last month\b|\bby this (time|point) last month\b|"
        r"\bat this point last month\b",
        text,
    ):
        return QuerySpec(
            task_type="week_compare", metric="expenses", scope=scope, reason_mode="mtd"
        )
    days = re.search(r"\b(?:last|past) (\d{1,2}) days\b", text)
    if days and re.search(
        r"\b(days before|previous \d{1,2} days|prior \d{1,2} days|before that)\b", text
    ):
        return QuerySpec(
            task_type="week_compare", metric="expenses", scope=scope, period_key=days.group(1)
        )
    if not re.search(r"\bthis week\b.*\blast week\b|\blast week\b.*\bthis week\b", text):
        return None
    return QuerySpec(task_type="week_compare", metric="expenses", scope=scope)


def asks_for_advice(message):
    """True for advice, explanation or what-if asks, which the model should answer."""
    text = _normalize(message)
    return bool(
        _ADVICE_RE.search(text)
        or re.search(
            r"\b(why|how come|should|what if|explain|recommend|suggest|think|opinion|advise)\b",
            text,
        )
    )


# ── Thresholds, counts, percentages, why-months, plans, breakdowns ───────


def _period_for(text, summary):
    """Month key the text names (this/last month, N months ago, a month name), or the
    selected month."""
    if "last month" in text:
        return previous_month_key(summary)
    ago = _MONTHS_AGO_RE.search(text)
    if ago:
        raw = ago.group(1)
        return _months_back(
            selected_month_key(summary), int(raw) if raw.isdigit() else _NUMBER_WORDS[raw]
        )
    return _transaction_list_month(text, summary) or selected_month_key(summary)


def _invalid_date_spec(text, summary, scope):
    """ "9/31", "feb 30": a date that doesn't exist."""
    slash = re.search(r"\b(\d{1,2})/(\d{1,2})\b", text)
    named = _MONTH_DAY_RE.search(text)
    iso = re.search(r"\b(20\d{2})-(\d{2})-(\d{2})\b", text)
    year = _selected_year(summary)
    if iso and not _valid_day(*(int(x) for x in iso.groups())):
        bad = iso.group(0)
    elif slash and not _valid_day(year, int(slash.group(1)), int(slash.group(2))):
        bad = slash.group(0)
    elif named and not _valid_day(
        year, MONTH_NAME_TO_NUM.get(named.group(1), 0) or 1, int(named.group(2))
    ):
        bad = named.group(0)
    else:
        return None
    return QuerySpec(
        task_type="data_pointer", scope=scope, reason_mode="invalid_date", category=bad
    )


def _threshold_spec(text, summary, scope):
    """ "did I spend over $2000 in september?", "was I under $2000 in september?" """
    match = re.search(
        r"\b(?:did|have|am|was) i (?:spend|spent|spending|go|gone|been)\b.*?\b"
        r"(over|more than|above|under|less than|below|at least|at most)\s+(\d{2,7})\b",
        text,
    ) or re.search(r"\b(?:was|am|were) i (over|under|above|below)\s+(\d{2,7})\b", text)
    if not match:
        return None
    every = re.search(r"\b(any|every|each) (single )?month\b|\bany of the months\b", text)
    if every:
        # "did I spend over $3000 in any month": the months that crossed it
        return QuerySpec(
            task_type="count_months",
            metric="expenses",
            period_type="every" if every.group(1) in {"every", "each"} else "any",
            period_key=_since_months(text, summary) or str(_selected_year(summary)),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode=match.group(1),
            compare_to=match.group(2),
        )
    # "over 2000" is an amount, not the year 2000.
    period_text = text[: match.start(2)] + text[match.end(2) :]
    return QuerySpec(
        task_type="threshold_check",
        metric="expenses",
        period_type="month",
        period_key=_period_for(period_text, summary),
        scope=scope,
        category=_category_in(text, summary),
        reason_mode=match.group(1),
        compare_to=match.group(2),
    )


def _since_months(text, summary):
    """ "since june": june to the last full month, comma-joined."""
    since = re.search(r"\bsince ([a-z]+)\b", text)
    start = _named_month_keys(since.group(0), summary) if since else []
    last_full = _months_back(date_cls.today().strftime("%Y-%m"), 1)
    if len(start) != 1 or start[0] > last_full:
        return ""
    return ",".join(_months_between(start[0], last_full))


def _count_months_spec(text, summary, scope):
    """ "how many months did I spend over $3000?" """
    match = re.search(
        r"\b(?:how many|which|what) (?:other )?months\b.*?\b(over|more than|above|under|less than|below)\s+"
        r"(\d{2,7})\b",
        text,
    )
    any_month = re.search(
        r"\b(?:was there|were there|is there|did i have|have i had|have i ever had) (?:a|any) "
        r"months?\b.*?\b(over|more than|above|under|less than|below)\s+(\d{2,7})\b",
        text,
    )
    if any_month:
        return QuerySpec(
            task_type="count_months",
            metric="income" if _amount_metric(text) == "income" else "expenses",
            period_type="any",
            period_key=_since_months(text, summary) or str(_selected_year(summary)),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode=any_month.group(1),
            compare_to=any_month.group(2),
        )
    if not match:
        return None
    return QuerySpec(
        task_type="count_months",
        metric="income" if _amount_metric(text) == "income" else "expenses",
        period_type="year",
        period_key=str(_selected_year(summary)),
        scope=scope,
        category=_category_in(text, summary),
        reason_mode=match.group(1),
        compare_to=match.group(2),
    )


def _percent_of_spec(text, summary, scope):
    """ "what's 10% of my monthly food spending?" ("%" is stripped, so "10 of my")."""
    match = re.search(r"\b(\d{1,3})\s+(?:percent\s+)?of my\b", text)
    if not match:
        return None
    return QuerySpec(
        task_type="percent_of",
        metric="income" if _amount_metric(text) == "income" else "expenses",
        period_type="month",
        period_key=match.group(1),
        scope=scope,
        category=_category_in(text, summary),
    )


def _why_month_spec(text, summary, scope):
    """ "why was august so expensive?", "what drove the drop in september?" """
    if not re.search(r"\b(why|what drove|what caused|how come|reason for|what made)\b", text):
        return None
    keys = _named_month_keys(text, summary)
    if len(keys) == 1:
        month = keys[0]
    elif "this month" in text:
        month = selected_month_key(summary)
    elif "last month" in text:
        month = previous_month_key(summary)
    else:
        return None
    return QuerySpec(
        task_type="explain",
        metric="expenses",
        period_type="month",
        period_key=month,
        scope=scope,
        reason_mode="spending_change",
        category=_category_in(text, summary),
    )


def _budget_plan_spec(text, summary, scope):
    if not re.search(
        r"\b(budget plan|plan (a|my) budget|make (me )?a budget|build (me )?a budget|"
        r"budget for next month|monthly budget plan|set up a budget)\b",
        text,
    ):
        return None
    return QuerySpec(
        task_type="budget_suggestion",
        metric="expenses",
        period_type="month",
        period_key=selected_month_key(summary),
        scope=scope,
        reason_mode="plan",
    )


def _by_category_spec(text, summary, scope):
    """ "show me spending by category for july", "what categories did I spend on" """
    if not re.search(
        r"\bby category\b|\bper category\b|\bcategory breakdown\b|\bbreakdown by\b|"
        r"\bcategory totals\b|\btotals by category\b|"
        r"\bwhat categories\b|\bwhich categories\b|\ball (my )?categories\b|\beach category\b|"
        r"\brank (my |the )?(spending )?categories\b|"
        r"\b(list|show|give me) (me )?(my |the |all )?([a-z]+ )?(spending )?categories\b|"
        r"\bspending categories (for|in)\b|\bhow did i spend (my )?money\b|"
        r"\bwhat did i spend (my )?money on\b|\bwhere (did )?(all )?my money (go|went)\b|"
        r"\bwhat (were|are|was) my (spending )?categories\b|"
        r"^(my |the |spending )?categories (for|in|from|of) ",
        text,
    ) and not (
        re.search(r"\bbreak ?down\b", text)
        and not re.search(r"\b(why|change|changed|compare|compared|vs|versus|than)\b", text)
    ):
        return None
    return QuerySpec(
        task_type="top_category_lookup",
        metric="top_category",
        period_type="month",
        period_key=_period_for(text, summary),
        scope=scope,
        reason_mode="top:12",
    )


def _each_month_spec(text, summary, scope):
    """ "how much did I spend each month this year?" """
    if re.search(r"\b(pay|paid) for\b", text) and not _category_in(text, summary):
        return None  # "how much do I pay for spotify each month" names a merchant
    if not re.search(r"\b(each month|every month|month by month|per month breakdown)\b", text):
        return None
    if re.search(r"\b(average|avg|usually|typically|should|save|saving)\b", text):
        return None
    if re.search(r"\bdo i (usually |normally |typically )?(spend|make|earn)\b", text):
        # "how much do I spend on food each month" asks for the usual amount.
        return QuerySpec(
            task_type="spending_trend",
            metric=_amount_metric(text)
            if _amount_metric(text) in {"income", "net"}
            else "expenses",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="average",
        )
    year = _selected_year(summary)
    months = [f"{year}-{m:02d}" for m in range(1, 13)]
    index = (summary or {}).get("month_index") or {}
    available = [m for m in months if m in index and m <= selected_month_key(summary)]
    if len(available) < 2:
        return None
    return QuerySpec(
        task_type="compare_periods",
        metric="expenses",
        period_type="month_range",
        period_key=",".join(available),
        scope=scope,
        category=_category_in(text, summary),
        reason_mode="series",
    )


def _all_time_spec(text, summary, scope):
    """ "how much did I spend in the past/ever" and "in the future"."""
    if re.search(r"\b(in the future|next year|future)\b", text) and _amount_metric(text):
        return QuerySpec(
            task_type="data_pointer",
            scope=scope,
            reason_mode="future_period",
            period_key="the future",
        )
    if not re.search(
        r"\b(in the past|ever|all time|since i started|in total overall|all together)\b", text
    ) or re.search(
        r"\b(past|last) (\d+|two|few|couple|several) (days|weeks|months)\b|"
        r"\bin the past (day|week|month|year|fortnight)\b",
        text,
    ):
        return None
    if re.search(r"\bcategor", text):
        return None  # "biggest category ever" is a ranking
    if not _amount_metric(text):
        return None
    return QuerySpec(
        task_type="all_time",
        metric=_amount_metric(text) if _amount_metric(text) in {"income", "net"} else "expenses",
        period_type="all",
        scope=scope,
        category=_category_in(text, summary),
    )


def _followup_about_previous(text, previous, summary):
    """Follow-ups that act on the previous question's answer."""
    prev_spec = _parse_query(previous, summary)
    month = prev_spec.period_key.split(",")[0] if prev_spec.period_key else ""
    has_month = prev_spec.period_type in {"month", "month_range"} and bool(
        re.match(r"^20\d{2}-\d{2}$", month)
    )
    than = re.match(
        r"^(is|was) (that|it|this) (more|less|higher|lower|bigger|smaller) than (.+?)\??$", text
    )
    stack = re.match(
        r"^(?:how (?:does|did|do) (?:that|it|this) (?:stack up|compare|measure up|look) "
        r"(?:against|to|with|next to)|(?:that|it|this) (?:compared? (?:to|with)|vs|versus)) (.+?)\??$",
        text,
    )
    target = than.group(4) if than else (stack.group(1) if stack else "")
    if target and has_month and prev_spec.period_type == "month":
        other = ""
        if re.match(r"(last month|the month before|the previous month|before)\b", target):
            other = _months_back(month, 1)
        else:
            named = _named_month_keys(target, summary) or _named_month_keys(f"in {target}", summary)
            other = named[0] if named and named[0] != month else ""
        if other:
            return QuerySpec(
                task_type="compare_periods",
                metric=prev_spec.metric if prev_spec.metric in {"income", "net"} else "expenses",
                period_type="month_range",
                period_key=f"{month},{other}",
                scope=prev_spec.scope,
                category=(prev_spec.category or "").split(",")[0],
                compare_to=""
                if not than
                else "asked_less"
                if than.group(3) in {"less", "lower", "smaller"}
                else "asked_more",
            )
    then = re.search(r"\b(then|that month|in that month|that same month)$", text)
    if (
        then
        and has_month
        and prev_spec.period_type == "month"
        and not _PERIOD_WORDS_RE.search(text)
    ):
        # "how much did I earn then?" after a question about September
        asked = _parse_query(f"{text[: then.start()].strip()} in {month}", summary)
        if asked.period_key == month:
            return asked
    if (
        re.search(r"\b(month (before|after)( that| it)?|previous month|following month)\b", text)
        and prev_spec.task_type == "category_change"
        and len((prev_spec.period_key or "").split(",")) == 2
    ):
        step = -1 if re.search(r"\b(after|following)\b", text) else 1
        left, right = prev_spec.period_key.split(",")
        return dataclasses.replace(
            prev_spec, period_key=f"{_months_back(left, step)},{_months_back(right, step)}"
        )
    if re.search(r"\b(month before( that| it)?|previous month|one before)\b", text) and has_month:
        return dataclasses.replace(
            prev_spec, period_key=_months_back(month, 1), period_type="month"
        )
    if re.search(r"\b(the )?week before( that| it)?\b|\bprevious week\b", text) and re.search(
        r"\b(last week|past week|last 7 days|past 7 days|this week)\b", _normalize(previous)
    ):
        today = date_cls.today()
        return QuerySpec(
            task_type="day_span",
            metric="expenses",
            period_type="days",
            period_key=f"{(today - timedelta(days=13)).isoformat()},"
            f"{(today - timedelta(days=7)).isoformat()}",
            scope=prev_spec.scope,
            category=prev_spec.category,
        )
    if (
        re.search(r"\b(year before( that| it)?|previous year|last year|the year prior)\b", text)
        and prev_spec.period_type == "year"
        and re.match(r"^20\d{2}$", prev_spec.period_key or "")
    ):
        return dataclasses.replace(prev_spec, period_key=str(int(prev_spec.period_key) - 1))
    if (
        re.match(
            r"^(which|what) (category|categories|one|ones)( mostly| most)? "
            r"(drove|caused|made|was behind|is behind|led to|explains?|did that)\b",
            text,
        )
        and has_month
    ):
        return QuerySpec(
            task_type="explain",
            metric="expenses",
            period_type="month",
            period_key=month,
            scope=prev_spec.scope,
            reason_mode="spending_change",
        )
    if re.search(r"\b(month after( that| it)?|following month|next one)\b", text) and has_month:
        return dataclasses.replace(
            prev_spec, period_key=_months_back(month, -1), period_type="month"
        )
    if re.search(
        r"\b(whole|entire|full) year\b|\bfor the year\b|\bthis year\b|"
        r"^(and |what about |how about )?(the|this) year$",
        text,
    ):
        return QuerySpec(
            task_type="amount_lookup",
            metric=prev_spec.metric if prev_spec.metric in {"income", "net"} else "expenses",
            period_type="year",
            period_key=month[:4] if has_month else str(_selected_year(summary)),
            scope=prev_spec.scope,
            category=prev_spec.category if prev_spec.task_type == "category_spending" else "",
        )
    if re.search(r"\bcompared? (to|with) (my )?(average|usual|normal)\b", text) and has_month:
        return QuerySpec(
            task_type="pace_check",
            metric="expenses",
            period_type="month",
            period_key=month,
            scope=prev_spec.scope,
            category=(prev_spec.category or "").split(",")[0],
        )
    if (
        re.match(r"^(is|was) (that|it|this) (good|bad|ok|okay|healthy|normal|fine)\b", text)
        and prev_spec.reason_mode == "savings_rate"
    ):
        return dataclasses.replace(prev_spec, compare_to="good")
    if re.match(r"^(is|was) (that|it|this) (good|bad|ok|okay|healthy|normal|fine)\b", text):
        span = parse_query_v2(previous, summary)
        if (
            span.metric == "net"
            and span.task_type == "amount_lookup"
            and span.period_type == "month_range"
        ):
            # "is that good?" after "did I spend more than I earned in q3"
            return dataclasses.replace(span, compare_to="judge")
    if (
        re.match(r"^(is|was) (that|it|this) (good|bad|ok|okay|healthy|normal|fine)\b", text)
        and prev_spec.metric == "net"
        and prev_spec.task_type == "amount_lookup"
        and prev_spec.period_type in {"month", "year"}
    ):
        return dataclasses.replace(prev_spec, reason_mode="earn_vs_spend", compare_to="judge")
    if re.match(
        r"^(is|was) (that|it|this) (a lot|too much|too high|too low|high|normal|bad|ok|okay|good|"
        r"(more|higher|bigger) than (usual|normal|average)|above (average|normal|usual)|unusual)\b",
        text,
    ):
        span = parse_query_v2(previous, summary)
        span_keys = [k for k in (span.period_key or "").split(",") if k]
        if (
            span.period_type == "month_range"
            and len(span_keys) >= 2
            and "," not in (span.category or "")
        ):
            # "is that a lot?" after "how much on entertainment in q3": the whole span
            return QuerySpec(
                task_type="pace_check",
                metric="expenses",
                period_type="month_range",
                period_key=",".join(sorted(span_keys)),
                scope=span.scope,
                category=span.category,
            )
        if has_month:
            return QuerySpec(
                task_type="pace_check",
                metric="expenses",
                period_type="month",
                period_key=month,
                scope=prev_spec.scope,
                category=(prev_spec.category or "").split(",")[0],
            )
    if re.match(
        r"^(how much is |what s |what is )?(that|it|this) (a|per|each) day\b|^(and )?(per|a) day$",
        text,
    ):
        if has_month and prev_spec.period_type == "month":
            # "how much is that a day?" after "how much did I spend in september?"
            return QuerySpec(
                task_type="derived_metric",
                metric="expenses",
                period_type="month",
                period_key=month,
                scope=prev_spec.scope,
                reason_mode="per_day",
            )
    if re.match(r"^(break (that|it) down|breakdown|by category|details|more detail)\b", text):
        if has_month:
            return QuerySpec(
                task_type="top_category_lookup",
                metric="top_category",
                period_type="month",
                period_key=month,
                scope=prev_spec.scope,
                reason_mode="top:12",
            )
    new_category = _category_in(text, summary)
    if (
        new_category
        and prev_spec.task_type in {"category_change", "compare_periods"}
        and len([k for k in (prev_spec.period_key or "").split(",") if k]) == 2
    ):
        return QuerySpec(
            task_type="compare_periods",
            metric="expenses",
            period_type="month_range",
            period_key=prev_spec.period_key,
            scope=prev_spec.scope,
            category=new_category,
        )
    compare_to = re.match(
        r"^(?:and |but )?(?:how (?:does|did|do) (?:that|this|it) )?compare(?:s|d)?( that| this| it)? "
        r"(to|with|against) (.+)$",
        text,
    )
    if (
        compare_to
        and _group_mentions(_normalize(previous), summary)
        and _group_mentions(compare_to.group(3), summary)
    ):
        # "and compared to q2?" after "how much did I spend in q3?"
        return parse_query_v2(f"{_normalize(previous)} compared to {compare_to.group(3)}", summary)
    if compare_to and prev_spec.period_type == "month" and prev_spec.period_key:
        other = _named_month_keys(compare_to.group(3), summary) or _named_month_keys(
            f"in {compare_to.group(3)}", summary
        )
        if "last month" in compare_to.group(3):
            other = [previous_month_key(summary)]
        if other and other[0] != prev_spec.period_key:
            return QuerySpec(
                task_type="compare_periods",
                metric=prev_spec.metric if prev_spec.metric in {"income", "net"} else "expenses",
                period_type="month_range",
                period_key=f"{prev_spec.period_key},{other[0]}",
                scope=prev_spec.scope,
                category=prev_spec.category if "," not in (prev_spec.category or "") else "",
            )
    if re.match(r"^which (was|is|one was|one is) (higher|more|bigger|lower|less|smaller)\b", text):
        lower = re.search(r"\b(lower|less|smaller)\b", text)
        groups = parse_query_v2(previous, summary)
        if groups.period_type == "quarters":
            return dataclasses.replace(groups, compare_to="which_lower" if lower else "which")
        if groups.task_type == "data_pointer" and groups.reason_mode == "card_income":
            return groups
        if prev_spec.task_type == "category_spending" and "," in (prev_spec.category or ""):
            return dataclasses.replace(prev_spec, reason_mode="versus")
        keys = [k for k in (prev_spec.period_key or "").split(",") if k]
        if len(keys) >= 2:
            return dataclasses.replace(
                prev_spec,
                task_type="compare_periods",
                period_type="month_range",
                compare_to="which_lower"
                if re.search(r"\b(lower|less|smaller)\b", text)
                else "which",
            )
    return None


def _savings_lever_spec(text, summary, scope):
    """ "what's one thing I could change to save the most?" -> the biggest category cut."""
    if not re.search(
        r"\b(save the most|biggest (impact|lever|difference)|one thing i could|"
        r"most savings|where (can|could) i save the most)\b|"
        r"\b(which|what) (category|categories|area|areas) (should|could|can) i (cut|trim|reduce)\b",
        text,
    ) or re.search(r"\d", text):
        return None
    return QuerySpec(
        task_type="savings_goal",
        metric="expenses",
        period_type="month",
        period_key="0",
        scope=scope,
        reason_mode="lever",
    )


def _category_share_spec(text, summary, scope):
    """ "what percent of my spending was food", "how much of my income goes to food" """
    category = _category_in(text, summary)
    if not category:
        return None
    if re.search(r"\b\d{1,3} percent of\b", text):
        return None  # "10 percent of my food spending" is a calculation, not a share
    of_income = re.search(r"\b(of|from) my (income|pay|paycheck|salary|earnings)\b", text)
    share = re.search(r"\b(percent|percentage|share|portion|fraction|how much of)\b", text)
    if not share and not of_income:
        return None
    return QuerySpec(
        task_type="category_spending",
        metric="expenses",
        period_type="month",
        period_key=_period_for(text, summary),
        scope=scope,
        category=category,
        reason_mode="share_of_income" if of_income else "share",
    )


# ── Day spans, saving targets, end-of-month outlook ──────────────────────

_WEEK_ORDINALS = {"first": 1, "second": 2, "third": 3, "fourth": 4, "last": 5}


def _weekend_of(text, summary):
    """ "the weekend of october 10": that date's Saturday and Sunday, or the next ones."""
    if not re.search(r"\bweekend (of|after|before)\b", text):
        return None
    day = _day_key(text, _selected_year(summary))
    if not day:
        return None
    when = date_cls.fromisoformat(day)
    if when.weekday() == 6:
        saturday = when - timedelta(days=1)
    else:
        saturday = when + timedelta(days=(5 - when.weekday()) % 7)
    if "before" in text and when.weekday() < 5:
        saturday -= timedelta(days=7)
    return saturday, saturday + timedelta(days=1)


def _last_weekend_asked(text):
    """ "how much did I spend over the weekend": one weekend's total, not an average."""
    return bool(
        re.search(
            r"\b(over|on|this|last|during|past) (the )?weekend\b|"
            r"\b(first|second|third|last|final) weekend (of|in)\b",
            text,
        )
        and not re.search(r"\b(weekends|average|usually|typically|per|each)\b", text)
        and _amount_metric(text)
    )


def _day_span_spec(text, summary, scope):
    """ "first week of october", "past two weeks", "last 10 days" -> a span of days."""
    today = date_cls.today()
    if re.search(r"\b(yesterday and today|today and yesterday)\b", text) and _amount_metric(text):
        return QuerySpec(
            task_type="day_span",
            metric="expenses",
            period_type="days",
            period_key=f"{(today - timedelta(days=1)).isoformat()},{today.isoformat()}",
            scope=scope,
            category=_category_in(text, summary),
        )
    weekend = _weekend_of(text, summary)
    if weekend and _amount_metric(text) in {"", "expenses"}:
        saturday, sunday = weekend
        return QuerySpec(
            task_type="day_span",
            metric="expenses",
            period_type="days",
            period_key=f"{saturday.isoformat()},{min(sunday, today).isoformat()}",
            scope=scope,
        )
    weeks_in = re.search(r"\bfirst (two|2|three|3) weeks of (this month|last month|[a-z]+)\b", text)
    if weeks_in:
        days_n = 14 if weeks_in.group(1) in {"two", "2"} else 21
        text = text.replace(weeks_in.group(0), f"first {days_n} days of {weeks_in.group(2)}")
    first_days = re.search(r"\bfirst (\d{1,2}) days of (this month|last month|[a-z]+)\b", text)
    if first_days and _amount_metric(text) in {"", "expenses"}:
        keys = _named_month_keys(first_days.group(2), summary)
        if first_days.group(2) == "this month":
            keys = [selected_month_key(summary)]
        elif first_days.group(2) == "last month":
            keys = [previous_month_key(summary)]
        if keys:
            year, month = (int(x) for x in keys[0].split("-"))
            last = min(int(first_days.group(1)), calendar.monthrange(year, month)[1])
            end = min(date_cls(year, month, last), today)
            return QuerySpec(
                task_type="day_span",
                metric="expenses",
                period_type="days",
                period_key=f"{year}-{month:02d}-01,{end.isoformat()}",
                scope=scope,
            )
    half = re.search(r"\b(first|second) half of (this month|last month|[a-z]+)\b", text)
    half_keys = _named_month_keys(half.group(2), summary) if half else []
    if half and half.group(2) == "this month":
        half_keys = [selected_month_key(summary)]
    elif half and half.group(2) == "last month":
        half_keys = [previous_month_key(summary)]
    if half and half_keys and _amount_metric(text) in {"", "expenses"}:
        year, month = (int(x) for x in half_keys[0].split("-"))
        days = calendar.monthrange(year, month)[1]
        start, end = (1, 15) if half.group(1) == "first" else (16, days)
        first = date_cls(year, month, start)
        last = min(date_cls(year, month, end), today)
        if first <= today:
            return QuerySpec(
                task_type="day_span",
                metric="expenses",
                period_type="days",
                period_key=f"{first.isoformat()},{last.isoformat()}",
                scope=scope,
            )
    nth_weekend = re.search(
        r"\b(first|second|third|last|final) weekend (?:of|in) (this month|last month|[a-z]+)\b",
        text,
    )
    if nth_weekend and _amount_metric(text) in {"", "expenses"}:
        keys = _named_month_keys(nth_weekend.group(2), summary)
        if nth_weekend.group(2) == "this month":
            keys = [selected_month_key(summary)]
        elif nth_weekend.group(2) == "last month":
            keys = [previous_month_key(summary)]
        if keys:
            year, month = (int(x) for x in keys[0].split("-"))
            days = calendar.monthrange(year, month)[1]
            saturdays = [
                date_cls(year, month, d)
                for d in range(1, days + 1)
                if date_cls(year, month, d).weekday() == 5
            ]
            index = {"first": 0, "second": 1, "third": 2}.get(nth_weekend.group(1), -1)
            saturday = saturdays[index]
            return QuerySpec(
                task_type="day_span",
                metric="expenses",
                period_type="days",
                period_key=f"{saturday.isoformat()},{(saturday + timedelta(days=1)).isoformat()}",
                scope=scope,
                category=_category_in(text, summary),
            )
    if _last_weekend_asked(text):
        # The latest Saturday and Sunday, or this weekend so far.
        saturday = today - timedelta(days=(today.weekday() - 5) % 7)
        sunday = min(saturday + timedelta(days=1), today)
        return QuerySpec(
            task_type="day_span",
            metric="expenses",
            period_type="days",
            period_key=f"{saturday.isoformat()},{sunday.isoformat()}",
            scope=scope,
        )
    week = re.search(
        r"\b(first|second|third|fourth|last|final) week of (this month|last month|[a-z]+)\b", text
    )
    if week:
        keys = _named_month_keys(week.group(2), summary)
        if week.group(2) == "this month":
            keys = [selected_month_key(summary)]
        elif week.group(2) == "last month":
            keys = [previous_month_key(summary)]
        if not keys:
            return None
        year, month = (int(x) for x in keys[0].split("-"))
        days = calendar.monthrange(year, month)[1]
        index = _WEEK_ORDINALS["last" if week.group(1) == "final" else week.group(1)]
        start = days - 6 if index == 5 else (index - 1) * 7 + 1
        end = days if index == 5 else min(index * 7, days)
        return QuerySpec(
            task_type="day_span",
            metric="expenses",
            period_type="days",
            period_key=f"{year}-{month:02d}-{start:02d},{year}-{month:02d}-{end:02d}",
            scope=scope,
            category=_category_in(text, summary),
        )
    span = re.search(
        r"\b(?:past|last|previous)\s+(\d{1,2}|two|three|four|couple of|few)\s+(days|weeks)\b", text
    )
    if not span or not _amount_metric(text):
        return None
    words = {"two": 2, "three": 3, "four": 4, "couple of": 2, "few": 3}
    raw = span.group(1)
    count = int(raw) if raw.isdigit() else words[raw]
    days_back = count * (7 if span.group(2) == "weeks" else 1)
    if days_back in {7, 30, 90}:
        return None  # the app's rolling 7/30/90-day windows answer these
    start = today - timedelta(days=days_back - 1)
    return QuerySpec(
        task_type="day_span",
        metric="expenses",
        period_type="days",
        period_key=f"{start.isoformat()},{today.isoformat()}",
        scope=scope,
    )


def _saving_target_spec(text, summary, scope):
    """ "if I saved 10% of my income each month", "can I save $3000 by the end of the
    year", "how much should I set aside each month to save $6000 in a year" """
    if re.search(
        r"\bhow much (will|would|am) i (going to |gonna )?(save|saving|have saved|keep)\b.*"
        r"\bthis month$",
        text,
    ):
        return QuerySpec(
            task_type="saving_target",
            metric="net",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
            reason_mode="projection",
        )
    by_when = re.search(
        r"\bhow much (will|would|could|can) i (have )?(save|saved|saving|set aside|put away)\b.*"
        r"\bby (the )?(end of (the |this )?year|year end|[a-z]+)$",
        text,
    )
    if by_when and not re.search(r"\d", text):
        when = by_when.group(5)
        target = _named_month_keys(when, summary) if MONTH_NAME_TO_NUM.get(when) else []
        if not target and "year" in when:
            target = [f"{_selected_year(summary)}-12"]
        if target and target[0] >= selected_month_key(summary):
            return QuerySpec(
                task_type="saving_target",
                metric="net",
                period_type="month",
                period_key=target[0],
                scope=scope,
                reason_mode="projection",
            )
    pct = re.search(r"\bsav(?:e|ed|ing) (\d{1,2}) percent of (?:my )?income\b", text)
    if re.search(r"\bhow much (can|could) i (save|set aside|put away)\b", text) and not re.search(
        r"\d", text
    ):
        return QuerySpec(
            task_type="saving_target",
            metric="net",
            period_type="percent",
            period_key="0",
            scope=scope,
            reason_mode="capacity",
        )
    if (
        not pct
        and re.search(r"\bhow much (should|do) i (save|be saving|set aside|put away)\b", text)
        and not re.search(r"\d", text)
    ):
        # No goal given: answer with the common 20%-of-income rule of thumb.
        return QuerySpec(
            task_type="saving_target",
            metric="net",
            period_type="percent",
            period_key="20",
            scope=scope,
            reason_mode="rule_of_thumb",
        )
    if pct:
        return QuerySpec(
            task_type="saving_target",
            metric="net",
            period_type="percent",
            period_key=pct.group(1),
            scope=scope,
        )
    by_date = re.search(
        r"\bsave (\d{2,7}) dollars? (?:by|before) (?:the )?(end of (?:the )?year|december|"
        r"year end|new year)\b",
        text,
    ) or re.search(r"\bsave (\d{2,7}) dollars? in (a|one) year\b", text)
    if by_date:
        return QuerySpec(
            task_type="saving_target",
            metric="net",
            period_type="deadline",
            period_key=by_date.group(1),
            scope=scope,
            compare_to=_deadline_kind(by_date.group(0)),
        )
    return None


def _month_outlook_spec(text, summary, scope):
    """ "will I have money left at the end of the month?" """
    keep = re.search(
        r"\b(can i spend|more can i spend|left to spend|can i still spend)\b.*\b(save|keep|have left)\s+"
        r"(\d{2,7})\b",
        text,
    )
    if keep:
        return QuerySpec(
            task_type="month_outlook",
            metric="net",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
            compare_to=keep.group(3),
        )
    if not re.search(
        r"\b(money left|left over|have anything left|run out of money|end the month|"
        r"end of the month|have left|left this month|left to spend|remaining this month)\b",
        text,
    ):
        return None
    if not re.search(r"\b(will|am i going to|gonna|going to|would|have|got)\b", text):
        return None
    return QuerySpec(
        task_type="month_outlook",
        metric="net",
        period_type="month",
        period_key=selected_month_key(summary),
        scope=scope,
    )


def _no_spend_days_spec(text, summary, scope):
    if not re.search(
        r"\b(days|day) (did i|i) (spend|spent) (nothing|zero|no money)\b|\bno spend days\b|"
        r"\bzero spend days\b|\bdays without spending\b",
        text,
    ):
        return None
    return QuerySpec(
        task_type="derived_metric",
        metric="expenses",
        period_type="month",
        period_key=_period_for(text, summary),
        scope=scope,
        reason_mode="no_spend_days",
    )


def _per_week_spec(text, summary, scope):
    yearly = re.search(r"\b(per|a|each|every) year\b|\byearly\b|\bannually\b", text)
    quarterly = re.search(r"\b(per|a|each|every) quarter\b|\bquarterly\b", text)
    if quarterly and (_amount_metric(text) or _category_in(text, summary)):
        return QuerySpec(
            task_type="spending_trend",
            metric=_amount_metric(text)
            if _amount_metric(text) in {"income", "net"}
            else "expenses",
            period_type="year",
            period_key=str(_selected_year(summary)),
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="per_quarter",
        )
    if not yearly and not re.search(
        r"\b(per|a|each|every) week\b|\bweekly\b|\b(average|typical|normal|usual) week\b", text
    ):
        return None
    if not re.search(
        r"\b(average|avg|usually|typically|normally|on average|typical|usual|normal)\b", text
    ) and not (re.search(r"\bdo i (spend|make|earn)\b|\bhow much (do|does)\b", text)):
        return None
    if not _amount_metric(text) and not _category_in(text, summary):
        return None
    named = _named_month_keys(text, summary)
    if len(named) == 1:
        # "food per week in september": that month, not the recent average
        return QuerySpec(
            task_type="spending_trend",
            metric="expenses",
            period_type="month_range",
            period_key=named[0],
            scope=scope,
            category=_category_in(text, summary),
            reason_mode="per_year" if yearly else "per_week",
        )
    return QuerySpec(
        task_type="spending_trend",
        metric="expenses",
        period_type="month",
        period_key=selected_month_key(summary),
        scope=scope,
        category=_category_in(text, summary),
        reason_mode="per_year" if yearly else "per_week",
    )


def _app_info_spec(text, summary, scope):
    if re.search(r"\b(who (made|built|created|developed)|who are you|what are you)\b", text):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="about")
    if re.search(
        r"\brecommend (a |an |me )?(credit card|card|bank|loan|insurance|stock|fund|app)\b|"
        r"\bwhich (credit card|bank|loan) should i\b|\bbest credit card\b",
        text,
    ):
        return QuerySpec(task_type="data_pointer", scope=scope, reason_mode="products")
    return None


def _deadline_kind(phrase):
    return "year_end" if ("end" in phrase or "december" in phrase) else "12_months"


def category_named(message, summary):
    """The first category a message names ("tips to cut my transport" -> Transport)."""
    return _category_in(_normalize(message), summary)
