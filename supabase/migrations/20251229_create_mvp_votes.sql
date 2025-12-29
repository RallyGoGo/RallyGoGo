-- 1. MVP Votes Table
CREATE TABLE IF NOT EXISTS public.mvp_votes (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    match_id UUID REFERENCES public.matches(id) ON DELETE CASCADE,
    voter_id UUID REFERENCES auth.users(id),
    target_id UUID REFERENCES public.profiles(id),
    tag TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    UNIQUE(match_id, voter_id) -- Prevent duplicate voting
);

-- 2. RLS Policies
ALTER TABLE public.mvp_votes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public Read" ON public.mvp_votes FOR SELECT USING (true);
CREATE POLICY "Authenticated Insert" ON public.mvp_votes FOR INSERT WITH CHECK (auth.uid() = voter_id);
