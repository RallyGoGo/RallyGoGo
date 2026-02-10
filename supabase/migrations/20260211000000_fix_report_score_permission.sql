-- ============================================================================
-- FIX: Report Score Permission (Allow Admin)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.report_score(
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
BEGIN -- 1. Identity Check
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- 2. Load Match
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- 3. Check Admin Status
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
-- 4. Check Participant Status
v_is_participant := v_user_id IN (
    v_match.player_1,
    v_match.player_2,
    v_match.player_3,
    v_match.player_4
);
-- 5. Permission Enforcement (Participant OR Admin)
IF NOT v_is_participant
AND NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
END IF;
-- 6. Status Validation (Admin can override status check theoretically, 
-- but keeping it strict to SCORING unless we want Admin to force it. 
-- Let's stick to SCORING for now as per workflow.)
IF v_match.status != 'SCORING' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '점수 입력은 SCORING 상태에서만 가능합니다.'
);
END IF;
-- 7. Update Scores
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
    reported_by = v_user_id -- Track who reported it
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
-- Ensure permission is granted
GRANT EXECUTE ON FUNCTION public.report_score(UUID, INTEGER, INTEGER, TEXT) TO authenticated,
    service_role;