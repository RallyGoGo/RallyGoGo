-- =============================================================================
-- Phase 5: Player Dispute RPC
-- Version: 1.0 | Date: 2026-01-31
-- Purpose: Allow players to dispute a reported score (Strict RPC)
-- =============================================================================
-- -----------------------------------------------------------------------------
-- dispute_match: Reject a score and set status to DISPUTED
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dispute_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
v_user_id UUID := auth.uid();
v_is_participant BOOLEAN;
BEGIN -- [Fetch Match]
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- [Status Check] Must be SCORING to dispute
IF v_match.status != 'SCORING' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'status',
    v_match.status
);
END IF;
-- [Permission Check] Must be a participant
v_is_participant := (
    v_match.player_1 = v_user_id
    OR v_match.player_2 = v_user_id
    OR v_match.player_3 = v_user_id
    OR v_match.player_4 = v_user_id
);
IF NOT v_is_participant THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_PARTICIPANT');
END IF;
-- [Action] Set to DISPUTED
UPDATE matches
SET status = 'DISPUTED',
    confirmed_by = NULL -- Reset any partial confirmation if applicable
WHERE id = p_match_id;
-- [Audit Log]
INSERT INTO match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        match_status_before,
        match_status_after,
        correction_reason
    )
VALUES (
        p_match_id,
        'DISPUTE_SCORE',
        v_user_id,
        'player',
        'SCORING',
        'DISPUTED',
        'Player disputed the reported score'
    );
RETURN jsonb_build_object(
    'success',
    true,
    'message',
    'Match disputed successfully'
);
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION dispute_match(UUID) TO authenticated;