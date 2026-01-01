-- Restore missing columns for UI functionality
-- These columns are essential for CourtBoard.tsx and were likely lost during the Reset
-- but are not present in the 'matches' table description provided by the user.

ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS court_name VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_category VARCHAR; -- e.g. 'MEN_D', 'MIXED'
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_type VARCHAR DEFAULT 'REGULAR'; -- 'REGULAR' or 'TOURNAMENT'

-- Force schema reload to be safe
NOTIFY pgrst, 'reload schema';
