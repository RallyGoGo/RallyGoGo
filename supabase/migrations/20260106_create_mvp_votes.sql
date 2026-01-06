-- Create mvp_votes table if not exists
CREATE TABLE IF NOT EXISTS public.mvp_votes (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    match_id UUID REFERENCES public.matches(id) ON DELETE CASCADE,
    voter_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    target_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(match_id, voter_id)
);
-- RLS Policies (Optional but good practice)
ALTER TABLE public.mvp_votes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Enable read/write for all users" ON public.mvp_votes FOR ALL USING (true) WITH CHECK (true);