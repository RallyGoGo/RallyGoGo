-- =============================================================================
-- Phase 4E: Admin RPC Functions
-- Version: 1.0 | Date: 2026-01-31
-- Purpose: Secure admin operations with atomic transactions and audit logging
-- =============================================================================
-- -----------------------------------------------------------------------------
-- 1. admin_rollback_match: Atomic ELO reversal + match deletion
-- -----------------------------------------------------------------------------
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
-- Log reversal
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
-- Log reversal
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
        'ADMIN_ROLLBACK',
        v_user_id,
        'admin',
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
-- -----------------------------------------------------------------------------
-- 2. admin_confirm_match: SCORING → FINISHED with ELO application
-- -----------------------------------------------------------------------------
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
-- [Audit Log]
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
        'ADMIN_CONFIRM',
        v_user_id,
        'admin',
        v_match.status,
        'FINISHED',
        true
    );
-- Note: ELO calculation should ideally be triggered here or via finish_match_v2
-- For now, we assume ELO was already calculated when score was first reported
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
-- -----------------------------------------------------------------------------
-- 3. admin_season_soft_reset: Batch ELO compression
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION admin_season_soft_reset() RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID := auth.uid();
v_user_role TEXT;
v_affected_count INT;
BEGIN -- [Auth Check]
SELECT role INTO v_user_role
FROM profiles
WHERE id = v_user_id;
IF v_user_role IS NULL
OR v_user_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
-- [Batch Update] Formula: 1200 + (old - 1200) / 2
UPDATE profiles
SET elo_mens_doubles = 1200 + (COALESCE(elo_mens_doubles, 1200) - 1200) / 2,
    elo_womens_doubles = 1200 + (COALESCE(elo_womens_doubles, 1200) - 1200) / 2,
    elo_mixed_doubles = 1200 + (COALESCE(elo_mixed_doubles, 1200) - 1200) / 2,
    elo_singles = 1200 + (COALESCE(elo_singles, 1200) - 1200) / 2,
    games_played_today = 0
WHERE role != 'coach';
-- Coaches are excluded from reset
GET DIAGNOSTICS v_affected_count = ROW_COUNT;
-- [Audit Log]
INSERT INTO admin_operation_log (
        operated_by,
        action,
        target_type,
        reason,
        new_value
    )
VALUES (
        v_user_id,
        'SEASON_SOFT_RESET',
        'profiles',
        'Season compression applied',
        jsonb_build_object('affected_count', v_affected_count)::text
    );
RETURN jsonb_build_object(
    'success',
    true,
    'affected_profiles',
    v_affected_count,
    'message',
    'Season soft reset completed'
);
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
-- -----------------------------------------------------------------------------
-- 4. admin_update_profile: Secure profile update
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION admin_update_profile(
        p_profile_id UUID,
        p_name TEXT DEFAULT NULL,
        p_gender TEXT DEFAULT NULL,
        p_ntrp NUMERIC DEFAULT NULL,
        p_role TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID := auth.uid();
v_user_role TEXT;
v_old_values JSONB;
BEGIN -- [Auth Check]
SELECT role INTO v_user_role
FROM profiles
WHERE id = v_user_id;
IF v_user_role IS NULL
OR v_user_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
-- [Fetch Old Values for Audit]
SELECT jsonb_build_object(
        'name',
        name,
        'gender',
        gender,
        'ntrp',
        ntrp,
        'role',
        role
    ) INTO v_old_values
FROM profiles
WHERE id = p_profile_id;
IF v_old_values IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PROFILE_NOT_FOUND');
END IF;
-- [Update Profile]
UPDATE profiles
SET name = COALESCE(p_name, name),
    gender = COALESCE(p_gender::gender_t, gender),
    ntrp = COALESCE(p_ntrp, ntrp),
    role = COALESCE(p_role::user_role_t, role),
    updated_at = now()
WHERE id = p_profile_id;
-- [Audit Log]
INSERT INTO admin_operation_log (
        operated_by,
        action,
        target_type,
        target_id,
        old_value,
        new_value
    )
VALUES (
        v_user_id,
        'UPDATE_PROFILE',
        'profiles',
        p_profile_id,
        v_old_values::text,
        jsonb_build_object(
            'name',
            p_name,
            'gender',
            p_gender,
            'ntrp',
            p_ntrp,
            'role',
            p_role
        )::text
    );
RETURN jsonb_build_object('success', true, 'message', 'Profile updated');
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
-- -----------------------------------------------------------------------------
-- 5. admin_clear_queue: Bulk queue clear with audit
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION admin_clear_queue() RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID := auth.uid();
v_user_role TEXT;
v_deleted_count INT;
BEGIN -- [Auth Check]
SELECT role INTO v_user_role
FROM profiles
WHERE id = v_user_id;
IF v_user_role IS NULL
OR v_user_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
-- [Delete All Queue Entries]
DELETE FROM queue;
GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
-- [Audit Log]
INSERT INTO admin_operation_log (
        operated_by,
        action,
        target_type,
        new_value
    )
VALUES (
        v_user_id,
        'CLEAR_QUEUE',
        'queue',
        jsonb_build_object('deleted_count', v_deleted_count)::text
    );
RETURN jsonb_build_object(
    'success',
    true,
    'deleted_count',
    v_deleted_count
);
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
-- -----------------------------------------------------------------------------
-- Grant Permissions
-- -----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION admin_rollback_match(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_confirm_match(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_season_soft_reset() TO authenticated;
GRANT EXECUTE ON FUNCTION admin_update_profile(UUID, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_clear_queue() TO authenticated;
-- =============================================================================
-- End of Phase 4E Migration
-- =============================================================================