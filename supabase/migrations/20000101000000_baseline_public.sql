


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."admin_adjust_rating"("p_player_id" "uuid", "p_new_rating" integer, "p_admin_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_old_rating INT;
v_diff INT;
v_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
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
SELECT elo_mixed_doubles INTO v_old_rating
FROM public.profiles
WHERE id = p_player_id;
IF v_old_rating IS NULL THEN RETURN jsonb_build_object('error', 'PLAYER_NOT_FOUND');
END IF;
v_diff := ABS(p_new_rating - v_old_rating);
IF v_diff > 300 THEN RETURN jsonb_build_object('error', 'ADJUSTMENT_EXCEEDS_LIMIT');
END IF;
UPDATE public.profiles
SET elo_mixed_doubles = p_new_rating
WHERE id = p_player_id;
INSERT INTO public.rating_adjustment_log (
        player_id,
        old_rating,
        new_rating,
        reason,
        adjusted_by
    )
VALUES (
        p_player_id,
        v_old_rating,
        p_new_rating,
        p_reason,
        p_admin_id
    )
RETURNING id INTO v_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'action_id',
    v_log_id,
    'old',
    v_old_rating,
    'new',
    p_new_rating
);
END;
$$;


ALTER FUNCTION "public"."admin_adjust_rating"("p_player_id" "uuid", "p_new_rating" integer, "p_admin_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_apply_match_correction"("p_audit_log_id" "uuid", "p_admin_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_audit_log public.match_audit_log %ROWTYPE;
v_match public.matches %ROWTYPE;
v_old_history_list RECORD;
v_player_ids UUID [];
v_player_id UUID;
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
v_h RECORD;
v_profile RECORD;
v_is_team1 BOOLEAN;
v_is_guest BOOLEAN;
v_affected_players JSONB := '[]'::jsonb;
v_op_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
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
SELECT * INTO v_match
FROM public.matches
WHERE id = v_audit_log.match_id FOR
UPDATE;
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
v_p1_expected := 1.0 / (
    1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0)
);
IF v_audit_log.score_team1 > v_audit_log.score_team2 THEN v_p1_actual := 1.0;
ELSIF v_audit_log.score_team1 < v_audit_log.score_team2 THEN v_p1_actual := 0.0;
ELSE v_p1_actual := 0.5;
END IF;
SELECT k_factor,
    multiplier INTO v_k_factor,
    v_base_multiplier
FROM public.get_elo_policy(false);
SELECT multiplier INTO v_guest_multiplier
FROM public.get_elo_policy(true);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
FOR v_h IN
SELECT *
FROM public.elo_history
WHERE match_id = v_match.id
    AND is_correction = false LOOP v_old_delta := v_h.new_rating - v_h.old_rating;
v_is_team1 := v_h.player_id IN (v_match.player_1, v_match.player_2);
IF v_is_team1 THEN v_new_delta := ROUND(v_base_delta);
ELSE v_new_delta := ROUND(v_base_delta * -1);
END IF;
SELECT is_guest INTO v_is_guest
FROM public.profiles
WHERE id = v_h.player_id;
IF v_is_guest THEN v_applied_multiplier := v_guest_multiplier;
ELSE v_applied_multiplier := v_base_multiplier;
END IF;
IF v_applied_multiplier <> 1.0 THEN v_new_delta := ROUND(v_new_delta * v_applied_multiplier);
END IF;
v_net_diff := v_new_delta - v_old_delta;
UPDATE public.profiles
SET elo_mixed_doubles = elo_mixed_doubles + v_net_diff
WHERE id = v_h.player_id;
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
UPDATE public.matches
SET score_team1 = v_audit_log.score_team1,
    score_team2 = v_audit_log.score_team2,
    status = 'FINISHED' -- Ensure it stays finished
WHERE id = v_match.id;
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
$$;


ALTER FUNCTION "public"."admin_apply_match_correction"("p_audit_log_id" "uuid", "p_admin_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_clear_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_old_count INT;
v_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
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
SELECT no_show_count INTO v_old_count
FROM public.queue
WHERE player_id = p_player_id FOR
UPDATE;
IF v_old_count IS NULL THEN v_old_count := 0;
END IF;
UPDATE public.queue
SET no_show_count = 0
WHERE player_id = p_player_id;
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
        'QUEUE',
        p_player_id,
        'CLEAR_NO_SHOW',
        v_old_count::text,
        '0',
        'Admin Manual Clear',
        p_admin_id
    )
RETURNING id INTO v_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'action_id',
    v_log_id,
    'old_count',
    v_old_count
);
END;
$$;


ALTER FUNCTION "public"."admin_clear_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_correct_match_result"("p_match_id" "uuid", "p_correct_score1" integer, "p_correct_score2" integer, "p_admin_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_match_exists BOOLEAN;
v_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
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
SELECT EXISTS(
        SELECT 1
        FROM public.matches
        WHERE id = p_match_id
            AND status = 'FINISHED'
    ) INTO v_match_exists;
IF NOT v_match_exists THEN RETURN jsonb_build_object('error', 'MATCH_NOT_FOUND_OR_NOT_FINISHED');
END IF;
INSERT INTO public.match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        confirmation_type,
        is_force_confirm,
        match_status_before,
        match_status_after,
        score_team1,
        score_team2,
        correction_reason
    )
VALUES (
        p_match_id,
        'ADMIN_CORRECTION',
        p_admin_id,
        'ADMIN',
        'ADMIN_CORRECTION',
        true,
        'FINISHED',
        'FINISHED',
        p_correct_score1,
        p_correct_score2,
        p_reason
    )
RETURNING id INTO v_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'action_id',
    v_log_id
);
END;
$$;


ALTER FUNCTION "public"."admin_correct_match_result"("p_match_id" "uuid", "p_correct_score1" integer, "p_correct_score2" integer, "p_admin_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_mark_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_old_count INT;
v_new_count INT;
v_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
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
UPDATE public.queue
SET no_show_count = COALESCE(no_show_count, 0) + 1,
    last_no_show_at = NOW()
WHERE player_id = p_player_id
RETURNING (no_show_count - 1),
    no_show_count INTO v_old_count,
    v_new_count;
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
        'QUEUE',
        p_player_id,
        'MARK_NO_SHOW',
        v_old_count::text,
        v_new_count::text,
        'Admin Manual Mark',
        p_admin_id
    )
RETURNING id INTO v_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'action_id',
    v_log_id
);
END;
$$;


ALTER FUNCTION "public"."admin_mark_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_merge_profile"("p_source" "uuid", "p_target" "uuid", "p_merged_by" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
IF v_current_uid IS NULL
OR v_current_uid != p_merged_by THEN RETURN jsonb_build_object('error', 'IDENTITY_MISMATCH');
END IF;
IF NOT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = p_merged_by
        AND role = 'admin'
) THEN RETURN jsonb_build_object('error', 'PERMISSION_DENIED');
END IF;
IF p_source = p_target THEN RETURN jsonb_build_object('error', 'CANNOT_MERGE_SAME_PROFILE');
END IF;
INSERT INTO public.profile_merge_log (
        source_profile,
        target_profile,
        merged_by
    )
VALUES (p_source, p_target, p_merged_by)
RETURNING id INTO v_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'action_id',
    v_log_id
);
END;
$$;


ALTER FUNCTION "public"."admin_merge_profile"("p_source" "uuid", "p_target" "uuid", "p_merged_by" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_prepare_undo"("p_target_correction_id" "uuid", "p_admin_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_target_log public.match_audit_log %ROWTYPE;
v_prev_log public.match_audit_log %ROWTYPE;
v_new_audit_log_id UUID;
v_match_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
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
SELECT * INTO v_target_log
FROM public.match_audit_log
WHERE id = p_target_correction_id;
IF v_target_log IS NULL THEN RETURN jsonb_build_object('error', 'TARGET_NOT_FOUND');
END IF;
IF v_target_log.correction_status != 'APPLIED' THEN RETURN jsonb_build_object('error', 'TARGET_NOT_APPLIED');
END IF;
IF EXISTS (
    SELECT 1
    FROM public.match_audit_log
    WHERE COALESCE(correction_chain_id, id) = COALESCE(
            v_target_log.correction_chain_id,
            v_target_log.id
        )
        AND correction_status = 'APPLIED'
        AND created_at > v_target_log.created_at
) THEN RETURN jsonb_build_object(
    'error',
    'CHAIN_INTEGRITY_VIOLATION: Traget is not the latest applied correction.'
);
END IF;
v_match_id := v_target_log.match_id;
SELECT * INTO v_prev_log
FROM public.match_audit_log
WHERE match_id = v_match_id
    AND created_at < v_target_log.created_at
ORDER BY created_at DESC
LIMIT 1;
IF v_prev_log IS NULL THEN -- This implies we are trying to undo the very first action? 
RETURN jsonb_build_object(
    'error',
    'HISTORY_GAP: Cannot find previous state to revert to.'
);
END IF;
INSERT INTO public.match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        score_team1,
        score_team2,
        correction_reason,
        correction_status,
        correction_chain_id
    )
VALUES (
        v_match_id,
        'ADMIN_CORRECTION',
        p_admin_id,
        'ADMIN',
        v_prev_log.score_team1,
        -- The scores we are reverting TO
        v_prev_log.score_team2,
        'UNDO: ' || COALESCE(v_target_log.correction_reason, 'Correction'),
        'PENDING',
        COALESCE(
            v_target_log.correction_chain_id,
            v_target_log.id
        ) -- Bind to same chain
    )
RETURNING id INTO v_new_audit_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'new_audit_log_id',
    v_new_audit_log_id,
    'reverted_scores',
    jsonb_build_object(
        'team1',
        v_prev_log.score_team1,
        'team2',
        v_prev_log.score_team2
    )
);
END;
$$;


ALTER FUNCTION "public"."admin_prepare_undo"("p_target_correction_id" "uuid", "p_admin_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_preview_match_correction"("p_audit_log_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_audit_log public.match_audit_log %ROWTYPE;
v_match public.matches %ROWTYPE;
v_team1_rating NUMERIC := 0;
v_team2_rating NUMERIC := 0;
v_team1_count INTEGER := 0;
v_team2_count INTEGER := 0;
v_p1_expected NUMERIC;
v_p1_actual NUMERIC;
v_base_delta NUMERIC;
v_k_factor INT;
v_base_multiplier NUMERIC;
v_guest_multiplier NUMERIC;
v_h RECORD;
v_old_delta INTEGER;
v_new_delta INTEGER;
v_net_diff INTEGER;
v_is_team1 BOOLEAN;
v_was_guest BOOLEAN;
v_applied_multiplier NUMERIC;
v_affected_players JSONB := '[]'::jsonb;
v_total_shift INTEGER := 0;
v_max_shift INTEGER := 0;
v_fp_text TEXT := '';
v_tier_change BOOLEAN := false;
BEGIN
SELECT * INTO v_audit_log
FROM public.match_audit_log
WHERE id = p_audit_log_id;
IF v_audit_log IS NULL THEN RETURN jsonb_build_object('error', 'AUDIT_LOG_NOT_FOUND');
END IF;
SELECT * INTO v_match
FROM public.matches
WHERE id = v_audit_log.match_id;
v_fp_text := v_audit_log.id || v_match.id || v_match.status || v_audit_log.score_team1 || v_audit_log.score_team2;
FOR v_h IN
SELECT *
FROM public.elo_history
WHERE match_id = v_match.id
    AND is_correction = false
ORDER BY id ASC LOOP v_fp_text := v_fp_text || v_h.id || v_h.old_rating || v_h.new_rating;
IF v_h.player_id IN (v_match.player_1, v_match.player_2) THEN v_team1_rating := v_team1_rating + v_h.old_rating;
v_team1_count := v_team1_count + 1;
ELSIF v_h.player_id IN (v_match.player_3, v_match.player_4) THEN v_team2_rating := v_team2_rating + v_h.old_rating;
v_team2_count := v_team2_count + 1;
END IF;
END LOOP;
IF v_team1_count = 0
OR v_team2_count = 0 THEN RETURN jsonb_build_object('error', 'HISTORY_INTEGRITY_FAILURE_SIMULATED');
END IF;
v_team1_rating := v_team1_rating / v_team1_count;
v_team2_rating := v_team2_rating / v_team2_count;
v_p1_expected := 1.0 / (
    1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0)
);
IF v_audit_log.score_team1 > v_audit_log.score_team2 THEN v_p1_actual := 1.0;
ELSIF v_audit_log.score_team1 < v_audit_log.score_team2 THEN v_p1_actual := 0.0;
ELSE v_p1_actual := 0.5;
END IF;
SELECT k_factor,
    multiplier INTO v_k_factor,
    v_base_multiplier
FROM public.get_elo_policy(false);
SELECT multiplier INTO v_guest_multiplier
FROM public.get_elo_policy(true);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
FOR v_h IN
SELECT *
FROM public.elo_history
WHERE match_id = v_match.id
    AND is_correction = false
ORDER BY id ASC LOOP v_old_delta := v_h.new_rating - v_h.old_rating;
v_is_team1 := v_h.player_id IN (v_match.player_1, v_match.player_2);
IF v_is_team1 THEN v_new_delta := ROUND(v_base_delta);
ELSE v_new_delta := ROUND(v_base_delta * -1);
END IF;
IF v_h.was_guest IS NOT NULL THEN v_was_guest := v_h.was_guest;
ELSE
SELECT is_guest INTO v_was_guest
FROM public.profiles
WHERE id = v_h.player_id;
END IF;
IF v_was_guest THEN v_applied_multiplier := v_guest_multiplier;
ELSE v_applied_multiplier := v_base_multiplier;
END IF;
IF v_applied_multiplier <> 1.0 THEN v_new_delta := ROUND(v_new_delta * v_applied_multiplier);
END IF;
v_net_diff := v_new_delta - v_old_delta;
v_total_shift := v_total_shift + ABS(v_net_diff);
IF ABS(v_net_diff) > v_max_shift THEN v_max_shift := ABS(v_net_diff);
END IF;
IF TRUNC(v_h.new_rating / 100.0) != TRUNC((v_h.new_rating + v_net_diff) / 100.0) THEN v_tier_change := true;
END IF;
v_affected_players := v_affected_players || jsonb_build_object(
    'player_id',
    v_h.player_id,
    'net_diff',
    v_net_diff,
    'projected_rating',
    (v_h.new_rating + v_net_diff),
    'old_rating',
    v_h.new_rating
);
END LOOP;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.7',
    'mode',
    'PREVIEW',
    'preview_fingerprint',
    md5(v_fp_text),
    'affected_players',
    v_affected_players,
    'total_rating_shift',
    v_total_shift,
    'max_single_shift',
    v_max_shift,
    'tier_change_detected',
    v_tier_change,
    'policy_snapshot',
    jsonb_build_object(
        'k_factor',
        v_k_factor,
        'base_multiplier',
        v_base_multiplier,
        'guest_multiplier',
        v_guest_multiplier
    )
);
END;
$$;


ALTER FUNCTION "public"."admin_preview_match_correction"("p_audit_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_system_flag"("p_key" "text", "p_value" boolean, "p_admin_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_old_val BOOLEAN;
v_log_id UUID;
v_system_uuid UUID := '00000000-0000-0000-0000-000000000000';
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
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
SELECT value INTO v_old_val
FROM public.system_flags
WHERE key = p_key;
IF v_old_val IS NOT NULL
AND v_old_val = p_value THEN RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'status',
    'NO_OP',
    'message',
    'Value unchanged'
);
END IF;
INSERT INTO public.system_flags (key, value, updated_at)
VALUES (p_key, p_value, NOW()) ON CONFLICT (key) DO
UPDATE
SET value = EXCLUDED.value,
    updated_at = NOW();
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
        'SYSTEM',
        v_system_uuid,
        'FLAG_CHANGE',
        CASE
            WHEN v_old_val THEN 'true'
            ELSE 'false'
        END,
        CASE
            WHEN p_value THEN 'true'
            ELSE 'false'
        END,
        'Key: ' || p_key,
        p_admin_id
    )
RETURNING id INTO v_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'action_id',
    v_log_id,
    'key',
    p_key,
    'value',
    p_value
);
END;
$$;


ALTER FUNCTION "public"."admin_set_system_flag"("p_key" "text", "p_value" boolean, "p_admin_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."confirm_match_v3_5"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid", "p_logic_version" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_match RECORD;
    v_item JSONB;
BEGIN
    -- [0] 멱등성 체크 (이미 처리된 요청인지 확인)
    -- 네트워크 오류로 재요청이 와도, DB에 기록이 있으면 성공으로 간주하고 리턴
    IF EXISTS (SELECT 1 FROM public.match_events WHERE client_request_id = p_client_request_id) THEN
        RETURN jsonb_build_object('success', true, 'message', '이미 처리된 요청입니다 (Idempotent).');
    END IF;

    -- [A] 잠금 (동시성 제어)
    SELECT * INTO v_match FROM public.matches WHERE id = p_match_id FOR UPDATE;

    -- [B] 상태 검증 (이미 끝난 경기인지)
    IF v_match.status = 'FINISHED' THEN
        RETURN jsonb_build_object('success', false, 'message', '이미 종료된 경기입니다.');
    END IF;

    -- [C] 권한 검증 (제안 2 반영)
    -- 요청자가 해당 경기의 플레이어(1~4) 중 한 명인지 확인
    IF p_reporter_id NOT IN (
        v_match.player_1, v_match.player_2, 
        v_match.player_3, v_match.player_4
    ) THEN
        RETURN jsonb_build_object('success', false, 'message', '권한이 없습니다. 참가자만 결과를 입력할 수 있습니다.');
    END IF;

    -- [D] 경기 상태 업데이트
    UPDATE public.matches 
    SET status = 'FINISHED', 
        score_team1 = p_team1_score, 
        score_team2 = p_team2_score,
        confirmed_by = p_reporter_id,
        end_time = NOW()
    WHERE id = p_match_id;

    -- [E] 프로필 점수 반영 (TS 계산값 신뢰)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_elo_updates)
    LOOP
        UPDATE public.profiles
        SET 
            elo_mixed_doubles = COALESCE(elo_mixed_doubles, 1200) + (v_item->>'delta')::INT,
            games_played_today = COALESCE(games_played_today, 0) + 1,
            -- 승무패 통계 (옵션)
            total_wins = total_wins + CASE WHEN (v_item->>'result')::TEXT = 'WIN' THEN 1 ELSE 0 END,
            total_losses = total_losses + CASE WHEN (v_item->>'result')::TEXT = 'LOSS' THEN 1 ELSE 0 END
        WHERE id = (v_item->>'id')::UUID;

        -- ELO 히스토리 저장
        INSERT INTO public.elo_history (player_id, match_type, elo_score, delta)
        VALUES (
            (v_item->>'id')::UUID, 
            v_match.match_category, 
            (COALESCE((SELECT elo_mixed_doubles FROM public.profiles WHERE id=(v_item->>'id')::UUID), 1200)), 
            (v_item->>'delta')::INT
        );
    END LOOP;

    -- [F] 대기열 복귀 (Upsert)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_queue_inserts)
    LOOP
        INSERT INTO public.queue (player_id, joined_at, is_active, priority_score)
        VALUES (
            (v_item->>'player_id')::UUID,
            NOW(),
            TRUE,
            (v_item->>'priority')::NUMERIC
        )
        ON CONFLICT (player_id) 
        DO UPDATE SET 
            joined_at = NOW(), 
            is_active = TRUE, 
            priority_score = EXCLUDED.priority_score;
    END LOOP;

    -- [G] 이벤트 로깅 (보완: 버전, 요청ID 저장)
    INSERT INTO public.match_events (
        client_request_id, match_id, event_type, version, payload
    ) VALUES (
        p_client_request_id,
        p_match_id, 
        'FINISHED', 
        p_logic_version,
        jsonb_build_object(
            'scores', jsonb_build_array(p_team1_score, p_team2_score),
            'reporter', p_reporter_id,
            'elo_updates', p_elo_updates
        )
    );

    RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."confirm_match_v3_5"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid", "p_logic_version" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."finish_match_atomic"("p_match_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_confirmed_by" "uuid", "p_confirmation_type" "text" DEFAULT 'NORMAL_CONFIRM'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_match public.matches %ROWTYPE;
v_team1_ids UUID [];
v_team2_ids UUID [];
v_all_player_ids UUID [];
v_profile RECORD;
v_team1_rating NUMERIC := 0;
v_team2_rating NUMERIC := 0;
v_team1_count INTEGER := 0;
v_team2_count INTEGER := 0;
v_p1_actual NUMERIC;
v_p1_expected NUMERIC;
v_base_delta NUMERIC;
v_updates JSONB := '[]'::jsonb;
v_old_rating INTEGER;
v_new_rating INTEGER;
v_result TEXT;
v_k_factor INT;
v_base_multiplier NUMERIC;
v_guest_multiplier NUMERIC;
v_applied_multiplier NUMERIC;
v_status_before TEXT;
v_trigger_role TEXT;
v_is_force BOOLEAN;
BEGIN -- 0. Input Validation (Strict Type Check)
IF p_confirmation_type NOT IN ('NORMAL_CONFIRM', 'ADMIN_FORCE_CONFIRM') THEN RETURN jsonb_build_object('error', 'INVALID_CONFIRMATION_TYPE');
END IF;
IF (
    p_team1_score < 0
    OR p_team1_score > 99
)
OR (
    p_team2_score < 0
    OR p_team2_score > 99
)
OR (
    p_team1_score = 0
    AND p_team2_score = 0
) THEN RETURN jsonb_build_object('error', 'INVALID_SCORE');
END IF;
SELECT * INTO v_match
FROM public.matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status = 'FINISHED' THEN RETURN jsonb_build_object('error', 'ALREADY_FINISHED');
END IF;
v_status_before := v_match.status;
v_team1_ids := ARRAY [v_match.player_1, v_match.player_2];
v_team2_ids := ARRAY [v_match.player_3, v_match.player_4];
SELECT array_agg(id) INTO v_team1_ids
FROM unnest(v_team1_ids) AS id
WHERE id IS NOT NULL;
SELECT array_agg(id) INTO v_team2_ids
FROM unnest(v_team2_ids) AS id
WHERE id IS NOT NULL;
v_all_player_ids := v_team1_ids || v_team2_ids;
IF p_confirmation_type = 'NORMAL_CONFIRM' THEN -- MUST be a participant
IF NOT (p_confirmed_by = ANY(v_all_player_ids)) THEN RETURN jsonb_build_object('error', 'CONFIRM_PERMISSION_DENIED');
END IF;
ELSIF p_confirmation_type = 'ADMIN_FORCE_CONFIRM' THEN -- MUST be an admin
IF NOT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = p_confirmed_by
        AND role = 'admin'
) THEN RETURN jsonb_build_object('error', 'CONFIRM_PERMISSION_DENIED');
END IF;
END IF;
FOR v_profile IN
SELECT *
FROM public.profiles
WHERE id = ANY(v_team1_ids) LOOP v_team1_rating := v_team1_rating + COALESCE(v_profile.elo_mixed_doubles, 1200);
v_team1_count := v_team1_count + 1;
END LOOP;
FOR v_profile IN
SELECT *
FROM public.profiles
WHERE id = ANY(v_team2_ids) LOOP v_team2_rating := v_team2_rating + COALESCE(v_profile.elo_mixed_doubles, 1200);
v_team2_count := v_team2_count + 1;
END LOOP;
IF v_team1_count = 0
OR v_team2_count = 0 THEN RETURN jsonb_build_object('error', 'MISSING_PLAYERS');
END IF;
v_team1_rating := v_team1_rating / v_team1_count;
v_team2_rating := v_team2_rating / v_team2_count;
v_p1_expected := 1.0 / (
    1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0)
);
IF p_team1_score > p_team2_score THEN v_p1_actual := 1.0;
v_result := 'WIN';
ELSIF p_team1_score < p_team2_score THEN v_p1_actual := 0.0;
v_result := 'LOSS';
ELSE v_p1_actual := 0.5;
v_result := 'DRAW';
END IF;
SELECT k_factor,
    multiplier INTO v_k_factor,
    v_base_multiplier
FROM public.get_elo_policy(false);
SELECT multiplier INTO v_guest_multiplier
FROM public.get_elo_policy(true);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
FOR v_profile IN
SELECT *
FROM public.profiles
WHERE id = ANY(v_all_player_ids) FOR
UPDATE LOOP
DECLARE is_team1 BOOLEAN;
final_delta INTEGER;
BEGIN is_team1 := v_profile.id = ANY(v_team1_ids);
IF is_team1 THEN final_delta := ROUND(v_base_delta);
ELSE final_delta := ROUND(v_base_delta * -1);
END IF;
IF v_profile.is_guest THEN v_applied_multiplier := v_guest_multiplier;
ELSE v_applied_multiplier := v_base_multiplier;
END IF;
IF v_applied_multiplier <> 1.0 THEN final_delta := ROUND(final_delta * v_applied_multiplier);
END IF;
v_old_rating := COALESCE(v_profile.elo_mixed_doubles, 1200);
v_new_rating := v_old_rating + final_delta;
UPDATE public.profiles
SET elo_mixed_doubles = v_new_rating,
    games_played_today = COALESCE(games_played_today, 0) + 1 -- Safe Increment
WHERE id = v_profile.id;
INSERT INTO public.elo_history (
        match_id,
        player_id,
        old_rating,
        new_rating,
        created_at
    )
VALUES (
        p_match_id,
        v_profile.id,
        v_old_rating,
        v_new_rating,
        NOW()
    );
v_updates := v_updates || jsonb_build_object(
    'id',
    v_profile.id,
    'delta',
    final_delta,
    'newRating',
    v_new_rating
);
END;
END LOOP;
DELETE FROM public.queue
WHERE player_id = ANY(v_all_player_ids)
    AND is_active = true;
UPDATE public.matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    confirmed_by = p_confirmed_by,
    end_time = NOW()
WHERE id = p_match_id;
IF p_confirmed_by = ANY(v_all_player_ids) THEN v_trigger_role := 'PLAYER';
ELSE v_trigger_role := 'ADMIN';
END IF;
v_is_force := (p_confirmation_type = 'ADMIN_FORCE_CONFIRM');
INSERT INTO public.match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        confirmation_type,
        -- New
        is_force_confirm,
        -- New
        match_status_before,
        match_status_after,
        score_team1,
        score_team2
    )
VALUES (
        p_match_id,
        'CONFIRM_MATCH',
        p_confirmed_by,
        v_trigger_role,
        p_confirmation_type,
        v_is_force,
        v_status_before,
        'FINISHED',
        p_team1_score,
        p_team2_score
    );
RETURN jsonb_build_object(
    'success',
    true,
    'updates',
    v_updates
);
END;
$$;


ALTER FUNCTION "public"."finish_match_atomic"("p_match_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_confirmed_by" "uuid", "p_confirmation_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_elo_policy"("p_is_guest" boolean) RETURNS TABLE("k_factor" integer, "multiplier" numeric)
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$ BEGIN RETURN QUERY
SELECT 32,
    -- Standard K-Factor
    CASE
        WHEN p_is_guest THEN 1.5
        ELSE 1.0
    END;
END;
$$;


ALTER FUNCTION "public"."get_elo_policy"("p_is_guest" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."place_bet"("p_match_id" "uuid", "p_user_id" "uuid", "p_pick" "text", "p_amount" integer, "p_odds" numeric) RETURNS json
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    current_points INTEGER;
    match_status TEXT;
BEGIN
    -- 1. 잔액 확인
    SELECT rally_point INTO current_points FROM profiles WHERE id = p_user_id;
    IF current_points < p_amount THEN
        RAISE EXCEPTION '포인트가 부족합니다.';
    END IF;

    -- 2. 경기 상태 확인 (배팅 가능한지)
    SELECT status INTO match_status FROM matches WHERE id = p_match_id;
    IF match_status NOT IN ('DRAFT', 'draft', 'PENDING', 'pending') THEN
        RAISE EXCEPTION '이미 시작되었거나 종료된 경기는 배팅할 수 없습니다.';
    END IF;

    -- 3. 포인트 차감
    UPDATE profiles SET rally_point = rally_point - p_amount WHERE id = p_user_id;

    -- 4. 배팅 기록 저장
    INSERT INTO bets (match_id, user_id, pick_team, amount, odds_at_bet)
    VALUES (p_match_id, p_user_id, p_pick, p_amount, p_odds);

    RETURN json_build_object('success', true, 'new_balance', current_points - p_amount);
END;
$$;


ALTER FUNCTION "public"."place_bet"("p_match_id" "uuid", "p_user_id" "uuid", "p_pick" "text", "p_amount" integer, "p_odds" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_match_completion"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_winner TEXT;
BEGIN -- 승자 결정 로직 (DB가 직접 판단)
IF p_team1_score > p_team2_score THEN v_winner := 'TEAM_1';
ELSIF p_team2_score > p_team1_score THEN v_winner := 'TEAM_2';
ELSE v_winner := 'DRAW';
END IF;
UPDATE public.matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner,
    confirmed_by = p_reporter_id,
    end_time = NOW()
WHERE id = p_match_id;
FOR i IN 0..jsonb_array_length(p_elo_updates) - 1 LOOP
UPDATE public.profiles
SET elo_mixed_doubles = COALESCE(elo_mixed_doubles, 1200) + (p_elo_updates->i->>'delta')::INT,
    games_played_today = COALESCE(games_played_today, 0) + 1
WHERE id = (p_elo_updates->i->>'id')::UUID;
END LOOP;
FOR i IN 0..jsonb_array_length(p_queue_inserts) - 1 LOOP
INSERT INTO public.queue (player_id, joined_at, is_active, priority_score)
VALUES (
        (p_queue_inserts->i->>'player_id')::UUID,
        NOW(),
        TRUE,
        (p_queue_inserts->i->>'priority')::NUMERIC
    ) ON CONFLICT (player_id) DO
UPDATE
SET joined_at = NOW(),
    is_active = TRUE,
    priority_score = EXCLUDED.priority_score;
END LOOP;
RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."process_match_completion"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_guest_and_enqueue"("p_name" "text", "p_ntrp" numeric, "p_gender" "text", "p_departure_time" timestamp with time zone) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_target_name TEXT;
v_player_id UUID;
v_reused BOOLEAN;
v_initial_elo INT;
v_priority_score INT;
v_queue_exists BOOLEAN;
BEGIN -- 1. Input Sanitization & Setup
v_target_name := TRIM(p_name) || ' (G)';
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
    WHEN p_ntrp >= 7.0 THEN 2800
    ELSE 1200 -- Default Fallback
END;
v_priority_score := FLOOR(5000 + ((p_ntrp + 0.25) * 100));
SELECT id INTO v_player_id
FROM public.profiles
WHERE name = v_target_name
    AND is_guest = true
LIMIT 1;
IF v_player_id IS NOT NULL THEN -- REUSE
v_reused := true;
ELSE -- CREATE NEW
v_reused := false;
v_player_id := gen_random_uuid();
INSERT INTO public.profiles (
        id,
        email,
        name,
        ntrp,
        gender,
        is_guest,
        role,
        elo_mixed_doubles,
        elo_men_doubles,
        elo_women_doubles,
        elo_singles,
        games_played_today,
        created_at
    )
VALUES (
        v_player_id,
        'guest_' || substring(
            v_player_id::text
            from 1 for 8
        ) || '@temp.temp',
        v_target_name,
        p_ntrp,
        -- RAW NTRP
        p_gender,
        true,
        'member',
        v_initial_elo,
        -- Deterministic ELO
        v_initial_elo,
        v_initial_elo,
        v_initial_elo,
        0,
        NOW()
    );
END IF;
SELECT EXISTS (
        SELECT 1
        FROM public.queue
        WHERE player_id = v_player_id
            AND is_active = true
    ) INTO v_queue_exists;
IF NOT v_queue_exists THEN
INSERT INTO public.queue (
        player_id,
        joined_at,
        is_active,
        priority_score,
        departure_time
    )
VALUES (
        v_player_id,
        NOW(),
        true,
        v_priority_score,
        p_departure_time
    );
END IF;
RETURN jsonb_build_object(
    'player_id',
    v_player_id,
    'reused',
    v_reused,
    'initial_elo',
    v_initial_elo
);
END;
$$;


ALTER FUNCTION "public"."register_guest_and_enqueue"("p_name" "text", "p_ntrp" numeric, "p_gender" "text", "p_departure_time" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."settle_bets_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_bet RECORD;
    v_winnings INTEGER;
BEGIN
    IF NEW.status = 'FINISHED' AND OLD.status != 'FINISHED' THEN
        FOR v_bet IN SELECT * FROM public.bets WHERE match_id = NEW.id AND result = 'PENDING' LOOP
            
            IF NEW.winner_team = 'DRAW' THEN
                UPDATE public.bets SET result = 'DRAW' WHERE id = v_bet.id;
                UPDATE public.profiles SET rally_point = rally_point + v_bet.amount WHERE id = v_bet.user_id;
            
            ELSIF NEW.winner_team = v_bet.pick_team THEN
                v_winnings := FLOOR(v_bet.amount * v_bet.odds_at_bet);
                UPDATE public.bets SET result = 'WIN' WHERE id = v_bet.id;
                UPDATE public.profiles SET rally_point = rally_point + v_winnings WHERE id = v_bet.user_id;

            ELSE
                UPDATE public.bets SET result = 'LOSE' WHERE id = v_bet.id;
            END IF;
            
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."settle_bets_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_player_elo"("p_match_type" character varying, "p_winners" "uuid"[], "p_losers" "uuid"[], "p_is_tournament" boolean DEFAULT false, "p_is_draw" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_player RECORD;
    v_team1_avg NUMERIC := 0;
    v_team2_avg NUMERIC := 0;
    v_expected_score NUMERIC;
    v_actual_score NUMERIC;
    v_k_factor INTEGER;
    v_delta INTEGER;
    v_current_elo INTEGER;
    v_new_elo INTEGER;
    v_is_winner BOOLEAN;
    v_is_draw_player BOOLEAN;
    v_updated_count INTEGER := 0;
BEGIN

    -- =====================================================================
    -- A. Calculate Team Averages from ACTUAL ELO (not NTRP!)
    -- =====================================================================
    -- Use CASE WHEN to prioritize ELO, only fallback to NTRP if ELO is NULL
    SELECT AVG(
        CASE 
            WHEN elo_mixed_doubles IS NOT NULL THEN elo_mixed_doubles
            WHEN ntrp IS NOT NULL THEN ROUND(ntrp * 400)
            ELSE 1200 
        END
    ) INTO v_team1_avg 
    FROM public.profiles WHERE id = ANY(p_winners);

    SELECT AVG(
        CASE 
            WHEN elo_mixed_doubles IS NOT NULL THEN elo_mixed_doubles
            WHEN ntrp IS NOT NULL THEN ROUND(ntrp * 400)
            ELSE 1200 
        END
    ) INTO v_team2_avg 
    FROM public.profiles WHERE id = ANY(p_losers);

    -- Safety: ensure not null
    v_team1_avg := COALESCE(v_team1_avg, 1200);
    v_team2_avg := COALESCE(v_team2_avg, 1200);

    -- =====================================================================
    -- B. Calculate Expected Score (Team1's perspective)
    -- =====================================================================
    v_expected_score := 1.0 / (1.0 + POWER(10.0, (v_team2_avg - v_team1_avg) / 400.0));

    -- =====================================================================
    -- C. Loop through ALL players and update
    -- =====================================================================
    FOR v_player IN SELECT * FROM public.profiles WHERE id = ANY(p_winners || p_losers) LOOP
        
        -- ★ KEY FIX: Read ACTUAL ELO from DB, not recalculate from NTRP
        v_current_elo := CASE 
            WHEN v_player.elo_mixed_doubles IS NOT NULL THEN v_player.elo_mixed_doubles
            WHEN v_player.ntrp IS NOT NULL THEN ROUND(v_player.ntrp * 400)
            ELSE 1200 
        END;

        -- Determine if winner
        v_is_winner := (v_player.id = ANY(p_winners));
        
        -- Determine actual score
        IF p_is_draw THEN
            v_actual_score := 0.5;
            v_is_draw_player := TRUE;
        ELSIF v_is_winner THEN
            v_actual_score := 1.0;
            v_is_draw_player := FALSE;
        ELSE
            v_actual_score := 0.0;
            v_is_draw_player := FALSE;
        END IF;

        -- Calculate K-Factor
        v_k_factor := 32;
        IF v_player.role = 'coach' THEN 
            v_k_factor := 0;
        ELSIF v_player.is_guest = TRUE THEN 
            v_k_factor := 80;
        ELSIF p_is_tournament = TRUE THEN 
            v_k_factor := 40;
        ELSIF COALESCE(v_player.total_games_history, 0) < 10 THEN 
            v_k_factor := 64;
        END IF;

        -- Calculate Delta
        IF v_is_winner THEN
            v_delta := ROUND(v_k_factor * (v_actual_score - v_expected_score));
        ELSE
            v_delta := ROUND(v_k_factor * (v_actual_score - (1.0 - v_expected_score)));
        END IF;

        -- ★ NEW ELO = CURRENT ELO + DELTA (not recalculated from NTRP!)
        v_new_elo := v_current_elo + v_delta;

        -- =====================================================================
        -- D. UPDATE THE DATABASE
        -- =====================================================================
        IF v_k_factor > 0 THEN
            IF v_is_draw_player THEN
                UPDATE public.profiles SET
                    elo_mixed_doubles = v_new_elo,
                    games_played_today = COALESCE(games_played_today, 0) + 1,
                    total_games_history = COALESCE(total_games_history, 0) + 1,
                    total_draws = COALESCE(total_draws, 0) + 1,
                    winning_streak = 0
                WHERE id = v_player.id;
            ELSIF v_is_winner THEN
                UPDATE public.profiles SET
                    elo_mixed_doubles = v_new_elo,
                    games_played_today = COALESCE(games_played_today, 0) + 1,
                    total_games_history = COALESCE(total_games_history, 0) + 1,
                    total_wins = COALESCE(total_wins, 0) + 1,
                    winning_streak = COALESCE(winning_streak, 0) + 1
                WHERE id = v_player.id;
            ELSE
                UPDATE public.profiles SET
                    elo_mixed_doubles = v_new_elo,
                    games_played_today = COALESCE(games_played_today, 0) + 1,
                    total_games_history = COALESCE(total_games_history, 0) + 1,
                    total_losses = COALESCE(total_losses, 0) + 1,
                    winning_streak = 0
                WHERE id = v_player.id;
            END IF;

            -- Record in history for graph
            INSERT INTO public.elo_history (player_id, match_type, elo_score, delta)
            VALUES (v_player.id, COALESCE(p_match_type, 'MIXED'), v_new_elo, v_delta);

            v_updated_count := v_updated_count + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'updated_players', v_updated_count,
        'team1_avg', v_team1_avg,
        'team2_avg', v_team2_avg,
        'expected_score', v_expected_score
    );
END;
$$;


ALTER FUNCTION "public"."update_player_elo"("p_match_type" character varying, "p_winners" "uuid"[], "p_losers" "uuid"[], "p_is_tournament" boolean, "p_is_draw" boolean) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."admin_operation_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "target_type" "text" NOT NULL,
    "target_id" "uuid",
    "action" "text" NOT NULL,
    "old_value" "text",
    "new_value" "text",
    "reason" "text",
    "operated_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."admin_operation_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "match_id" "uuid",
    "user_id" "uuid",
    "pick_team" "text" NOT NULL,
    "amount" integer NOT NULL,
    "odds_at_bet" numeric NOT NULL,
    "result" "text" DEFAULT 'PENDING'::"text",
    CONSTRAINT "bets_amount_check" CHECK (("amount" > 0))
);


ALTER TABLE "public"."bets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."elo_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "player_id" "uuid",
    "match_type" character varying NOT NULL,
    "elo_score" integer NOT NULL,
    "delta" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "calculation_version" "text" DEFAULT 'v8.8'::"text",
    "is_correction" boolean DEFAULT false,
    "related_history_id" "uuid",
    "was_guest" boolean,
    "applied_multiplier" numeric,
    "match_id" "uuid",
    "old_rating" integer,
    "new_rating" integer
);


ALTER TABLE "public"."elo_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."match_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "match_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "triggered_by" "uuid" NOT NULL,
    "trigger_role" "text" NOT NULL,
    "match_status_before" "text" NOT NULL,
    "match_status_after" "text" NOT NULL,
    "score_team1" integer,
    "score_team2" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "correction_reason" "text",
    "related_action_id" "uuid",
    "correction_status" "text",
    "correction_started_at" timestamp with time zone,
    "correction_finished_at" timestamp with time zone,
    "correction_error" "text",
    "correction_chain_id" "uuid",
    CONSTRAINT "match_audit_log_correction_status_check" CHECK (("correction_status" = ANY (ARRAY['PENDING'::"text", 'APPLYING'::"text", 'APPLIED'::"text", 'FAILED'::"text"])))
);


ALTER TABLE "public"."match_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."match_audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "match_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "performed_by" "uuid",
    "performed_at" timestamp with time zone DEFAULT "now"(),
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."match_audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."match_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_request_id" "uuid",
    "match_id" "uuid" NOT NULL,
    "event_type" character varying NOT NULL,
    "version" integer DEFAULT 1,
    "payload" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."match_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."matches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "player_1" "uuid",
    "player_2" "uuid",
    "player_3" "uuid",
    "player_4" "uuid",
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "score_team1" integer DEFAULT 0,
    "score_team2" integer DEFAULT 0,
    "winner_team" "text",
    "match_category" "text" DEFAULT 'MIXED'::"text",
    "match_type" "text" DEFAULT 'REGULAR'::"text",
    "reported_by" "uuid",
    "confirmed_by" "uuid",
    "end_time" timestamp with time zone,
    "court_name" character varying,
    "start_time" timestamp with time zone,
    "betting_closes_at" timestamp with time zone,
    "is_auto_generated" boolean DEFAULT false,
    CONSTRAINT "matches_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'completed'::"text", 'cancelled'::"text", 'DRAFT'::"text", 'PLAYING'::"text", 'SCORING'::"text", 'PENDING'::"text", 'FINISHED'::"text", 'DISPUTED'::"text"])))
);


ALTER TABLE "public"."matches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mvp_votes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "match_id" "uuid",
    "voter_id" "uuid",
    "target_id" "uuid",
    "tag" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."mvp_votes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "content" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."notices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profile_merge_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_profile" "uuid" NOT NULL,
    "target_profile" "uuid" NOT NULL,
    "merged_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profile_merge_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text",
    "name" "text",
    "phone" "text",
    "gender" "text",
    "ntrp" double precision,
    "elo_singles" integer DEFAULT 1200,
    "role" "text" DEFAULT 'player'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_guest" boolean DEFAULT false,
    "admin_memo" "text",
    "elo_men_doubles" integer DEFAULT 1200,
    "elo_women_doubles" integer DEFAULT 1200,
    "elo_mixed_doubles" integer DEFAULT 1200,
    "emoji" "text" DEFAULT '🎾'::"text",
    "avatar_url" "text",
    "games_played_today" integer DEFAULT 0,
    "total_games_history" integer DEFAULT 0,
    "rally_point" integer DEFAULT 1000,
    "total_wins" integer DEFAULT 0,
    "total_losses" integer DEFAULT 0,
    "total_draws" integer DEFAULT 0,
    "winning_streak" integer DEFAULT 0,
    "departure_time" character varying,
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'manager'::"text", 'player'::"text", 'member'::"text", 'coach'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "player_id" "uuid",
    "game_type" "text" DEFAULT 'DOUBLES'::"text",
    "departure_time" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "priority_score" double precision DEFAULT 0,
    "tier" "text" DEFAULT 'BRONZE'::"text",
    "joined_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "no_show_count" integer DEFAULT 0,
    "last_no_show_at" timestamp with time zone
);


ALTER TABLE "public"."queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rating_adjustment_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "player_id" "uuid" NOT NULL,
    "old_rating" integer NOT NULL,
    "new_rating" integer NOT NULL,
    "reason" "text",
    "adjusted_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rating_adjustment_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."seasons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "is_active" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."seasons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_flags" (
    "key" "text" NOT NULL,
    "value" boolean NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."system_flags" OWNER TO "postgres";


COMMENT ON TABLE "public"."system_flags" IS 'Schema Version: V8.9 (Operational Infrastructure)';



CREATE OR REPLACE VIEW "public"."view_admin_correction_chain" AS
 WITH "chain_activity" AS (
         SELECT COALESCE("match_audit_log"."correction_chain_id", "match_audit_log"."id") AS "chain_id",
            "match_audit_log"."correction_status",
            "match_audit_log"."created_at",
            "match_audit_log"."correction_finished_at"
           FROM "public"."match_audit_log"
          WHERE ("match_audit_log"."action" = 'ADMIN_CORRECTION'::"text")
        ), "chain_summary" AS (
         SELECT "chain_activity"."chain_id",
            "count"(*) AS "number_of_corrections",
            "count"(*) FILTER (WHERE ("chain_activity"."correction_status" = 'APPLIED'::"text")) AS "applied_count",
            "count"(*) FILTER (WHERE ("chain_activity"."correction_status" = 'FAILED'::"text")) AS "fail_count",
            "max"("chain_activity"."correction_finished_at") AS "last_activity_at"
           FROM "chain_activity"
          GROUP BY "chain_activity"."chain_id"
        ), "latest_status" AS (
         SELECT DISTINCT ON ("chain_activity"."chain_id") "chain_activity"."chain_id",
            "chain_activity"."correction_status"
           FROM "chain_activity"
          ORDER BY "chain_activity"."chain_id", "chain_activity"."created_at" DESC
        )
 SELECT "s"."chain_id",
    "s"."number_of_corrections",
    "s"."applied_count",
    "s"."fail_count",
    "s"."last_activity_at",
    "l"."correction_status" AS "current_chain_status"
   FROM ("chain_summary" "s"
     JOIN "latest_status" "l" ON (("s"."chain_id" = "l"."chain_id")));


ALTER VIEW "public"."view_admin_correction_chain" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."view_admin_correction_chain_detail" AS
 WITH "raw_log" AS (
         SELECT "match_audit_log"."id" AS "audit_log_id",
            COALESCE("match_audit_log"."correction_chain_id", "match_audit_log"."id") AS "chain_id",
            "match_audit_log"."created_at",
            "match_audit_log"."correction_reason",
            "match_audit_log"."correction_status",
            "match_audit_log"."correction_finished_at",
            (COALESCE("match_audit_log"."correction_chain_id", "match_audit_log"."id") = "match_audit_log"."id") AS "is_initial"
           FROM "public"."match_audit_log"
          WHERE ("match_audit_log"."action" = 'ADMIN_CORRECTION'::"text")
        ), "applied_ranking" AS (
         SELECT "raw_log"."audit_log_id",
            "row_number"() OVER (PARTITION BY "raw_log"."chain_id" ORDER BY "raw_log"."correction_finished_at" DESC NULLS LAST, "raw_log"."created_at" DESC) AS "rn"
           FROM "raw_log"
          WHERE ("raw_log"."correction_status" = 'APPLIED'::"text")
        )
 SELECT "r"."audit_log_id",
    "r"."chain_id",
    "r"."created_at",
    "r"."correction_reason",
    "r"."correction_status",
    "r"."correction_finished_at",
    "r"."is_initial",
    (("r"."correction_status" = 'APPLIED'::"text") AND ("ar"."rn" = 1)) AS "is_undo_candidate",
    NULL::integer AS "total_net_shift_placeholder"
   FROM ("raw_log" "r"
     LEFT JOIN "applied_ranking" "ar" ON (("r"."audit_log_id" = "ar"."audit_log_id")))
  ORDER BY "r"."chain_id", "r"."created_at";


ALTER VIEW "public"."view_admin_correction_chain_detail" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."view_admin_correction_dashboard" AS
 WITH "chain_latest" AS (
         SELECT DISTINCT ON (COALESCE("match_audit_log"."correction_chain_id", "match_audit_log"."id")) "match_audit_log"."id" AS "audit_log_id",
            COALESCE("match_audit_log"."correction_chain_id", "match_audit_log"."id") AS "chain_id"
           FROM "public"."match_audit_log"
          WHERE ("match_audit_log"."action" = 'ADMIN_CORRECTION'::"text")
          ORDER BY COALESCE("match_audit_log"."correction_chain_id", "match_audit_log"."id"), "match_audit_log"."created_at" DESC
        )
 SELECT "l"."id" AS "audit_log_id",
    "l"."match_id",
    "l"."action",
    "l"."correction_status",
    "l"."correction_reason",
    "l"."correction_started_at",
    "l"."correction_finished_at",
    "l"."correction_error",
    "l"."created_at",
        CASE
            WHEN ("cl"."audit_log_id" IS NOT NULL) THEN true
            ELSE false
        END AS "is_latest_in_chain",
        CASE
            WHEN (("l"."correction_status" = ANY (ARRAY['PENDING'::"text", 'FAILED'::"text"])) AND ("cl"."audit_log_id" IS NOT NULL)) THEN true
            ELSE false
        END AS "can_retry"
   FROM ("public"."match_audit_log" "l"
     LEFT JOIN "chain_latest" "cl" ON (("l"."id" = "cl"."audit_log_id")))
  WHERE ("l"."action" = 'ADMIN_CORRECTION'::"text");


ALTER VIEW "public"."view_admin_correction_dashboard" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."view_admin_correction_status" AS
 SELECT "id" AS "audit_log_id",
    "match_id",
    "action",
    "correction_status",
    "correction_started_at",
    "correction_finished_at",
    "correction_error",
        CASE
            WHEN ("correction_status" = ANY (ARRAY['PENDING'::"text", 'FAILED'::"text"])) THEN true
            ELSE false
        END AS "can_retry",
    (EXTRACT(epoch FROM (COALESCE("correction_finished_at", "now"()) - "correction_started_at")))::numeric(10,2) AS "duration_seconds"
   FROM "public"."match_audit_log"
  WHERE ("action" = 'ADMIN_CORRECTION'::"text");


ALTER VIEW "public"."view_admin_correction_status" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admin_operation_log"
    ADD CONSTRAINT "admin_operation_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bets"
    ADD CONSTRAINT "bets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."elo_history"
    ADD CONSTRAINT "elo_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."match_audit_log"
    ADD CONSTRAINT "match_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."match_audit_logs"
    ADD CONSTRAINT "match_audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."match_events"
    ADD CONSTRAINT "match_events_client_request_id_key" UNIQUE ("client_request_id");



ALTER TABLE ONLY "public"."match_events"
    ADD CONSTRAINT "match_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mvp_votes"
    ADD CONSTRAINT "mvp_votes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notices"
    ADD CONSTRAINT "notices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profile_merge_log"
    ADD CONSTRAINT "profile_merge_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."queue"
    ADD CONSTRAINT "queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."queue"
    ADD CONSTRAINT "queue_player_id_key" UNIQUE ("player_id");



ALTER TABLE ONLY "public"."queue"
    ADD CONSTRAINT "queue_player_id_unique" UNIQUE ("player_id");



ALTER TABLE ONLY "public"."rating_adjustment_log"
    ADD CONSTRAINT "rating_adjustment_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."seasons"
    ADD CONSTRAINT "seasons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_flags"
    ADD CONSTRAINT "system_flags_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."mvp_votes"
    ADD CONSTRAINT "unique_vote_per_match" UNIQUE ("match_id", "voter_id");



CREATE INDEX "idx_elo_history_match_correction" ON "public"."elo_history" USING "btree" ("match_id", "is_correction", "id") WHERE ("match_id" IS NOT NULL);



CREATE INDEX "idx_match_audit_log_match_id" ON "public"."match_audit_log" USING "btree" ("match_id");



CREATE INDEX "idx_match_audit_logs_match_id" ON "public"."match_audit_logs" USING "btree" ("match_id");



ALTER TABLE ONLY "public"."bets"
    ADD CONSTRAINT "bets_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bets"
    ADD CONSTRAINT "bets_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."elo_history"
    ADD CONSTRAINT "elo_history_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_confirmed_by_fkey" FOREIGN KEY ("confirmed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_player_1_fkey" FOREIGN KEY ("player_1") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_player_2_fkey" FOREIGN KEY ("player_2") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_player_3_fkey" FOREIGN KEY ("player_3") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_player_4_fkey" FOREIGN KEY ("player_4") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_reported_by_fkey" FOREIGN KEY ("reported_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."mvp_votes"
    ADD CONSTRAINT "mvp_votes_target_id_fkey" FOREIGN KEY ("target_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."mvp_votes"
    ADD CONSTRAINT "mvp_votes_voter_id_fkey" FOREIGN KEY ("voter_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."queue"
    ADD CONSTRAINT "queue_user_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



CREATE POLICY "Admin Delete" ON "public"."profiles" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "profiles_1"
  WHERE (("profiles_1"."id" = "auth"."uid"()) AND ("profiles_1"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can insert ops logs" ON "public"."admin_operation_log" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can manage profile_merge_log" ON "public"."profile_merge_log" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can manage rating_adjustment_log" ON "public"."rating_adjustment_log" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can manage system_flags" ON "public"."system_flags" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can view all audit logs" ON "public"."match_audit_log" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can view audit logs" ON "public"."match_audit_logs" FOR SELECT USING ((("auth"."role"() = 'service_role'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text"))))));



CREATE POLICY "Admins can view ops logs" ON "public"."admin_operation_log" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Allow authenticated insert" ON "public"."mvp_votes" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow authenticated insert/update" ON "public"."notices" TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to insert guest profiles" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow public read" ON "public"."mvp_votes" FOR SELECT USING (true);



CREATE POLICY "Allow public read" ON "public"."notices" FOR SELECT USING (true);



CREATE POLICY "Auth Insert" ON "public"."profiles" FOR INSERT WITH CHECK (((("auth"."role"() = 'authenticated'::"text") AND ("is_guest" = true)) OR ("auth"."uid"() = "id")));



CREATE POLICY "Elo history viewable by everyone" ON "public"."elo_history" FOR SELECT USING (true);



CREATE POLICY "Enable all access for authenticated users" ON "public"."matches" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Enable all access for queue" ON "public"."queue" USING (true) WITH CHECK (true);



CREATE POLICY "Enable insert for all users" ON "public"."profiles" FOR INSERT WITH CHECK (true);



CREATE POLICY "Enable read access for all users" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Enable read/insert for users" ON "public"."bets" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Enable read/write for all users" ON "public"."mvp_votes" USING (true) WITH CHECK (true);



CREATE POLICY "Enable update for all users" ON "public"."profiles" FOR UPDATE USING (true);



CREATE POLICY "Everyone can read system_flags" ON "public"."system_flags" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Insert own votes" ON "public"."mvp_votes" FOR INSERT WITH CHECK (("auth"."uid"() = "voter_id"));



CREATE POLICY "MVP votes viewable by everyone" ON "public"."mvp_votes" FOR SELECT USING (true);



CREATE POLICY "Players can view logs for their matches" ON "public"."match_audit_log" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matches" "m"
  WHERE (("m"."id" = "match_audit_log"."match_id") AND (("m"."player_1" = "auth"."uid"()) OR ("m"."player_2" = "auth"."uid"()) OR ("m"."player_3" = "auth"."uid"()) OR ("m"."player_4" = "auth"."uid"()))))));



CREATE POLICY "Public Read" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Public Update" ON "public"."profiles" FOR UPDATE USING (true);



CREATE POLICY "Public access to queue" ON "public"."queue" USING (true) WITH CHECK (true);



CREATE POLICY "Public notices are viewable by everyone" ON "public"."notices" FOR SELECT USING (true);



CREATE POLICY "Public read mvp_votes" ON "public"."mvp_votes" FOR SELECT USING (true);



CREATE POLICY "Public read profiles" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Users can insert votes" ON "public"."mvp_votes" FOR INSERT WITH CHECK (("auth"."uid"() = "voter_id"));



ALTER TABLE "public"."admin_operation_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bets_delete_all" ON "public"."bets" FOR DELETE USING (true);



CREATE POLICY "bets_insert_all" ON "public"."bets" FOR INSERT WITH CHECK (true);



CREATE POLICY "bets_select_all" ON "public"."bets" FOR SELECT USING (true);



CREATE POLICY "bets_update_all" ON "public"."bets" FOR UPDATE USING (true);



ALTER TABLE "public"."elo_history" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "insert_own_profile" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



ALTER TABLE "public"."match_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."match_audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."match_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."matches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "matches_delete_all" ON "public"."matches" FOR DELETE USING (true);



CREATE POLICY "matches_insert_all" ON "public"."matches" FOR INSERT WITH CHECK (true);



CREATE POLICY "matches_select_all" ON "public"."matches" FOR SELECT USING (true);



CREATE POLICY "matches_update_all" ON "public"."matches" FOR UPDATE USING (true);



ALTER TABLE "public"."mvp_votes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "mvp_votes_delete_all" ON "public"."mvp_votes" FOR DELETE USING (true);



CREATE POLICY "mvp_votes_insert_all" ON "public"."mvp_votes" FOR INSERT WITH CHECK (true);



CREATE POLICY "mvp_votes_select_all" ON "public"."mvp_votes" FOR SELECT USING (true);



CREATE POLICY "mvp_votes_update_all" ON "public"."mvp_votes" FOR UPDATE USING (true);



ALTER TABLE "public"."notices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "policy_insert_own" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "policy_read_all" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "policy_update_own" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."profile_merge_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."queue" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "queue_delete_all" ON "public"."queue" FOR DELETE USING (true);



CREATE POLICY "queue_insert_all" ON "public"."queue" FOR INSERT WITH CHECK (true);



CREATE POLICY "queue_select_all" ON "public"."queue" FOR SELECT USING (true);



CREATE POLICY "queue_update_all" ON "public"."queue" FOR UPDATE USING (true);



ALTER TABLE "public"."rating_adjustment_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."seasons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "seasons_delete_all" ON "public"."seasons" FOR DELETE USING (true);



CREATE POLICY "seasons_insert_all" ON "public"."seasons" FOR INSERT WITH CHECK (true);



CREATE POLICY "seasons_select_all" ON "public"."seasons" FOR SELECT USING (true);



CREATE POLICY "seasons_update_all" ON "public"."seasons" FOR UPDATE USING (true);



ALTER TABLE "public"."system_flags" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "update_own_profile" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_adjust_rating"("p_player_id" "uuid", "p_new_rating" integer, "p_admin_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_adjust_rating"("p_player_id" "uuid", "p_new_rating" integer, "p_admin_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_adjust_rating"("p_player_id" "uuid", "p_new_rating" integer, "p_admin_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_apply_match_correction"("p_audit_log_id" "uuid", "p_admin_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_apply_match_correction"("p_audit_log_id" "uuid", "p_admin_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_apply_match_correction"("p_audit_log_id" "uuid", "p_admin_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_clear_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_clear_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_clear_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_correct_match_result"("p_match_id" "uuid", "p_correct_score1" integer, "p_correct_score2" integer, "p_admin_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_correct_match_result"("p_match_id" "uuid", "p_correct_score1" integer, "p_correct_score2" integer, "p_admin_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_correct_match_result"("p_match_id" "uuid", "p_correct_score1" integer, "p_correct_score2" integer, "p_admin_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_mark_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_mark_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_mark_no_show"("p_player_id" "uuid", "p_admin_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_merge_profile"("p_source" "uuid", "p_target" "uuid", "p_merged_by" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_merge_profile"("p_source" "uuid", "p_target" "uuid", "p_merged_by" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_merge_profile"("p_source" "uuid", "p_target" "uuid", "p_merged_by" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_prepare_undo"("p_target_correction_id" "uuid", "p_admin_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_prepare_undo"("p_target_correction_id" "uuid", "p_admin_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_prepare_undo"("p_target_correction_id" "uuid", "p_admin_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_preview_match_correction"("p_audit_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_preview_match_correction"("p_audit_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_preview_match_correction"("p_audit_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_system_flag"("p_key" "text", "p_value" boolean, "p_admin_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_system_flag"("p_key" "text", "p_value" boolean, "p_admin_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_system_flag"("p_key" "text", "p_value" boolean, "p_admin_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."confirm_match_v3_5"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid", "p_logic_version" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."confirm_match_v3_5"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid", "p_logic_version" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."confirm_match_v3_5"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid", "p_logic_version" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."finish_match_atomic"("p_match_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_confirmed_by" "uuid", "p_confirmation_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."finish_match_atomic"("p_match_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_confirmed_by" "uuid", "p_confirmation_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."finish_match_atomic"("p_match_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_confirmed_by" "uuid", "p_confirmation_type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_elo_policy"("p_is_guest" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_elo_policy"("p_is_guest" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_elo_policy"("p_is_guest" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."place_bet"("p_match_id" "uuid", "p_user_id" "uuid", "p_pick" "text", "p_amount" integer, "p_odds" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."place_bet"("p_match_id" "uuid", "p_user_id" "uuid", "p_pick" "text", "p_amount" integer, "p_odds" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."place_bet"("p_match_id" "uuid", "p_user_id" "uuid", "p_pick" "text", "p_amount" integer, "p_odds" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."process_match_completion"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."process_match_completion"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_match_completion"("p_match_id" "uuid", "p_reporter_id" "uuid", "p_team1_score" integer, "p_team2_score" integer, "p_elo_updates" "jsonb", "p_queue_inserts" "jsonb", "p_client_request_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."register_guest_and_enqueue"("p_name" "text", "p_ntrp" numeric, "p_gender" "text", "p_departure_time" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."register_guest_and_enqueue"("p_name" "text", "p_ntrp" numeric, "p_gender" "text", "p_departure_time" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_guest_and_enqueue"("p_name" "text", "p_ntrp" numeric, "p_gender" "text", "p_departure_time" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."settle_bets_trigger"() TO "anon";
GRANT ALL ON FUNCTION "public"."settle_bets_trigger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."settle_bets_trigger"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_player_elo"("p_match_type" character varying, "p_winners" "uuid"[], "p_losers" "uuid"[], "p_is_tournament" boolean, "p_is_draw" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."update_player_elo"("p_match_type" character varying, "p_winners" "uuid"[], "p_losers" "uuid"[], "p_is_tournament" boolean, "p_is_draw" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_player_elo"("p_match_type" character varying, "p_winners" "uuid"[], "p_losers" "uuid"[], "p_is_tournament" boolean, "p_is_draw" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."admin_operation_log" TO "anon";
GRANT ALL ON TABLE "public"."admin_operation_log" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_operation_log" TO "service_role";



GRANT ALL ON TABLE "public"."bets" TO "anon";
GRANT ALL ON TABLE "public"."bets" TO "authenticated";
GRANT ALL ON TABLE "public"."bets" TO "service_role";



GRANT ALL ON TABLE "public"."elo_history" TO "anon";
GRANT ALL ON TABLE "public"."elo_history" TO "authenticated";
GRANT ALL ON TABLE "public"."elo_history" TO "service_role";



GRANT ALL ON TABLE "public"."match_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."match_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."match_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."match_audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."match_audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."match_audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."match_events" TO "anon";
GRANT ALL ON TABLE "public"."match_events" TO "authenticated";
GRANT ALL ON TABLE "public"."match_events" TO "service_role";



GRANT ALL ON TABLE "public"."matches" TO "anon";
GRANT ALL ON TABLE "public"."matches" TO "authenticated";
GRANT ALL ON TABLE "public"."matches" TO "service_role";



GRANT ALL ON TABLE "public"."mvp_votes" TO "anon";
GRANT ALL ON TABLE "public"."mvp_votes" TO "authenticated";
GRANT ALL ON TABLE "public"."mvp_votes" TO "service_role";



GRANT ALL ON TABLE "public"."notices" TO "anon";
GRANT ALL ON TABLE "public"."notices" TO "authenticated";
GRANT ALL ON TABLE "public"."notices" TO "service_role";



GRANT ALL ON TABLE "public"."profile_merge_log" TO "anon";
GRANT ALL ON TABLE "public"."profile_merge_log" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_merge_log" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT SELECT("name") ON TABLE "public"."profiles" TO "anon";
GRANT SELECT("name") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("gender") ON TABLE "public"."profiles" TO "anon";
GRANT SELECT("gender") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("ntrp") ON TABLE "public"."profiles" TO "anon";
GRANT SELECT("ntrp") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("emoji") ON TABLE "public"."profiles" TO "anon";
GRANT SELECT("emoji") ON TABLE "public"."profiles" TO "authenticated";



GRANT ALL ON TABLE "public"."queue" TO "anon";
GRANT ALL ON TABLE "public"."queue" TO "authenticated";
GRANT ALL ON TABLE "public"."queue" TO "service_role";



GRANT ALL ON TABLE "public"."rating_adjustment_log" TO "anon";
GRANT ALL ON TABLE "public"."rating_adjustment_log" TO "authenticated";
GRANT ALL ON TABLE "public"."rating_adjustment_log" TO "service_role";



GRANT ALL ON TABLE "public"."seasons" TO "anon";
GRANT ALL ON TABLE "public"."seasons" TO "authenticated";
GRANT ALL ON TABLE "public"."seasons" TO "service_role";



GRANT ALL ON TABLE "public"."system_flags" TO "anon";
GRANT ALL ON TABLE "public"."system_flags" TO "authenticated";
GRANT ALL ON TABLE "public"."system_flags" TO "service_role";



GRANT ALL ON TABLE "public"."view_admin_correction_chain" TO "anon";
GRANT ALL ON TABLE "public"."view_admin_correction_chain" TO "authenticated";
GRANT ALL ON TABLE "public"."view_admin_correction_chain" TO "service_role";



GRANT ALL ON TABLE "public"."view_admin_correction_chain_detail" TO "anon";
GRANT ALL ON TABLE "public"."view_admin_correction_chain_detail" TO "authenticated";
GRANT ALL ON TABLE "public"."view_admin_correction_chain_detail" TO "service_role";



GRANT ALL ON TABLE "public"."view_admin_correction_dashboard" TO "anon";
GRANT ALL ON TABLE "public"."view_admin_correction_dashboard" TO "authenticated";
GRANT ALL ON TABLE "public"."view_admin_correction_dashboard" TO "service_role";



GRANT ALL ON TABLE "public"."view_admin_correction_status" TO "anon";
GRANT ALL ON TABLE "public"."view_admin_correction_status" TO "authenticated";
GRANT ALL ON TABLE "public"."view_admin_correction_status" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







