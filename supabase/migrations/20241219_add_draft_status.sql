-- Update status constraint to include 'DRAFT' and 'SCORING'
ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_status_check;
ALTER TABLE public.matches ADD CONSTRAINT matches_status_check 
    CHECK (status IN ('pending', 'DRAFT', 'PLAYING', 'SCORING', 'completed', 'cancelled', 'FINISHED'));
-- Added FINISHED just in case, though standardizing on 'completed' is better, user snippet used FINISHED sometimes.
