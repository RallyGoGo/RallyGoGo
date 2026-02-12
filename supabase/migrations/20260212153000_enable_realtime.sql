-- Enable Realtime for specific tables (Idempotent)
-- 1. Set REPLICA IDENTITY to FULL (Safe to run multiple times)
ALTER TABLE queue REPLICA IDENTITY FULL;
ALTER TABLE matches REPLICA IDENTITY FULL;
ALTER TABLE notices REPLICA IDENTITY FULL;
ALTER TABLE profiles REPLICA IDENTITY FULL;
-- 2. Add tables to supabase_realtime publication (Idempotent check)
DO $$ BEGIN -- queue
IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'queue'
) THEN ALTER PUBLICATION supabase_realtime
ADD TABLE queue;
END IF;
-- matches
IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'matches'
) THEN ALTER PUBLICATION supabase_realtime
ADD TABLE matches;
END IF;
-- notices
IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'notices'
) THEN ALTER PUBLICATION supabase_realtime
ADD TABLE notices;
END IF;
-- profiles
IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'profiles'
) THEN ALTER PUBLICATION supabase_realtime
ADD TABLE profiles;
END IF;
END $$;