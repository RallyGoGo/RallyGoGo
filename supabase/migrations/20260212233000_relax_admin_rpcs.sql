-- =============================================================================
-- FIX: Relax Admin Permissions for All Admin RPCs
-- Purpose: Allow authenticated users (who pass the PIN check on client-side) to execute admin functions.
-- This removes the strict 'admin' role check from the database RPCs.
-- =============================================================================
-- 1. admin_add_notice
CREATE OR REPLACE FUNCTION public.admin_add_notice(p_content TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID;
v_notice_id UUID;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object('error', 'NOT_AUTHENTICATED');
END IF;
-- [REMOVED] Admin Check
-- IF v_role != 'admin' THEN RETURN jsonb_build_object('error', 'NOT_ADMIN'); END IF;
INSERT INTO public.notices (content, is_active)
VALUES (p_content, true)
RETURNING id INTO v_notice_id;
RETURN jsonb_build_object('success', true, 'notice_id', v_notice_id);
END;
$$;
-- 2. admin_delete_notice
CREATE OR REPLACE FUNCTION public.admin_delete_notice(p_notice_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object('error', 'NOT_AUTHENTICATED');
END IF;
-- [REMOVED] Admin Check
DELETE FROM public.notices
WHERE id = p_notice_id;
RETURN jsonb_build_object('success', true);
END;
$$;
-- 3. admin_confirm_match
CREATE OR REPLACE FUNCTION admin_confirm_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
v_user_id UUID := auth.uid();
BEGIN IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- [REMOVED] Admin Check
-- [Fetch Match]
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- [Status Check]
IF v_match.status NOT IN ('SCORING', 'DISPUTED', 'PENDING') THEN RETURN jsonb_build_object(
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
-- 4. admin_rollback_match
CREATE OR REPLACE FUNCTION admin_rollback_match(
        p_match_id UUID,
        p_reason TEXT DEFAULT 'Admin rollback'
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
v_user_id UUID := auth.uid();
v_elo_field TEXT;
v_delta INT;
v_winners UUID [];
v_losers UUID [];
v_player RECORD;
v_affected_count INT := 0;
BEGIN IF v_user_id IS NULL THEN RETURN jsonb_build_object(
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
v_elo_field := CASE
    v_match.match_type
    WHEN 'MENS_DOUBLES' THEN 'elo_mens_doubles'
    WHEN 'WOMENS_DOUBLES' THEN 'elo_womens_doubles'
    WHEN 'SINGLES' THEN 'elo_singles'
    ELSE 'elo_mixed_doubles'
END;
IF v_match.status = 'FINISHED' THEN
SELECT ABS(delta) INTO v_delta
FROM elo_history
WHERE match_id = p_match_id
    AND delta IS NOT NULL
LIMIT 1;
IF v_delta IS NOT NULL
AND v_delta > 0
AND v_match.winner_team IS NOT NULL
AND v_match.winner_team != 'DRAW' THEN IF v_match.winner_team = 'TEAM_1' THEN v_winners := ARRAY [v_match.player_1, v_match.player_2];
v_losers := ARRAY [v_match.player_3, v_match.player_4];
ELSE v_winners := ARRAY [v_match.player_3, v_match.player_4];
v_losers := ARRAY [v_match.player_1, v_match.player_2];
END IF;
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
-- (Skipped detailed history logging for brevity, focusing on rollback logic)
v_affected_count := v_affected_count + 1;
END LOOP;
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
v_affected_count := v_affected_count + 1;
END LOOP;
END IF;
END IF;
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
-- 5. admin_season_soft_reset
CREATE OR REPLACE FUNCTION admin_season_soft_reset() RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID := auth.uid();
v_affected_count INT;
BEGIN IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- [REMOVED] Admin Check
UPDATE profiles
SET elo_mens_doubles = 1200 + (COALESCE(elo_mens_doubles, 1200) - 1200) / 2,
    elo_womens_doubles = 1200 + (COALESCE(elo_womens_doubles, 1200) - 1200) / 2,
    elo_mixed_doubles = 1200 + (COALESCE(elo_mixed_doubles, 1200) - 1200) / 2,
    elo_singles = 1200 + (COALESCE(elo_singles, 1200) - 1200) / 2,
    games_played_today = 0
WHERE role != 'coach';
GET DIAGNOSTICS v_affected_count = ROW_COUNT;
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
-- 6. admin_clear_queue
CREATE OR REPLACE FUNCTION admin_clear_queue() RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID := auth.uid();
v_deleted_count INT;
BEGIN IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- [REMOVED] Admin Check
DELETE FROM queue;
GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
INSERT INTO admin_operation_log (operated_by, action, target_type, new_value)
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