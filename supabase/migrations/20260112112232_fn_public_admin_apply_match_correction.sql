CREATE OR REPLACE FUNCTION public.admin_apply_match_correction(p_audit_log_id uuid, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_audit_log public.match_audit_log %ROWTYPE;
v_match public.matches %ROWTYPE;
v_old_history_list RECORD;
v_player_ids UUID [];
v_player_id UUID;
-- Calculation Vars
v_team1_rating NUMERIC := 0;
v_team2_rating NUMERIC := 0;
v_team1_count INTEGER := 0;
v_team2_count INTEGER := 0;
v_p1_expected NUMERIC;
v_p1_actual NUMERIC;
v_base_delta NUMERIC;
v_old_delta INTEGER;
v_new_delta INTEGER;
v_net_diff INTEGER;
v_k_factor INT;
v_base_multiplier NUMERIC;
v_guest_multiplier NUMERIC;
v_applied_multiplier NUMERIC;
-- Loop Vars
v_h RECORD;
v_profile RECORD;
v_is_team1 BOOLEAN;
v_is_guest BOOLEAN;
-- Response
v_affected_players JSONB := '[]'::jsonb;
v_op_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
-- 1. Security Check
IF v_current_uid IS NULL
OR v_current_uid != p_admin_id THEN RETURN jsonb_build_object('error', 'IDENTITY_MISMATCH');
END IF;
IF NOT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = p_admin_id
        AND role = 'admin'
) THEN RETURN jsonb_build_object('error', 'PERMISSION_DENIED');
END IF;
-- 2. Fetch Audit Log
SELECT * INTO v_audit_log
FROM public.match_audit_log
WHERE id = p_audit_log_id FOR
UPDATE;
IF v_audit_log IS NULL THEN RETURN jsonb_build_object('error', 'AUDIT_LOG_NOT_FOUND');
END IF;
IF v_audit_log.action <> 'ADMIN_CORRECTION' THEN RETURN jsonb_build_object('error', 'INVALID_ACTION_TYPE');
END IF;
IF v_audit_log.related_action_id IS NOT NULL THEN RETURN jsonb_build_object('error', 'ALREADY_APPLIED');
END IF;
-- 3. Fetch Match & Lock
SELECT * INTO v_match
FROM public.matches
WHERE id = v_audit_log.match_id FOR
UPDATE;
-- 4. Reconstruct Original State (Pre-Calculation)
-- We need the 'old_rating' from the original history entries to recalculate expectations correctly.
-- Assuming team composition hasn't changed (correction is usually about score).
-- Fetch Original History
-- We assume the 'latest' non-correction history for this match is the one we want to revert.
-- Or simply all non-correction history for this match.
FOR v_h IN
SELECT *
FROM public.elo_history
WHERE match_id = v_match.id
    AND is_correction = false LOOP -- Accumulate Team Ratings based on ORIGINAL STARTING RATING
    IF v_h.player_id IN (v_match.player_1, v_match.player_2) THEN v_team1_rating := v_team1_rating + v_h.old_rating;
v_team1_count := v_team1_count + 1;
ELSIF v_h.player_id IN (v_match.player_3, v_match.player_4) THEN v_team2_rating := v_team2_rating + v_h.old_rating;
v_team2_count := v_team2_count + 1;
END IF;
END LOOP;
IF v_team1_count = 0
OR v_team2_count = 0 THEN RETURN jsonb_build_object('error', 'HISTORY_INTEGRITY_FAILURE');
END IF;
v_team1_rating := v_team1_rating / v_team1_count;
v_team2_rating := v_team2_rating / v_team2_count;
-- 5. Calculate New Delta (Based on Corrected Scores)
-- v_audit_log.score_team1 is the CORRECTED score
-- Expected
v_p1_expected := 1.0 / (
    1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0)
);
-- Actual (Corrected)
IF v_audit_log.score_team1 > v_audit_log.score_team2 THEN v_p1_actual := 1.0;
ELSIF v_audit_log.score_team1 < v_audit_log.score_team2 THEN v_p1_actual := 0.0;
ELSE v_p1_actual := 0.5;
END IF;
-- Policy
SELECT k_factor,
    multiplier INTO v_k_factor,
    v_base_multiplier
FROM public.get_elo_policy(false);
SELECT multiplier INTO v_guest_multiplier
FROM public.get_elo_policy(true);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
-- 6. Apply Deltas
FOR v_h IN
SELECT *
FROM public.elo_history
WHERE match_id = v_match.id
    AND is_correction = false LOOP v_old_delta := v_h.new_rating - v_h.old_rating;
-- Determine direction & multiplier for NEW delta
v_is_team1 := v_h.player_id IN (v_match.player_1, v_match.player_2);
IF v_is_team1 THEN v_new_delta := ROUND(v_base_delta);
ELSE v_new_delta := ROUND(v_base_delta * -1);
END IF;
-- Check Role for Multiplier
SELECT is_guest INTO v_is_guest
FROM public.profiles
WHERE id = v_h.player_id;
IF v_is_guest THEN v_applied_multiplier := v_guest_multiplier;
ELSE v_applied_multiplier := v_base_multiplier;
END IF;
IF v_applied_multiplier <> 1.0 THEN v_new_delta := ROUND(v_new_delta * v_applied_multiplier);
END IF;
-- Net Difference
v_net_diff := v_new_delta - v_old_delta;
-- Update Profile (Current Rating + Net Diff)
UPDATE public.profiles
SET elo_mixed_doubles = elo_mixed_doubles + v_net_diff
WHERE id = v_h.player_id;
-- Insert Correction History
INSERT INTO public.elo_history (
        match_id,
        player_id,
        old_rating,
        new_rating,
        is_correction,
        related_history_id
    )
VALUES (
        v_match.id,
        v_h.player_id,
        v_h.new_rating,
        -- 'Old' for correction is validly the 'New' of the previous entry?
        -- Or should we log the shift?
        -- Standard: old_rating = Current Profile Rating Before Update?
        -- Let's stick to Tracking the Delta.
        -- Actually, explicit audit trail: old_rating = v_h.new_rating (state after error), new_rating = v_h.new_rating + net_diff (corrected state).
        v_h.new_rating,
        v_h.new_rating + v_net_diff,
        true,
        v_h.id
    );
v_affected_players := v_affected_players || jsonb_build_object(
    'player_id',
    v_h.player_id,
    'old_delta',
    v_old_delta,
    'new_delta',
    v_new_delta,
    'net_diff',
    v_net_diff
);
END LOOP;
-- 7. Update Match Record (Scores)
UPDATE public.matches
SET score_team1 = v_audit_log.score_team1,
    score_team2 = v_audit_log.score_team2,
    status = 'FINISHED' -- Ensure it stays finished
WHERE id = v_match.id;
-- 8. Mark Audit Log as Applied
INSERT INTO public.admin_operation_log (
        target_type,
        target_id,
        action,
        old_value,
        new_value,
        reason,
        operated_by
    )
VALUES (
        'MATCH',
        v_match.id,
        'APPLY_MATCH_CORRECTION',
        'Log: ' || p_audit_log_id,
        'Applied',
        v_audit_log.correction_reason,
        p_admin_id
    )
RETURNING id INTO v_op_log_id;
UPDATE public.match_audit_log
SET related_action_id = v_op_log_id
WHERE id = p_audit_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.2',
    'affected_players',
    v_affected_players,
    'elo_delta_reverted',
    true,
    'elo_delta_applied',
    true
);
END;
$function$;

