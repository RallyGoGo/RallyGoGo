-- ============================================================================
-- HOTFIX: Relax finish_match_v2 ADMIN_FORCE_CONFIRM role gate
-- Date: 2026-02-14
-- Reason: admin_confirm_match delegates to finish_match_v2('ADMIN_FORCE_CONFIRM'),
--         but PIN-admin operators may not have DB role='admin'.
-- Scope: Removes ADMIN_REQUIRED hard fail for ADMIN_FORCE_CONFIRM path only.
-- ============================================================================

-- ============================================================================
-- V9.9.4 HOTFIX - Add auto-rejoin to v9.8.1 finish_match_v2 (MINIMAL PATCH)
-- Date: 2026-02-04
-- ============================================================================
-- Strategy: Copy v9.8.1's working finish_match_v2, add ONE line for rejoin
-- ============================================================================
DROP FUNCTION IF EXISTS finish_match_v2(UUID, INTEGER, INTEGER, TEXT);
CREATE OR REPLACE FUNCTION finish_match_v2(
        p_match_id UUID,
        p_team1_score INTEGER,
        p_team2_score INTEGER,
        p_confirmation_type TEXT DEFAULT 'NORMAL_CONFIRM'
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_is_admin BOOLEAN;
v_is_participant BOOLEAN;
v_winner_team TEXT;
v_all_player_ids UUID [];
v_team1_ids UUID [];
v_team2_ids UUID [];
v_team1_rating NUMERIC := 0;
v_team2_rating NUMERIC := 0;
v_p1_expected NUMERIC;
v_p1_actual NUMERIC;
v_base_delta NUMERIC;
v_k_factor INTEGER := 32;
v_bets_settled INTEGER;
v_status_before TEXT;
v_profile RECORD;
v_is_team1 BOOLEAN;
v_final_delta INTEGER;
v_old_rating INTEGER;
v_new_rating INTEGER;
v_multiplier NUMERIC := 1.0;
v_match_type TEXT;
v_rejoin_result JSONB;
-- ✨ V9.9.4 ADDED
BEGIN -- Auth check
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- Score validation
IF p_team1_score < 0
OR p_team1_score > 99
OR p_team2_score < 0
OR p_team2_score > 99 THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_SCORE',
    'message',
    '유효하지 않은 점수입니다.'
);
END IF;
IF p_team1_score = 0
AND p_team2_score = 0 THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_SCORE',
    'message',
    '0:0은 허용되지 않습니다.'
);
END IF;
-- Get match with lock
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status = 'FINISHED' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ALREADY_FINISHED',
    'message',
    '이미 종료된 경기입니다.'
);
END IF;
v_status_before := v_match.status::TEXT;
v_match_type := COALESCE(v_match.match_type::TEXT, 'MIXED');
-- Build player arrays (filter NULLs)
v_team1_ids := ARRAY [v_match.player_1, v_match.player_2];
v_team2_ids := ARRAY [v_match.player_3, v_match.player_4];
v_all_player_ids := v_team1_ids || v_team2_ids;
SELECT array_agg(x) INTO v_all_player_ids
FROM unnest(v_all_player_ids) x
WHERE x IS NOT NULL;
SELECT array_agg(x) INTO v_team1_ids
FROM unnest(v_team1_ids) x
WHERE x IS NOT NULL;
SELECT array_agg(x) INTO v_team2_ids
FROM unnest(v_team2_ids) x
WHERE x IS NOT NULL;
-- Permission check
v_is_participant := v_user_id = ANY(v_all_player_ids);
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
IF p_confirmation_type = 'NORMAL_CONFIRM'
AND NOT v_is_participant THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PERMISSION_DENIED',
    'message',
    '경기 참가자만 결과를 입력할 수 있습니다.'
);
END IF;
IF p_confirmation_type = 'ADMIN_FORCE_CONFIRM'
AND NOT v_is_admin THEN
    -- PIN-based admin mode: admin dashboard controls access on client-side.
    NULL;
END IF;
-- Determine winner
IF p_team1_score > p_team2_score THEN v_winner_team := 'TEAM_1';
v_p1_actual := 1.0;
ELSIF p_team2_score > p_team1_score THEN v_winner_team := 'TEAM_2';
v_p1_actual := 0.0;
ELSE v_winner_team := 'DRAW';
v_p1_actual := 0.5;
END IF;
-- Calculate team ratings based on match_type
IF v_match_type = 'MENS_DOUBLES' THEN
SELECT COALESCE(AVG(elo_mens_doubles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_mens_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
ELSIF v_match_type = 'WOMENS_DOUBLES' THEN
SELECT COALESCE(AVG(elo_womens_doubles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_womens_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
ELSIF v_match_type = 'SINGLES' THEN
SELECT COALESCE(AVG(elo_singles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_singles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
ELSE
SELECT COALESCE(AVG(elo_mixed_doubles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_mixed_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
END IF;
-- ELO calculation
v_p1_expected := 1.0 / (
    1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0)
);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
-- Update each player's ELO
FOR v_profile IN
SELECT *
FROM profiles
WHERE id = ANY(v_all_player_ids) FOR
UPDATE LOOP v_is_team1 := v_profile.id = ANY(v_team1_ids);
v_multiplier := 1.0;
-- Get old rating based on match_type
IF v_match_type = 'MENS_DOUBLES' THEN v_old_rating := COALESCE(v_profile.elo_mens_doubles, 1200);
ELSIF v_match_type = 'WOMENS_DOUBLES' THEN v_old_rating := COALESCE(v_profile.elo_womens_doubles, 1200);
ELSIF v_match_type = 'SINGLES' THEN v_old_rating := COALESCE(v_profile.elo_singles, 1200);
ELSE v_old_rating := COALESCE(v_profile.elo_mixed_doubles, 1200);
END IF;
-- Calculate delta (positive for Team1 if they won)
IF v_is_team1 THEN v_final_delta := ROUND(v_base_delta);
ELSE v_final_delta := ROUND(v_base_delta * -1);
END IF;
-- Guest multiplier
IF v_profile.is_guest THEN v_multiplier := 1.5;
v_final_delta := ROUND(v_final_delta * v_multiplier);
END IF;
v_new_rating := GREATEST(0, LEAST(4000, v_old_rating + v_final_delta));
-- Update correct ELO column + stats
IF v_match_type = 'MENS_DOUBLES' THEN
UPDATE profiles
SET elo_mens_doubles = v_new_rating,
    games_played_today = COALESCE(games_played_today, 0) + 1,
    total_games_history = COALESCE(total_games_history, 0) + 1,
    total_wins = total_wins + CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN 1
        ELSE 0
    END,
    total_losses = total_losses + CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_2'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_1'
        ) THEN 1
        ELSE 0
    END,
    total_draws = total_draws + CASE
        WHEN v_winner_team = 'DRAW' THEN 1
        ELSE 0
    END,
    winning_streak = CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN COALESCE(winning_streak, 0) + 1
        ELSE 0
    END
WHERE id = v_profile.id;
ELSIF v_match_type = 'WOMENS_DOUBLES' THEN
UPDATE profiles
SET elo_womens_doubles = v_new_rating,
    games_played_today = COALESCE(games_played_today, 0) + 1,
    total_games_history = COALESCE(total_games_history, 0) + 1,
    total_wins = total_wins + CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN 1
        ELSE 0
    END,
    total_losses = total_losses + CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_2'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_1'
        ) THEN 1
        ELSE 0
    END,
    total_draws = total_draws + CASE
        WHEN v_winner_team = 'DRAW' THEN 1
        ELSE 0
    END,
    winning_streak = CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN COALESCE(winning_streak, 0) + 1
        ELSE 0
    END
WHERE id = v_profile.id;
ELSIF v_match_type = 'SINGLES' THEN
UPDATE profiles
SET elo_singles = v_new_rating,
    games_played_today = COALESCE(games_played_today, 0) + 1,
    total_games_history = COALESCE(total_games_history, 0) + 1,
    total_wins = total_wins + CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN 1
        ELSE 0
    END,
    total_losses = total_losses + CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_2'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_1'
        ) THEN 1
        ELSE 0
    END,
    total_draws = total_draws + CASE
        WHEN v_winner_team = 'DRAW' THEN 1
        ELSE 0
    END,
    winning_streak = CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN COALESCE(winning_streak, 0) + 1
        ELSE 0
    END
WHERE id = v_profile.id;
ELSE
UPDATE profiles
SET elo_mixed_doubles = v_new_rating,
    games_played_today = COALESCE(games_played_today, 0) + 1,
    total_games_history = COALESCE(total_games_history, 0) + 1,
    total_wins = total_wins + CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN 1
        ELSE 0
    END,
    total_losses = total_losses + CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_2'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_1'
        ) THEN 1
        ELSE 0
    END,
    total_draws = total_draws + CASE
        WHEN v_winner_team = 'DRAW' THEN 1
        ELSE 0
    END,
    winning_streak = CASE
        WHEN (
            v_is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT v_is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN COALESCE(winning_streak, 0) + 1
        ELSE 0
    END
WHERE id = v_profile.id;
END IF;
-- Log ELO history
INSERT INTO elo_history (
        player_id,
        match_id,
        match_type,
        old_rating,
        new_rating,
        was_guest,
        applied_multiplier
    )
VALUES (
        v_profile.id,
        p_match_id,
        v_match.match_type,
        v_old_rating,
        v_new_rating,
        v_profile.is_guest,
        v_multiplier
    );
END LOOP;
-- Update match status
UPDATE matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner_team,
    confirmed_by = v_user_id,
    end_time = now()
WHERE id = p_match_id;
-- Settle bets
SELECT settle_match_bets(p_match_id, v_winner_team) INTO v_bets_settled;
-- Remove players from queue (original behavior)
DELETE FROM queue
WHERE player_id = ANY(v_all_player_ids);
-- Audit log
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
        'CONFIRM_MATCH',
        v_user_id,
        CASE
            WHEN v_is_admin THEN 'ADMIN'
            ELSE 'PLAYER'
        END,
        v_status_before::match_status_t,
        'FINISHED'::match_status_t,
        p_team1_score,
        p_team2_score,
        p_confirmation_type,
        p_confirmation_type = 'ADMIN_FORCE_CONFIRM'
    );
-- ============================================================================
-- ✨ V9.9.4 ADDED: Auto-rejoin queue after match ✨
-- ============================================================================
BEGIN v_rejoin_result := rejoin_queue_after_match(p_match_id);
EXCEPTION
WHEN OTHERS THEN v_rejoin_result := jsonb_build_object('success', false, 'error', SQLERRM);
END;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'winner_team',
    v_winner_team,
    'bets_settled',
    v_bets_settled,
    'mvp_voting_open',
    true,
    'match_type',
    v_match_type,
    'rejoin_result',
    v_rejoin_result,
    -- ✨ V9.9.4 ADDED
    'message',
    '경기가 종료되었습니다. MVP 투표가 시작되었습니다!'
);
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INTERNAL_ERROR',
    'sqlstate',
    SQLSTATE,
    'message',
    SQLERRM
);
END;
$$;
GRANT EXECUTE ON FUNCTION finish_match_v2(UUID, INTEGER, INTEGER, TEXT) TO authenticated;
-- ============================================================================
-- DONE. Test: Create match → Score → Force confirm → Check queue
-- ============================================================================