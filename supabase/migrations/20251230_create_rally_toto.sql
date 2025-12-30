-- 1. Profiles: Add Points
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS rally_point INTEGER DEFAULT 1000;

-- 2. Matches: Add Odds
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS odds_team1 NUMERIC(4, 2);
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS odds_team2 NUMERIC(4, 2);

-- 3. Bets Table
CREATE TABLE IF NOT EXISTS public.bets (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    match_id UUID REFERENCES public.matches(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    pick_team VARCHAR(10) NOT NULL, -- 'TEAM_1' or 'TEAM_2'
    amount INTEGER CHECK (amount > 0),
    odds_at_bet NUMERIC(4, 2) NOT NULL,
    result VARCHAR(10) DEFAULT 'PENDING', -- 'PENDING', 'WIN', 'LOSE', 'DRAW', 'CANCELLED'
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- RLS for Bets
ALTER TABLE public.bets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view their own bets" ON public.bets FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert their own bets" ON public.bets FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 4. RPC: Place Bet (Atomic Transaction)
-- Handles concurrency: Check status, Check balance, Deduct points, Insert bet
CREATE OR REPLACE FUNCTION public.place_bet(
    p_match_id UUID,
    p_user_id UUID,
    p_pick_team VARCHAR,
    p_amount INTEGER,
    p_odds NUMERIC
) RETURNS JSONB AS $$
DECLARE
    v_match_status VARCHAR;
    v_current_points INTEGER;
BEGIN
    -- Check Match Status (Must be 'draft' or 'pending' but ideally only 'draft')
    -- Allow 'pending' if it means "Waiting for start", but strictly lock once playing.
    -- Assuming 'draft' is the open state.
    SELECT status INTO v_match_status FROM public.matches WHERE id = p_match_id;
    
    IF v_match_status IS NULL THEN
        RAISE EXCEPTION 'Match not found';
    END IF;

    IF v_match_status != 'draft' THEN
        RAISE EXCEPTION 'Betting is closed for this match (Status: %)', v_match_status;
    END IF;

    -- Check Balance
    SELECT rally_point INTO v_current_points FROM public.profiles WHERE id = p_user_id;
    
    IF v_current_points < p_amount THEN
        RAISE EXCEPTION 'Insufficient points (Current: %, Required: %)', v_current_points, p_amount;
    END IF;

    -- Deduct Points
    UPDATE public.profiles 
    SET rally_point = rally_point - p_amount 
    WHERE id = p_user_id;

    -- Insert Bet
    INSERT INTO public.bets (match_id, user_id, pick_team, amount, odds_at_bet)
    VALUES (p_match_id, p_user_id, p_pick_team, p_amount, p_odds);

    RETURN jsonb_build_object('success', true, 'new_balance', v_current_points - p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 5. Trigger: Auto Settlement
-- Triggered when match status changes to 'FINISHED'
CREATE OR REPLACE FUNCTION public.settle_bets_trigger() RETURNS TRIGGER AS $$
DECLARE
    v_bet RECORD;
    v_winnings INTEGER;
BEGIN
    -- Only run if status changed to FINISHED
    IF NEW.status = 'FINISHED' AND OLD.status != 'FINISHED' THEN
        
        -- Loop through all PENDING bets for this match
        FOR v_bet IN SELECT * FROM public.bets WHERE match_id = NEW.id AND result = 'PENDING' LOOP
            
            -- CASE 1: DRAW (Return Principal)
            IF NEW.winner_team = 'DRAW' THEN
                UPDATE public.bets SET result = 'DRAW' WHERE id = v_bet.id;
                UPDATE public.profiles SET rally_point = rally_point + v_bet.amount WHERE id = v_bet.user_id;
            
            -- CASE 2: WIN
            ELSIF NEW.winner_team = v_bet.pick_team THEN
                -- Calculate Winnings: Floor(Amount * Odds)
                v_winnings := FLOOR(v_bet.amount * v_bet.odds_at_bet);
                UPDATE public.bets SET result = 'WIN' WHERE id = v_bet.id;
                UPDATE public.profiles SET rally_point = rally_point + v_winnings WHERE id = v_bet.user_id;

            -- CASE 3: LOSE
            ELSE
                UPDATE public.bets SET result = 'LOSE' WHERE id = v_bet.id;
                -- No points returned
            END IF;
            
        END LOOP;
        
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Limit Trigger Execution to Status-Change Only
DROP TRIGGER IF EXISTS on_match_finish ON public.matches;
CREATE TRIGGER on_match_finish
AFTER UPDATE OF status ON public.matches
FOR EACH ROW
WHEN (NEW.status = 'FINISHED')
EXECUTE FUNCTION public.settle_bets_trigger();
