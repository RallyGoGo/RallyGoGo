-- =============================================================================
-- FIX: Relax Match Operation Permissions (PDCA)
-- Purpose: Allow any authenticated user (e.g., via shared tablet or admin) 
-- to Start, End, Cancel matches and Report scores without strict role checks.
-- This resolves "ADMIN_REQUIRED" and "PERMISSION_DENIED" errors during field usage.
-- =============================================================================
-- 1. start_match (Remove Admin Check)
CREATE OR REPLACE FUNCTION start_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- [REMOVED] Admin Check
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status != 'DRAFT' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    'DRAFT 상태만 시작 가능.'
);
END IF;
-- UPDATE STATUS & SET BETTING DEADLINE (5 mins)
UPDATE matches
SET status = 'PLAYING',
    start_time = now(),
    betting_closes_at = now() + interval '5 minutes'
WHERE id = p_match_id;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'status',
    'PLAYING',
    'message',
    '경기가 시작되었습니다. (배팅 5분간 가능)'
);
END;
$$;
-- 2. end_match (Remove Participant/Admin Check)
CREATE OR REPLACE FUNCTION end_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
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
IF v_match.status != 'PLAYING' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '진행 중인 경기만 종료할 수 있습니다.'
);
END IF;
-- [REMOVED] Participant/Admin Check -> Allow any authenticated user
UPDATE matches
SET status = 'SCORING',
    end_time = now()
WHERE id = p_match_id;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'new_status',
    'SCORING',
    'message',
    '경기가 종료되었습니다. 점수를 입력해주세요.'
);
END;
$$;
-- 3. cancel_match (Remove Admin Check)
CREATE OR REPLACE FUNCTION cancel_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_player_ids UUID [];
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- [REMOVED] Admin Check -> Allow any authenticated user to cancel (e.g. mistake correction)
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status NOT IN ('DRAFT', 'PLAYING', 'SCORING') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'CANNOT_CANCEL',
    'message',
    '취소 불가 상태입니다.'
);
END IF;
-- Update Status
UPDATE matches
SET status = 'CANCELLED'
WHERE id = p_match_id;
-- Cancel Bets & Refund
UPDATE bets
SET result = 'CANCELLED'
WHERE match_id = p_match_id
    AND result IN ('OPEN', 'LOCKED');
UPDATE profiles p
SET rally_point = p.rally_point + b.amount
FROM bets b
WHERE b.match_id = p_match_id
    AND b.result = 'CANCELLED'
    AND p.id = b.user_id;
-- Audit Log
INSERT INTO match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        match_status_before,
        match_status_after
    )
VALUES (
        p_match_id,
        'CANCEL_MATCH',
        v_user_id,
        'USER',
        v_match.status,
        'CANCELLED'
    );
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'message',
    '경기가 취소되었습니다.'
);
END;
$$;
-- 4. report_score (Remove Participant Check)
CREATE OR REPLACE FUNCTION report_score(
        p_match_id UUID,
        p_team1_score INTEGER,
        p_team2_score INTEGER,
        p_winner TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
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
IF v_match.status != 'SCORING' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '점수 입력은 SCORING 상태에서만 가능합니다.'
);
END IF;
-- [REMOVED] Participant Check -> Allow any authenticated user (e.g. referee/admin)
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
RETURN jsonb_build_object('success', true, 'message', '점수가 기록되었습니다.');
END;
$$;