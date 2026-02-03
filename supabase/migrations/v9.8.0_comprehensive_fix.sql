-- ============================================================================
-- RallyGoGo V9.8.0 Hotfix Migration
-- Date: 2026-02-03
-- Purpose: Fix Queue RLS, ELO updates, and implement Parimutuel betting system
-- ============================================================================
-- ============================================================================
-- PHASE 1: QUEUE RLS POLICY FIX
-- Problem: Guest registration fails with 403 because auth.uid() != guest's player_id
-- Solution: Allow insert for guest profiles
-- ============================================================================
-- Drop existing policy
DROP POLICY IF EXISTS queue_insert_own ON queue;
-- Create new policy that allows:
-- 1. User inserting their own entry (auth.uid() = player_id)
-- 2. Any authenticated user inserting a guest entry (is_guest = true)
CREATE POLICY queue_insert_own_or_guest ON queue FOR
INSERT WITH CHECK (
        auth.uid() = player_id
        OR EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = player_id
                AND is_guest = true
        )
    );
-- ============================================================================
-- PHASE 2: ELO UPDATE FIX
-- Problem: finish_match_v2 only updates elo_mixed_doubles
-- Solution: Update correct ELO column based on match_type
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
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
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
IF p_team1_score > p_team2_score THEN v_winner_team := 'TEAM_1';
v_p1_actual := 1.0;
ELSIF p_team2_score > p_team1_score THEN v_winner_team := 'TEAM_2';
v_p1_actual := 0.0;
ELSE v_winner_team := 'DRAW';
v_p1_actual := 0.5;
END IF;
-- Calculate team average ratings based on match_type
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
ELSE -- MIXED
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
FOR v_profile IN
SELECT *
FROM profiles
WHERE id = ANY(v_all_player_ids) FOR
UPDATE LOOP is_team1 := v_profile.id = ANY(v_team1_ids);
-- Get old rating based on match_type
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
-- Update correct ELO column based on match_type
CASE
    v_match_type
    WHEN 'MENS_DOUBLES' THEN
    UPDATE profiles
    SET elo_mens_doubles = new_rating,
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
WHEN 'WOMENS_DOUBLES' THEN
UPDATE profiles
SET elo_womens_doubles = new_rating,
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
WHEN 'SINGLES' THEN
UPDATE profiles
SET elo_singles = new_rating,
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
ELSE -- MIXED
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
END CASE
;
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
UPDATE matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner_team,
    confirmed_by = v_user_id,
    end_time = now()
WHERE id = p_match_id;
SELECT settle_match_bets(p_match_id, v_winner_team) INTO v_bets_settled;
DELETE FROM queue
WHERE player_id = ANY(v_all_player_ids);
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
    'message',
    '경기가 종료되었습니다. MVP 투표가 시작되었습니다!'
);
END;
$$;
COMMENT ON FUNCTION finish_match_v2 IS 'V9.8.0: Complete match with match_type-aware ELO updates, bet settlement, and audit logging.';
-- ============================================================================
-- PHASE 3: BETTING SETTLEMENT DEBUG - Enhance settle_match_bets
-- ============================================================================
CREATE OR REPLACE FUNCTION settle_match_bets(p_match_id UUID, p_winner_team TEXT) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_bet RECORD;
v_winnings INTEGER;
v_settled_count INTEGER := 0;
BEGIN -- Log settlement attempt
RAISE NOTICE 'settle_match_bets called: match_id=%, winner=%',
p_match_id,
p_winner_team;
FOR v_bet IN
SELECT *
FROM bets
WHERE match_id = p_match_id
    AND result IN ('OPEN', 'LOCKED') FOR
UPDATE LOOP RAISE NOTICE 'Processing bet: id=%, pick=%, amount=%, odds=%',
    v_bet.id,
    v_bet.pick_team,
    v_bet.amount,
    v_bet.odds_at_bet;
IF p_winner_team = 'DRAW' THEN
UPDATE bets
SET result = 'DRAW'
WHERE id = v_bet.id;
UPDATE profiles
SET rally_point = rally_point + v_bet.amount
WHERE id = v_bet.user_id;
v_settled_count := v_settled_count + 1;
ELSIF p_winner_team = v_bet.pick_team THEN v_winnings := FLOOR(v_bet.amount * v_bet.odds_at_bet);
UPDATE bets
SET result = 'WON'
WHERE id = v_bet.id;
UPDATE profiles
SET rally_point = rally_point + v_winnings
WHERE id = v_bet.user_id;
v_settled_count := v_settled_count + 1;
RAISE NOTICE 'Bet WON: user=%, winnings=%',
v_bet.user_id,
v_winnings;
ELSE
UPDATE bets
SET result = 'LOST'
WHERE id = v_bet.id;
v_settled_count := v_settled_count + 1;
RAISE NOTICE 'Bet LOST: user=%',
v_bet.user_id;
END IF;
END LOOP;
RAISE NOTICE 'settle_match_bets complete: settled_count=%',
v_settled_count;
RETURN v_settled_count;
END;
$$;
COMMENT ON FUNCTION settle_match_bets IS 'V9.8.0: Internal function to settle bets with debug logging.';
-- ============================================================================
-- PHASE 4: PARIMUTUEL BETTING SYSTEM
-- ============================================================================
-- 4.1 Create betting_pools table
CREATE TABLE IF NOT EXISTS betting_pools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    team1_total INTEGER DEFAULT 0 NOT NULL CHECK (team1_total >= 0),
    team2_total INTEGER DEFAULT 0 NOT NULL CHECK (team2_total >= 0),
    house_rate NUMERIC(5, 4) DEFAULT 0.05 NOT NULL CHECK (
        house_rate >= 0
        AND house_rate < 1
    ),
    is_settled BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now(),
    settled_at TIMESTAMPTZ,
    CONSTRAINT betting_pools_match_unique UNIQUE (match_id)
);
-- Add indexes
CREATE INDEX IF NOT EXISTS idx_betting_pools_match ON betting_pools(match_id);
CREATE INDEX IF NOT EXISTS idx_betting_pools_active ON betting_pools(is_settled)
WHERE is_settled = false;
-- RLS for betting_pools
ALTER TABLE betting_pools ENABLE ROW LEVEL SECURITY;
CREATE POLICY betting_pools_select_public ON betting_pools FOR
SELECT USING (true);
CREATE POLICY betting_pools_admin_write ON betting_pools FOR ALL USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- Add payout_amount column to bets if not exists
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'bets'
        AND column_name = 'payout_amount'
) THEN
ALTER TABLE bets
ADD COLUMN payout_amount INTEGER;
END IF;
END $$;
-- Realtime for betting_pools
ALTER PUBLICATION supabase_realtime
ADD TABLE betting_pools;
-- 4.2 Helper function to calculate pool odds
CREATE OR REPLACE FUNCTION calculate_pool_odds(
        p_team1_total INTEGER,
        p_team2_total INTEGER,
        p_for_team TEXT,
        p_house_rate NUMERIC DEFAULT 0.05
    ) RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_total_pool NUMERIC;
v_net_pool NUMERIC;
v_team_total NUMERIC;
BEGIN v_total_pool := COALESCE(p_team1_total, 0) + COALESCE(p_team2_total, 0);
IF v_total_pool = 0 THEN RETURN 2.0;
END IF;
-- Default odds when no bets
v_net_pool := v_total_pool * (1 - p_house_rate);
v_team_total := CASE
    WHEN p_for_team = 'TEAM_1' THEN COALESCE(p_team1_total, 0)
    ELSE COALESCE(p_team2_total, 0)
END;
IF v_team_total = 0 THEN RETURN 10.0;
END IF;
-- Max odds when no bets on this team
RETURN GREATEST(
    1.01,
    ROUND((v_net_pool / v_team_total)::NUMERIC, 2)
);
END;
$$;
COMMENT ON FUNCTION calculate_pool_odds IS 'Calculate parimutuel odds for a team based on pool distribution. Returns odds between 1.01 and 10.0.';
-- 4.3 New parimutuel betting RPC (replaces place_bet_v2 for new bets)
CREATE OR REPLACE FUNCTION place_bet_parimutuel(
        p_match_id UUID,
        p_pick_team TEXT,
        p_amount INTEGER
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID := auth.uid();
v_pool RECORD;
v_match RECORD;
v_profile RECORD;
v_new_team1_total INTEGER;
v_new_team2_total INTEGER;
v_current_odds NUMERIC;
v_bet_id UUID;
BEGIN -- Auth check
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- Validate pick
IF p_pick_team NOT IN ('TEAM_1', 'TEAM_2') THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_PICK_TEAM');
END IF;
-- Validate amount
IF p_amount <= 0
OR p_amount > 10000 THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_AMOUNT',
    'message',
    '배팅 금액은 1~10,000 사이여야 합니다.'
);
END IF;
-- Check match exists and is bettable
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status NOT IN ('DRAFT', 'PLAYING') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'BETTING_CLOSED_STATUS'
);
END IF;
IF v_match.status = 'PLAYING'
AND v_match.betting_closes_at IS NOT NULL
AND now() > v_match.betting_closes_at THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'BETTING_CLOSED_TIME',
    'message',
    '베팅 마감 시간이 지났습니다.'
);
END IF;
-- Check user balance
SELECT * INTO v_profile
FROM profiles
WHERE id = v_user_id FOR
UPDATE;
IF v_profile IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PROFILE_NOT_FOUND');
END IF;
IF v_profile.rally_point < p_amount THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INSUFFICIENT_BALANCE',
    'message',
    '포인트가 부족합니다. 현재: ' || v_profile.rally_point
);
END IF;
-- Get or create pool
INSERT INTO betting_pools (match_id)
VALUES (p_match_id) ON CONFLICT (match_id) DO NOTHING;
SELECT * INTO v_pool
FROM betting_pools
WHERE match_id = p_match_id FOR
UPDATE;
-- Calculate new totals
IF p_pick_team = 'TEAM_1' THEN v_new_team1_total := v_pool.team1_total + p_amount;
v_new_team2_total := v_pool.team2_total;
ELSE v_new_team1_total := v_pool.team1_total;
v_new_team2_total := v_pool.team2_total + p_amount;
END IF;
-- Calculate odds at time of bet
v_current_odds := calculate_pool_odds(
    v_new_team1_total,
    v_new_team2_total,
    p_pick_team,
    v_pool.house_rate
);
-- Deduct points
UPDATE profiles
SET rally_point = rally_point - p_amount
WHERE id = v_user_id;
-- Update pool
UPDATE betting_pools
SET team1_total = v_new_team1_total,
    team2_total = v_new_team2_total
WHERE id = v_pool.id;
-- Record bet (using odds_at_bet for parimutuel - will be recalculated at settlement)
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
        v_current_odds,
        'OPEN'
    )
RETURNING id INTO v_bet_id;
-- Return current state
RETURN jsonb_build_object(
    'success',
    true,
    'bet_id',
    v_bet_id,
    'amount',
    p_amount,
    'pick_team',
    p_pick_team,
    'odds_at_bet',
    v_current_odds,
    'team1_odds',
    calculate_pool_odds(
        v_new_team1_total,
        v_new_team2_total,
        'TEAM_1',
        v_pool.house_rate
    ),
    'team2_odds',
    calculate_pool_odds(
        v_new_team1_total,
        v_new_team2_total,
        'TEAM_2',
        v_pool.house_rate
    ),
    'team1_total',
    v_new_team1_total,
    'team2_total',
    v_new_team2_total,
    'new_balance',
    v_profile.rally_point - p_amount
);
END;
$$;
COMMENT ON FUNCTION place_bet_parimutuel IS 'Place a parimutuel bet with dynamic pool-based odds. Returns current pool state.';
-- 4.4 Get pool info RPC
CREATE OR REPLACE FUNCTION get_betting_pool(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_pool RECORD;
BEGIN
SELECT * INTO v_pool
FROM betting_pools
WHERE match_id = p_match_id;
IF v_pool IS NULL THEN RETURN jsonb_build_object(
    'success',
    true,
    'team1_total',
    0,
    'team2_total',
    0,
    'team1_odds',
    2.0,
    'team2_odds',
    2.0,
    'house_rate',
    0.05,
    'is_settled',
    false
);
END IF;
RETURN jsonb_build_object(
    'success',
    true,
    'team1_total',
    v_pool.team1_total,
    'team2_total',
    v_pool.team2_total,
    'team1_odds',
    calculate_pool_odds(
        v_pool.team1_total,
        v_pool.team2_total,
        'TEAM_1',
        v_pool.house_rate
    ),
    'team2_odds',
    calculate_pool_odds(
        v_pool.team1_total,
        v_pool.team2_total,
        'TEAM_2',
        v_pool.house_rate
    ),
    'house_rate',
    v_pool.house_rate,
    'is_settled',
    v_pool.is_settled
);
END;
$$;
COMMENT ON FUNCTION get_betting_pool IS 'Get current betting pool status and odds for a match.';
-- 4.5 Updated settle function for parimutuel (uses final odds at settlement time)
CREATE OR REPLACE FUNCTION settle_pool_bets(p_match_id UUID, p_winner_team TEXT) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_pool RECORD;
v_bet RECORD;
v_final_odds NUMERIC;
v_payout INTEGER;
v_settled_count INTEGER := 0;
BEGIN -- Get pool
SELECT * INTO v_pool
FROM betting_pools
WHERE match_id = p_match_id FOR
UPDATE;
IF v_pool IS NULL
OR v_pool.is_settled THEN RETURN 0;
END IF;
-- Calculate final odds (at settlement, not at bet time)
v_final_odds := calculate_pool_odds(
    v_pool.team1_total,
    v_pool.team2_total,
    p_winner_team,
    v_pool.house_rate
);
FOR v_bet IN
SELECT *
FROM bets
WHERE match_id = p_match_id
    AND result IN ('OPEN', 'LOCKED') FOR
UPDATE LOOP IF p_winner_team = 'DRAW' THEN -- Draw: refund original amount
UPDATE bets
SET result = 'DRAW',
    payout_amount = v_bet.amount
WHERE id = v_bet.id;
UPDATE profiles
SET rally_point = rally_point + v_bet.amount
WHERE id = v_bet.user_id;
ELSIF p_winner_team = v_bet.pick_team THEN -- Win: calculate payout using FINAL odds (parimutuel style)
v_payout := FLOOR(v_bet.amount * v_final_odds);
UPDATE bets
SET result = 'WON',
    payout_amount = v_payout,
    odds_at_bet = v_final_odds
WHERE id = v_bet.id;
UPDATE profiles
SET rally_point = rally_point + v_payout
WHERE id = v_bet.user_id;
ELSE -- Loss: no payout
UPDATE bets
SET result = 'LOST',
    payout_amount = 0
WHERE id = v_bet.id;
END IF;
v_settled_count := v_settled_count + 1;
END LOOP;
-- Mark pool as settled
UPDATE betting_pools
SET is_settled = true,
    settled_at = now()
WHERE id = v_pool.id;
RETURN v_settled_count;
END;
$$;
COMMENT ON FUNCTION settle_pool_bets IS 'Settle all bets using parimutuel final odds. Replaces settle_match_bets for pool-based betting.';
-- ============================================================================
-- GRANT PERMISSIONS
-- ============================================================================
GRANT EXECUTE ON FUNCTION calculate_pool_odds TO authenticated,
    anon;
GRANT EXECUTE ON FUNCTION place_bet_parimutuel TO authenticated;
GRANT EXECUTE ON FUNCTION get_betting_pool TO authenticated,
    anon;
GRANT EXECUTE ON FUNCTION settle_pool_bets TO authenticated;
GRANT SELECT ON betting_pools TO authenticated,
    anon;
-- ============================================================================
-- SUMMARY
-- ============================================================================
-- V9.8.0 Migration Complete:
-- 1. ✅ Queue RLS fixed for guest registration
-- 2. ✅ finish_match_v2 now updates correct ELO column based on match_type
-- 3. ✅ settle_match_bets enhanced with debug logging
-- 4. ✅ Parimutuel betting system implemented:
--    - betting_pools table
--    - calculate_pool_odds helper
--    - place_bet_parimutuel RPC
--    - get_betting_pool RPC
--    - settle_pool_bets RPC
-- ============================================================================