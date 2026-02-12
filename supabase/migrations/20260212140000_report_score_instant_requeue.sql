-- ============================================================================
-- 경기 결과 입력 즉시 대기열 복귀 (v2 - 갈시간 복원)
-- 변경사항:
--   1. matches.player_departure_times JSONB에서 갈시간 복원
--   2. PLAYING 상태에서도 점수 입력 허용
--   3. departure_time을 queue INSERT 시 함께 설정
-- Supabase SQL Editor에서 실행
-- ============================================================================
CREATE OR REPLACE FUNCTION report_score(
        p_match_id UUID,
        p_team1_score INTEGER,
        p_team2_score INTEGER,
        p_winner TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_is_participant BOOLEAN;
v_is_admin BOOLEAN;
v_pid UUID;
v_departure_times JSONB;
v_dep_time TIMESTAMPTZ;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- 관리자 체크
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
-- 참가자 체크
v_is_participant := v_user_id IN (
    v_match.player_1,
    v_match.player_2,
    v_match.player_3,
    v_match.player_4
);
IF NOT v_is_participant
AND NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
END IF;
-- PLAYING, SCORING, PENDING 상태에서 허용 (재입력 가능)
IF v_match.status NOT IN ('PLAYING', 'SCORING', 'PENDING') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '점수 입력은 PLAYING/SCORING 상태에서만 가능합니다. 현재: ' || v_match.status::TEXT
);
END IF;
-- 점수 기록 + PENDING으로 전환 (코트 해방)
UPDATE matches
SET score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = COALESCE(
        p_winner,
        CASE
            WHEN p_team1_score > p_team2_score THEN 'TEAM_1'
            WHEN p_team2_score > p_team1_score THEN 'TEAM_2'
            ELSE 'DRAW'
        END
    ),
    reported_by = v_user_id,
    status = 'PENDING'
WHERE id = p_match_id;
-- ═══════════════════════════════════════════════════════════
-- ✅ 즉시 대기열 복귀 + 갈시간(departure_time) 복원
-- matches.player_departure_times JSONB에서 원래 갈시간을 복원
-- ═══════════════════════════════════════════════════════════
v_departure_times := v_match.player_departure_times;
FOREACH v_pid IN ARRAY ARRAY [
        v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4
    ] LOOP IF v_pid IS NOT NULL THEN BEGIN -- 원래 갈시간 복원
v_dep_time := NULL;
IF v_departure_times IS NOT NULL
AND v_departure_times ? v_pid::text THEN BEGIN v_dep_time := (v_departure_times->>v_pid::text)::timestamptz;
EXCEPTION
WHEN OTHERS THEN v_dep_time := NULL;
END;
END IF;
INSERT INTO queue (
        player_id,
        priority_score,
        is_active,
        joined_at,
        departure_time
    )
VALUES (v_pid, 500, true, now(), v_dep_time) ON CONFLICT (player_id) DO
UPDATE
SET is_active = true,
    priority_score = 500,
    joined_at = now(),
    departure_time = COALESCE(EXCLUDED.departure_time, queue.departure_time);
EXCEPTION
WHEN OTHERS THEN RAISE WARNING 'report_score: auto-rejoin failed for player %: %',
v_pid,
SQLERRM;
END;
END IF;
END LOOP;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'status',
    'PENDING',
    'score_team1',
    p_team1_score,
    'score_team2',
    p_team2_score,
    'queue_rejoined',
    true,
    'message',
    '점수가 기록되었습니다. 대기열에 자동 복귀되었습니다.'
);
END;
$$;
GRANT EXECUTE ON FUNCTION report_score(UUID, INTEGER, INTEGER, TEXT) TO authenticated;