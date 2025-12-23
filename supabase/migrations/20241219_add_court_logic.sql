-- Add court_name and start_time columns
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS court_name text;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS start_time timestamptz DEFAULT now();

-- Update status constraint to include 'PLAYING'
ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_status_check;
ALTER TABLE public.matches ADD CONSTRAINT matches_status_check 
    CHECK (status IN ('pending', 'PLAYING', 'completed', 'cancelled'));
