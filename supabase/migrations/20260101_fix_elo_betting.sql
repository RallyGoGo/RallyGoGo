-- ELO & Betting System Fix Implementation
-- 1. ELO Update via RPC (Security Definier to bypass RLS)
-- 2. Betting Settlement Trigger (Re-apply)

-- A. ELO Calc Function (Ported from TypeScript)
CREATE OR REPLACE FUNCTION public.update_player_elo(
    p_match_type VARCHAR, -- 'MEN_D', 'WOMEN_D', 'MIXED', 'SINGLES'
    p_winners UUID[],
    p_losers UUID[],
    p_is_tournament BOOLEAN
) RETURNS JSONB AS $$
DECLARE
    v_player RECORD;
    v_elo_field VARCHAR;
    v_team1_avg NUMERIC := 0;
    v_team2_avg NUMERIC := 0;
    v_count INTEGER;
    v_expected_score NUMERIC;
    v_actual_score NUMERIC;
    v_k_factor INTEGER;
    v_delta INTEGER;
    v_current_elo INTEGER;
    v_new_elo INTEGER;
    v_updates JSONB := '[]'::JSONB;
BEGIN
    -- 1. Determine ELO Field
    CASE p_match_type
        WHEN 'MEN_D' THEN v_elo_field := 'elo_men_doubles';
        WHEN 'WOMEN_D' THEN v_elo_field := 'elo_women_doubles';
        WHEN 'SINGLES' THEN v_elo_field := 'elo_singles';
        ELSE v_elo_field := 'elo_mixed_doubles';
    END CASE;

    -- 2. Calculate Team Averages
    -- Team 1 (Winners)
    SELECT AVG(
        CASE 
            WHEN v_elo_field = 'elo_men_doubles' THEN elo_men_doubles
            WHEN v_elo_field = 'elo_women_doubles' THEN elo_women_doubles
            WHEN v_elo_field = 'elo_singles' THEN elo_singles
            ELSE elo_mixed_doubles 
        END
    ) INTO v_team1_avg
    FROM public.profiles WHERE id = ANY(p_winners);

    -- Team 2 (Losers)
    SELECT AVG(
        CASE 
            WHEN v_elo_field = 'elo_men_doubles' THEN elo_men_doubles
            WHEN v_elo_field = 'elo_women_doubles' THEN elo_women_doubles
            WHEN v_elo_field = 'elo_singles' THEN elo_singles
            ELSE elo_mixed_doubles 
        END
    ) INTO v_team2_avg
    FROM public.profiles WHERE id = ANY(p_losers);

    v_team1_avg := COALESCE(v_team1_avg, 1200);
    v_team2_avg := COALESCE(v_team2_avg, 1200);

    -- 3. Calculate Expectation for Team 1 (Winner)
    v_expected_score := 1.0 / (1.0 + POWER(10.0, (v_team2_avg - v_team1_avg) / 400.0));

    -- 4. Loop Logic for All Players
    FOR v_player IN SELECT * FROM public.profiles WHERE id = ANY(p_winners || p_losers) LOOP
        
        -- Get Current ELO
        CASE v_elo_field
            WHEN 'elo_men_doubles' THEN v_current_elo := COALESCE(v_player.elo_men_doubles, 1200);
            WHEN 'elo_women_doubles' THEN v_current_elo := COALESCE(v_player.elo_women_doubles, 1200);
            WHEN 'elo_singles' THEN v_current_elo := COALESCE(v_player.elo_singles, 1200);
            ELSE v_current_elo := COALESCE(v_player.elo_mixed_doubles, 1200);
        END CASE;

        -- Determine Actual Score (1 for Winner, 0 for Loser)
        IF v_player.id = ANY(p_winners) THEN
            v_actual_score := 1.0;
        ELSE
            v_actual_score := 0.0;
        END IF;

        -- Determine K-Factor
        v_k_factor := 32; -- Default
        IF v_player.role = 'coach' THEN
            v_k_factor := 0;
        ELSIF v_player.is_guest IS TRUE THEN
            v_k_factor := 80;
        ELSIF p_is_tournament IS TRUE THEN
            v_k_factor := 40;
        ELSE
            -- New Member Logic
            IF (COALESCE(v_player.games_played_today, 0) + COALESCE(v_player.total_games_history, 0)) < 10 THEN
                v_k_factor := 64;
            ELSIF v_current_elo > 1800 AND (COALESCE(v_player.games_played_today, 0) + COALESCE(v_player.total_games_history, 0)) > 100 THEN
                v_k_factor := 20;
            END IF;
        END IF;

        -- Calculate Delta
        -- For Winner: Actual=1, Expected=Exp. Delta = K * (1 - Exp)
        -- For Loser: Actual=0, Expected=(1-Exp). Delta = K * (0 - (1-Exp)) = K * (Exp - 1) = - DeltaWinner
        -- Note: Expectation is for Team 1.
        IF v_player.id = ANY(p_winners) THEN
             v_delta := ROUND(v_k_factor * (1.0 - v_expected_score));
        ELSE
             v_delta := ROUND(v_k_factor * (0.0 - (1.0 - (1.0 - v_expected_score)))); -- Simplified: K * (0 - Exp_Loser)
             -- Wait, Expectation for Team 2 is (1 - v_expected_score).
             -- Delta = K * (0 - (1 - v_expected_score))
             v_delta := ROUND(v_k_factor * (v_expected_score - 1.0));
        END IF;

        v_new_elo := v_current_elo + v_delta;

        -- Update DB if K != 0
        IF v_k_factor > 0 THEN
            EXECUTE format('UPDATE public.profiles SET %I = $1, games_played_today = COALESCE(games_played_today, 0) + 1, total_games_history = COALESCE(total_games_history, 0) + 1 WHERE id = $2', v_elo_field)
            USING v_new_elo, v_player.id;
            
            -- Insert History
            INSERT INTO public.elo_history (player_id, match_type, elo_score, delta)
            VALUES (v_player.id, p_match_type, v_new_elo, v_delta);
        END IF;

    END LOOP;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- B. Re-apply Betting Settlement Trigger
CREATE OR REPLACE FUNCTION public.settle_bets_trigger() RETURNS TRIGGER AS $$
DECLARE
    v_bet RECORD;
    v_winnings INTEGER;
BEGIN
    IF NEW.status = 'FINISHED' AND OLD.status != 'FINISHED' THEN
        FOR v_bet IN SELECT * FROM public.bets WHERE match_id = NEW.id AND result = 'PENDING' LOOP
            
            IF NEW.winner_team = 'DRAW' THEN
                UPDATE public.bets SET result = 'DRAW' WHERE id = v_bet.id;
                UPDATE public.profiles SET rally_point = rally_point + v_bet.amount WHERE id = v_bet.user_id;
            
            ELSIF NEW.winner_team = v_bet.pick_team THEN
                v_winnings := FLOOR(v_bet.amount * v_bet.odds_at_bet);
                UPDATE public.bets SET result = 'WIN' WHERE id = v_bet.id;
                UPDATE public.profiles SET rally_point = rally_point + v_winnings WHERE id = v_bet.user_id;

            ELSE
                UPDATE public.bets SET result = 'LOSE' WHERE id = v_bet.id;
            END IF;
            
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Re-create Trigger
DROP TRIGGER IF EXISTS on_match_finish ON public.matches;
CREATE TRIGGER on_match_finish
AFTER UPDATE OF status ON public.matches
FOR EACH ROW
WHEN (NEW.status = 'FINISHED')
EXECUTE FUNCTION public.settle_bets_trigger();

-- Force schema reload
NOTIFY pgrst, 'reload schema';
