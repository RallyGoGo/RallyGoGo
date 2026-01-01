-- Add start_time and end_time to matches table
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS start_time TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS end_time TIMESTAMP WITH TIME ZONE;

-- Force schema reload
NOTIFY pgrst, 'reload schema';
