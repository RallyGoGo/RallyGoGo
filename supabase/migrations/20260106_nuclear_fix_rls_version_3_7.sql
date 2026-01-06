-- 🔥 1. 보안 정책(RLS) 대개방 (이게 막혀서 게스트 중복/대기열 튕김 발생함)
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.queue ENABLE ROW LEVEL SECURITY;
-- 기존 정책 삭제 (충돌 방지)
DROP POLICY IF EXISTS "Enable read access for all users" ON public.profiles;
DROP POLICY IF EXISTS "Enable insert for all users" ON public.profiles;
DROP POLICY IF EXISTS "Enable update for all users" ON public.profiles;
DROP POLICY IF EXISTS "Enable all access for queue" ON public.queue;
DROP POLICY IF EXISTS "Public profiles are viewable by everyone" ON public.profiles;
-- 새 정책: 누구나 프로필 조회 가능 (게스트 찾기 위해 필수)
CREATE POLICY "Enable read access for all users" ON public.profiles FOR
SELECT USING (true);
CREATE POLICY "Enable insert for all users" ON public.profiles FOR
INSERT WITH CHECK (true);
CREATE POLICY "Enable update for all users" ON public.profiles FOR
UPDATE USING (true);
-- 새 정책: 대기열 누구나 조작 가능
CREATE POLICY "Enable all access for queue" ON public.queue FOR ALL USING (true) WITH CHECK (true);
-- 🔥 2. 점수 계산 및 대기열 복귀 로직 (강제 업데이트)
CREATE OR REPLACE FUNCTION public.process_match_completion(
        p_match_id UUID,
        p_reporter_id UUID,
        p_team1_score INT,
        p_team2_score INT,
        p_elo_updates JSONB,
        p_queue_inserts JSONB,
        p_client_request_id UUID
    ) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;