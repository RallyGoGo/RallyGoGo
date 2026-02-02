CREATE OR REPLACE FUNCTION public.admin_preview_match_correction(p_audit_log_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
-- loop var
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
-- Tier Logic
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
-- Tier Check (Logic: Change in 100-point bracket)
-- e.g. 1490 (14) -> 1510 (15) => TRUE
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
$function$;

