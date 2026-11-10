"""Helpers for exercising Flask routes through the test client with no network."""

import contextlib
from types import SimpleNamespace
from unittest import mock

import auth
import supabase_repo
from app_factory import create_app
from routes import ai_routes

API_KEY = "test-internal-api-key"
VALID_TOKEN = "valid-supabase-token"
USER_ID = "user-123"
OTHER_TOKEN = "other-supabase-token"
OTHER_USER_ID = "user-456"
_USERS_BY_TOKEN = {VALID_TOKEN: USER_ID, OTHER_TOKEN: OTHER_USER_ID}


def fake_get_user(token):
    """Stand-in for supabase.auth.get_user: only the known test tokens resolve to a user."""
    user_id = _USERS_BY_TOKEN.get(token)
    if user_id:
        return SimpleNamespace(user=SimpleNamespace(id=user_id))
    return SimpleNamespace(user=None)


@contextlib.contextmanager
def app_client(generate_reply=None, linked_bank=True):
    """Yield a Flask test client with the API key set and Supabase auth mocked.

    generate_reply replaces the LLM provider handed to the services; it defaults to an
    autospec of the real provider so a wrong call signature fails like it does in prod.
    linked_bank is what the linked-bank lookup answers for every user.
    """
    import app_factory

    if generate_reply is None:
        generate_reply = mock.create_autospec(app_factory.generate_llm_reply, return_value="")
    with (
        mock.patch.object(auth, "INTERNAL_API_KEY", API_KEY),
        mock.patch.object(auth.supabase.auth, "get_user", side_effect=fake_get_user),
        mock.patch.object(app_factory, "generate_llm_reply", generate_reply),
        mock.patch.object(supabase_repo, "has_linked_bank", return_value=linked_bank),
    ):
        auth._rate_buckets.clear()
        ai_routes._linked_users.clear()
        app = create_app()
        app.testing = True
        app.config["question_log"] = None  # never write to the real database from tests
        app.config["chat_service"].rewrite_cache = None
        yield app.test_client()
        auth._rate_buckets.clear()
        ai_routes._linked_users.clear()


def headers(token=None, **extra):
    result = {"x-api-key": API_KEY}
    if token:
        result["Authorization"] = f"Bearer {token}"
    result.update(extra)
    return result
