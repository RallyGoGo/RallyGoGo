-- ============================================================================
-- UPDATE: report_score should set status to 'PENDING'
-- This frees up the court for the next match immediately.
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
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
v_is_participant := v_user_id IN (
    v_match.player_1,
    v_match.player_2,
    v_match.player_3,
    v_match.player_4
);
IF NOT v_is_participant
AND NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
END IF;
-- Allow PENDING update too (in case of correction)
IF v_match.status != 'SCORING'
AND v_match.status != 'PENDING' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    '점수 입력은 SCORING 상태에서만 가능합니다.'
);
END IF;
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
    status = 'PENDING' -- ✅ Set status to PENDING to free the court
WHERE id = p_match_id;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'status',
    'PENDING',
    'message',
    '점수가 기록되었습니다. 승인 대기 상태로 전환됩니다.'
);
END;
$$;