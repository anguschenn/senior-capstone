-- Tracks that a user explicitly said "Not a subscription" so detection
-- doesn't resurrect it on the next sync (see subscription_detector.py).
ALTER TABLE subscriptions
ADD COLUMN IF NOT EXISTS user_dismissed boolean DEFAULT false;
