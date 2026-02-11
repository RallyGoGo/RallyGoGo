-- ============================================================================
-- PDCA TOTAL FIX — 근본 원인 5개 동시 해결
-- Date: 2026-02-11
-- ============================================================================
-- 과거 대화 분석 및 47개 마이그레이션 전수 분석 결과:
--   원인1: match_status_t에 PENDING enum 누락
--   원인2: finish_match_v2 컬럼명 불일치 (winner↔winner_team, finished_at↔end_time)
--   원인3: 큐 재등록 시 DELETE만 하거나 미존재 함수 호출
--   원인4: check_and_reset_daily VOID vs BOOLEAN 반환타입 불일치
--   원인5: database.types.ts에 PENDING 미포함 (별도 TS 수정)
--
-- 기준: final_v3_reset.sql의 정확한 스키마 컬럼명
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
-- STEP 2: system_flags.value_text 컬럼 안전 추가
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
-- STEP 3: check_and_reset_daily → BOOLEAN 반환 (프론트엔드 호환)
-- ============================================================================
-- 프론트엔드(useRallyData.ts:152)에서 직접 호출하며 data === true 체크함
-- 반드시 BOOLEAN을 반환해야 함
-- ============================================================================
DROP FUNCTION IF EXISTS check_and_reset_daily();
CREATE OR REPLACE FUNCTION check_and_reset_daily() RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_last_reset TEXT;
v_today TEXT;
v_did_reset BOOLEAN := false;
BEGIN -- 타임존 안전 처리
BEGIN v_today := to_char(now() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD');
EXCEPTION
WHEN OTHERS THEN v_today := to_char(now(), 'YYYY-MM-DD');
END;
-- 리셋 로직 (실패해도 트랜잭션 유지)
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
v_did_reset := true;
END IF;
EXCEPTION
WHEN OTHERS THEN RAISE WARNING 'check_and_reset_daily failed: %',
SQLERRM;
END;
RETURN v_did_reset;
END;
$$;
GRANT EXECUTE ON FUNCTION check_and_reset_daily() TO authenticated;
-- ============================================================================
-- STEP 4: report_score — SCORING → PENDING 전환
-- ============================================================================
-- 기준: final_v3_reset.sql line 740 (원본)
-- 변경: status를 PENDING으로 전환하여 코트를 해방
-- 컬럼명: winner_team (NOT winner), reported_by
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
-- SCORING 또는 PENDING 상태에서만 허용 (재입력 가능)
IF v_match.status NOT IN ('SCORING', 'PENDING') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '점수 입력은 SCORING 상태에서만 가능합니다. 현재: ' || v_match.status::TEXT
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
    'message',
    '점수가 기록되었습니다. 승인 대기 중입니다.'
);
END;
$$;
GRANT EXECUTE ON FUNCTION report_score(UUID, INTEGER, INTEGER, TEXT) TO authenticated;
-- ============================================================================
-- STEP 5: finish_match_v2 — 원본 기반 + match_type별 ELO + 큐 직접 UPSERT
-- ============================================================================
-- 기준: final_v3_reset.sql line 826-892 (원본)
-- 파라미터: p_team1_score / p_team2_score (프론트엔드 CourtBoard.tsx:385, MatchReviewModal.tsx:63과 일치)
-- 컬럼명: winner_team, end_time, confirmed_by (실제 matches 테이블 스키마)
-- 변경1: match_type별 ELO 계산 (MIXED/MENS/WOMENS/SINGLES)
-- 변경2: DELETE FROM queue → INSERT INTO queue ON CONFLICT (큐 재등록)
-- 변경3: settle_match_bets Exception-safe 래핑
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
v_bets_settled INTEGER := 0;
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
-- 매치 조회 (FOR UPDATE 잠금)
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
-- 팀 구성 (NULL 필터링)
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
-- ═══════════════════════════════════════════════════════════
-- ELO 계산: match_type별 평균 레이팅 조회
-- ═══════════════════════════════════════════════════════════
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
ELSE -- MIXED (기본값)
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
-- ═══════════════════════════════════════════════════════════
-- 각 선수 프로필 업데이트 (ELO + 통계)
-- ═══════════════════════════════════════════════════════════
FOR v_profile IN
SELECT *
FROM profiles
WHERE id = ANY(v_all_player_ids) FOR
UPDATE LOOP is_team1 := v_profile.id = ANY(v_team1_ids);
multiplier := 1.0;
-- 해당 match_type의 현재 ELO
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
-- 게스트 배율 적용
IF v_profile.is_guest THEN multiplier := 1.5;
final_delta := ROUND(final_delta * multiplier);
END IF;
new_rating := GREATEST(0, LEAST(4000, old_rating + final_delta));
-- match_type별 ELO 컬럼 업데이트
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
-- ═══════════════════════════════════════════════════════════
-- 매치 상태 → FINISHED (정확한 컬럼명 사용)
-- 컬럼: status, score_team1, score_team2, winner_team, confirmed_by, end_time
-- ═══════════════════════════════════════════════════════════
UPDATE matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner_team,
    confirmed_by = v_user_id,
    end_time = now()
WHERE id = p_match_id;
-- ═══════════════════════════════════════════════════════════
-- 베팅 정산 (Exception-safe)
-- ═══════════════════════════════════════════════════════════
BEGIN
SELECT settle_match_bets(p_match_id, v_winner_team) INTO v_bets_settled;
EXCEPTION
WHEN OTHERS THEN v_bets_settled := 0;
RAISE WARNING 'settle_match_bets failed: %',
SQLERRM;
END;
-- ═══════════════════════════════════════════════════════════
-- 감사 로그 (match_audit_log)
-- ═══════════════════════════════════════════════════════════
BEGIN
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
EXCEPTION
WHEN OTHERS THEN RAISE WARNING 'audit log failed: %',
SQLERRM;
END;
-- ═══════════════════════════════════════════════════════════
-- ✅ 대기열 자동 재등록 (핵심 수정)
-- 원본: DELETE FROM queue (버그)
-- 수정: INSERT INTO queue ON CONFLICT DO UPDATE (재등록)
-- 외부 함수 의존 없음 (rejoin_queue_after_match 불필요)
-- ═══════════════════════════════════════════════════════════
IF v_all_player_ids IS NOT NULL THEN FOREACH v_pid IN ARRAY v_all_player_ids LOOP IF v_pid IS NOT NULL THEN BEGIN
INSERT INTO queue (player_id, priority_score, is_active, joined_at)
VALUES (v_pid, 500, true, now()) ON CONFLICT (player_id) DO
UPDATE
SET is_active = true,
    priority_score = 500,
    joined_at = now();
EXCEPTION
WHEN OTHERS THEN RAISE WARNING 'Auto-rejoin failed for player %: %',
v_pid,
SQLERRM;
END;
END IF;
END LOOP;
END IF;
-- ═══════════════════════════════════════════════════════════
-- 결과 반환
-- ═══════════════════════════════════════════════════════════
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
GRANT EXECUTE ON FUNCTION finish_match_v2(UUID, INTEGER, INTEGER, TEXT) TO authenticated;
-- ============================================================================
-- STEP 6: admin_confirm_match — finish_match_v2 위임
-- ============================================================================
-- 기준: v9.8.2_fix_admin_confirm.sql
-- admin_confirm_match는 점수가 이미 입력된 매치를 관리자가 승인
-- 내부에서 finish_match_v2를 ADMIN_FORCE_CONFIRM으로 호출
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
-- finish_match_v2로 위임 (ELO + 베팅 + 큐 재등록 모두 포함)
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
-- STEP 7: join_queue — daily reset 안전 호출
-- ============================================================================
-- 기준: final_v3_reset.sql line 477-521 (원본)
-- 변경: check_and_reset_daily()를 안전하게 호출 (실패 무시)
-- unique_violation 시 is_active = true로 복구
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
-- Daily reset (실패해도 큐 진입 허용)
BEGIN PERFORM check_and_reset_daily();
EXCEPTION
WHEN OTHERS THEN NULL;
-- 무시
END;
-- 프로필 확인
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
-- 이미 대기열에 있는지 확인
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
-- 진행 중인 경기 확인
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
-- 큐 삽입
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
WHEN unique_violation THEN -- 이미 있으면 활성화
UPDATE queue
SET is_active = true,
    joined_at = now(),
    priority_score = COALESCE(p_priority_score, 0)
WHERE player_id = v_user_id
RETURNING id INTO v_queue_id;
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
GRANT EXECUTE ON FUNCTION join_queue(NUMERIC, TIMESTAMPTZ) TO authenticated;
-- ============================================================================
-- VERIFICATION QUERIES (Supabase SQL Editor에서 실행)
-- ============================================================================
-- 1. Enum 확인:
--    SELECT enumlabel FROM pg_enum
--    WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'match_status_t')
--    ORDER BY enumsortorder;
--    → DRAFT, PLAYING, SCORING, PENDING, FINISHED, CANCELLED, DISPUTED
--
-- 2. 함수 파라미터 확인:
--    SELECT proname, pg_get_function_arguments(oid) FROM pg_proc
--    WHERE proname IN ('finish_match_v2','report_score','admin_confirm_match','check_and_reset_daily');
--
-- 3. finish_match_v2가 큐 UPSERT 포함하는지:
--    SELECT proname FROM pg_proc
--    WHERE proname = 'finish_match_v2' AND prosrc LIKE '%INSERT INTO queue%';
--
-- 4. check_and_reset_daily 반환타입:
--    SELECT proname, pg_get_function_result(oid) FROM pg_proc
--    WHERE proname = 'check_and_reset_daily';
--    → boolean
-- ============================================================================