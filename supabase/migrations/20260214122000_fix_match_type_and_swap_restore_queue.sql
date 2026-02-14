-- ============================================================================
-- Fix: Match Type Drift + Swap Queue State Restore
-- Date: 2026-02-14
--
-- Problem 1:
--   Same-gender doubles sometimes finalized as MIXED, causing unexpected
--   elo_mixed_doubles updates.
--
-- Problem 2:
--   swap_player reinserts the swapped-out player with joined_at=now(),
--   priority_score=1000. This resets waiting context and makes queue score drop.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0) Schema guard for queue snapshot in matches
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'matches'
          AND column_name = 'player_queue_meta'
    ) THEN
        ALTER TABLE public.matches
        ADD COLUMN player_queue_meta JSONB DEFAULT '{}'::jsonb;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 1) create_match_draft: store queue snapshot + normalize effective match_type
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_match_draft(
    p_player_ids UUID[],
    p_match_type match_type_t DEFAULT 'MIXED',
    p_court_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
    v_match_id UUID;
    v_player_count INTEGER;
    v_departure_times JSONB := '{}'::jsonb;
    v_queue_meta JSONB := '{}'::jsonb;
    v_queue_record RECORD;
    v_p3 UUID;
    v_p4 UUID;
    v_effective_match_type match_type_t := COALESCE(p_match_type, 'MIXED');
    v_male_count INTEGER := 0;
    v_female_count INTEGER := 0;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    v_player_count := array_length(p_player_ids, 1);
    IF v_player_count IS NULL OR v_player_count < 2 OR v_player_count > 4 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_PLAYER_COUNT',
            'message', '2~4명의 플레이어를 선택해주세요.'
        );
    END IF;

    -- Normalize match type to prevent accidental MIXED ELO updates on same-gender doubles.
    IF v_player_count = 2 THEN
        v_effective_match_type := 'SINGLES';
    ELSIF v_effective_match_type = 'MIXED' THEN
        SELECT
            COUNT(*) FILTER (WHERE gender = 'MALE'),
            COUNT(*) FILTER (WHERE gender = 'FEMALE')
          INTO v_male_count, v_female_count
          FROM public.profiles
         WHERE id = ANY(p_player_ids);

        IF v_male_count = v_player_count THEN
            v_effective_match_type := 'MENS_DOUBLES';
        ELSIF v_female_count = v_player_count THEN
            v_effective_match_type := 'WOMENS_DOUBLES';
        END IF;
    END IF;

    -- Singles slot mapping
    v_p3 := NULL;
    v_p4 := NULL;
    IF v_effective_match_type = 'SINGLES' OR v_player_count = 2 THEN
        v_p3 := p_player_ids[2];
    END IF;

    -- Capture queue snapshot before removal
    FOR v_queue_record IN
        SELECT player_id, departure_time, priority_score, joined_at
        FROM public.queue
        WHERE player_id = ANY(p_player_ids)
          AND is_active = true
    LOOP
        v_departure_times := v_departure_times || jsonb_build_object(
            v_queue_record.player_id::text,
            v_queue_record.departure_time
        );

        v_queue_meta := v_queue_meta || jsonb_build_object(
            v_queue_record.player_id::text,
            jsonb_build_object(
                'priority_score', v_queue_record.priority_score,
                'joined_at', v_queue_record.joined_at,
                'departure_time', v_queue_record.departure_time
            )
        );
    END LOOP;

    INSERT INTO public.matches (
        player_1,
        player_2,
        player_3,
        player_4,
        status,
        match_type,
        court_name,
        player_departure_times,
        player_queue_meta,
        created_at,
        created_by
    )
    VALUES (
        p_player_ids[1],
        CASE
            WHEN v_effective_match_type = 'SINGLES' THEN NULL
            ELSE p_player_ids[2]
        END,
        CASE
            WHEN v_effective_match_type = 'SINGLES' THEN p_player_ids[2]
            ELSE p_player_ids[3]
        END,
        CASE
            WHEN v_player_count >= 4 THEN p_player_ids[4]
            ELSE NULL
        END,
        'DRAFT',
        v_effective_match_type,
        p_court_name,
        v_departure_times,
        v_queue_meta,
        now(),
        v_user_id
    )
    RETURNING id INTO v_match_id;

    DELETE FROM public.queue
    WHERE player_id = ANY(p_player_ids);

    RETURN jsonb_build_object(
        'success', true,
        'match_id', v_match_id,
        'status', 'DRAFT',
        'match_type', v_effective_match_type,
        'message', '매치가 생성되었습니다.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_match_draft(UUID[], match_type_t, TEXT) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2) swap_player: restore swapped-out player's queue snapshot (joined_at/priority)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.swap_player(
    p_match_id UUID,
    p_old_player_id UUID,
    p_new_player_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_match RECORD;
    v_col TEXT;
    v_departure_times JSONB := '{}'::jsonb;
    v_queue_meta JSONB := '{}'::jsonb;
    v_new_queue RECORD;
    v_new_meta JSONB := '{}'::jsonb;
    v_old_meta JSONB := '{}'::jsonb;
    v_old_priority NUMERIC;
    v_old_joined TIMESTAMPTZ;
    v_old_departure TIMESTAMPTZ;
    v_new_departure TIMESTAMPTZ;
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
    IF v_match.status <> 'DRAFT' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_DRAFT');
    END IF;

    IF p_new_player_id IN (v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4) THEN
        RETURN jsonb_build_object('success', false, 'error', 'NEW_PLAYER_ALREADY_IN_MATCH');
    END IF;

    IF v_match.player_1 = p_old_player_id THEN
        v_col := 'player_1';
    ELSIF v_match.player_2 = p_old_player_id THEN
        v_col := 'player_2';
    ELSIF v_match.player_3 = p_old_player_id THEN
        v_col := 'player_3';
    ELSIF v_match.player_4 = p_old_player_id THEN
        v_col := 'player_4';
    ELSE
        RETURN jsonb_build_object('success', false, 'error', 'PLAYER_NOT_IN_MATCH');
    END IF;

    v_departure_times := COALESCE(v_match.player_departure_times, '{}'::jsonb);
    v_queue_meta := COALESCE(v_match.player_queue_meta, '{}'::jsonb);

    -- New player should come from queue; capture snapshot before removing.
    SELECT player_id, priority_score, joined_at, departure_time
      INTO v_new_queue
      FROM public.queue
     WHERE player_id = p_new_player_id
       AND is_active = true
     FOR UPDATE;

    IF v_new_queue IS NULL AND NOT (v_queue_meta ? p_new_player_id::text) THEN
        RETURN jsonb_build_object('success', false, 'error', 'NEW_PLAYER_NOT_IN_QUEUE');
    END IF;

    IF v_new_queue IS NOT NULL THEN
        v_new_meta := jsonb_build_object(
            'priority_score', v_new_queue.priority_score,
            'joined_at', v_new_queue.joined_at,
            'departure_time', v_new_queue.departure_time
        );
        v_new_departure := v_new_queue.departure_time;
    ELSE
        v_new_meta := COALESCE(v_queue_meta -> p_new_player_id::text, '{}'::jsonb);
        BEGIN
            v_new_departure := (v_new_meta ->> 'departure_time')::timestamptz;
        EXCEPTION
            WHEN OTHERS THEN
                v_new_departure := NULL;
        END;
    END IF;

    -- Restore old player's waiting context from snapshot.
    v_old_meta := COALESCE(v_queue_meta -> p_old_player_id::text, '{}'::jsonb);
    BEGIN
        v_old_priority := (v_old_meta ->> 'priority_score')::numeric;
    EXCEPTION
        WHEN OTHERS THEN
            v_old_priority := NULL;
    END;
    BEGIN
        v_old_joined := (v_old_meta ->> 'joined_at')::timestamptz;
    EXCEPTION
        WHEN OTHERS THEN
            v_old_joined := NULL;
    END;
    BEGIN
        v_old_departure := (v_old_meta ->> 'departure_time')::timestamptz;
    EXCEPTION
        WHEN OTHERS THEN
            v_old_departure := NULL;
    END;

    IF v_old_departure IS NULL AND v_departure_times ? p_old_player_id::text THEN
        BEGIN
            v_old_departure := (v_departure_times ->> p_old_player_id::text)::timestamptz;
        EXCEPTION
            WHEN OTHERS THEN
                v_old_departure := NULL;
        END;
    END IF;

    v_old_priority := COALESCE(v_old_priority, 500);
    v_old_joined := COALESCE(v_old_joined, v_match.created_at, now());

    INSERT INTO public.queue (
        player_id,
        priority_score,
        joined_at,
        is_active,
        departure_time
    )
    VALUES (
        p_old_player_id,
        v_old_priority,
        v_old_joined,
        true,
        v_old_departure
    )
    ON CONFLICT (player_id) DO UPDATE
    SET is_active = true,
        priority_score = COALESCE(EXCLUDED.priority_score, queue.priority_score),
        joined_at = COALESCE(EXCLUDED.joined_at, queue.joined_at),
        departure_time = COALESCE(EXCLUDED.departure_time, queue.departure_time);

    DELETE FROM public.queue
    WHERE player_id = p_new_player_id
      AND is_active = true;

    -- Keep snapshots aligned with current match players.
    v_queue_meta := v_queue_meta - p_old_player_id::text;
    v_queue_meta := jsonb_set(v_queue_meta, ARRAY[p_new_player_id::text], v_new_meta, true);

    v_departure_times := v_departure_times - p_old_player_id::text;
    IF v_new_departure IS NOT NULL THEN
        v_departure_times := jsonb_set(v_departure_times, ARRAY[p_new_player_id::text], to_jsonb(v_new_departure), true);
    END IF;

    EXECUTE format(
        'UPDATE public.matches SET %I = $1, player_queue_meta = $2, player_departure_times = $3 WHERE id = $4',
        v_col
    )
    USING p_new_player_id, v_queue_meta, v_departure_times, p_match_id;

    RETURN jsonb_build_object(
        'success', true,
        'restored_player_id', p_old_player_id,
        'restored_joined_at', v_old_joined,
        'restored_priority', v_old_priority
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.swap_player(UUID, UUID, UUID) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3) admin_confirm_match: normalize effective match_type before finalize
-- ----------------------------------------------------------------------------
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
    v_effective_match_type match_type_t;
    v_player_count INTEGER := 0;
    v_male_count INTEGER := 0;
    v_female_count INTEGER := 0;
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

    v_effective_match_type := COALESCE(v_match.match_type, 'MIXED');
    SELECT COUNT(*) INTO v_player_count
    FROM unnest(ARRAY[v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4]) x
    WHERE x IS NOT NULL;

    IF v_player_count = 2 THEN
        v_effective_match_type := 'SINGLES';
    ELSIF v_effective_match_type = 'MIXED' THEN
        SELECT
            COUNT(*) FILTER (WHERE gender = 'MALE'),
            COUNT(*) FILTER (WHERE gender = 'FEMALE')
          INTO v_male_count, v_female_count
          FROM public.profiles
         WHERE id IN (v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4);

        IF v_male_count = v_player_count THEN
            v_effective_match_type := 'MENS_DOUBLES';
        ELSIF v_female_count = v_player_count THEN
            v_effective_match_type := 'WOMENS_DOUBLES';
        END IF;
    END IF;

    IF v_effective_match_type IS DISTINCT FROM v_match.match_type THEN
        UPDATE public.matches
        SET match_type = v_effective_match_type
        WHERE id = p_match_id;
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

