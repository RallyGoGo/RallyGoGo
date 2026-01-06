-- ========================================================================
-- 20260105_drop_match_triggers.sql
-- ========================================================================
-- CRITICAL FIX: Drop Conflicting Triggers on 'matches' table
-- Prevents 409 Conflict (Duplicate Key) when logic runs on both Client & DB
-- ========================================================================

-- Drop the trigger if it exists
DROP TRIGGER IF EXISTS on_match_finish ON public.matches;

-- Drop the function associated with the trigger
DROP FUNCTION IF EXISTS public.handle_match_finish();

-- Force schema cache reload
NOTIFY pgrst, 'reload schema';
