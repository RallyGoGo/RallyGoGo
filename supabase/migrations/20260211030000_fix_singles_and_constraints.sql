-- ============================================================================
-- FIX: Singles Team Assignment & Court Constraints
-- 1. Modify create_match_draft:
--    - If SINGLES, assign 2nd player to player_3 (Team 2)
-- 2. Relax Court Constraints:
--    - Allow multiple matches on same court if statuses are compatible
-- ============================================================================
-- 1. UPDATE Create Match Logic
CREATE OR REPLACE FUNCTION create_match_draft(
        p_player_ids UUID [],
        p_match_type match_type_t DEFAULT 'MIXED',
        p_court_name TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_is_admin BOOLEAN;
v_match_id UUID;
v_player_count INTEGER;
v_departure_times JSONB := '{}';
v_queue_record RECORD;
v_p3 UUID;
v_p4 UUID;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
IF NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
v_player_count := array_length(p_player_ids, 1);
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
-- [FIX] Singles Team Assignment
-- If SINGLES (2 players), put 2nd player in player_3 (Team 2 slot 1)
-- If DOUBLES (4 players), normal assignment
v_p3 := NULL;
v_p4 := NULL;
IF p_match_type = 'SINGLES'
OR v_player_count = 2 THEN v_p3 := p_player_ids [2];
-- Opponent goes to Team 2
-- p_player_ids[2] is used as p3, so we shouldn't put it in p2.
-- Wait, logic below uses p_player_ids[2] for player_2 column. We need to shift.
END IF;
-- Capture departure times
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
-- Insert Match
-- Logic:
-- P1 always p_ids[1]
-- P2: If Singles -> NULL. Else -> p_ids[2]
-- P3: If Singles -> p_ids[2]. Else -> p_ids[3]
-- P4: If Singles -> NULL. Else -> p_ids[4]
INSERT INTO matches (
        player_1,
        player_2,
        player_3,
        player_4,
        status,
        match_type,
        court_name,
        player_departure_times,
        created_at
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
        now()
    )
RETURNING id INTO v_match_id;
-- Delete from queue
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
-- 2. Relax Constraints (if any exist)
-- Check for unique index on active matches per court and replace it
DO $$ BEGIN -- Drop existing strict index if it exists (names may vary, try common ones)
-- We want to enforce: ONE match in DRAFT/PLAYING/SCORING per court.
-- We explicitely ALLOW 'PENDING' to coexist with DRAFT/PLAYING.
-- Drop potential old indexes
DROP INDEX IF EXISTS idx_matches_active_court;
DROP INDEX IF EXISTS unique_active_court_match;
-- Create new partial index
CREATE UNIQUE INDEX IF NOT EXISTS idx_matches_occupied_court ON matches(court_name)
WHERE status IN ('DRAFT', 'PLAYING', 'SCORING');
-- Note: PENDING and FINISHED are excluded, so a PENDING match won't block a DRAFT match.
END $$;