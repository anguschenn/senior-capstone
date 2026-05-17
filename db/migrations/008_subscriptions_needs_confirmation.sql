ALTER TABLE subscriptions
ADD COLUMN IF NOT EXISTS needs_confirmation boolean DEFAULT false;
