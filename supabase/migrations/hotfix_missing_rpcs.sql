-- ============================================================================
-- HOTFIX: Missing RPC Functions
-- ============================================================================
-- Date: 2026-01-23
-- 
-- This hotfix addresses three critical bugs discovered during runtime testing:
--   1. end_match - RPC missing (404 error)
--   2. register_guest_and_enqueue - RPC missing (404 error)
--   3. cancel_match - RPC missing (assumed needed based on CourtBoard.tsx)
--
-- All functions follow V2 conventions:
--   - SECURITY DEFINER for row-level bypass
--   - auth.uid() identity enforcement
--   - JSONB return type for consistent API
-- ============================================================================
-- ============================================================================
-- 1. END_MATCH
-- ============================================================================
-- Transitions a match from PLAYING → SCORING state
-- Called when a game physically ends on the court
-- Sets end_time for statistics tracking
-- ============================================================================
CREATE OR REPLACE FUNCTION end_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_is_participant BOOLEAN;
v_is_admin BOOLEAN;
BEGIN -- ================================================================
-- STEP 1: Identity Check
-- ================================================================
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED',
    'message',
    '로그인이 필요합니다.'
);
END IF;
-- ================================================================
-- STEP 2: Lock and Load Match
-- ================================================================
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'MATCH_NOT_FOUND',
    'message',
    '경기를 찾을 수 없습니다.'
);
END IF;
-- ================================================================
-- STEP 3: Validate Status Transition
-- Can only end PLAYING matches
-- ================================================================
IF v_match.status != 'PLAYING' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '진행 중인 경기만 종료할 수 있습니다. 현재 상태: ' || v_match.status::TEXT
);
END IF;
-- ================================================================
-- STEP 4: Permission Check (participant or admin)
-- ================================================================
v_is_participant := v_user_id IN (
    v_match.player_1,
    v_match.player_2,
    v_match.player_3,
    v_match.player_4
);
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
IF NOT v_is_participant
AND NOT v_is_admin THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PERMISSION_DENIED',
    'message',
    '경기 참가자 또는 관리자만 종료할 수 있습니다.'
);
END IF;
-- ================================================================
-- STEP 5: Update Match Status to SCORING
-- ================================================================
UPDATE matches
SET status = 'SCORING',
    end_time = now()
WHERE id = p_match_id;
-- ================================================================
-- Success Response
-- ================================================================
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'new_status',
    'SCORING',
    'end_time',
    now(),
    'message',
    '경기가 종료되었습니다. 점수를 입력해주세요.'
);
END;
$$;
COMMENT ON FUNCTION end_match IS 'Transition match from PLAYING → SCORING. Sets end_time.
Called when physical game ends, before score entry.';
-- ============================================================================
-- 2. REGISTER_GUEST_AND_ENQUEUE
-- ============================================================================
-- Atomic guest registration + queue entry
-- Creates or reuses guest profile, then adds to queue
-- Used for quick onboarding of walk-in players
-- ============================================================================
CREATE OR REPLACE FUNCTION register_guest_and_enqueue(
        p_name TEXT,
        p_ntrp NUMERIC,
        p_gender TEXT,
        p_departure_time TIMESTAMPTZ
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_guest_id UUID;
v_initial_elo INTEGER;
v_priority_score NUMERIC;
v_queue_id UUID;
v_reused BOOLEAN := false;
v_gender_enum gender_t;
BEGIN -- ================================================================
-- STEP 1: Identity Check (admin/host required)
-- ================================================================
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED',
    'message',
    '로그인이 필요합니다.'
);
END IF;
-- ================================================================
-- STEP 2: Validate Input
-- ================================================================
IF p_name IS NULL
OR trim(p_name) = '' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_NAME',
    'message',
    '이름을 입력해주세요.'
);
END IF;
IF p_ntrp IS NULL
OR p_ntrp < 1.0
OR p_ntrp > 7.0 THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_NTRP',
    'message',
    'NTRP는 1.0~7.0 사이여야 합니다.'
);
END IF;
-- Convert gender text to enum
IF upper(p_gender) = 'MALE'
OR upper(p_gender) = 'M'
OR p_gender = 'Male' THEN v_gender_enum := 'MALE';
ELSIF upper(p_gender) = 'FEMALE'
OR upper(p_gender) = 'F'
OR p_gender = 'Female' THEN v_gender_enum := 'FEMALE';
ELSE v_gender_enum := 'OTHER';
END IF;
-- ================================================================
-- STEP 3: Calculate Initial ELO from NTRP
-- ================================================================
v_initial_elo := CASE
    WHEN p_ntrp = 1.0 THEN 600
    WHEN p_ntrp = 1.5 THEN 800
    WHEN p_ntrp = 2.0 THEN 1000
    WHEN p_ntrp = 2.5 THEN 1100
    WHEN p_ntrp = 3.0 THEN 1200
    WHEN p_ntrp = 3.5 THEN 1400
    WHEN p_ntrp = 4.0 THEN 1600
    WHEN p_ntrp = 4.5 THEN 1800
    WHEN p_ntrp = 5.0 THEN 2000
    WHEN p_ntrp = 5.5 THEN 2200
    WHEN p_ntrp = 6.0 THEN 2400
    WHEN p_ntrp = 7.0 THEN 2800
    ELSE 1200
END;
-- ================================================================
-- STEP 4: Check for Existing Guest with Same Name
-- ================================================================
SELECT id INTO v_guest_id
FROM profiles
WHERE is_guest = true
    AND lower(trim(name)) = lower(trim(p_name))
LIMIT 1;
IF v_guest_id IS NOT NULL THEN -- Reuse existing guest profile
v_reused := true;
-- Update departure time if already in queue
UPDATE queue
SET departure_time = p_departure_time,
    is_active = true
WHERE player_id = v_guest_id;
IF FOUND THEN
SELECT id INTO v_queue_id
FROM queue
WHERE player_id = v_guest_id;
RETURN jsonb_build_object(
    'success',
    true,
    'player_id',
    v_guest_id,
    'queue_id',
    v_queue_id,
    'reused',
    true,
    'initial_elo',
    v_initial_elo,
    'message',
    '기존 게스트 대기열 업데이트.'
);
END IF;
ELSE -- Create new guest profile
v_guest_id := gen_random_uuid();
INSERT INTO profiles (
        id,
        name,
        ntrp,
        gender,
        is_guest,
        elo_mixed_doubles,
        elo_mens_doubles,
        elo_womens_doubles,
        elo_singles
    )
VALUES (
        v_guest_id,
        trim(p_name) || ' (G)',
        p_ntrp,
        v_gender_enum,
        true,
        v_initial_elo,
        v_initial_elo,
        v_initial_elo,
        v_initial_elo
    );
END IF;
-- ================================================================
-- STEP 5: Calculate Priority Score
-- Guests get base priority, adjusted for departure urgency
-- ================================================================
v_priority_score := 500;
-- Base score for guests
-- Urgency boost if leaving within 40 minutes
IF p_departure_time IS NOT NULL THEN
DECLARE diff_mins NUMERIC;
BEGIN diff_mins := EXTRACT(
    EPOCH
    FROM (p_departure_time - now())
) / 60;
IF diff_mins > 0
AND diff_mins <= 40 THEN v_priority_score := v_priority_score + 70;
END IF;
END;
END IF;
-- ================================================================
-- STEP 6: Insert into Queue
-- ================================================================
BEGIN
INSERT INTO queue (
        player_id,
        priority_score,
        departure_time,
        is_active,
        joined_at
    )
VALUES (
        v_guest_id,
        v_priority_score,
        p_departure_time,
        true,
        now()
    )
RETURNING id INTO v_queue_id;
EXCEPTION
WHEN unique_violation THEN
SELECT id INTO v_queue_id
FROM queue
WHERE player_id = v_guest_id;
v_reused := true;
END;
-- ================================================================
-- Success Response
-- ================================================================
RETURN jsonb_build_object(
    'success',
    true,
    'player_id',
    v_guest_id,
    'queue_id',
    v_queue_id,
    'reused',
    v_reused,
    'initial_elo',
    v_initial_elo,
    'message',
    CASE
        WHEN v_reused THEN '기존 게스트 프로필 사용.'
        ELSE '새 게스트 등록 완료!'
    END
);
END;
$$;
COMMENT ON FUNCTION register_guest_and_enqueue IS 'Atomic guest registration + queue entry.
Creates guest profile with initial ELO from NTRP, then adds to matchmaking queue.';
-- ============================================================================
-- 3. CANCEL_MATCH
-- ============================================================================
-- Cancels a DRAFT or PLAYING match
-- Returns players to queue if they were removed
-- ============================================================================
CREATE OR REPLACE FUNCTION cancel_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_is_admin BOOLEAN;
v_player_ids UUID [];
BEGIN -- ================================================================
-- STEP 1: Identity Check
-- ================================================================
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED',
    'message',
    '로그인이 필요합니다.'
);
END IF;
-- ================================================================
-- STEP 2: Admin Check
-- ================================================================
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
IF NOT v_is_admin THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ADMIN_REQUIRED',
    'message',
    '관리자만 경기를 취소할 수 있습니다.'
);
END IF;
-- ================================================================
-- STEP 3: Lock and Load Match
-- ================================================================
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'MATCH_NOT_FOUND',
    'message',
    '경기를 찾을 수 없습니다.'
);
END IF;
-- ================================================================
-- STEP 4: Validate Status (can only cancel DRAFT or PLAYING)
-- ================================================================
IF v_match.status NOT IN ('DRAFT', 'PLAYING', 'SCORING') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'CANNOT_CANCEL',
    'message',
    '이 상태에서는 취소할 수 없습니다: ' || v_match.status::TEXT
);
END IF;
-- ================================================================
-- STEP 5: Collect Player IDs
-- ================================================================
v_player_ids := ARRAY [
        v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4
    ];
-- Remove NULLs
SELECT array_agg(x) INTO v_player_ids
FROM unnest(v_player_ids) x
WHERE x IS NOT NULL;
-- ================================================================
-- STEP 6: Update Match Status
-- ================================================================
UPDATE matches
SET status = 'CANCELLED'
WHERE id = p_match_id;
-- ================================================================
-- STEP 7: Cancel Related Bets (return stakes)
-- ================================================================
UPDATE bets
SET result = 'CANCELLED'
WHERE match_id = p_match_id
    AND result IN ('OPEN', 'LOCKED');
-- Return bet amounts to users
UPDATE profiles p
SET rally_point = p.rally_point + b.amount
FROM bets b
WHERE b.match_id = p_match_id
    AND b.result = 'CANCELLED'
    AND p.id = b.user_id;
-- ================================================================
-- STEP 8: Create Audit Log
-- ================================================================
INSERT INTO match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        match_status_before,
        match_status_after,
        confirmation_type
    )
VALUES (
        p_match_id,
        'CANCEL_MATCH',
        v_user_id,
        'ADMIN',
        v_match.status,
        'CANCELLED',
        'ADMIN_CANCEL'
    );
-- ================================================================
-- Success Response
-- ================================================================
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'cancelled_status',
    v_match.status::TEXT,
    'players_affected',
    array_length(v_player_ids, 1),
    'message',
    '경기가 취소되었습니다.'
);
END;
$$;
COMMENT ON FUNCTION cancel_match IS 'Cancel a DRAFT/PLAYING/SCORING match. Admin only.
Cancels related bets and returns stakes.';
-- ============================================================================
-- 4. REPORT_SCORE (if missing - check if exists first)
-- ============================================================================
-- This function may be needed for CourtBoard.tsx score submission
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
BEGIN -- Identity Check
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- Load Match
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- Must be in SCORING status
IF v_match.status != 'SCORING' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '점수 입력은 SCORING 상태에서만 가능합니다.'
);
END IF;
-- Permission check
v_is_participant := v_user_id IN (
    v_match.player_1,
    v_match.player_2,
    v_match.player_3,
    v_match.player_4
);
IF NOT v_is_participant THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
END IF;
-- Update scores
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
    )
WHERE id = p_match_id;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'score_team1',
    p_team1_score,
    'score_team2',
    p_team2_score,
    'message',
    '점수가 기록되었습니다. 확정을 진행해주세요.'
);
END;
$$;
COMMENT ON FUNCTION report_score IS 'Record match scores in SCORING state. Participant only.
Does not finalize match - use finish_match_v2 for that.';