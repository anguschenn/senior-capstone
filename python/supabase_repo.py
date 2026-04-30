"""Supabase client initialisation and thin DB helpers."""

from supabase import create_client

from config import SUPABASE_KEY, SUPABASE_URL

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
