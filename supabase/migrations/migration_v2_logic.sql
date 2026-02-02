-- ============================================================================
-- RallyGoGo V2 Logic Layer Migration
-- ============================================================================
-- Purpose: Core RPC functions for atomic operations with proper locking,
--          identity enforcement, and race condition prevention.
--
-- Created: 2026-01-22
-- Depends on: migration_v1_full_reset.sql (schema)
--
-- Functions:
--   1. place_bet_v2 - Betting with timing check and balance lock
--   2. finish_match_v2 - Match completion with ELO and bet settlement
--   3. join_queue - Queue entry with duplicate prevention
--   4. create_match_draft - Atomic match creation from queue
--   5. leave_queue - Safe queue exit
--   6. start_match - DRAFT → PLAYING transition
--   7. cast_mvp_vote - MVP voting with idempotency
--   8. settle_match_bets - Internal bet settlement helper
--
-- All functions use:
--   - SECURITY DEFINER: Execute with owner privileges (bypasses RLS)
--   - SET search_path = public: Security best practice
--   - auth.uid() enforcement: Identity verification
-- ============================================================================
-- ============================================================================
-- HELPER FUNCTION: Get current authenticated user ID
-- ============================================================================
CREATE OR REPLACE FUNCTION get_current_user_id() RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$ BEGIN RETURN auth.uid();
END;
$$;
COMMENT ON FUNCTION get_current_user_id IS 'Helper to get current auth.uid() in SECURITY DEFINER context';
-- ============================================================================
-- 1. PLACE BET V2
-- ============================================================================
-- Secure betting with:
--   - Timing validation (before betting_closes_at)
--   - FOR UPDATE lock on balance (prevents double-spend)
--   - Identity enforcement (can only bet with own points)
--   - Atomic balance deduction + bet creation
-- ============================================================================
CREATE OR REPLACE FUNCTION place_bet_v2(
        p_match_id UUID,
        p_pick_team TEXT,
        -- 'TEAM_1' or 'TEAM_2'
        p_amount INTEGER
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_profile RECORD;
v_odds NUMERIC;
v_bet_id UUID;
v_team1_elo INTEGER;
v_team2_elo INTEGER;
BEGIN -- ================================================================
-- STEP 1: Identity Enforcement
-- Only authenticated users can bet, and only for themselves
-- ================================================================
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED',
    'message',
    '로그인이 필요합니다.'
);
END IF;
-- ================================================================
-- STEP 2: Validate Input
-- ================================================================
IF p_pick_team NOT IN ('TEAM_1', 'TEAM_2') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_PICK_TEAM',
    'message',
    '올바른 팀을 선택해주세요. (TEAM_1 또는 TEAM_2)'
);
END IF;
IF p_amount <= 0 THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_AMOUNT',
    'message',
    '베팅 금액은 0보다 커야 합니다.'
);
END IF;
-- ================================================================
-- STEP 3: Lock and Validate Match
-- FOR UPDATE prevents concurrent modifications
-- ================================================================
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'MATCH_NOT_FOUND',
    'message',
    '경기를 찾을 수 없습니다.'
);
END IF;
-- ================================================================
-- STEP 4: Timing Check - Betting Window Validation
-- Betting must be done while match is DRAFT or before betting_closes_at
-- ================================================================
IF v_match.status NOT IN ('DRAFT', 'PLAYING') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'BETTING_CLOSED_STATUS',
    'message',
    '이 경기는 더 이상 베팅할 수 없습니다.'
);
END IF;
-- Check betting_closes_at for PLAYING matches
IF v_match.status = 'PLAYING'
AND v_match.betting_closes_at IS NOT NULL THEN IF now() > v_match.betting_closes_at THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'BETTING_CLOSED_TIME',
    'message',
    '베팅 마감 시간이 지났습니다. (경기 시작 후 5분)'
);
END IF;
END IF;
-- ================================================================
-- STEP 5: Lock Profile and Check Balance
-- FOR UPDATE ensures atomic balance check + deduction
-- This prevents race condition: two bets exceeding balance
-- ================================================================
SELECT * INTO v_profile
FROM profiles
WHERE id = v_user_id FOR
UPDATE;
IF v_profile IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PROFILE_NOT_FOUND',
    'message',
    '프로필을 찾을 수 없습니다.'
);
END IF;
IF v_profile.rally_point < p_amount THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INSUFFICIENT_BALANCE',
    'message',
    '포인트가 부족합니다. 현재 잔액: ' || v_profile.rally_point || ' RP'
);
END IF;
-- ================================================================
-- STEP 6: Calculate Odds
-- Based on team ELO ratings using logistic probability
-- ================================================================
SELECT COALESCE(p1.elo_mixed_doubles, 1200) + COALESCE(p2.elo_mixed_doubles, 1200) INTO v_team1_elo
FROM profiles p1,
    profiles p2
WHERE p1.id = v_match.player_1
    AND p2.id = v_match.player_2;
IF v_team1_elo IS NULL THEN v_team1_elo := 2400;
-- Default for 2 players at 1200
END IF;
SELECT COALESCE(p3.elo_mixed_doubles, 1200) + COALESCE(p4.elo_mixed_doubles, 1200) INTO v_team2_elo
FROM profiles p3,
    profiles p4
WHERE p3.id = v_match.player_3
    AND p4.id = v_match.player_4;
IF v_team2_elo IS NULL THEN v_team2_elo := 2400;
END IF;
-- Calculate odds using ELO probability formula
-- P(A wins) = 1 / (1 + 10^((RB - RA) / 400))
-- Odds = 0.95 / P (5% house edge)
DECLARE prob_team1 NUMERIC;
prob_team2 NUMERIC;
BEGIN prob_team1 := 1.0 / (
    1.0 + power(10.0, (v_team2_elo - v_team1_elo) / 800.0)
);
prob_team2 := 1.0 - prob_team1;
IF p_pick_team = 'TEAM_1' THEN v_odds := LEAST(GREATEST(0.95 / prob_team1, 1.1), 10.0);
ELSE v_odds := LEAST(GREATEST(0.95 / prob_team2, 1.1), 10.0);
END IF;
v_odds := ROUND(v_odds, 2);
END;
-- ================================================================
-- STEP 7: Atomic Transaction - Deduct Balance + Create Bet
-- ================================================================
-- Deduct balance
UPDATE profiles
SET rally_point = rally_point - p_amount
WHERE id = v_user_id;
-- Create bet (UNIQUE constraint handles duplicate prevention)
BEGIN
INSERT INTO bets (
        match_id,
        user_id,
        pick_team,
        amount,
        odds_at_bet,
        result
    )
VALUES (
        p_match_id,
        v_user_id,
        p_pick_team,
        p_amount,
        v_odds,
        'OPEN'
    )
RETURNING id INTO v_bet_id;
EXCEPTION
WHEN unique_violation THEN -- Rollback balance deduction by re-adding
UPDATE profiles
SET rally_point = rally_point + p_amount
WHERE id = v_user_id;
RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'DUPLICATE_BET',
    'message',
    '이미 해당 팀에 베팅하셨습니다.'
);
END;
-- ================================================================
-- Success Response
-- ================================================================
RETURN jsonb_build_object(
    'success',
    true,
    'bet_id',
    v_bet_id,
    'new_balance',
    v_profile.rally_point - p_amount,
    'odds',
    v_odds,
    'amount',
    p_amount,
    'pick_team',
    p_pick_team
);
END;
$$;
COMMENT ON FUNCTION place_bet_v2 IS 'Secure betting with FOR UPDATE lock on balance, timing validation, and identity enforcement. 
Prevents double-spend via atomic deduction + creation in same transaction.';
-- ============================================================================
-- 2. SETTLE MATCH BETS (Internal Helper)
-- ============================================================================
-- Called internally by finish_match_v2 to settle all bets for a match
-- ============================================================================
CREATE OR REPLACE FUNCTION settle_match_bets(
        p_match_id UUID,
        p_winner_team TEXT -- 'TEAM_1', 'TEAM_2', or 'DRAW'
    ) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_bet RECORD;
v_winnings INTEGER;
v_settled_count INTEGER := 0;
BEGIN -- ================================================================
-- Process each LOCKED bet for this match
-- ================================================================
FOR v_bet IN
SELECT *
FROM bets
WHERE match_id = p_match_id
    AND result IN ('OPEN', 'LOCKED') FOR
UPDATE LOOP IF p_winner_team = 'DRAW' THEN -- ================================================================
    -- DRAW: Return original stake to bettor
    -- ================================================================
UPDATE bets
SET result = 'DRAW'
WHERE id = v_bet.id;
UPDATE profiles
SET rally_point = rally_point + v_bet.amount
WHERE id = v_bet.user_id;
v_settled_count := v_settled_count + 1;
ELSIF p_winner_team = v_bet.pick_team THEN -- ================================================================
-- WIN: Pay out at recorded odds
-- Winnings = amount * odds (includes original stake)
-- ================================================================
v_winnings := FLOOR(v_bet.amount * v_bet.odds_at_bet);
UPDATE bets
SET result = 'WON'
WHERE id = v_bet.id;
UPDATE profiles
SET rally_point = rally_point + v_winnings
WHERE id = v_bet.user_id;
v_settled_count := v_settled_count + 1;
ELSE -- ================================================================
-- LOSE: Bet is lost, no payout (stake already deducted)
-- ================================================================
UPDATE bets
SET result = 'LOST'
WHERE id = v_bet.id;
v_settled_count := v_settled_count + 1;
END IF;
END LOOP;
RETURN v_settled_count;
END;
$$;
COMMENT ON FUNCTION settle_match_bets IS 'Internal function to settle all bets for a match. Called by finish_match_v2.
WIN: Pays amount * odds_at_bet. LOSE: No payout. DRAW: Returns original stake.';
-- ============================================================================
-- 3. FINISH MATCH V2
-- ============================================================================
-- Complete match lifecycle:
--   - Validate caller is participant or admin
--   - Update match status and scores
--   - Calculate and apply ELO changes
--   - Settle all bets
--   - Remove players from queue
--   - Create audit log entry
-- ============================================================================
CREATE OR REPLACE FUNCTION finish_match_v2(
        p_match_id UUID,
        p_team1_score INTEGER,
        p_team2_score INTEGER,
        p_confirmation_type TEXT DEFAULT 'NORMAL_CONFIRM'
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_profile RECORD;
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
v_elo_updates JSONB := '[]'::JSONB;
v_bets_settled INTEGER;
v_status_before TEXT;
BEGIN -- ================================================================
-- STEP 1: Identity Check
-- ================================================================
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- ================================================================
-- STEP 2: Validate Input
-- ================================================================
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
-- ================================================================
-- STEP 3: Lock and Load Match
-- ================================================================
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'MATCH_NOT_FOUND'
);
END IF;
-- ================================================================
-- STEP 4: Idempotency Check
-- ================================================================
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
-- ================================================================
-- STEP 5: Permission Check
-- ================================================================
v_team1_ids := ARRAY [v_match.player_1, v_match.player_2];
v_team2_ids := ARRAY [v_match.player_3, v_match.player_4];
v_all_player_ids := v_team1_ids || v_team2_ids;
-- Remove NULLs
SELECT array_agg(x) INTO v_all_player_ids
FROM unnest(v_all_player_ids) x
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
ELSIF p_confirmation_type = 'ADMIN_FORCE_CONFIRM' THEN IF NOT v_is_admin THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ADMIN_REQUIRED'
);
END IF;
END IF;
-- ================================================================
-- STEP 6: Determine Winner
-- ================================================================
IF p_team1_score > p_team2_score THEN v_winner_team := 'TEAM_1';
v_p1_actual := 1.0;
ELSIF p_team2_score > p_team1_score THEN v_winner_team := 'TEAM_2';
v_p1_actual := 0.0;
ELSE v_winner_team := 'DRAW';
v_p1_actual := 0.5;
END IF;
-- ================================================================
-- STEP 7: Calculate Team Average Ratings
-- ================================================================
SELECT COALESCE(AVG(elo_mixed_doubles), 1200) INTO v_team1_rating
FROM profiles
WHERE id = ANY(v_team1_ids);
SELECT COALESCE(AVG(elo_mixed_doubles), 1200) INTO v_team2_rating
FROM profiles
WHERE id = ANY(v_team2_ids);
-- Expected score for Team 1 (ELO probability)
v_p1_expected := 1.0 / (
    1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0)
);
v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);
-- ================================================================
-- STEP 8: Apply ELO Updates
-- ================================================================
FOR v_profile IN
SELECT *
FROM profiles
WHERE id = ANY(v_all_player_ids) FOR
UPDATE LOOP
DECLARE is_team1 BOOLEAN;
final_delta INTEGER;
old_rating INTEGER;
new_rating INTEGER;
multiplier NUMERIC := 1.0;
BEGIN is_team1 := v_profile.id = ANY(v_team1_ids);
old_rating := COALESCE(v_profile.elo_mixed_doubles, 1200);
IF is_team1 THEN final_delta := ROUND(v_base_delta);
ELSE final_delta := ROUND(v_base_delta * -1);
END IF;
-- Guest multiplier (faster learning)
IF v_profile.is_guest THEN multiplier := 1.5;
final_delta := ROUND(final_delta * multiplier);
END IF;
new_rating := GREATEST(0, LEAST(4000, old_rating + final_delta));
-- Update profile
UPDATE profiles
SET elo_mixed_doubles = new_rating,
    games_played_today = COALESCE(games_played_today, 0) + 1,
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
            (
                is_team1
                AND v_winner_team = 'TEAM_1'
            )
            OR (
                NOT is_team1
                AND v_winner_team = 'TEAM_2'
            )
        ) THEN COALESCE(winning_streak, 0) + 1
        ELSE 0
    END
WHERE id = v_profile.id;
-- Record ELO history
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
v_elo_updates := v_elo_updates || jsonb_build_object(
    'player_id',
    v_profile.id,
    'old_rating',
    old_rating,
    'new_rating',
    new_rating,
    'delta',
    final_delta
);
END;
END LOOP;
-- ================================================================
-- STEP 9: Update Match Status
-- ================================================================
UPDATE matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner_team,
    confirmed_by = v_user_id,
    end_time = now()
WHERE id = p_match_id;
-- ================================================================
-- STEP 10: Settle Bets
-- ================================================================
SELECT settle_match_bets(p_match_id, v_winner_team) INTO v_bets_settled;
-- ================================================================
-- STEP 11: Remove Players from Queue
-- ================================================================
DELETE FROM queue
WHERE player_id = ANY(v_all_player_ids);
-- ================================================================
-- STEP 12: Create Audit Log
-- ================================================================
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
-- ================================================================
-- Success Response
-- MVP Voting is now open for all authenticated users
-- ================================================================
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'winner_team',
    v_winner_team,
    'elo_updates',
    v_elo_updates,
    'bets_settled',
    v_bets_settled,
    'mvp_voting_open',
    true,
    'message',
    '경기가 종료되었습니다. MVP 투표가 시작되었습니다!'
);
END;
$$;
COMMENT ON FUNCTION finish_match_v2 IS 'Complete match with ELO updates, bet settlement, and audit logging.
MVP voting opens automatically for all authenticated users after match completion.';
-- ============================================================================
-- 4. JOIN QUEUE
-- ============================================================================
-- Add player to matchmaking queue:
--   - Supports guests (is_guest = true)
--   - Prevents duplicate entries
--   - Checks if already in active match
-- ============================================================================
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
BEGIN -- ================================================================
-- STEP 1: Identity Check
-- ================================================================
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED',
    'message',
    '로그인이 필요합니다.'
);
END IF;
-- ================================================================
-- STEP 2: Get Profile (guests allowed)
-- ================================================================
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
-- ================================================================
-- STEP 3: Check for Existing Queue Entry
-- ================================================================
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
    v_existing_queue.id,
    'joined_at',
    v_existing_queue.joined_at
);
END IF;
-- ================================================================
-- STEP 4: Check for Active Match
-- Player cannot join queue if in non-finished match
-- ================================================================
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
    '진행 중인 경기가 있습니다. 경기 완료 후 다시 시도해주세요.',
    'match_id',
    v_active_match.id,
    'match_status',
    v_active_match.status
);
END IF;
-- ================================================================
-- STEP 5: Insert into Queue
-- UNIQUE constraint prevents duplicate if race condition occurs
-- ================================================================
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
WHEN unique_violation THEN -- Race condition: another request already added
SELECT id INTO v_queue_id
FROM queue
WHERE player_id = v_user_id;
RETURN jsonb_build_object(
    'success',
    true,
    'queue_id',
    v_queue_id,
    'message',
    '이미 대기열에 등록되어 있습니다.',
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
COMMENT ON FUNCTION join_queue IS 'Add player to matchmaking queue. Supports guests. 
UNIQUE constraint prevents duplicate entries from race conditions.';
-- ============================================================================
-- 5. LEAVE QUEUE
-- ============================================================================
-- Remove player from queue (self-service)
-- ============================================================================
CREATE OR REPLACE FUNCTION leave_queue() RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_deleted_count INTEGER;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
DELETE FROM queue
WHERE player_id = v_user_id;
GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
IF v_deleted_count = 0 THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'NOT_IN_QUEUE',
    'message',
    '대기열에 없습니다.'
);
END IF;
RETURN jsonb_build_object(
    'success',
    true,
    'message',
    '대기열에서 나왔습니다.'
);
END;
$$;
-- ============================================================================
-- 6. CREATE MATCH DRAFT
-- ============================================================================
-- Admin-only: Create match from selected queue players
-- Atomic operation: Creates match + removes players from queue
-- ============================================================================
CREATE OR REPLACE FUNCTION create_match_draft(
        p_player_ids UUID [],
        -- Array of 2-4 player UUIDs
        p_match_type match_type_t DEFAULT 'MIXED',
        p_court_name TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_is_admin BOOLEAN;
v_match_id UUID;
v_player_count INTEGER;
v_player_id UUID;
v_in_match BOOLEAN;
v_in_queue BOOLEAN;
v_locked_queue_ids UUID [] := '{}';
BEGIN -- ================================================================
-- STEP 1: Admin Check
-- ================================================================
v_user_id := auth.uid();
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
IF NOT v_is_admin THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ADMIN_REQUIRED',
    'message',
    '관리자만 매치를 생성할 수 있습니다.'
);
END IF;
-- ================================================================
-- STEP 2: Validate Player Count (2-4 players)
-- ================================================================
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
-- ================================================================
-- STEP 3: Lock Queue Entries and Validate
-- FOR UPDATE ensures no concurrent match creation with same players
-- ================================================================
FOR v_player_id IN
SELECT unnest(p_player_ids) LOOP -- Check if player is in another active match
SELECT EXISTS(
        SELECT 1
        FROM matches
        WHERE status NOT IN ('FINISHED', 'CANCELLED')
            AND (
                player_1 = v_player_id
                OR player_2 = v_player_id
                OR player_3 = v_player_id
                OR player_4 = v_player_id
            )
    ) INTO v_in_match;
IF v_in_match THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PLAYER_IN_ACTIVE_MATCH',
    'message',
    '플레이어 ' || v_player_id || '가 진행 중인 경기에 있습니다.',
    'player_id',
    v_player_id
);
END IF;
-- Lock and verify queue entry exists
SELECT EXISTS(
        SELECT 1
        FROM queue
        WHERE player_id = v_player_id FOR
        UPDATE
    ) INTO v_in_queue;
IF NOT v_in_queue THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PLAYER_NOT_IN_QUEUE',
    'message',
    '플레이어 ' || v_player_id || '가 대기열에 없습니다.',
    'player_id',
    v_player_id
);
END IF;
v_locked_queue_ids := v_locked_queue_ids || v_player_id;
END LOOP;
-- ================================================================
-- STEP 4: Create Match
-- ================================================================
INSERT INTO matches (
        player_1,
        player_2,
        player_3,
        player_4,
        status,
        match_type,
        court_name,
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
        now()
    )
RETURNING id INTO v_match_id;
-- ================================================================
-- STEP 5: Remove Players from Queue (Atomic)
-- ================================================================
DELETE FROM queue
WHERE player_id = ANY(p_player_ids);
-- ================================================================
-- STEP 6: Audit Log
-- ================================================================
INSERT INTO admin_operation_log (
        target_type,
        target_id,
        action,
        new_value,
        operated_by
    )
VALUES (
        'MATCH',
        v_match_id,
        'CREATE_MATCH_DRAFT',
        'Players: ' || array_to_string(p_player_ids, ', '),
        v_user_id
    );
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    v_match_id,
    'players',
    p_player_ids,
    'status',
    'DRAFT',
    'message',
    '매치가 생성되었습니다.'
);
END;
$$;
COMMENT ON FUNCTION create_match_draft IS 'Admin-only: Create match from queue players atomically.
Locks queue entries first, validates players not in active matches, 
then creates match and removes from queue in single transaction.';
-- ============================================================================
-- 7. START MATCH (DRAFT → PLAYING)
-- ============================================================================
-- Transition match from DRAFT to PLAYING
-- Automatically sets betting close time (start_time + 5 minutes)
-- ============================================================================
CREATE OR REPLACE FUNCTION start_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_is_admin BOOLEAN;
v_match RECORD;
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
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status != 'DRAFT' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_STATUS',
    'message',
    'DRAFT 상태의 경기만 시작할 수 있습니다. 현재: ' || v_match.status
);
END IF;
-- Trigger handle_match_start() will set start_time and betting_closes_at
UPDATE matches
SET status = 'PLAYING'
WHERE id = p_match_id;
-- Get updated match
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id;
RETURN jsonb_build_object(
    'success',
    true,
    'match_id',
    p_match_id,
    'status',
    'PLAYING',
    'start_time',
    v_match.start_time,
    'betting_closes_at',
    v_match.betting_closes_at,
    'message',
    '경기가 시작되었습니다. 베팅은 5분 후에 마감됩니다.'
);
END;
$$;
-- ============================================================================
-- 8. CAST MVP VOTE
-- ============================================================================
-- Cast MVP vote with idempotency (UNIQUE constraint handles duplicates)
-- All authenticated users can vote (not just participants)
-- ============================================================================
CREATE OR REPLACE FUNCTION cast_mvp_vote(
        p_match_id UUID,
        p_target_id UUID,
        p_tag TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_match RECORD;
v_vote_id UUID;
BEGIN -- ================================================================
-- STEP 1: Identity Check
-- ================================================================
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- ================================================================
-- STEP 2: Verify Match is FINISHED
-- ================================================================
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status != 'FINISHED' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'VOTING_NOT_OPEN',
    'message',
    '경기가 종료된 후에 투표할 수 있습니다.'
);
END IF;
-- ================================================================
-- STEP 3: Verify Target is a Participant
-- ================================================================
IF p_target_id NOT IN (
    v_match.player_1,
    v_match.player_2,
    v_match.player_3,
    v_match.player_4
) THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_TARGET',
    'message',
    '해당 경기 참가자에게만 투표할 수 있습니다.'
);
END IF;
-- ================================================================
-- STEP 4: Insert Vote (UNIQUE constraint handles idempotency)
-- ================================================================
BEGIN
INSERT INTO mvp_votes (match_id, voter_id, target_id, tag)
VALUES (p_match_id, v_user_id, p_target_id, p_tag)
RETURNING id INTO v_vote_id;
EXCEPTION
WHEN unique_violation THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'ALREADY_VOTED',
    'message',
    '이미 투표하셨습니다.'
);
END;
RETURN jsonb_build_object(
    'success',
    true,
    'vote_id',
    v_vote_id,
    'message',
    'MVP 투표가 완료되었습니다.'
);
END;
$$;
COMMENT ON FUNCTION cast_mvp_vote IS 'Cast MVP vote. All authenticated users can vote (not just participants).
UNIQUE constraint prevents duplicate votes - returns friendly error message.';
-- ============================================================================
-- GRANT EXECUTE PERMISSIONS
-- ============================================================================
-- Revoke from PUBLIC first, then grant to specific roles
-- Player-facing RPCs: authenticated only
REVOKE ALL ON FUNCTION place_bet_v2
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION place_bet_v2 TO authenticated,
    service_role;
REVOKE ALL ON FUNCTION join_queue
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION join_queue TO authenticated,
    service_role;
REVOKE ALL ON FUNCTION leave_queue
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leave_queue TO authenticated,
    service_role;
REVOKE ALL ON FUNCTION cast_mvp_vote
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cast_mvp_vote TO authenticated,
    service_role;
REVOKE ALL ON FUNCTION finish_match_v2
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finish_match_v2 TO authenticated,
    service_role;
-- Admin-only RPCs
REVOKE ALL ON FUNCTION create_match_draft
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_match_draft TO authenticated,
    service_role;
REVOKE ALL ON FUNCTION start_match
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION start_match TO authenticated,
    service_role;
-- Internal-only (service_role)
REVOKE ALL ON FUNCTION settle_match_bets
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION settle_match_bets TO service_role;
REVOKE ALL ON FUNCTION lock_expired_bets
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION lock_expired_bets TO service_role;
-- Helper function
REVOKE ALL ON FUNCTION get_current_user_id
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_current_user_id TO authenticated,
    service_role;
-- ============================================================================
-- SCHEMA VERSION COMMENT
-- ============================================================================
COMMENT ON SCHEMA public IS 'RallyGoGo V1.0 + V2.0 Logic Layer - 2026-01-22';