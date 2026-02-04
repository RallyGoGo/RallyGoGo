-- ============================================================================
-- RallyGoGo V9.9.0 - Auto-Rejoin Queue After Match
-- Date: 2026-02-04
-- ============================================================================
-- FEATURE: If player's departure_time is 30+ minutes away after match ends,
-- automatically re-add them to the queue.
--
-- CHANGES:
-- 1. Add player_departure_times column to matches table
-- 2. Modify create_match_draft to save departure times before deleting from queue
-- 3. Add rejoin_queue_after_match helper function
-- 4. Modify finish_match_v2 to call rejoin helper
-- ============================================================================
-- ============================================================================
-- STEP 1: Add departure times storage to matches table
-- ============================================================================
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'matches'
        AND column_name = 'player_departure_times'
) THEN
ALTER TABLE matches
ADD COLUMN player_departure_times JSONB DEFAULT '{}';
COMMENT ON COLUMN matches.player_departure_times IS 'Stores original departure times for each player {player_id: timestamp}';
END IF;
END $$;
-- ============================================================================
-- STEP 2: Update create_match_draft to save departure times
-- ============================================================================
DROP FUNCTION IF EXISTS create_match_draft(UUID [], match_type_t, TEXT);
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
-- ✅ NEW: Save departure times BEFORE deleting from queue
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
-- Create match with departure times
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
        p_player_ids [2],
        CASE
            WHEN v_player_count >= 3 THEN p_player_ids [3]
            ELSE NULL
        END,
        CASE
            WHEN v_player_count >= 4 THEN p_player_ids [4]
            ELSE NULL
        END,
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
    'players',
    p_player_ids,
    'status',
    'DRAFT',
    'departure_times_saved',
    v_departure_times,
    'message',
    '매치가 생성되었습니다.'
);
END;
$$;
-- ============================================================================
-- STEP 3: Create rejoin_queue_after_match helper function
-- ============================================================================
DROP FUNCTION IF EXISTS rejoin_queue_after_match(UUID);
CREATE OR REPLACE FUNCTION rejoin_queue_after_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_match RECORD;
v_player_id UUID;
v_departure_time TIMESTAMPTZ;
v_player_ids UUID [];
v_rejoined_count INTEGER := 0;
v_rejoined_players UUID [] := '{}';
v_min_remaining_minutes INTEGER := 30;
-- Minimum 30 minutes required to rejoin
BEGIN -- Get match with departure times
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- Get all player IDs
v_player_ids := ARRAY [v_match.player_1, v_match.player_2];
IF v_match.player_3 IS NOT NULL THEN v_player_ids := v_player_ids || v_match.player_3;
END IF;
IF v_match.player_4 IS NOT NULL THEN v_player_ids := v_player_ids || v_match.player_4;
END IF;
-- Check each player's departure time
FOREACH v_player_id IN ARRAY v_player_ids LOOP -- Skip if player_id is null
IF v_player_id IS NULL THEN CONTINUE;
END IF;
-- Get saved departure time from JSONB
v_departure_time := (
    v_match.player_departure_times->>v_player_id::TEXT
)::TIMESTAMPTZ;
-- Skip if no departure time saved
IF v_departure_time IS NULL THEN CONTINUE;
END IF;
-- Check if 30+ minutes remaining until departure
IF v_departure_time > (
    now() + (v_min_remaining_minutes || ' minutes')::INTERVAL
) THEN -- Check if not already in queue
IF NOT EXISTS (
    SELECT 1
    FROM queue
    WHERE player_id = v_player_id
        AND is_active = true
) THEN -- Re-add to queue with original departure time
INSERT INTO queue (
        player_id,
        departure_time,
        priority_score,
        is_active
    )
VALUES (
        v_player_id,
        v_departure_time,
        EXTRACT(
            EPOCH
            FROM (v_departure_time - now())
        ) / 60,
        -- Priority based on remaining time
        true
    ) ON CONFLICT (player_id)
WHERE is_active = true DO NOTHING;
v_rejoined_count := v_rejoined_count + 1;
v_rejoined_players := v_rejoined_players || v_player_id;
END IF;
END IF;
END LOOP;
RETURN jsonb_build_object(
    'success',
    true,
    'rejoined_count',
    v_rejoined_count,
    'rejoined_players',
    v_rejoined_players,
    'message',
    CASE
        WHEN v_rejoined_count > 0 THEN v_rejoined_count || '명이 대기열에 자동 재등록되었습니다.'
        ELSE '재등록 대상 플레이어가 없습니다.'
    END
);
END;
$$;
-- ============================================================================
-- STEP 4: Update finish_match_v2 to call rejoin helper
-- This is a WRAPPER that calls the existing finish_match_v2 and then rejoin
-- ============================================================================
-- Note: We don't modify finish_match_v2 directly to avoid breaking it
-- Instead, we create a trigger that runs AFTER match status changes to FINISHED
DROP FUNCTION IF EXISTS trigger_auto_rejoin_queue();
DROP TRIGGER IF EXISTS trg_auto_rejoin_queue ON matches;
CREATE OR REPLACE FUNCTION trigger_auto_rejoin_queue() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_result JSONB;
BEGIN -- Only trigger when status changes TO 'FINISHED'
IF NEW.status = 'FINISHED'
AND (
    OLD.status IS NULL
    OR OLD.status != 'FINISHED'
) THEN -- Call rejoin function
v_result := rejoin_queue_after_match(NEW.id);
-- Log the result (optional, for debugging)
RAISE NOTICE '[Auto-Rejoin] Match %: %',
NEW.id,
v_result;
END IF;
RETURN NEW;
END;
$$;
CREATE TRIGGER trg_auto_rejoin_queue
AFTER
UPDATE ON matches FOR EACH ROW EXECUTE FUNCTION trigger_auto_rejoin_queue();
-- ============================================================================
-- STEP 5: Grant permissions
-- ============================================================================
GRANT EXECUTE ON FUNCTION create_match_draft(UUID [], match_type_t, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rejoin_queue_after_match(UUID) TO authenticated;
-- ============================================================================
-- VERIFICATION QUERIES (run after migration):
-- ============================================================================
-- 1. Check column exists:
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'matches' AND column_name = 'player_departure_times';
--
-- 2. Check trigger exists:
-- SELECT trigger_name FROM information_schema.triggers WHERE trigger_name = 'trg_auto_rejoin_queue';
--
-- 3. Check functions exist:
-- SELECT proname FROM pg_proc WHERE proname IN ('create_match_draft', 'rejoin_queue_after_match', 'trigger_auto_rejoin_queue');
-- ============================================================================