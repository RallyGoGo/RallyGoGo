-- Emergency Fix: Add 'joined_at' column if missing and reload schema cache

-- 1. Add 'joined_at' column to 'queue' table if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'queue'
        AND column_name = 'joined_at'
    ) THEN
        ALTER TABLE public.queue ADD COLUMN joined_at TIMESTAMP WITH TIME ZONE DEFAULT now();
    END IF;
END $$;

-- 2. Force Schema Cache Reload
-- This is crucial for PostgREST to pick up the new column immediately
NOTIFY pgrst, 'reload schema';
