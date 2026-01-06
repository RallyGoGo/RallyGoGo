-- System Integrity Fix: Comprehensive Schema & RPC Update
-- 1. Profile Stats Columns
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_wins INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_losses INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_draws INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS winning_streak INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS games_played_today INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_games_history INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS departure_time VARCHAR;

-- 2. Queue Table Columns
ALTER TABLE public.queue ADD COLUMN IF NOT EXISTS player_id UUID REFERENCES public.profiles(id);
ALTER TABLE public.queue ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;
ALTER TABLE public.queue ADD COLUMN IF NOT EXISTS priority_score INTEGER DEFAULT 1000;
ALTER TABLE public.queue ADD COLUMN IF NOT EXISTS departure_time VARCHAR;
ALTER TABLE public.queue ADD COLUMN IF NOT EXISTS joined_at TIMESTAMP WITH TIME ZONE DEFAULT now();

-- 2b. Add unique constraint for upsert support
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'queue_player_id_unique') THEN
        ALTER TABLE public.queue ADD CONSTRAINT queue_player_id_unique UNIQUE (player_id);
    END IF;
END $$;

-- 3. Matches Table Columns
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS court_name VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_category VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_type VARCHAR DEFAULT 'REGULAR';
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS start_time TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS end_time TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS betting_closes_at TIMESTAMP WITH TIME ZONE;

-- 4. Update Status Constraint
ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_status_check;
ALTER TABLE public.matches ADD CONSTRAINT matches_status_check 
CHECK (status IN ('DRAFT', 'draft', 'PLAYING', 'playing', 'SCORING', 'scoring', 'PENDING', 'pending', 'FINISHED', 'finished', 'DISPUTED', 'disputed'));

-- 5. Ensure elo_history Table Exists
CREATE TABLE IF NOT EXISTS public.elo_history (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    player_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    match_type VARCHAR,
    elo_score INTEGER,
    delta INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 6. Redefine ELO Update RPC
CREATE OR REPLACE FUNCTION public.update_player_elo(
    p_match_type VARCHAR,
    p_winners UUID[],
    p_losers UUID[],
    p_is_tournament BOOLEAN
) RETURNS JSONB AS $$
DECLARE
    v_player RECORD;
    v_elo_field VARCHAR;
    v_team1_avg NUMERIC := 0;
    v_team2_avg NUMERIC := 0;
    v_expected_score NUMERIC;
    v_actual_score NUMERIC;
    v_k_factor INTEGER;
    v_delta INTEGER;
    v_current_elo INTEGER;
    v_new_elo INTEGER;
BEGIN
    CASE p_match_type
        WHEN 'MEN_D' THEN v_elo_field := 'elo_men_doubles';
        WHEN 'WOMEN_D' THEN v_elo_field := 'elo_women_doubles';
        WHEN 'SINGLES' THEN v_elo_field := 'elo_singles';
        ELSE v_elo_field := 'elo_mixed_doubles';
    END CASE;

    SELECT AVG(CASE WHEN v_elo_field = 'elo_men_doubles' THEN elo_men_doubles WHEN v_elo_field = 'elo_women_doubles' THEN elo_women_doubles WHEN v_elo_field = 'elo_singles' THEN elo_singles ELSE elo_mixed_doubles END) INTO v_team1_avg FROM public.profiles WHERE id = ANY(p_winners);
    SELECT AVG(CASE WHEN v_elo_field = 'elo_men_doubles' THEN elo_men_doubles WHEN v_elo_field = 'elo_women_doubles' THEN elo_women_doubles WHEN v_elo_field = 'elo_singles' THEN elo_singles ELSE elo_mixed_doubles END) INTO v_team2_avg FROM public.profiles WHERE id = ANY(p_losers);

    v_team1_avg := COALESCE(v_team1_avg, 1200);
    v_team2_avg := COALESCE(v_team2_avg, 1200);
    v_expected_score := 1.0 / (1.0 + POWER(10.0, (v_team2_avg - v_team1_avg) / 400.0));

    FOR v_player IN SELECT * FROM public.profiles WHERE id = ANY(p_winners || p_losers) LOOP
        CASE v_elo_field
            WHEN 'elo_men_doubles' THEN v_current_elo := COALESCE(v_player.elo_men_doubles, 1200);
            WHEN 'elo_women_doubles' THEN v_current_elo := COALESCE(v_player.elo_women_doubles, 1200);
            WHEN 'elo_singles' THEN v_current_elo := COALESCE(v_player.elo_singles, 1200);
            ELSE v_current_elo := COALESCE(v_player.elo_mixed_doubles, 1200);
        END CASE;

        IF v_player.id = ANY(p_winners) THEN v_actual_score := 1.0; ELSE v_actual_score := 0.0; END IF;

        v_k_factor := 32;
        IF v_player.role = 'coach' THEN v_k_factor := 0;
        ELSIF v_player.is_guest IS TRUE THEN v_k_factor := 80;
        ELSIF p_is_tournament IS TRUE THEN v_k_factor := 40;
        ELSE
            IF (COALESCE(v_player.games_played_today, 0) + COALESCE(v_player.total_games_history, 0)) < 10 THEN v_k_factor := 64;
            ELSIF v_current_elo > 1800 AND (COALESCE(v_player.games_played_today, 0) + COALESCE(v_player.total_games_history, 0)) > 100 THEN v_k_factor := 20;
            END IF;
        END IF;

        IF v_actual_score = 1.0 THEN v_delta := ROUND(v_k_factor * (1.0 - v_expected_score));
        ELSE v_delta := ROUND(v_k_factor * (v_expected_score - 1.0));
        END IF;

        v_new_elo := v_current_elo + v_delta;

        IF v_k_factor > 0 THEN
            EXECUTE format('UPDATE public.profiles SET %I = $1, games_played_today = COALESCE(games_played_today, 0) + 1, total_games_history = COALESCE(total_games_history, 0) + 1, total_wins = COALESCE(total_wins, 0) + CASE WHEN $3 THEN 1 ELSE 0 END, total_losses = COALESCE(total_losses, 0) + CASE WHEN $3 THEN 0 ELSE 1 END, winning_streak = CASE WHEN $3 THEN COALESCE(winning_streak, 0) + 1 ELSE 0 END WHERE id = $2', v_elo_field)
            USING v_new_elo, v_player.id, (v_actual_score = 1.0);
            
            INSERT INTO public.elo_history (player_id, match_type, elo_score, delta) VALUES (v_player.id, p_match_type, v_new_elo, v_delta);
        END IF;
    END LOOP;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Force Schema Reload
NOTIFY pgrst, 'reload schema';
