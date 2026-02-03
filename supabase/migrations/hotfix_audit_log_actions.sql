-- =============================================================================
-- Hotfix: Fix audit log action values to match constraint
-- Date: 2026-02-03
-- =============================================================================
-- The match_audit_log table has a CHECK constraint that only allows these actions:
-- 'CONFIRM_MATCH', 'ADMIN_CORRECTION', 'ADMIN_FORCE_CONFIRM', 'STATUS_CHANGE', 'SCORE_UPDATE', 'CANCEL_MATCH'
--
-- The RPCs were using invalid action values:
-- - admin_confirm_match: 'ADMIN_CONFIRM' → 'ADMIN_FORCE_CONFIRM'
-- - admin_rollback_match: 'ADMIN_ROLLBACK' → 'CANCEL_MATCH'
-- =============================================================================
-- Fix admin_confirm_match
CREATE OR REPLACE FUNCTION admin_confirm_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
v_user_id UUID := auth.uid();
v_user_role TEXT;
BEGIN -- [Auth Check]
SELECT role INTO v_user_role
FROM profiles
WHERE id = v_user_id;
IF v_user_role IS NULL
OR v_user_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
-- [Fetch Match]
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- [Status Check]
IF v_match.status NOT IN ('SCORING', 'DISPUTED') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'current_status',
    v_match.status
);
END IF;
-- [Update Status]
UPDATE matches
SET status = 'FINISHED',
    confirmed_by = v_user_id,
    end_time = COALESCE(end_time, now())
WHERE id = p_match_id;
-- [Audit Log] - FIXED: Use 'ADMIN_FORCE_CONFIRM' instead of 'ADMIN_CONFIRM'
INSERT INTO match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        match_status_before,
        match_status_after,
        is_force_confirm
    )
VALUES (
        p_match_id,
        'ADMIN_FORCE_CONFIRM',
        v_user_id,
        'ADMIN',
        v_match.status,
        'FINISHED',
        true
    );
RETURN jsonb_build_object(
    'success',
    true,
    'message',
    'Match confirmed by admin'
);
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
-- Fix admin_rollback_match
CREATE OR REPLACE FUNCTION admin_rollback_match(
        p_match_id UUID,
        p_reason TEXT DEFAULT 'Admin rollback'
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
v_user_id UUID := auth.uid();
v_user_role TEXT;
v_elo_field TEXT;
v_delta INT;
v_winners UUID [];
v_losers UUID [];
v_player RECORD;
v_affected_count INT := 0;
BEGIN -- [Auth Check] Verify admin role
SELECT role INTO v_user_role
FROM profiles
WHERE id = v_user_id;
IF v_user_role IS NULL
OR v_user_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
-- [Lock & Fetch] Get match with FOR UPDATE lock
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- [Determine ELO Field]
v_elo_field := CASE
    v_match.match_type
    WHEN 'MENS_DOUBLES' THEN 'elo_mens_doubles'
    WHEN 'WOMENS_DOUBLES' THEN 'elo_womens_doubles'
    WHEN 'SINGLES' THEN 'elo_singles'
    ELSE 'elo_mixed_doubles'
END;
-- [ELO Reversal] Only for FINISHED matches with non-zero delta
IF v_match.status = 'FINISHED' THEN -- Get delta from elo_history (most recent entry for this match)
SELECT ABS(delta) INTO v_delta
FROM elo_history
WHERE match_id = p_match_id
    AND delta IS NOT NULL
LIMIT 1;
IF v_delta IS NOT NULL
AND v_delta > 0
AND v_match.winner_team IS NOT NULL
AND v_match.winner_team != 'DRAW' THEN -- Determine winners and losers
IF v_match.winner_team = 'TEAM_1' THEN v_winners := ARRAY [v_match.player_1, v_match.player_2];
v_losers := ARRAY [v_match.player_3, v_match.player_4];
ELSE v_winners := ARRAY [v_match.player_3, v_match.player_4];
v_losers := ARRAY [v_match.player_1, v_match.player_2];
END IF;
-- Revert winners (subtract delta)
FOR v_player IN
SELECT id
FROM profiles
WHERE id = ANY(v_winners) FOR
UPDATE LOOP EXECUTE format(
        'UPDATE profiles SET %I = COALESCE(%I, 1200) - $1 WHERE id = $2',
        v_elo_field,
        v_elo_field
    ) USING v_delta,
    v_player.id;
INSERT INTO elo_history (
        player_id,
        match_id,
        match_type,
        old_rating,
        new_rating,
        delta,
        is_correction
    )
SELECT v_player.id,
    p_match_id,
    v_match.match_type,
    COALESCE(
        (
            SELECT new_rating
            FROM elo_history
            WHERE player_id = v_player.id
            ORDER BY created_at DESC
            LIMIT 1
        ), 1200
    ), COALESCE(
        (
            SELECT new_rating
            FROM elo_history
            WHERE player_id = v_player.id
            ORDER BY created_at DESC
            LIMIT 1
        ), 1200
    ) - v_delta, - v_delta, true;
v_affected_count := v_affected_count + 1;
END LOOP;
-- Revert losers (add delta)
FOR v_player IN
SELECT id
FROM profiles
WHERE id = ANY(v_losers) FOR
UPDATE LOOP EXECUTE format(
        'UPDATE profiles SET %I = COALESCE(%I, 1200) + $1 WHERE id = $2',
        v_elo_field,
        v_elo_field
    ) USING v_delta,
    v_player.id;
INSERT INTO elo_history (
        player_id,
        match_id,
        match_type,
        old_rating,
        new_rating,
        delta,
        is_correction
    )
SELECT v_player.id,
    p_match_id,
    v_match.match_type,
    COALESCE(
        (
            SELECT new_rating
            FROM elo_history
            WHERE player_id = v_player.id
            ORDER BY created_at DESC
            LIMIT 1
        ), 1200
    ), COALESCE(
        (
            SELECT new_rating
            FROM elo_history
            WHERE player_id = v_player.id
            ORDER BY created_at DESC
            LIMIT 1
        ), 1200
    ) + v_delta, v_delta, true;
v_affected_count := v_affected_count + 1;
END LOOP;
END IF;
END IF;
-- [Audit Log] - FIXED: Use 'CANCEL_MATCH' instead of 'ADMIN_ROLLBACK'
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
        'CANCEL_MATCH',
        v_user_id,
        'ADMIN',
        v_match.status,
        'CANCELLED',
        p_reason
    );
-- [Delete Match] (or set to CANCELLED if you prefer soft delete)
DELETE FROM matches
WHERE id = p_match_id;
RETURN jsonb_build_object(
    'success',
    true,
    'affected_players',
    v_affected_count,
    'message',
    'Match rolled back successfully'
);
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
-- Ensure permissions
GRANT EXECUTE ON FUNCTION admin_confirm_match(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_rollback_match(UUID, TEXT) TO authenticated;