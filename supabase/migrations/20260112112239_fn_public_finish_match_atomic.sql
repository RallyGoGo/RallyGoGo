CREATE OR REPLACE FUNCTION public.finish_match_atomic(p_match_id uuid, p_team1_score integer, p_team2_score integer, p_confirmed_by uuid, p_confirmation_type text DEFAULT 'NORMAL_CONFIRM'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_match public.matches %ROWTYPE;
v_team1_ids UUID [];
v_team2_ids UUID [];
v_all_player_ids UUID [];
v_profile RECORD;
-- ELO Calc Variables
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
-- Policy Vars
v_k_factor INT;
v_base_multiplier NUMERIC;
v_guest_multiplier NUMERIC;
v_applied_multiplier NUMERIC;
-- Audit Vars
v_status_before TEXT;
v_trigger_role TEXT;
v_is_force BOOLEAN;
BEGIN -- 0. Input Validation (Strict Type Check)
IF p_confirmation_type NOT IN ('NORMAL_CONFIRM', 'ADMIN_FORCE_CONFIRM') THEN RETURN jsonb_build_object('error', 'INVALID_CONFIRMATION_TYPE');
END IF;
-- 0.1 Score Validation (Safety Guard)
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
-- 1. Lock Match & Validate
SELECT * INTO v_match
FROM public.matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('error', 'MATCH_NOT_FOUND');
END IF;
-- Idempotency Check (No Log)
IF v_match.status = 'FINISHED' THEN RETURN jsonb_build_object('error', 'ALREADY_FINISHED');
END IF;
-- Capture State Before
v_status_before := v_match.status;
-- 2. Identify Players
v_team1_ids := ARRAY [v_match.player_1, v_match.player_2];
v_team2_ids := ARRAY [v_match.player_3, v_match.player_4];
-- Filter NULLs
SELECT array_agg(id) INTO v_team1_ids
FROM unnest(v_team1_ids) AS id
WHERE id IS NOT NULL;
SELECT array_agg(id) INTO v_team2_ids
FROM unnest(v_team2_ids) AS id
WHERE id IS NOT NULL;
v_all_player_ids := v_team1_ids || v_team2_ids;
-- 2.5 Security & Permission Check
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
-- 3. Calculate Team Averages
-- Team 1
FOR v_profile IN
SELECT *
FROM public.profiles
WHERE id = ANY(v_team1_ids) LOOP v_team1_rating := v_team1_rating + COALESCE(v_profile.elo_mixed_doubles, 1200);
v_team1_count := v_team1_count + 1;
END LOOP;
-- Team 2
FOR v_profile IN
SELECT *
FROM public.profiles
WHERE id = ANY(v_team2_ids) LOOP v_team2_rating := v_team2_rating + COALESCE(v_profile.elo_mixed_doubles, 1200);
v_team2_count := v_team2_count + 1;
END LOOP;
-- Safety Check
IF v_team1_count = 0
OR v_team2_count = 0 THEN RETURN jsonb_build_object('error', 'MISSING_PLAYERS');
END IF;
v_team1_rating := v_team1_rating / v_team1_count;
v_team2_rating := v_team2_rating / v_team2_count;
-- 4. Calculate Expected & Base Delta
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
-- POLICY SNAPSHOT
SELECT k_factor,
    multiplier INTO v_k_factor,
    v_base_multiplier
FROM public.get_elo_policy(false);
SELECT multiplier INTO v_guest_multiplier
FROM public.get_elo_policy(true);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
-- 5. Apply Updates Loop
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
-- Apply Multiplier
IF v_profile.is_guest THEN v_applied_multiplier := v_guest_multiplier;
ELSE v_applied_multiplier := v_base_multiplier;
END IF;
IF v_applied_multiplier <> 1.0 THEN final_delta := ROUND(final_delta * v_applied_multiplier);
END IF;
v_old_rating := COALESCE(v_profile.elo_mixed_doubles, 1200);
v_new_rating := v_old_rating + final_delta;
-- UPDATE PROFILE (NULL-Safe Games Played)
UPDATE public.profiles
SET elo_mixed_doubles = v_new_rating,
    games_played_today = COALESCE(games_played_today, 0) + 1 -- Safe Increment
WHERE id = v_profile.id;
-- RECORD HISTORY
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
-- Build Response Log
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
-- 6. Cleanup Queue
DELETE FROM public.queue
WHERE player_id = ANY(v_all_player_ids)
    AND is_active = true;
-- 7. Finalize Match
UPDATE public.matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    confirmed_by = p_confirmed_by,
    end_time = NOW()
WHERE id = p_match_id;
-- 8. AUDIT LOG (Plan C: Strict Alignment)
-- Determine Role: Participant -> PLAYER, Else -> ADMIN
IF p_confirmed_by = ANY(v_all_player_ids) THEN v_trigger_role := 'PLAYER';
ELSE v_trigger_role := 'ADMIN';
END IF;
-- Determine Force Flag
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
$function$;

