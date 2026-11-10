"""Supabase client initialisation and thin DB helpers."""

from supabase import create_client

from config import SUPABASE_KEY, SUPABASE_URL

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)


def has_linked_bank(user_id):
    """Whether the user has connected at least one bank (a plaid_items row)."""
    rows = supabase.table("plaid_items").select("id").eq("user_id", user_id).limit(1).execute()
    return bool(rows.data)
