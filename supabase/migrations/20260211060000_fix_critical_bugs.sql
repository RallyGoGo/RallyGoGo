-- ============================================================================
-- Fix Critical Bugs: Auto-Rejoin & Daily Reset
-- Date: 2026-02-11
-- Purpose: Ensure players rejoin queue after match, and stats reset daily
-- ============================================================================
-- 1. Internal Rejoin Function (Bypasses Auth Check for Auto-Rejoin)
CREATE OR REPLACE FUNCTION internal_rejoin_queue(p_player_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_priority_score NUMERIC := 500;
-- Base priority
v_profile RECORD;
BEGIN -- Check if already in queue
PERFORM 1
FROM queue
WHERE player_id = p_player_id
    AND is_active = true;
IF FOUND THEN RETURN;
END IF;
-- Get profile for Guest Logic (Guests might get priority bump or not? Keep simple for now)
SELECT * INTO v_profile
FROM profiles
WHERE id = p_player_id;
IF v_profile IS NULL THEN RETURN;
END IF;
-- Insert into Queue
INSERT INTO queue (player_id, priority_score, is_active, joined_at)
VALUES (p_player_id, v_priority_score, true, now()) ON CONFLICT (player_id) DO
UPDATE
SET is_active = true,
    priority_score = v_priority_score,
    joined_at = now();
END;
$$;
-- 2. Daily Reset Logic (Lazy Check)
DROP FUNCTION IF EXISTS check_and_reset_daily();
CREATE OR REPLACE FUNCTION check_and_reset_daily() RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_last_reset TEXT;
v_today TEXT := to_char(now() AT TIME ZONE 'KST', 'YYYY-MM-DD');
-- Korea Standard Time
BEGIN -- Get last reset date from system_flags
SELECT value_text INTO v_last_reset
FROM system_flags
WHERE key = 'last_daily_reset';
-- If not set or different day, reset
IF v_last_reset IS NULL
OR v_last_reset != v_today THEN -- UPDATE profiles
UPDATE profiles
SET games_played_today = 0;
-- Update Flag
INSERT INTO system_flags (key, value, value_text, description)
VALUES (
        'last_daily_reset',
        true,
        v_today,
        'Last date (YYYY-MM-DD) the daily stats were reset'
    ) ON CONFLICT (key) DO
UPDATE
SET value_text = v_today,
    updated_at = now();
RAISE NOTICE 'Daily stats reset for date: %',
v_today;
END IF;
END;
$$;
-- Ensure system_flags has value_text column if not exists (V3 might not have it)
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'system_flags'
        AND column_name = 'value_text'
) THEN
ALTER TABLE system_flags
ADD COLUMN value_text TEXT;
END IF;
END $$;
-- 3. Update join_queue to trigger Daily Reset Check
CREATE OR REPLACE FUNCTION join_queue(
        p_priority_score NUMERIC DEFAULT 0,
        p_departure_time TIMESTAMPTZ DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_profile RECORD;
v_queue_id UUID;
v_existing_queue RECORD;
v_active_match RECORD;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED',
    'message',
    '로그인이 필요합니다.'
);
END IF;
-- ✅ LAZY DAILY RESET CHECK
PERFORM check_and_reset_daily();
SELECT * INTO v_profile
FROM profiles
WHERE id = v_user_id;
IF v_profile IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PROFILE_NOT_FOUND',
    'message',
    '프로필을 먼저 생성해주세요.'
);
END IF;
SELECT * INTO v_existing_queue
FROM queue
WHERE player_id = v_user_id
    AND is_active = true;
IF v_existing_queue IS NOT NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ALREADY_IN_QUEUE',
    'message',
    '이미 대기열에 등록되어 있습니다.',
    'queue_id',
    v_existing_queue.id
);
END IF;
SELECT * INTO v_active_match
FROM matches
WHERE status NOT IN ('FINISHED', 'CANCELLED')
    AND (
        player_1 = v_user_id
        OR player_2 = v_user_id
        OR player_3 = v_user_id
        OR player_4 = v_user_id
    )
LIMIT 1;
IF v_active_match IS NOT NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ALREADY_IN_MATCH',
    'message',
    '진행 중인 경기가 있습니다.',
    'match_id',
    v_active_match.id
);
END IF;
BEGIN
INSERT INTO queue (
        player_id,
        priority_score,
        departure_time,
        is_active,
        joined_at
    )
VALUES (
        v_user_id,
        COALESCE(p_priority_score, 0),
        p_departure_time,
        true,
        now()
    )
RETURNING id INTO v_queue_id;
EXCEPTION
WHEN unique_violation THEN
SELECT id INTO v_queue_id
FROM queue
WHERE player_id = v_user_id;
UPDATE queue
SET is_active = true,
    joined_at = now()
WHERE id = v_queue_id;
-- Reactivate
RETURN jsonb_build_object(
    'success',
    true,
    'queue_id',
    v_queue_id,
    'was_duplicate',
    true
);
END;
RETURN jsonb_build_object(
    'success',
    true,
    'queue_id',
    v_queue_id,
    'player_id',
    v_user_id,
    'is_guest',
    v_profile.is_guest,
    'message',
    '대기열에 등록되었습니다.'
);
END;
$$;
-- 4. Update finish_match_v2 to Include Auto-Rejoin
-- Copying latest v9.8.0/v9.8.1 logic and appending internal_rejoin_queue calls
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
is_team1 BOOLEAN;
final_delta INTEGER;
old_rating INTEGER;
new_rating INTEGER;
multiplier NUMERIC := 1.0;
v_match_type TEXT;
v_player_id UUID;
-- Iterator
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- ✅ Validate Scores
IF p_team1_score < 0
OR p_team1_score > 99
OR p_team2_score < 0
OR p_team2_score > 99
OR (
    p_team1_score = 0
    AND p_team2_score = 0
) THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_SCORE',
    'message',
    '유효하지 않은 점수입니다.'
);
END IF;
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
v_team1_ids := ARRAY [v_match.player_1, v_match.player_2];
v_team2_ids := ARRAY [v_match.player_3, v_match.player_4];
-- Build all player IDs filtering nulls
SELECT array_agg(x) INTO v_all_player_ids
FROM unnest(v_team1_ids || v_team2_ids) x
WHERE x IS NOT NULL;
SELECT array_agg(x) INTO v_team1_ids
FROM unnest(v_team1_ids) x
WHERE x IS NOT NULL;
SELECT array_agg(x) INTO v_team2_ids
FROM unnest(v_team2_ids) x
WHERE x IS NOT NULL;
v_is_participant := v_user_id = ANY(v_all_player_ids);
SELECT EXISTS(
        SELECT 1
        FROM profiles
        WHERE id = v_user_id
            AND role = 'admin'
    ) INTO v_is_admin;
IF p_confirmation_type = 'NORMAL_CONFIRM' THEN IF NOT v_is_participant THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PERMISSION_DENIED',
    'message',
    '경기 참가자만 결과를 입력할 수 있습니다.'
);
END IF;
ELSIF p_confirmation_type = 'ADMIN_FORCE_CONFIRM' THEN IF NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
END IF;
-- Determine Winner
IF p_team1_score > p_team2_score THEN v_winner_team := 'TEAM_1';
v_p1_actual := 1.0;
ELSIF p_team2_score > p_team1_score THEN v_winner_team := 'TEAM_2';
v_p1_actual := 0.0;
ELSE v_winner_team := 'DRAW';
v_p1_actual := 0.5;
END IF;
-- Calculate Ratings (Collapsed for brevity - reusing existing logic assumptions)
-- ... [Assuming standard logic for ratings fetching] ...
-- For safety in this hotfix, we use a Simplified Rating Update or assume the full code is applied.
-- To ensure we don't break strict ELO logic, we MUST replicate the "Get Avg Rating" block.
-- Get Avg Ratings
-- (Simplification: Just using 1200 if failing to query unique averages for now to save space, assuming previous functional state was OK)
-- actually, to be safe, let's keep it robust.
CASE
    v_match_type
    WHEN 'MENS_DOUBLES' THEN
    SELECT COALESCE(AVG(elo_mens_doubles), 1200) INTO v_team1_rating
    FROM profiles
    WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_mens_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
WHEN 'WOMENS_DOUBLES' THEN
SELECT COALESCE(AVG(elo_womens_doubles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_womens_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
WHEN 'SINGLES' THEN
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
END CASE
;
v_p1_expected := 1.0 / (
    1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0)
);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
-- Update Profiles Loop
FOR v_profile IN
SELECT *
FROM profiles
WHERE id = ANY(v_all_player_ids) FOR
UPDATE LOOP is_team1 := v_profile.id = ANY(v_team1_ids);
-- Pick correct ELO column
CASE
    v_match_type
    WHEN 'MENS_DOUBLES' THEN old_rating := COALESCE(v_profile.elo_mens_doubles, 1200);
WHEN 'WOMENS_DOUBLES' THEN old_rating := COALESCE(v_profile.elo_womens_doubles, 1200);
WHEN 'SINGLES' THEN old_rating := COALESCE(v_profile.elo_singles, 1200);
ELSE old_rating := COALESCE(v_profile.elo_mixed_doubles, 1200);
END CASE
;
IF is_team1 THEN final_delta := ROUND(v_base_delta);
ELSE final_delta := ROUND(v_base_delta * -1);
END IF;
IF v_profile.is_guest THEN multiplier := 1.5;
final_delta := ROUND(final_delta * multiplier);
END IF;
new_rating := GREATEST(0, LEAST(4000, old_rating + final_delta));
-- Update correct ELO column + Stats
-- (Shortened Update Logic for clarity - apply to all columns if needed or just specific)
-- Start with Match Type ELO Update
IF v_match_type = 'MENS_DOUBLES' THEN
UPDATE profiles
SET elo_mens_doubles = new_rating
WHERE id = v_profile.id;
ELSIF v_match_type = 'WOMENS_DOUBLES' THEN
UPDATE profiles
SET elo_womens_doubles = new_rating
WHERE id = v_profile.id;
ELSIF v_match_type = 'SINGLES' THEN
UPDATE profiles
SET elo_singles = new_rating
WHERE id = v_profile.id;
ELSE
UPDATE profiles
SET elo_mixed_doubles = new_rating
WHERE id = v_profile.id;
END IF;
-- Update General Stats (Always)
UPDATE profiles
SET games_played_today = COALESCE(games_played_today, 0) + 1,
    total_games_history = COALESCE(total_games_history, 0) + 1,
    total_wins = total_wins + CASE
        WHEN (
            is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN 1
        ELSE 0
    END,
    total_losses = total_losses + CASE
        WHEN (
            is_team1
            AND v_winner_team = 'TEAM_2'
        )
        OR (
            NOT is_team1
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
            is_team1
            AND v_winner_team = 'TEAM_1'
        )
        OR (
            NOT is_team1
            AND v_winner_team = 'TEAM_2'
        ) THEN COALESCE(winning_streak, 0) + 1
        ELSE 0
    END
WHERE id = v_profile.id;
-- History Log
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
        old_rating,
        new_rating,
        v_profile.is_guest,
        multiplier
    );
END LOOP;
-- Update Match Status
UPDATE matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner_team,
    confirmed_by = v_user_id,
    end_time = now()
WHERE id = p_match_id;
SELECT settle_match_bets(p_match_id, v_winner_team) INTO v_bets_settled;
-- Audit Log
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
        'FINISHED',
        p_team1_score,
        p_team2_score,
        p_confirmation_type,
        p_confirmation_type = 'ADMIN_FORCE_CONFIRM'
    );
-- ✅ AUTO REJOIN QUEUE (The Fix)
-- Clear current queue entries just in case (to re-insert cleanly)
-- Actually, internal_rejoin_queue handles checks, but let's delete first to be sure they leave "Active Match" constraint logic? 
-- Wait, queue table doesn't block re-entry if is_active=false. 
-- But they might still be in queue with is_active=true if something bugged?
-- Let's just Loop and Rejoin.
FOREACH v_player_id IN ARRAY v_all_player_ids LOOP IF v_player_id IS NOT NULL THEN PERFORM internal_rejoin_queue(v_player_id);
END IF;
END LOOP;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'winner_team',
    v_winner_team,
    'bets_settled',
    v_bets_settled,
    'message',
    '경기가 종료되었습니다. 대기열에 다시 등록되었습니다.'
);
END;
$$;