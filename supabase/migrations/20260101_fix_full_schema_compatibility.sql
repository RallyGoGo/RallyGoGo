-- Comprehensive fix for Matches table compatibility with CourtBoard.tsx

-- 1. Ensure ALL required columns exist (Idempotent)
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS court_name VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_category VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_type VARCHAR DEFAULT 'REGULAR';
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS start_time TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS end_time TIMESTAMP WITH TIME ZONE;

-- 2. Update Status Constraint
-- The 'CourtBoard' logic requires PLAYING and SCORING states.
-- If the current DB enforces only 'DRAFT', 'PENDING', 'FINISHED', 'DISPUTED', it causes 400 Errors.
ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_status_check;

ALTER TABLE public.matches ADD CONSTRAINT matches_status_check 
CHECK (status IN ('DRAFT', 'PLAYING', 'SCORING', 'PENDING', 'FINISHED', 'DISPUTED'));

-- Force schema reload to apply changes immediately
NOTIFY pgrst, 'reload schema';
