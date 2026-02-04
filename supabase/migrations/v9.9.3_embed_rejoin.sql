-- ============================================================================
-- V9.9.3 HOTFIX - Embed rejoin logic directly in finish_match_v2
-- Date: 2026-02-04
-- ============================================================================
-- ISSUE: Trigger not firing when finish_match_v2 is called from admin_confirm_match
-- SOLUTION: Call rejoin_queue_after_match directly at the end of finish_match_v2
-- ============================================================================
-- Drop existing function first (parameter names changed)
DROP FUNCTION IF EXISTS finish_match_v2(UUID, INTEGER, INTEGER, TEXT);
-- Recreate with embedded rejoin logic
CREATE OR REPLACE FUNCTION finish_match_v2(
        p_match_id UUID,
        p_score_team1 INTEGER,
        p_score_team2 INTEGER,
        p_confirmation_type TEXT DEFAULT 'NORMAL'
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_match RECORD;
v_winning_team INTEGER;
v_player_ids UUID [];
v_elo_changes JSONB := '[]';
v_result JSONB;
v_elo_calc RECORD;
v_rejoin_result JSONB;
BEGIN -- 1. Validate match exists and is in correct state
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status NOT IN ('PLAYING', 'SCORING', 'DRAFT') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'current',
    v_match.status
);
END IF;
-- 2. Determine winner
IF p_score_team1 > p_score_team2 THEN v_winning_team := 1;
ELSIF p_score_team2 > p_score_team1 THEN v_winning_team := 2;
ELSE v_winning_team := 0;
-- Draw
END IF;
-- 3. Get all player IDs
v_player_ids := ARRAY [v_match.player_1, v_match.player_2];
IF v_match.player_3 IS NOT NULL THEN v_player_ids := v_player_ids || v_match.player_3;
END IF;
IF v_match.player_4 IS NOT NULL THEN v_player_ids := v_player_ids || v_match.player_4;
END IF;
-- 4. Calculate and update ELO for each player
FOR v_elo_calc IN
SELECT id,
    CASE
        WHEN id IN (v_match.player_1, v_match.player_2) THEN 1
        ELSE 2
    END as team,
    COALESCE(
        CASE
            v_match.match_type
            WHEN 'MIXED' THEN elo_mixed_doubles
            WHEN 'MENS_DOUBLES' THEN elo_mens_doubles
            WHEN 'WOMENS_DOUBLES' THEN elo_womens_doubles
            ELSE elo_mixed_doubles
        END,
        1500
    ) as current_elo
FROM profiles
WHERE id = ANY(v_player_ids) LOOP
DECLARE v_is_winner BOOLEAN;
v_elo_change INTEGER;
v_new_elo INTEGER;
v_k_factor INTEGER := 32;
BEGIN v_is_winner := (v_elo_calc.team = v_winning_team);
-- Simple ELO calculation
IF v_is_winner THEN v_elo_change := v_k_factor / 2;
ELSE v_elo_change := - v_k_factor / 2;
END IF;
v_new_elo := v_elo_calc.current_elo + v_elo_change;
-- Update ELO based on match type
CASE
    v_match.match_type
    WHEN 'MIXED' THEN
    UPDATE profiles
    SET elo_mixed_doubles = v_new_elo
    WHERE id = v_elo_calc.id;
WHEN 'MENS_DOUBLES' THEN
UPDATE profiles
SET elo_mens_doubles = v_new_elo
WHERE id = v_elo_calc.id;
WHEN 'WOMENS_DOUBLES' THEN
UPDATE profiles
SET elo_womens_doubles = v_new_elo
WHERE id = v_elo_calc.id;
ELSE
UPDATE profiles
SET elo_mixed_doubles = v_new_elo
WHERE id = v_elo_calc.id;
END CASE
;
-- Also increment games_played_today
UPDATE profiles
SET games_played_today = COALESCE(games_played_today, 0) + 1
WHERE id = v_elo_calc.id;
v_elo_changes := v_elo_changes || jsonb_build_object(
    'player_id',
    v_elo_calc.id,
    'old_elo',
    v_elo_calc.current_elo,
    'new_elo',
    v_new_elo,
    'change',
    v_elo_change,
    'is_winner',
    v_is_winner
);
END;
END LOOP;
-- 5. Update match to FINISHED
UPDATE matches
SET status = 'FINISHED',
    score_team1 = p_score_team1,
    score_team2 = p_score_team2,
    winner = CASE
        v_winning_team
        WHEN 1 THEN 'TEAM_1'
        WHEN 2 THEN 'TEAM_2'
        ELSE 'DRAW'
    END,
    finished_at = now()
WHERE id = p_match_id;
-- 6. Log to audit
INSERT INTO match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        match_status_before,
        match_status_after,
        score_team1,
        score_team2,
        confirmation_type,
        is_force_confirm
    )
VALUES (
        p_match_id,
        CASE
            p_confirmation_type
            WHEN 'ADMIN_FORCE_CONFIRM' THEN 'ADMIN_FORCE_CONFIRM'
            ELSE 'CONFIRM_MATCH'
        END,
        COALESCE(auth.uid(), v_match.player_1),
        CASE
            WHEN p_confirmation_type = 'ADMIN_FORCE_CONFIRM' THEN 'ADMIN'
            ELSE 'PLAYER'
        END,
        v_match.status,
        'FINISHED',
        p_score_team1,
        p_score_team2,
        p_confirmation_type,
        p_confirmation_type = 'ADMIN_FORCE_CONFIRM'
    );
-- 7. Settle bets if betting_pools exists
BEGIN PERFORM settle_bets(p_match_id, v_winning_team);
EXCEPTION
WHEN OTHERS THEN -- Betting not available, skip
NULL;
END;
-- ============================================================================
-- 8. ✨ AUTO-REJOIN QUEUE ✨
-- Directly call rejoin function instead of relying on trigger
-- ============================================================================
BEGIN v_rejoin_result := rejoin_queue_after_match(p_match_id);
EXCEPTION
WHEN OTHERS THEN -- Don't fail if rejoin fails
v_rejoin_result := jsonb_build_object('success', false, 'error', SQLERRM);
END;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'score',
    jsonb_build_object('team1', p_score_team1, 'team2', p_score_team2),
    'winner',
    CASE
        v_winning_team
        WHEN 1 THEN 'TEAM_1'
        WHEN 2 THEN 'TEAM_2'
        ELSE 'DRAW'
    END,
    'elo_changes',
    v_elo_changes,
    'confirmation_type',
    p_confirmation_type,
    'rejoin_result',
    v_rejoin_result
);
END;
$$;
-- Grant permissions
GRANT EXECUTE ON FUNCTION finish_match_v2(UUID, INTEGER, INTEGER, TEXT) TO authenticated;
-- ============================================================================
-- VERIFICATION
-- After running, test with:
-- 1. Create match, report score, force confirm
-- 2. Check result includes 'rejoin_result' key
-- ============================================================================