CREATE OR REPLACE FUNCTION public.process_match_completion(p_match_id uuid, p_reporter_id uuid, p_team1_score integer, p_team2_score integer, p_elo_updates jsonb, p_queue_inserts jsonb, p_client_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_winner TEXT;
BEGIN -- 승자 결정 로직 (DB가 직접 판단)
IF p_team1_score > p_team2_score THEN v_winner := 'TEAM_1';
ELSIF p_team2_score > p_team1_score THEN v_winner := 'TEAM_2';
ELSE v_winner := 'DRAW';
END IF;
-- 매치 상태 업데이트 (결과 확정)
UPDATE public.matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner,
    confirmed_by = p_reporter_id,
    end_time = NOW()
WHERE id = p_match_id;
-- ELO 점수 반영 (Mixed Doubles 기준)
FOR i IN 0..jsonb_array_length(p_elo_updates) - 1 LOOP
UPDATE public.profiles
SET elo_mixed_doubles = COALESCE(elo_mixed_doubles, 1200) + (p_elo_updates->i->>'delta')::INT,
    games_played_today = COALESCE(games_played_today, 0) + 1
WHERE id = (p_elo_updates->i->>'id')::UUID;
END LOOP;
-- 대기열 복귀 (가장 중요)
FOR i IN 0..jsonb_array_length(p_queue_inserts) - 1 LOOP
INSERT INTO public.queue (player_id, joined_at, is_active, priority_score)
VALUES (
        (p_queue_inserts->i->>'player_id')::UUID,
        NOW(),
        TRUE,
        (p_queue_inserts->i->>'priority')::NUMERIC
    ) ON CONFLICT (player_id) DO
UPDATE
SET joined_at = NOW(),
    is_active = TRUE,
    priority_score = EXCLUDED.priority_score;
END LOOP;
RETURN jsonb_build_object('success', true);
END;
$function$;

