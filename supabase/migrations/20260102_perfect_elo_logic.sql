-- Perfect ELO Logic with NTRP Fallback + Draw Handling
-- 점수가 NULL일 경우, 무조건 1200이 아니라 플레이어의 NTRP를 기반으로 계산합니다.
-- 예: NTRP 3.0 -> 1200, NTRP 4.0 -> 1600
-- [NEW] Draw 처리: 약한 팀은 점수 상승, 강한 팀은 점수 하락 (Expected Score 기반)

CREATE OR REPLACE FUNCTION public.update_player_elo(
    p_match_type VARCHAR,
    p_winners UUID[],
    p_losers UUID[],
    p_is_tournament BOOLEAN,
    p_is_draw BOOLEAN DEFAULT FALSE  -- [NEW] Draw flag
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
    v_base_elo INTEGER;
    v_new_elo INTEGER;
    v_is_winner BOOLEAN;
    v_is_draw_player BOOLEAN;
BEGIN
    -- A. 매치 타입에 따른 컬럼 선택
    CASE COALESCE(p_match_type, 'MIXED')
        WHEN 'MEN_D' THEN v_elo_field := 'elo_men_doubles';
        WHEN 'WOMEN_D' THEN v_elo_field := 'elo_women_doubles';
        WHEN 'SINGLES' THEN v_elo_field := 'elo_singles';
        ELSE v_elo_field := 'elo_mixed_doubles';
    END CASE;

    -- B. 팀 평균 ELO 계산 (NTRP 기반 보정 로직 적용)
    SELECT AVG(
        CASE 
            WHEN v_elo_field = 'elo_men_doubles' THEN COALESCE(elo_men_doubles, (ntrp * 400), 1200)
            WHEN v_elo_field = 'elo_women_doubles' THEN COALESCE(elo_women_doubles, (ntrp * 400), 1200)
            WHEN v_elo_field = 'elo_singles' THEN COALESCE(elo_singles, (ntrp * 400), 1200)
            ELSE COALESCE(elo_mixed_doubles, (ntrp * 400), 1200)
        END
    ) INTO v_team1_avg 
    FROM public.profiles WHERE id = ANY(p_winners);

    SELECT AVG(
        CASE 
            WHEN v_elo_field = 'elo_men_doubles' THEN COALESCE(elo_men_doubles, (ntrp * 400), 1200)
            WHEN v_elo_field = 'elo_women_doubles' THEN COALESCE(elo_women_doubles, (ntrp * 400), 1200)
            WHEN v_elo_field = 'elo_singles' THEN COALESCE(elo_singles, (ntrp * 400), 1200)
            ELSE COALESCE(elo_mixed_doubles, (ntrp * 400), 1200)
        END
    ) INTO v_team2_avg 
    FROM public.profiles WHERE id = ANY(p_losers);

    v_team1_avg := COALESCE(v_team1_avg, 1200);
    v_team2_avg := COALESCE(v_team2_avg, 1200);

    -- 승자팀(Team1) 기대 승률 계산
    v_expected_score := 1.0 / (1.0 + POWER(10.0, (v_team2_avg - v_team1_avg) / 400.0));

    -- C. 각 플레이어 루프 돌며 업데이트
    FOR v_player IN SELECT * FROM public.profiles WHERE id = ANY(p_winners || p_losers) LOOP
        
        v_base_elo := ROUND(COALESCE(v_player.ntrp * 400, 1200));

        CASE v_elo_field
            WHEN 'elo_men_doubles' THEN v_current_elo := COALESCE(v_player.elo_men_doubles, v_base_elo);
            WHEN 'elo_women_doubles' THEN v_current_elo := COALESCE(v_player.elo_women_doubles, v_base_elo);
            WHEN 'elo_singles' THEN v_current_elo := COALESCE(v_player.elo_singles, v_base_elo);
            ELSE v_current_elo := COALESCE(v_player.elo_mixed_doubles, v_base_elo);
        END CASE;

        v_is_winner := (v_player.id = ANY(p_winners));
        
        -- [Draw Logic] Actual Score: Win=1.0, Draw=0.5, Loss=0.0
        IF p_is_draw THEN
            v_actual_score := 0.5;  -- Draw: Both teams get 0.5
            v_is_draw_player := TRUE;
        ELSIF v_is_winner THEN
            v_actual_score := 1.0;
            v_is_draw_player := FALSE;
        ELSE
            v_actual_score := 0.0;
            v_is_draw_player := FALSE;
        END IF;

        -- K-Factor 결정
        v_k_factor := 32;
        IF v_player.role = 'coach' THEN v_k_factor := 0;
        ELSIF v_player.is_guest IS TRUE THEN v_k_factor := 80;
        ELSIF p_is_tournament IS TRUE THEN v_k_factor := 40;
        ELSE
            IF (COALESCE(v_player.games_played_today, 0) + COALESCE(v_player.total_games_history, 0)) < 10 THEN 
                v_k_factor := 64;
            END IF;
        END IF;

        -- [Draw ELO Logic] 
        -- For Team1 (p_winners): Delta = K * (0.5 - Expected)
        --   If Expected > 0.5 (favored team), Delta < 0 (loses points)
        --   If Expected < 0.5 (underdog), Delta > 0 (gains points)
        -- For Team2 (p_losers): Same logic, but from their perspective
        IF v_is_winner THEN
            v_delta := ROUND(v_k_factor * (v_actual_score - v_expected_score));
        ELSE
            v_delta := ROUND(v_k_factor * (v_actual_score - (1.0 - v_expected_score)));
        END IF;

        v_new_elo := v_current_elo + v_delta;

        IF v_k_factor > 0 THEN
            -- [Stats Update] Separate logic for Draw vs Win/Loss
            IF v_is_draw_player THEN
                -- Draw: Increment total_draws
                EXECUTE format('
                    UPDATE public.profiles SET 
                        %I = $1, 
                        games_played_today = COALESCE(games_played_today, 0) + 1, 
                        total_games_history = COALESCE(total_games_history, 0) + 1, 
                        total_draws = COALESCE(total_draws, 0) + 1,
                        winning_streak = 0
                    WHERE id = $2', v_elo_field)
                USING v_new_elo, v_player.id;
            ELSE
                -- Win/Loss: Increment wins or losses
                EXECUTE format('
                    UPDATE public.profiles SET 
                        %I = $1, 
                        games_played_today = COALESCE(games_played_today, 0) + 1, 
                        total_games_history = COALESCE(total_games_history, 0) + 1, 
                        total_wins = COALESCE(total_wins, 0) + CASE WHEN $3 THEN 1 ELSE 0 END, 
                        total_losses = COALESCE(total_losses, 0) + CASE WHEN $3 THEN 0 ELSE 1 END, 
                        winning_streak = CASE WHEN $3 THEN COALESCE(winning_streak, 0) + 1 ELSE 0 END 
                    WHERE id = $2', v_elo_field)
                USING v_new_elo, v_player.id, v_is_winner;
            END IF;
            
            INSERT INTO public.elo_history (player_id, match_type, elo_score, delta) 
            VALUES (v_player.id, p_match_type, v_new_elo, v_delta);
        END IF;
    END LOOP;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Reload Schema
NOTIFY pgrst, 'reload schema';

