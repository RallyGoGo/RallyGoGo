-- ============================================================================
-- TOTAL FIX - 모든 핵심 RPC 재정의 (final_v3_reset.sql 원본 기반)
-- Date: 2026-02-11
-- ============================================================================
-- 이 파일은 아래 버그를 한 번에 해결합니다:
--   1. 대기열 재등록 실패 (finish_match_v2가 DELETE만 했음)
--   2. 관리자 경기결과 안보임 (report_score가 PENDING으로 전환 실패)
--   3. check_and_reset_daily 에러로 join_queue 크래시
-- ============================================================================
-- ============================================================================
-- STEP 1: match_status_t ENUM에 'PENDING' 안전 추가
-- ============================================================================
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_enum
    WHERE enumlabel = 'PENDING'
        AND enumtypid = (
            SELECT oid
            FROM pg_type
            WHERE typname = 'match_status_t'
        )
) THEN ALTER TYPE match_status_t
ADD VALUE 'PENDING'
AFTER 'SCORING';
END IF;
END $$;
-- ============================================================================
-- STEP 2: system_flags 테이블에 value_text 컬럼 보강
-- ============================================================================
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'system_flags'
        AND column_name = 'value_text'
) THEN
ALTER TABLE system_flags
ADD COLUMN value_text TEXT;
END IF;
END $$;
-- ============================================================================
-- STEP 3: check_and_reset_daily (Exception-Safe)
-- ============================================================================
DROP FUNCTION IF EXISTS check_and_reset_daily();
CREATE OR REPLACE FUNCTION check_and_reset_daily() RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_last_reset TEXT;
v_today TEXT;
BEGIN BEGIN v_today := to_char(now() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD');
EXCEPTION
WHEN OTHERS THEN v_today := to_char(now(), 'YYYY-MM-DD');
END;
BEGIN
SELECT value_text INTO v_last_reset
FROM system_flags
WHERE key = 'last_daily_reset';
IF v_last_reset IS NULL
OR v_last_reset != v_today THEN
UPDATE profiles
SET games_played_today = 0;
INSERT INTO system_flags (key, value, value_text, description)
VALUES (
        'last_daily_reset',
        true,
        v_today,
        'Daily stats reset date'
    ) ON CONFLICT (key) DO
UPDATE
SET value_text = v_today,
    updated_at = now();
END IF;
EXCEPTION
WHEN OTHERS THEN RAISE WARNING 'check_and_reset_daily failed: %',
SQLERRM;
END;
END;
$$;
-- ============================================================================
-- STEP 4: report_score — SCORING → PENDING 전환 (코트 해방)
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
-- SCORING 또는 PENDING 상태에서만 허용
IF v_match.status NOT IN ('SCORING', 'PENDING') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '점수 입력은 SCORING 상태에서만 가능합니다. 현재: ' || v_match.status::TEXT
);
END IF;
-- 점수 기록 + PENDING으로 전환
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
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'status',
    'PENDING',
    'message',
    '점수가 기록되었습니다. 승인 대기 중입니다.'
);
END;
$$;
-- ============================================================================
-- STEP 5: finish_match_v2 (final_v3_reset.sql 원본 기반 + 대기열 재등록)
-- ============================================================================
-- ⚠️  파라미터명은 p_team1_score / p_team2_score (프론트엔드 호출과 일치)
-- ⚠️  컬럼명은 winner_team / end_time / confirmed_by (실제 스키마와 일치)
-- ============================================================================
DROP FUNCTION IF EXISTS finish_match_v2(UUID, INTEGER, INTEGER, TEXT);
CREATE OR REPLACE FUNCTION finish_match_v2(
        p_match_id UUID,
        p_team1_score INTEGER,
        p_team2_score INTEGER,
        p_confirmation_type TEXT DEFAULT 'NORMAL_CONFIRM'
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_is_admin BOOLEAN;
v_is_participant BOOLEAN;
v_winner_team TEXT;
v_all_player_ids UUID [];
v_team1_ids UUID [];
v_team2_ids UUID [];
v_team1_rating NUMERIC := 0;
v_team2_rating NUMERIC := 0;
v_p1_expected NUMERIC;
v_p1_actual NUMERIC;
v_base_delta NUMERIC;
v_k_factor INTEGER := 32;
v_bets_settled INTEGER;
v_status_before TEXT;
v_profile RECORD;
is_team1 BOOLEAN;
final_delta INTEGER;
old_rating INTEGER;
new_rating INTEGER;
multiplier NUMERIC := 1.0;
v_match_type TEXT;
v_pid UUID;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- 점수 검증
IF p_team1_score < 0
OR p_team1_score > 99
OR p_team2_score < 0
OR p_team2_score > 99
OR (
    p_team1_score = 0
    AND p_team2_score = 0
) THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_SCORE',
    'message',
    '유효하지 않은 점수입니다.'
);
END IF;
-- 매치 조회
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status = 'FINISHED' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ALREADY_FINISHED',
    'message',
    '이미 종료된 경기입니다.'
);
END IF;
v_status_before := v_match.status::TEXT;
v_match_type := COALESCE(v_match.match_type::TEXT, 'MIXED');
-- 팀 구성
v_team1_ids := ARRAY [v_match.player_1, v_match.player_2];
v_team2_ids := ARRAY [v_match.player_3, v_match.player_4];
v_all_player_ids := v_team1_ids || v_team2_ids;
SELECT array_agg(x) INTO v_all_player_ids
FROM unnest(v_all_player_ids) x
WHERE x IS NOT NULL;
SELECT array_agg(x) INTO v_team1_ids
FROM unnest(v_team1_ids) x
WHERE x IS NOT NULL;
SELECT array_agg(x) INTO v_team2_ids
FROM unnest(v_team2_ids) x
WHERE x IS NOT NULL;
-- 권한 검증
v_is_participant := v_user_id = ANY(v_all_player_ids);
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
IF p_confirmation_type = 'NORMAL_CONFIRM' THEN IF NOT v_is_participant THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PERMISSION_DENIED',
    'message',
    '경기 참가자만 결과를 입력할 수 있습니다.'
);
END IF;
ELSIF p_confirmation_type = 'ADMIN_FORCE_CONFIRM' THEN IF NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
END IF;
-- 승리팀 결정
IF p_team1_score > p_team2_score THEN v_winner_team := 'TEAM_1';
v_p1_actual := 1.0;
ELSIF p_team2_score > p_team1_score THEN v_winner_team := 'TEAM_2';
v_p1_actual := 0.0;
ELSE v_winner_team := 'DRAW';
v_p1_actual := 0.5;
END IF;
-- ELO 계산: match_type별 평균 레이팅 조회
CASE
    v_match_type
    WHEN 'MENS_DOUBLES' THEN
    SELECT COALESCE(AVG(elo_mens_doubles), 1200) INTO v_team1_rating
    FROM profiles
    WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_mens_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
WHEN 'WOMENS_DOUBLES' THEN
SELECT COALESCE(AVG(elo_womens_doubles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_womens_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
WHEN 'SINGLES' THEN
SELECT COALESCE(AVG(elo_singles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_singles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
ELSE -- MIXED 또는 기본
SELECT COALESCE(AVG(elo_mixed_doubles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_mixed_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
END CASE
;
v_p1_expected := 1.0 / (
    1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0)
);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
-- 각 선수 프로필 업데이트
FOR v_profile IN
SELECT *
FROM profiles
WHERE id = ANY(v_all_player_ids) FOR
UPDATE LOOP is_team1 := v_profile.id = ANY(v_team1_ids);
multiplier := 1.0;
-- 해당 match_type의 ELO 가져오기
CASE
    v_match_type
    WHEN 'MENS_DOUBLES' THEN old_rating := COALESCE(v_profile.elo_mens_doubles, 1200);
WHEN 'WOMENS_DOUBLES' THEN old_rating := COALESCE(v_profile.elo_womens_doubles, 1200);
WHEN 'SINGLES' THEN old_rating := COALESCE(v_profile.elo_singles, 1200);
ELSE old_rating := COALESCE(v_profile.elo_mixed_doubles, 1200);
END CASE
;
-- 델타 계산
IF is_team1 THEN final_delta := ROUND(v_base_delta);
ELSE final_delta := ROUND(v_base_delta * -1);
END IF;
-- 게스트 배율
IF v_profile.is_guest THEN multiplier := 1.5;
final_delta := ROUND(final_delta * multiplier);
END IF;
new_rating := GREATEST(0, LEAST(4000, old_rating + final_delta));
-- match_type별 ELO 업데이트
IF v_match_type = 'MENS_DOUBLES' THEN
UPDATE profiles
SET elo_mens_doubles = new_rating
WHERE id = v_profile.id;
ELSIF v_match_type = 'WOMENS_DOUBLES' THEN
UPDATE profiles
SET elo_womens_doubles = new_rating
WHERE id = v_profile.id;
ELSIF v_match_type = 'SINGLES' THEN
UPDATE profiles
SET elo_singles = new_rating
WHERE id = v_profile.id;
ELSE
UPDATE profiles
SET elo_mixed_doubles = new_rating
WHERE id = v_profile.id;
END IF;
-- 일반 통계 업데이트
UPDATE profiles
SET games_played_today = COALESCE(games_played_today, 0) + 1,
    total_games_history = COALESCE(total_games_history, 0) + 1,
    total_wins = total_wins + CASE
        WHEN (
            is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN 1
        ELSE 0
    END,
    total_losses = total_losses + CASE
        WHEN (
            is_team1
            AND v_winner_team = 'TEAM_2'
        )
        OR (
            NOT is_team1
            AND v_winner_team = 'TEAM_1'
        ) THEN 1
        ELSE 0
    END,
    total_draws = total_draws + CASE
        WHEN v_winner_team = 'DRAW' THEN 1
        ELSE 0
    END,
    winning_streak = CASE
        WHEN (
            (
                is_team1
                AND v_winner_team = 'TEAM_1'
            )
            OR (
                NOT is_team1
                AND v_winner_team = 'TEAM_2'
            )
        ) THEN COALESCE(winning_streak, 0) + 1
        ELSE 0
    END
WHERE id = v_profile.id;
-- ELO 히스토리 기록
INSERT INTO elo_history (
        player_id,
        match_id,
        match_type,
        old_rating,
        new_rating,
        was_guest,
        applied_multiplier
    )
VALUES (
        v_profile.id,
        p_match_id,
        v_match.match_type,
        old_rating,
        new_rating,
        v_profile.is_guest,
        multiplier
    );
END LOOP;
-- 매치 상태 업데이트 → FINISHED
UPDATE matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner_team,
    confirmed_by = v_user_id,
    end_time = now()
WHERE id = p_match_id;
-- 베팅 정산
BEGIN
SELECT settle_match_bets(p_match_id, v_winner_team) INTO v_bets_settled;
EXCEPTION
WHEN OTHERS THEN v_bets_settled := 0;
END;
-- 감사 로그
INSERT INTO match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        match_status_before,
        match_status_after,
        score_team1,
        score_team2,
        confirmation_type,
        is_force_confirm
    )
VALUES (
        p_match_id,
        'CONFIRM_MATCH',
        v_user_id,
        CASE
            WHEN v_is_admin THEN 'ADMIN'
            ELSE 'PLAYER'
        END,
        v_status_before::match_status_t,
        'FINISHED',
        p_team1_score,
        p_team2_score,
        p_confirmation_type,
        p_confirmation_type = 'ADMIN_FORCE_CONFIRM'
    );
-- ✅ 대기열 자동 재등록 (DELETE 대신 UPSERT)
FOREACH v_pid IN ARRAY v_all_player_ids LOOP IF v_pid IS NOT NULL THEN BEGIN
INSERT INTO queue (player_id, priority_score, is_active, joined_at)
VALUES (v_pid, 500, true, now()) ON CONFLICT (player_id) DO
UPDATE
SET is_active = true,
    priority_score = 500,
    joined_at = now();
EXCEPTION
WHEN OTHERS THEN RAISE WARNING 'Auto-rejoin failed for %: %',
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
    'winner_team',
    v_winner_team,
    'bets_settled',
    COALESCE(v_bets_settled, 0),
    'mvp_voting_open',
    true,
    'message',
    '경기가 종료되었습니다. 대기열에 자동 재등록되었습니다.'
);
END;
$$;
-- 권한 부여
GRANT EXECUTE ON FUNCTION finish_match_v2(UUID, INTEGER, INTEGER, TEXT) TO authenticated;
-- ============================================================================
-- STEP 6: admin_confirm_match (finish_match_v2 위임)
-- ============================================================================
DROP FUNCTION IF EXISTS admin_confirm_match(UUID);
CREATE OR REPLACE FUNCTION admin_confirm_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_match RECORD;
v_user_id UUID := auth.uid();
v_user_role TEXT;
v_result JSONB;
BEGIN -- 관리자 체크
SELECT role INTO v_user_role
FROM profiles
WHERE id = v_user_id;
IF v_user_role IS NULL
OR v_user_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
-- 매치 조회
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status = 'FINISHED' THEN RETURN jsonb_build_object('success', false, 'error', 'ALREADY_FINISHED');
END IF;
-- 점수 존재 확인
IF v_match.score_team1 IS NULL
OR v_match.score_team2 IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'SCORE_REQUIRED',
    'message',
    '점수가 입력되지 않았습니다.'
);
END IF;
-- finish_match_v2로 위임 (ELO + 베팅 + 대기열 재등록 모두 포함)
v_result := finish_match_v2(
    p_match_id,
    COALESCE(v_match.score_team1, 0),
    COALESCE(v_match.score_team2, 0),
    'ADMIN_FORCE_CONFIRM'
);
RETURN v_result;
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INTERNAL_ERROR',
    'sqlstate',
    SQLSTATE,
    'message',
    SQLERRM
);
END;
$$;
GRANT EXECUTE ON FUNCTION admin_confirm_match(UUID) TO authenticated;
-- ============================================================================
-- STEP 7: join_queue (daily reset 안전 호출 포함)
-- ============================================================================
CREATE OR REPLACE FUNCTION join_queue(
        p_priority_score NUMERIC DEFAULT 0,
        p_departure_time TIMESTAMPTZ DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_profile RECORD;
v_queue_id UUID;
v_existing_queue RECORD;
v_active_match RECORD;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED',
    'message',
    '로그인이 필요합니다.'
);
END IF;
-- Daily reset (실패해도 진행)
BEGIN PERFORM check_and_reset_daily();
EXCEPTION
WHEN OTHERS THEN NULL;
-- 무시
END;
SELECT * INTO v_profile
FROM profiles
WHERE id = v_user_id;
IF v_profile IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PROFILE_NOT_FOUND',
    'message',
    '프로필을 먼저 생성해주세요.'
);
END IF;
SELECT * INTO v_existing_queue
FROM queue
WHERE player_id = v_user_id
    AND is_active = true;
IF v_existing_queue IS NOT NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ALREADY_IN_QUEUE',
    'message',
    '이미 대기열에 등록되어 있습니다.',
    'queue_id',
    v_existing_queue.id
);
END IF;
SELECT * INTO v_active_match
FROM matches
WHERE status NOT IN ('FINISHED', 'CANCELLED')
    AND (
        player_1 = v_user_id
        OR player_2 = v_user_id
        OR player_3 = v_user_id
        OR player_4 = v_user_id
    )
LIMIT 1;
IF v_active_match IS NOT NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ALREADY_IN_MATCH',
    'message',
    '진행 중인 경기가 있습니다.',
    'match_id',
    v_active_match.id
);
END IF;
BEGIN
INSERT INTO queue (
        player_id,
        priority_score,
        departure_time,
        is_active,
        joined_at
    )
VALUES (
        v_user_id,
        COALESCE(p_priority_score, 0),
        p_departure_time,
        true,
        now()
    )
RETURNING id INTO v_queue_id;
EXCEPTION
WHEN unique_violation THEN
SELECT id INTO v_queue_id
FROM queue
WHERE player_id = v_user_id;
UPDATE queue
SET is_active = true,
    joined_at = now()
WHERE id = v_queue_id;
RETURN jsonb_build_object(
    'success',
    true,
    'queue_id',
    v_queue_id,
    'was_duplicate',
    true
);
END;
RETURN jsonb_build_object(
    'success',
    true,
    'queue_id',
    v_queue_id,
    'player_id',
    v_user_id,
    'is_guest',
    v_profile.is_guest,
    'message',
    '대기열에 등록되었습니다.'
);
END;
$$;
-- ============================================================================
-- STEP 8: database.types.ts의 check_and_reset_daily 리턴타입 맞추기
-- (check_and_reset_daily는 VOID를 반환하지만 types에는 boolean으로 되어있음)
-- 이건 프론트에서 직접 호출하지 않으므로 실질적 영향 없음
-- ============================================================================
-- ============================================================================
-- VERIFICATION QUERIES (Supabase SQL Editor에서 실행)
-- ============================================================================
-- 1. Enum 확인:
-- SELECT enumlabel FROM pg_enum WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'match_status_t') ORDER BY enumsortorder;
-- 결과: DRAFT, PLAYING, SCORING, PENDING, FINISHED, CANCELLED, DISPUTED
--
-- 2. 함수 파라미터 확인:
-- SELECT proname, pg_get_function_arguments(oid) FROM pg_proc WHERE proname IN ('finish_match_v2', 'report_score', 'admin_confirm_match');
-- finish_match_v2: p_match_id uuid, p_team1_score integer, p_team2_score integer, p_confirmation_type text
--
-- 3. 함수 본문에 'queue' 포함 확인:
-- SELECT proname FROM pg_proc WHERE proname = 'finish_match_v2' AND prosrc LIKE '%queue%';
-- ============================================================================