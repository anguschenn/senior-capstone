import re
from datetime import date as date_cls

MONTH_NAME_TO_NUM = {
    "january": 1,
    "jan": 1,
    "february": 2,
    "feb": 2,
    "march": 3,
    "mar": 3,
    "april": 4,
    "apr": 4,
    "may": 5,
    "june": 6,
    "jun": 6,
    "july": 7,
    "jul": 7,
    "august": 8,
    "aug": 8,
    "september": 9,
    "sep": 9,
    "sept": 9,
    "october": 10,
    "oct": 10,
    "november": 11,
    "nov": 11,
    "december": 12,
    "dec": 12,
}


def previous_month_key(today=None):
    current = today or date_cls.today()
    year = current.year
    month = current.month - 1
    if month <= 0:
        month = 12
        year -= 1
    return f"{year}-{month:02d}"


def previous_year_key(today=None):
    current = today or date_cls.today()
    return str(current.year - 1)


def extract_specific_month_key(message, default_year):
    text = (message or "").lower().strip()
    if not text:
        return ""
    if "last month" in text:
        return previous_month_key()
    month_key_match = re.search(r"\b(20\d{2}-\d{2})\b", text)
    if month_key_match:
        return month_key_match.group(1)
    year_month_match = re.search(r"\b(20\d{2})[-/](\d{1,2})\b", text)
    if year_month_match:
        year = int(year_month_match.group(1))
        month = int(year_month_match.group(2))
        if 1 <= month <= 12:
            return f"{year}-{month:02d}"
    year_match = re.search(r"\b(20\d{2})\b", text)
    year = int(year_match.group(1)) if year_match else int(default_year or 0)
    if year <= 0:
        return ""
    for month_name, month_num in MONTH_NAME_TO_NUM.items():
        if re.search(rf"\b{re.escape(month_name)}\b", text):
            return f"{year}-{month_num:02d}"
    return ""


def extract_month_range_keys(message, default_year):
    text = (message or "").lower().strip()
    if not text:
        return []

    explicit = re.findall(r"\b20\d{2}-\d{2}\b", text)
    if len(explicit) >= 2:
        return explicit[:6]

    last_n = re.search(r"\blast\s+(\d{1,2})\s+months?\b", text)
    if last_n:
        count = max(2, min(12, int(last_n.group(1))))
        keys = []
        year, month = date_cls.today().year, date_cls.today().month
        for _ in range(count):
            month -= 1
            if month <= 0:
                month = 12
                year -= 1
            keys.append(f"{year}-{month:02d}")
        keys.reverse()
        return keys

    first_n = re.search(r"\bfirst\s+(\d{1,2})\s+months?\b", text)
    if first_n:
        count = max(2, min(12, int(first_n.group(1))))
        year_match = re.search(r"\b(20\d{2})\b", text)
        year = int(year_match.group(1)) if year_match else int(default_year or date_cls.today().year)
        return [f"{year}-{m:02d}" for m in range(1, count + 1)]

    return []


def extract_specific_date_key(message, default_year):
    text = (message or "").lower().strip()
    if not text:
        return ""

    iso_match = re.search(r"\b(20\d{2}-\d{2}-\d{2})\b", text)
    if iso_match:
        return iso_match.group(1)

    if "today" in text:
        return date_cls.today().isoformat()
    if "yesterday" in text:
        return date_cls.fromordinal(date_cls.today().toordinal() - 1).isoformat()

    year_match = re.search(r"\b(20\d{2})\b", text)
    year = int(year_match.group(1)) if year_match else int(default_year or 0)
    if year <= 0:
        return ""

    for month_name, month_num in MONTH_NAME_TO_NUM.items():
        match = re.search(rf"\b{re.escape(month_name)}\s+(\d{{1,2}})(st|nd|rd|th)?\b", text)
        if not match:
            continue
        day = int(match.group(1))
        if day < 1 or day > 31:
            continue
        return f"{year}-{month_num:02d}-{day:02d}"
    return ""


def extract_period(text):
    if not text:
        return ("unknown", "")
    day_key = re.search(r"\b(20\d{2}-\d{2}-\d{2})\b", text)
    if day_key:
        day_value = day_key.group(1)
        try:
            date_cls.fromisoformat(day_value)
            return ("day", day_value)
        except Exception:
            return ("invalid", "")
    month_key = re.search(r"\b(20\d{2})-(\d{2})\b", text)
    if month_key:
        year = int(month_key.group(1))
        month = int(month_key.group(2))
        if 1 <= month <= 12:
            return ("month", f"{year}-{month:02d}")
        return ("invalid", "")
    year_month_key = re.search(r"\b(20\d{2})/(\d{1,2})\b", text)
    if year_month_key:
        year = int(year_month_key.group(1))
        month = int(year_month_key.group(2))
        if 1 <= month <= 12:
            return ("month", f"{year}-{month:02d}")
        return ("invalid", "")
    month_range = re.search(r"\blast\s+(\d{1,2})\s+months?\b", text)
    if month_range:
        count = max(2, min(12, int(month_range.group(1))))
        keys = []
        year, month = date_cls.today().year, date_cls.today().month
        for _ in range(count):
            month -= 1
            if month <= 0:
                month = 12
                year -= 1
            keys.append(f"{year}-{month:02d}")
        keys.reverse()
        return ("month_range", ",".join(keys))
    rolling_days = re.search(r"\blast\s+(\d{1,3})\s+days?\b", text)
    if rolling_days:
        days = max(1, min(365, int(rolling_days.group(1))))
        if days == 30:
            return ("rolling_30d", "rolling_30d")
        return ("rolling_days", f"rolling_{days}d")
    rolling_days_compact = re.search(r"\blast\s*(\d{1,3})d\b", text)
    if rolling_days_compact:
        days = max(1, min(365, int(rolling_days_compact.group(1))))
        if days == 30:
            return ("rolling_30d", "rolling_30d")
        return ("rolling_days", f"rolling_{days}d")
    if re.search(r"\b(this week|current week)\b", text):
        return ("rolling_days", "rolling_7d")
    if re.search(r"\blast week\b", text):
        return ("rolling_days", "rolling_7d")
    if re.search(r"\b30d\b", text):
        return ("rolling_30d", "rolling_30d")
    if re.search(r"\b(this month|current month)\b", text):
        return ("month", date_cls.today().strftime("%Y-%m"))
    if re.search(r"\blast month\b", text):
        return ("month", previous_month_key())
    if re.search(r"\b(this year|current year)\b", text):
        return ("year", str(date_cls.today().year))
    if re.search(r"\blast year\b", text):
        return ("year", previous_year_key())
    month_name = re.search(
        r"\b(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b",
        text,
    )
    if month_name:
        year_key = re.search(r"\b(20\d{2})\b", text)
        year = int(year_key.group(1)) if year_key else date_cls.today().year
        month = MONTH_NAME_TO_NUM[month_name.group(1)]
        return ("month", f"{year}-{month:02d}")
    year_key = re.search(r"\b(20\d{2})\b", text)
    if year_key:
        return ("year", year_key.group(1))
    return ("unknown", "")
