"""Helpers for exercising Flask routes through the test client with no network."""

import contextlib
from types import SimpleNamespace
from unittest import mock

import auth
from app_factory import create_app

API_KEY = "test-internal-api-key"
VALID_TOKEN = "valid-supabase-token"
USER_ID = "user-123"


def fake_get_user(token):
    """Stand-in for supabase.auth.get_user: only VALID_TOKEN resolves to a user."""
    if token == VALID_TOKEN:
        return SimpleNamespace(user=SimpleNamespace(id=USER_ID))
    return SimpleNamespace(user=None)


@contextlib.contextmanager
def app_client(generate_reply=None):
    """Yield a Flask test client with the API key set and Supabase auth mocked.

    generate_reply replaces the LLM provider handed to the services; it defaults to an
    autospec of the real provider so a wrong call signature fails like it does in prod.
    """
    import app_factory

    if generate_reply is None:
        generate_reply = mock.create_autospec(app_factory.generate_llm_reply, return_value="")
    with (
        mock.patch.object(auth, "INTERNAL_API_KEY", API_KEY),
        mock.patch.object(auth.supabase.auth, "get_user", side_effect=fake_get_user),
        mock.patch.object(app_factory, "generate_llm_reply", generate_reply),
    ):
        auth._rate_buckets.clear()
        app = create_app()
        app.testing = True
        yield app.test_client()
        auth._rate_buckets.clear()


def headers(token=None, **extra):
    result = {"x-api-key": API_KEY}
    if token:
        result["Authorization"] = f"Bearer {token}"
    result.update(extra)
    return result
