-- ============================================================================
-- V9.9.1 HOTFIX - Fix auto-rejoin queue trigger
-- Date: 2026-02-04
-- ============================================================================
-- ISSUE: Auto-rejoin is not working despite departure_times being saved
-- ROOT CAUSE: Possible interval syntax issue and need better debugging
-- ============================================================================
-- ============================================================================
-- STEP 1: Drop and recreate rejoin function with better logging
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
v_skipped_reasons JSONB := '[]';
v_now TIMESTAMPTZ := now();
v_min_time TIMESTAMPTZ;
BEGIN -- Calculate minimum departure time (now + 30 minutes)
v_min_time := v_now + INTERVAL '30 minutes';
-- Get match with departure times
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- Check if departure_times exist
IF v_match.player_departure_times IS NULL
OR v_match.player_departure_times = '{}'::JSONB THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'NO_DEPARTURE_TIMES',
    'message',
    'This match was created before v9.9.0 migration'
);
END IF;
-- Get all player IDs from match
v_player_ids := ARRAY []::UUID [];
IF v_match.player_1 IS NOT NULL THEN v_player_ids := v_player_ids || v_match.player_1;
END IF;
IF v_match.player_2 IS NOT NULL THEN v_player_ids := v_player_ids || v_match.player_2;
END IF;
IF v_match.player_3 IS NOT NULL THEN v_player_ids := v_player_ids || v_match.player_3;
END IF;
IF v_match.player_4 IS NOT NULL THEN v_player_ids := v_player_ids || v_match.player_4;
END IF;
-- Process each player
FOREACH v_player_id IN ARRAY v_player_ids LOOP -- Skip null player IDs
IF v_player_id IS NULL THEN CONTINUE;
END IF;
-- Get saved departure time from JSONB (key is player_id as string)
v_departure_time := (
    v_match.player_departure_times->>v_player_id::TEXT
)::TIMESTAMPTZ;
-- Check if departure time exists for this player
IF v_departure_time IS NULL THEN v_skipped_reasons := v_skipped_reasons || jsonb_build_object(
    'player_id',
    v_player_id,
    'reason',
    'NO_DEPARTURE_TIME_FOR_PLAYER'
);
CONTINUE;
END IF;
-- Check if 30+ minutes remaining until departure
IF v_departure_time <= v_min_time THEN v_skipped_reasons := v_skipped_reasons || jsonb_build_object(
    'player_id',
    v_player_id,
    'reason',
    'NOT_ENOUGH_TIME',
    'departure',
    v_departure_time,
    'min_required',
    v_min_time
);
CONTINUE;
END IF;
-- Check if already in queue
IF EXISTS (
    SELECT 1
    FROM queue
    WHERE player_id = v_player_id
        AND is_active = true
) THEN v_skipped_reasons := v_skipped_reasons || jsonb_build_object(
    'player_id',
    v_player_id,
    'reason',
    'ALREADY_IN_QUEUE'
);
CONTINUE;
END IF;
-- Re-add to queue with original departure time
INSERT INTO queue (
        player_id,
        departure_time,
        priority_score,
        is_active,
        joined_at
    )
VALUES (
        v_player_id,
        v_departure_time,
        EXTRACT(
            EPOCH
            FROM (v_departure_time - v_now)
        ) / 60,
        true,
        v_now
    ) ON CONFLICT (player_id)
WHERE is_active = true DO NOTHING;
v_rejoined_count := v_rejoined_count + 1;
v_rejoined_players := v_rejoined_players || v_player_id;
END LOOP;
RETURN jsonb_build_object(
    'success',
    true,
    'rejoined_count',
    v_rejoined_count,
    'rejoined_players',
    v_rejoined_players,
    'skipped',
    v_skipped_reasons,
    'debug',
    jsonb_build_object(
        'now',
        v_now,
        'min_time',
        v_min_time,
        'player_count',
        array_length(v_player_ids, 1),
        'departure_times',
        v_match.player_departure_times
    ),
    'message',
    CASE
        WHEN v_rejoined_count > 0 THEN v_rejoined_count || '명이 대기열에 자동 재등록되었습니다.'
        ELSE '재등록 대상 플레이어가 없습니다.'
    END
);
END;
$$;
-- ============================================================================
-- STEP 2: Fix trigger to ensure it fires correctly
-- ============================================================================
DROP TRIGGER IF EXISTS trg_auto_rejoin_queue ON matches;
DROP FUNCTION IF EXISTS trigger_auto_rejoin_queue();
CREATE OR REPLACE FUNCTION trigger_auto_rejoin_queue() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_result JSONB;
BEGIN -- Only trigger when status changes TO 'FINISHED'
IF NEW.status = 'FINISHED'
AND (
    OLD.status IS DISTINCT
    FROM 'FINISHED'
) THEN -- Call rejoin function
v_result := rejoin_queue_after_match(NEW.id);
-- Log to match_audit_log for debugging
INSERT INTO match_audit_log (
        match_id,
        action,
        details,
        triggered_by,
        trigger_role
    )
VALUES (
        NEW.id,
        'AUTO_REJOIN_ATTEMPT',
        v_result,
        auth.uid(),
        'SYSTEM'
    );
END IF;
RETURN NEW;
EXCEPTION
WHEN OTHERS THEN -- Log error but don't fail the transaction
INSERT INTO match_audit_log (
        match_id,
        action,
        details,
        triggered_by,
        trigger_role
    )
VALUES (
        NEW.id,
        'AUTO_REJOIN_ERROR',
        jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE),
        auth.uid(),
        'SYSTEM'
    );
RETURN NEW;
END;
$$;
CREATE TRIGGER trg_auto_rejoin_queue
AFTER
UPDATE ON matches FOR EACH ROW EXECUTE FUNCTION trigger_auto_rejoin_queue();
-- ============================================================================
-- STEP 3: Grant permissions
-- ============================================================================
GRANT EXECUTE ON FUNCTION rejoin_queue_after_match(UUID) TO authenticated;
-- ============================================================================
-- MANUAL TEST (run this after creating a new match and finishing it):
-- ============================================================================
-- SELECT rejoin_queue_after_match('609b8ccc-0609-4a2f-bc9e-ad81c8fdaaa2');
-- 
-- Check audit log:
-- SELECT * FROM match_audit_log WHERE action LIKE 'AUTO_REJOIN%' ORDER BY created_at DESC LIMIT 5;
-- ============================================================================