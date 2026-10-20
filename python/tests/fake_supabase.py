"""A tiny in-memory stand-in for the supabase-py query builder, for tests that need to see
what a function wrote and read back. Supports the calls user_model and server_summary use:
select / eq / gte / lt / or_(user_id) / order / range / limit, insert, upsert(on_conflict),
update, delete."""

import copy


class _Result:
    def __init__(self, data):
        self.data = data


class _Query:
    def __init__(self, db, table):
        self._db, self._table = db, table
        self._filters = []
        self._action = "select"
        self._payload = None
        self._on_conflict = None
        self._order = None
        self._range = None
        self._limit = None

    # ── builders ──
    def select(self, _columns="*"):
        self._action = "select"
        return self

    def insert(self, payload):
        self._action, self._payload = "insert", payload
        return self

    def upsert(self, payload, on_conflict=None):
        self._action, self._payload, self._on_conflict = "upsert", payload, on_conflict
        return self

    def update(self, payload):
        self._action, self._payload = "update", payload
        return self

    def delete(self):
        self._action = "delete"
        return self

    def eq(self, column, value):
        self._filters.append(lambda r: r.get(column) == value)
        return self

    def gte(self, column, value):
        self._filters.append(lambda r: str(r.get(column)) >= str(value))
        return self

    def lt(self, column, value):
        self._filters.append(lambda r: str(r.get(column)) < str(value))
        return self

    def or_(self, expression):
        # Only the "user_id.eq.X,user_id.is.null" form is used.
        user_id = expression.split(",")[0].split(".eq.")[1]
        self._filters.append(lambda r: r.get("user_id") in (user_id, None))
        return self

    def order(self, column, desc=False):
        self._order = (column, desc)
        return self

    def range(self, start, end):
        self._range = (start, end)
        return self

    def limit(self, count):
        self._limit = count
        return self

    # ── execution ──
    def _matches(self, row):
        return all(f(row) for f in self._filters)

    def execute(self):
        rows = self._db.tables.setdefault(self._table, [])
        if self._action == "select":
            found = [copy.deepcopy(r) for r in rows if self._matches(r)]
            if self._order:
                column, desc = self._order
                found.sort(key=lambda r: str(r.get(column)), reverse=desc)
            if self._range:
                found = found[self._range[0] : self._range[1] + 1]
            if self._limit is not None:
                found = found[: self._limit]
            return _Result(found)
        if self._action == "insert":
            payload = self._payload if isinstance(self._payload, list) else [self._payload]
            rows.extend(copy.deepcopy(p) for p in payload)
            return _Result(payload)
        if self._action == "upsert":
            payload = self._payload if isinstance(self._payload, list) else [self._payload]
            keys = (self._on_conflict or "id").split(",")
            for item in payload:
                existing = next(
                    (r for r in rows if all(r.get(k) == item.get(k) for k in keys)), None
                )
                if existing is None:
                    new = copy.deepcopy(item)
                    new.setdefault("id", f"{self._table}-{len(rows) + 1}")
                    rows.append(new)
                else:
                    existing.update(copy.deepcopy(item))
            return _Result(payload)
        if self._action == "update":
            for row in rows:
                if self._matches(row):
                    row.update(copy.deepcopy(self._payload))
            return _Result([])
        if self._action == "delete":
            self._db.tables[self._table] = [r for r in rows if not self._matches(r)]
            return _Result([])
        raise AssertionError(self._action)


class FakeSupabase:
    def __init__(self, tables=None):
        self.tables = copy.deepcopy(tables or {})

    def table(self, name):
        return _Query(self, name)
