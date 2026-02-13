-- =============================================================================
-- FIX: Add Missing Columns to Schema
-- Problem: 
-- 1. 'create_match_draft' tries to insert into 'matches.created_by', which does not exist.
-- 2. Queue updates try to write to 'queue.updated_at', which does not exist.
-- Solution:
-- 1. Add 'created_by' column to 'matches' table.
-- 2. Add 'updated_at' column to 'queue' table.
-- =============================================================================
-- 1. Add created_by to matches if it doesn't exist
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'matches'
        AND column_name = 'created_by'
) THEN
ALTER TABLE public.matches
ADD COLUMN created_by UUID REFERENCES auth.users(id);
END IF;
END $$;
-- 2. Add updated_at to queue if it doesn't exist
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'queue'
        AND column_name = 'updated_at'
) THEN
ALTER TABLE public.queue
ADD COLUMN updated_at TIMESTAMPTZ DEFAULT now();
END IF;
END $$;