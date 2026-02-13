-- =============================================================================
-- FIX: Allow Non-Admin Users to Create Matches
-- Problem: 'create_match_draft' was restricted to admins only, causing 'ADMIN_REQUIRED' error.
-- Solution: Remove the admin check. Authenticated users can create matches.
-- =============================================================================
CREATE OR REPLACE FUNCTION create_match_draft(
        p_player_ids UUID [],
        p_match_type match_type_t DEFAULT 'MIXED',
        p_court_name TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match_id UUID;
v_player_count INTEGER;
v_departure_times JSONB := '{}';
v_queue_record RECORD;
v_p3 UUID;
v_p4 UUID;
BEGIN -- 1. Authentication Check
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- [REMOVED] Admin Check
-- IF NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED'); END IF;
-- 2. Setup Variables
v_player_count := array_length(p_player_ids, 1);
-- 3. Validation
IF v_player_count IS NULL
OR v_player_count < 2
OR v_player_count > 4 THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_PLAYER_COUNT',
    'message',
    '2~4명의 플레이어를 선택해주세요.'
);
END IF;
-- 4. Singles Logic (Assign P2 -> P3 slot for Team 2)
v_p3 := NULL;
v_p4 := NULL;
IF p_match_type = 'SINGLES'
OR v_player_count = 2 THEN v_p3 := p_player_ids [2];
-- Opponent goes to Team 2 (Player 3 slot)
END IF;
-- 5. Capture Departure Times
FOR v_queue_record IN
SELECT player_id,
    departure_time
FROM queue
WHERE player_id = ANY(p_player_ids)
    AND is_active = true LOOP v_departure_times := v_departure_times || jsonb_build_object(
        v_queue_record.player_id::TEXT,
        v_queue_record.departure_time
    );
END LOOP;
-- 6. Insert Match
INSERT INTO matches (
        player_1,
        player_2,
        player_3,
        player_4,
        status,
        match_type,
        court_name,
        player_departure_times,
        created_at,
        created_by -- Track who created it
    )
VALUES (
        p_player_ids [1],
        CASE
            WHEN p_match_type = 'SINGLES' THEN NULL
            ELSE p_player_ids [2]
        END,
        -- P2
        CASE
            WHEN p_match_type = 'SINGLES' THEN p_player_ids [2]
            ELSE p_player_ids [3]
        END,
        -- P3 (Team 2)
        CASE
            WHEN v_player_count >= 4 THEN p_player_ids [4]
            ELSE NULL
        END,
        -- P4
        'DRAFT',
        p_match_type,
        p_court_name,
        v_departure_times,
        now(),
        v_user_id
    )
RETURNING id INTO v_match_id;
-- 7. Remove from Queue
DELETE FROM queue
WHERE player_id = ANY(p_player_ids);
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    v_match_id,
    'status',
    'DRAFT',
    'message',
    '매치가 생성되었습니다.'
);
END;
$$;