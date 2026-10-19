"""Shared pytest setup.

supabase_repo creates the Supabase client at import time and the SDK rejects an empty
URL, so without a python/.env every test module that imports it fails to collect.
Placeholders let the suite run in CI and on fresh clones; no test talks to Supabase
(each one mocks the client), so the values are never used for a real request.
"""

import os

os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_KEY", "test-service-role-key")
