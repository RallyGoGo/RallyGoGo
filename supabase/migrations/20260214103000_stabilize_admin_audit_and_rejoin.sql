-- =============================================================================
-- Stabilization Patch
-- Date: 2026-02-14
-- Goal:
--   1) Stop admin confirm/reject runtime failures caused by audit-log constraints.
--   2) Unify admin confirm flow through finish_match_v2.
--   3) Restore queue departure_time on score/report and post-finish rejoin.
--   4) Normalize admin_operation_log target_type values.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0) Schema safety guards (fresh/stale environments)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'matches'
          AND column_name = 'created_by'
    ) THEN
        ALTER TABLE public.matches
        ADD COLUMN created_by UUID REFERENCES auth.users(id);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'matches'
          AND column_name = 'player_departure_times'
    ) THEN
        ALTER TABLE public.matches
        ADD COLUMN player_departure_times JSONB DEFAULT '{}'::jsonb;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'queue'
          AND column_name = 'updated_at'
    ) THEN
        ALTER TABLE public.queue
        ADD COLUMN updated_at TIMESTAMPTZ DEFAULT now();
    END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 1) Canonical helper: restore rejoin with departure_time
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rejoin_queue_after_match(p_match_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_match RECORD;
    v_pid UUID;
    v_dep_time TIMESTAMPTZ;
    v_now TIMESTAMPTZ := now();
    v_min_time TIMESTAMPTZ := v_now + INTERVAL '30 minutes';
    v_rejoined_count INTEGER := 0;
    v_skipped_count INTEGER := 0;
BEGIN
    SELECT id, player_1, player_2, player_3, player_4, player_departure_times
      INTO v_match
      FROM public.matches
     WHERE id = p_match_id;

    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
    END IF;

    FOREACH v_pid IN ARRAY ARRAY[v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4]
    LOOP
        IF v_pid IS NULL THEN
            CONTINUE;
        END IF;

        BEGIN
            v_dep_time := NULL;
            IF v_match.player_departure_times IS NOT NULL
               AND v_match.player_departure_times ? v_pid::text THEN
                v_dep_time := (v_match.player_departure_times ->> v_pid::text)::timestamptz;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                v_dep_time := NULL;
        END;

        -- Preserve original 30-minute rule.
        IF v_dep_time IS NULL OR v_dep_time <= v_min_time THEN
            v_skipped_count := v_skipped_count + 1;
            CONTINUE;
        END IF;

        INSERT INTO public.queue (
            player_id,
            departure_time,
            priority_score,
            is_active,
            joined_at
        )
        VALUES (
            v_pid,
            v_dep_time,
            GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (v_dep_time - v_now)) / 60)::INTEGER),
            true,
            v_now
        )
        ON CONFLICT (player_id) DO UPDATE
        SET is_active = true,
            joined_at = EXCLUDED.joined_at,
            priority_score = EXCLUDED.priority_score,
            departure_time = EXCLUDED.departure_time;

        v_rejoined_count := v_rejoined_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'rejoined_count', v_rejoined_count,
        'skipped_count', v_skipped_count
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rejoin_queue_after_match(UUID) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2) report_score: restore departure_time immediately on queue rejoin
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_score(
    p_match_id UUID,
    p_team1_score INTEGER,
    p_team2_score INTEGER,
    p_winner TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
    v_match RECORD;
    v_is_participant BOOLEAN;
    v_is_admin BOOLEAN;
    v_trigger_role TEXT := 'PLAYER';
    v_pid UUID;
    v_dep_time TIMESTAMPTZ;
    v_departure_times JSONB;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    SELECT *
      INTO v_match
      FROM public.matches
     WHERE id = p_match_id
     FOR UPDATE;

    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE id = v_user_id
          AND role = 'admin'
    ) INTO v_is_admin;

    IF v_is_admin THEN
        v_trigger_role := 'ADMIN';
    END IF;

    v_is_participant := v_user_id IN (v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4);
    IF NOT v_is_participant AND NOT v_is_admin THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    IF v_match.status NOT IN ('PLAYING', 'SCORING', 'PENDING') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_STATUS',
            'message', '점수 입력은 PLAYING/SCORING/PENDING 상태에서만 가능합니다. 현재: ' || v_match.status::text
        );
    END IF;

    UPDATE public.matches
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
        status = 'PENDING'
    WHERE id = p_match_id;

    v_departure_times := v_match.player_departure_times;
    FOREACH v_pid IN ARRAY ARRAY[v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4]
    LOOP
        IF v_pid IS NULL THEN
            CONTINUE;
        END IF;

        BEGIN
            v_dep_time := NULL;
            IF v_departure_times IS NOT NULL AND v_departure_times ? v_pid::text THEN
                v_dep_time := (v_departure_times ->> v_pid::text)::timestamptz;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                v_dep_time := NULL;
        END;

        INSERT INTO public.queue (
            player_id,
            priority_score,
            is_active,
            joined_at,
            departure_time
        )
        VALUES (
            v_pid,
            500,
            true,
            now(),
            v_dep_time
        )
        ON CONFLICT (player_id) DO UPDATE
        SET is_active = true,
            priority_score = 500,
            joined_at = now(),
            departure_time = COALESCE(EXCLUDED.departure_time, queue.departure_time);
    END LOOP;

    BEGIN
        INSERT INTO public.match_audit_log (
            match_id,
            action,
            triggered_by,
            trigger_role,
            match_status_before,
            match_status_after,
            score_team1,
            score_team2
        )
        VALUES (
            p_match_id,
            'SCORE_UPDATE',
            v_user_id,
            v_trigger_role,
            v_match.status,
            'PENDING',
            p_team1_score,
            p_team2_score
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'report_score audit log failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
        'success', true,
        'match_id', p_match_id,
        'status', 'PENDING',
        'score_team1', p_team1_score,
        'score_team2', p_team2_score,
        'queue_rejoined', true,
        'message', '점수가 기록되었습니다. 대기열에 자동 복귀되었습니다.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_score(UUID, INTEGER, INTEGER, TEXT) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) admin_confirm_match: single path via finish_match_v2 + post-rejoin sync
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_confirm_match(p_match_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_match RECORD;
    v_result JSONB;
    v_rejoin_result JSONB;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    SELECT *
      INTO v_match
      FROM public.matches
     WHERE id = p_match_id
     FOR UPDATE;

    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
    END IF;

    IF v_match.status NOT IN ('SCORING', 'DISPUTED', 'PENDING') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_STATUS',
            'current_status', v_match.status
        );
    END IF;

    IF v_match.score_team1 IS NULL OR v_match.score_team2 IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'SCORE_REQUIRED',
            'message', '점수가 입력되지 않았습니다.'
        );
    END IF;

    v_result := public.finish_match_v2(
        p_match_id,
        COALESCE(v_match.score_team1, 0),
        COALESCE(v_match.score_team2, 0),
        'ADMIN_FORCE_CONFIRM'
    );

    IF COALESCE((v_result ->> 'success')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN v_result;
    END IF;

    BEGIN
        v_rejoin_result := public.rejoin_queue_after_match(p_match_id);
    EXCEPTION
        WHEN OTHERS THEN
            v_rejoin_result := jsonb_build_object('success', false, 'error', SQLERRM);
    END;

    RETURN v_result || jsonb_build_object('rejoin_result', v_rejoin_result);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_confirm_match(UUID) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4) admin_rollback_match: audit action/role normalization
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_rollback_match(
    p_match_id UUID,
    p_reason TEXT DEFAULT 'Admin rollback'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_match RECORD;
    v_user_id UUID := auth.uid();
    v_is_admin BOOLEAN := false;
    v_trigger_role TEXT := 'PLAYER';
    v_elo_field TEXT;
    v_delta INT;
    v_winners UUID[];
    v_losers UUID[];
    v_player RECORD;
    v_affected_count INT := 0;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    SELECT COALESCE(role = 'admin', false)
      INTO v_is_admin
      FROM public.profiles
     WHERE id = v_user_id;
    IF v_is_admin THEN
        v_trigger_role := 'ADMIN';
    END IF;

    SELECT *
      INTO v_match
      FROM public.matches
     WHERE id = p_match_id
     FOR UPDATE;

    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
    END IF;

    v_elo_field := CASE v_match.match_type
        WHEN 'MENS_DOUBLES' THEN 'elo_mens_doubles'
        WHEN 'WOMENS_DOUBLES' THEN 'elo_womens_doubles'
        WHEN 'SINGLES' THEN 'elo_singles'
        ELSE 'elo_mixed_doubles'
    END;

    IF v_match.status = 'FINISHED' THEN
        SELECT ABS(delta)
          INTO v_delta
          FROM public.elo_history
         WHERE match_id = p_match_id
           AND delta IS NOT NULL
         LIMIT 1;

        IF v_delta IS NOT NULL
           AND v_delta > 0
           AND v_match.winner_team IS NOT NULL
           AND v_match.winner_team != 'DRAW' THEN
            IF v_match.winner_team = 'TEAM_1' THEN
                v_winners := ARRAY[v_match.player_1, v_match.player_2];
                v_losers := ARRAY[v_match.player_3, v_match.player_4];
            ELSE
                v_winners := ARRAY[v_match.player_3, v_match.player_4];
                v_losers := ARRAY[v_match.player_1, v_match.player_2];
            END IF;

            FOR v_player IN
                SELECT id
                FROM public.profiles
                WHERE id = ANY(v_winners)
                FOR UPDATE
            LOOP
                EXECUTE format(
                    'UPDATE public.profiles SET %I = COALESCE(%I, 1200) - $1 WHERE id = $2',
                    v_elo_field,
                    v_elo_field
                ) USING v_delta, v_player.id;

                v_affected_count := v_affected_count + 1;
            END LOOP;

            FOR v_player IN
                SELECT id
                FROM public.profiles
                WHERE id = ANY(v_losers)
                FOR UPDATE
            LOOP
                EXECUTE format(
                    'UPDATE public.profiles SET %I = COALESCE(%I, 1200) + $1 WHERE id = $2',
                    v_elo_field,
                    v_elo_field
                ) USING v_delta, v_player.id;

                v_affected_count := v_affected_count + 1;
            END LOOP;
        END IF;
    END IF;

    BEGIN
        INSERT INTO public.match_audit_log (
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
            v_trigger_role,
            v_match.status,
            'CANCELLED',
            p_reason
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'admin_rollback_match audit log failed: %', SQLERRM;
    END;

    DELETE FROM public.matches
    WHERE id = p_match_id;

    RETURN jsonb_build_object(
        'success', true,
        'affected_players', v_affected_count,
        'message', 'Match rolled back successfully'
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rollback_match(UUID, TEXT) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5) cancel_match/dispute_match: audit value normalization
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_match(p_match_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
    v_match RECORD;
    v_is_admin BOOLEAN := false;
    v_trigger_role TEXT := 'PLAYER';
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    SELECT COALESCE(role = 'admin', false)
      INTO v_is_admin
      FROM public.profiles
     WHERE id = v_user_id;
    IF v_is_admin THEN
        v_trigger_role := 'ADMIN';
    END IF;

    SELECT *
      INTO v_match
      FROM public.matches
     WHERE id = p_match_id
     FOR UPDATE;

    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
    END IF;

    IF v_match.status NOT IN ('DRAFT', 'PLAYING', 'SCORING', 'PENDING') THEN
        RETURN jsonb_build_object('success', false, 'error', 'CANNOT_CANCEL', 'message', '취소 불가 상태입니다.');
    END IF;

    UPDATE public.matches
    SET status = 'CANCELLED'
    WHERE id = p_match_id;

    UPDATE public.bets
    SET result = 'CANCELLED'
    WHERE match_id = p_match_id
      AND result IN ('OPEN', 'LOCKED');

    UPDATE public.profiles p
    SET rally_point = p.rally_point + b.amount
    FROM public.bets b
    WHERE b.match_id = p_match_id
      AND b.result = 'CANCELLED'
      AND p.id = b.user_id;

    BEGIN
        INSERT INTO public.match_audit_log (
            match_id,
            action,
            triggered_by,
            trigger_role,
            match_status_before,
            match_status_after
        )
        VALUES (
            p_match_id,
            'CANCEL_MATCH',
            v_user_id,
            v_trigger_role,
            v_match.status,
            'CANCELLED'
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'cancel_match audit log failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
        'success', true,
        'match_id', p_match_id,
        'message', '경기가 취소되었습니다.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_match(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.dispute_match(p_match_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_match RECORD;
    v_user_id UUID := auth.uid();
    v_is_participant BOOLEAN;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    SELECT *
      INTO v_match
      FROM public.matches
     WHERE id = p_match_id
     FOR UPDATE;

    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
    END IF;

    IF v_match.status <> 'SCORING' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_match.status);
    END IF;

    v_is_participant := (
        v_match.player_1 = v_user_id OR
        v_match.player_2 = v_user_id OR
        v_match.player_3 = v_user_id OR
        v_match.player_4 = v_user_id
    );
    IF NOT v_is_participant THEN
        RETURN jsonb_build_object('success', false, 'error', 'NOT_PARTICIPANT');
    END IF;

    UPDATE public.matches
    SET status = 'DISPUTED',
        confirmed_by = NULL
    WHERE id = p_match_id;

    BEGIN
        INSERT INTO public.match_audit_log (
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
            'STATUS_CHANGE',
            v_user_id,
            'PLAYER',
            'SCORING',
            'DISPUTED',
            'Player disputed the reported score'
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'dispute_match audit log failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('success', true, 'message', 'Match disputed successfully');
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.dispute_match(UUID) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6) admin operation RPCs: normalize target_type values (PROFILE/QUEUE/SYSTEM)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_clear_queue()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_deleted_count INT;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    DELETE FROM public.queue
    WHERE true;
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    BEGIN
        INSERT INTO public.admin_operation_log (operated_by, action, target_type, new_value)
        VALUES (
            v_user_id,
            'CLEAR_QUEUE',
            'QUEUE',
            jsonb_build_object('deleted_count', v_deleted_count)::text
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'admin_clear_queue operation log failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('success', true, 'deleted_count', v_deleted_count);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_clear_queue() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_update_profile(
    p_profile_id UUID,
    p_name TEXT DEFAULT NULL,
    p_gender TEXT DEFAULT NULL,
    p_ntrp NUMERIC DEFAULT NULL,
    p_role TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_old_values JSONB;
    v_current_ntrp NUMERIC;
    v_new_elo INT;
    v_msg TEXT := '프로필이 수정되었습니다.';
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    SELECT jsonb_build_object(
               'name', name,
               'gender', gender,
               'ntrp', ntrp,
               'role', role
           ),
           ntrp
      INTO v_old_values, v_current_ntrp
      FROM public.profiles
     WHERE id = p_profile_id;

    IF v_old_values IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'PROFILE_NOT_FOUND');
    END IF;

    v_new_elo := NULL;
    IF p_ntrp IS NOT NULL AND p_ntrp <> v_current_ntrp THEN
        v_new_elo := ROUND(p_ntrp * 400);
    END IF;

    UPDATE public.profiles
    SET name = COALESCE(p_name, name),
        gender = COALESCE(p_gender::gender_t, gender),
        ntrp = COALESCE(p_ntrp, ntrp),
        role = COALESCE(p_role::user_role_t, role),
        elo_mens_doubles = CASE WHEN v_new_elo IS NOT NULL THEN v_new_elo ELSE elo_mens_doubles END,
        elo_womens_doubles = CASE WHEN v_new_elo IS NOT NULL THEN v_new_elo ELSE elo_womens_doubles END,
        elo_mixed_doubles = CASE WHEN v_new_elo IS NOT NULL THEN v_new_elo ELSE elo_mixed_doubles END,
        elo_singles = CASE WHEN v_new_elo IS NOT NULL THEN v_new_elo ELSE elo_singles END,
        updated_at = now()
    WHERE id = p_profile_id;

    IF v_new_elo IS NOT NULL THEN
        v_msg := '프로필 수정 및 ELO 점수가 초기화되었습니다 (' || v_new_elo || '점)';
    END IF;

    BEGIN
        INSERT INTO public.admin_operation_log (
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
            'PROFILE',
            p_profile_id,
            v_old_values::text,
            jsonb_build_object('name', p_name, 'ntrp', p_ntrp, 'new_elo', v_new_elo)::text
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'admin_update_profile operation log failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('success', true, 'message', v_msg);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_profile(UUID, TEXT, TEXT, NUMERIC, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_season_soft_reset()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_affected_count INT;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    UPDATE public.profiles
    SET elo_mens_doubles = 1200 + (COALESCE(elo_mens_doubles, 1200) - 1200) / 2,
        elo_womens_doubles = 1200 + (COALESCE(elo_womens_doubles, 1200) - 1200) / 2,
        elo_mixed_doubles = 1200 + (COALESCE(elo_mixed_doubles, 1200) - 1200) / 2,
        elo_singles = 1200 + (COALESCE(elo_singles, 1200) - 1200) / 2,
        games_played_today = 0
    WHERE role != 'coach';

    GET DIAGNOSTICS v_affected_count = ROW_COUNT;

    BEGIN
        INSERT INTO public.admin_operation_log (
            operated_by,
            action,
            target_type,
            reason,
            new_value
        )
        VALUES (
            v_user_id,
            'SEASON_SOFT_RESET',
            'SYSTEM',
            'Season compression applied',
            jsonb_build_object('affected_count', v_affected_count)::text
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'admin_season_soft_reset operation log failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
        'success', true,
        'affected_profiles', v_affected_count,
        'message', 'Season soft reset completed'
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_season_soft_reset() TO authenticated, service_role;
