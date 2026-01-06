-- ========================================================================
-- 20260104_fix_elo_final.sql - DEFINITIVE ELO FIX (NTRP Isolation)
-- ========================================================================
-- ROOT CAUSE: COALESCE(elo, ntrp*400, 1200) resets to NTRP every time
-- SOLUTION: Use CASE WHEN to check ELO first, NTRP only if ELO IS NULL

-- ========================================================================
-- STEP 1: Ensure all required columns exist
-- ========================================================================
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_men_doubles INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_women_doubles INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_mixed_doubles INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_singles INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS ntrp NUMERIC(3,1);
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_wins INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_losses INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_draws INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS winning_streak INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS games_played_today INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_games_history INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_guest BOOLEAN DEFAULT FALSE;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS role VARCHAR DEFAULT 'member';

-- ========================================================================
-- STEP 2: Seed ELO for existing users who have NULL ELO (ONE-TIME MIGRATION)
-- ========================================================================
-- This ensures NTRP is only used ONCE as the initial seed
UPDATE public.profiles SET elo_mixed_doubles = ROUND(ntrp * 400) 
WHERE elo_mixed_doubles IS NULL AND ntrp IS NOT NULL;

UPDATE public.profiles SET elo_men_doubles = ROUND(ntrp * 400) 
WHERE elo_men_doubles IS NULL AND ntrp IS NOT NULL;

UPDATE public.profiles SET elo_women_doubles = ROUND(ntrp * 400) 
WHERE elo_women_doubles IS NULL AND ntrp IS NOT NULL;

UPDATE public.profiles SET elo_singles = ROUND(ntrp * 400) 
WHERE elo_singles IS NULL AND ntrp IS NOT NULL;

-- Default to 1200 if no NTRP either
UPDATE public.profiles SET elo_mixed_doubles = 1200 
WHERE elo_mixed_doubles IS NULL;

-- ========================================================================
-- STEP 3: Ensure elo_history table exists
-- ========================================================================
CREATE TABLE IF NOT EXISTS public.elo_history (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    player_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    match_type VARCHAR,
    elo_score INTEGER NOT NULL,
    delta INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE INDEX IF NOT EXISTS elo_history_player_idx ON public.elo_history(player_id);
CREATE INDEX IF NOT EXISTS elo_history_created_idx ON public.elo_history(created_at);

-- ========================================================================
-- STEP 4: DROP ALL EXISTING FUNCTION SIGNATURES
-- ========================================================================
DROP FUNCTION IF EXISTS public.update_player_elo(VARCHAR, UUID[], UUID[], BOOLEAN);
DROP FUNCTION IF EXISTS public.update_player_elo(VARCHAR, UUID[], UUID[], BOOLEAN, BOOLEAN);

-- ========================================================================
-- STEP 5: THE DEFINITIVE ELO UPDATE FUNCTION (NTRP ISOLATED)
-- ========================================================================
-- KEY CHANGE: ELO columns are now ALWAYS used for calculations.
-- NTRP fallback is ONLY for the very rare case where ELO is still NULL 
-- (which shouldn't happen after Step 2 migration)

CREATE OR REPLACE FUNCTION public.update_player_elo(
    p_match_type VARCHAR,
    p_winners UUID[],
    p_losers UUID[],
    p_is_tournament BOOLEAN DEFAULT FALSE,
    p_is_draw BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    v_player RECORD;
    v_team1_avg NUMERIC := 0;
    v_team2_avg NUMERIC := 0;
    v_expected_score NUMERIC;
    v_actual_score NUMERIC;
    v_k_factor INTEGER;
    v_delta INTEGER;
    v_current_elo INTEGER;
    v_new_elo INTEGER;
    v_is_winner BOOLEAN;
    v_is_draw_player BOOLEAN;
    v_updated_count INTEGER := 0;
BEGIN

    -- =====================================================================
    -- A. Calculate Team Averages from ACTUAL ELO (not NTRP!)
    -- =====================================================================
    -- Use CASE WHEN to prioritize ELO, only fallback to NTRP if ELO is NULL
    SELECT AVG(
        CASE 
            WHEN elo_mixed_doubles IS NOT NULL THEN elo_mixed_doubles
            WHEN ntrp IS NOT NULL THEN ROUND(ntrp * 400)
            ELSE 1200 
        END
    ) INTO v_team1_avg 
    FROM public.profiles WHERE id = ANY(p_winners);

    SELECT AVG(
        CASE 
            WHEN elo_mixed_doubles IS NOT NULL THEN elo_mixed_doubles
            WHEN ntrp IS NOT NULL THEN ROUND(ntrp * 400)
            ELSE 1200 
        END
    ) INTO v_team2_avg 
    FROM public.profiles WHERE id = ANY(p_losers);

    -- Safety: ensure not null
    v_team1_avg := COALESCE(v_team1_avg, 1200);
    v_team2_avg := COALESCE(v_team2_avg, 1200);

    -- =====================================================================
    -- B. Calculate Expected Score (Team1's perspective)
    -- =====================================================================
    v_expected_score := 1.0 / (1.0 + POWER(10.0, (v_team2_avg - v_team1_avg) / 400.0));

    -- =====================================================================
    -- C. Loop through ALL players and update
    -- =====================================================================
    FOR v_player IN SELECT * FROM public.profiles WHERE id = ANY(p_winners || p_losers) LOOP
        
        -- ★ KEY FIX: Read ACTUAL ELO from DB, not recalculate from NTRP
        v_current_elo := CASE 
            WHEN v_player.elo_mixed_doubles IS NOT NULL THEN v_player.elo_mixed_doubles
            WHEN v_player.ntrp IS NOT NULL THEN ROUND(v_player.ntrp * 400)
            ELSE 1200 
        END;

        -- Determine if winner
        v_is_winner := (v_player.id = ANY(p_winners));
        
        -- Determine actual score
        IF p_is_draw THEN
            v_actual_score := 0.5;
            v_is_draw_player := TRUE;
        ELSIF v_is_winner THEN
            v_actual_score := 1.0;
            v_is_draw_player := FALSE;
        ELSE
            v_actual_score := 0.0;
            v_is_draw_player := FALSE;
        END IF;

        -- Calculate K-Factor
        v_k_factor := 32;
        IF v_player.role = 'coach' THEN 
            v_k_factor := 0;
        ELSIF v_player.is_guest = TRUE THEN 
            v_k_factor := 80;
        ELSIF p_is_tournament = TRUE THEN 
            v_k_factor := 40;
        ELSIF COALESCE(v_player.total_games_history, 0) < 10 THEN 
            v_k_factor := 64;
        END IF;

        -- Calculate Delta
        IF v_is_winner THEN
            v_delta := ROUND(v_k_factor * (v_actual_score - v_expected_score));
        ELSE
            v_delta := ROUND(v_k_factor * (v_actual_score - (1.0 - v_expected_score)));
        END IF;

        -- ★ NEW ELO = CURRENT ELO + DELTA (not recalculated from NTRP!)
        v_new_elo := v_current_elo + v_delta;

        -- =====================================================================
        -- D. UPDATE THE DATABASE
        -- =====================================================================
        IF v_k_factor > 0 THEN
            IF v_is_draw_player THEN
                UPDATE public.profiles SET
                    elo_mixed_doubles = v_new_elo,
                    games_played_today = COALESCE(games_played_today, 0) + 1,
                    total_games_history = COALESCE(total_games_history, 0) + 1,
                    total_draws = COALESCE(total_draws, 0) + 1,
                    winning_streak = 0
                WHERE id = v_player.id;
            ELSIF v_is_winner THEN
                UPDATE public.profiles SET
                    elo_mixed_doubles = v_new_elo,
                    games_played_today = COALESCE(games_played_today, 0) + 1,
                    total_games_history = COALESCE(total_games_history, 0) + 1,
                    total_wins = COALESCE(total_wins, 0) + 1,
                    winning_streak = COALESCE(winning_streak, 0) + 1
                WHERE id = v_player.id;
            ELSE
                UPDATE public.profiles SET
                    elo_mixed_doubles = v_new_elo,
                    games_played_today = COALESCE(games_played_today, 0) + 1,
                    total_games_history = COALESCE(total_games_history, 0) + 1,
                    total_losses = COALESCE(total_losses, 0) + 1,
                    winning_streak = 0
                WHERE id = v_player.id;
            END IF;

            -- Record in history for graph
            INSERT INTO public.elo_history (player_id, match_type, elo_score, delta)
            VALUES (v_player.id, COALESCE(p_match_type, 'MIXED'), v_new_elo, v_delta);

            v_updated_count := v_updated_count + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'updated_players', v_updated_count,
        'team1_avg', v_team1_avg,
        'team2_avg', v_team2_avg,
        'expected_score', v_expected_score
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ========================================================================
-- STEP 6: Grant permissions
-- ========================================================================
GRANT EXECUTE ON FUNCTION public.update_player_elo TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_player_elo TO anon;

-- ========================================================================
-- STEP 7: Force schema reload
-- ========================================================================
NOTIFY pgrst, 'reload schema';
