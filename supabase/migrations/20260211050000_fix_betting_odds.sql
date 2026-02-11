-- ============================================================================
-- Fix Betting Odds with ELO-seeded AMM (Virtual Liquidity)
-- Date: 2026-02-11
-- Purpose: Anchor betting odds to ELO win probability using Virtual Liquidity
-- ============================================================================
-- 1. Helper to get Match Probabilities based on ELO
CREATE OR REPLACE FUNCTION get_match_probability(p_match_id UUID) RETURNS TABLE (
        team1_prob NUMERIC,
        team1_elo NUMERIC,
        team2_elo NUMERIC
    ) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_match RECORD;
v_team1_avg NUMERIC;
v_team2_avg NUMERIC;
v_elo_col TEXT;
BEGIN
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id;
IF v_match IS NULL THEN team1_prob := 0.5;
team1_elo := 1200;
team2_elo := 1200;
RETURN NEXT;
RETURN;
END IF;
-- Determine ELO column based on match_type
v_elo_col := CASE
    WHEN v_match.match_type = 'MENS_DOUBLES' THEN 'elo_mens_doubles'
    WHEN v_match.match_type = 'WOMENS_DOUBLES' THEN 'elo_womens_doubles'
    WHEN v_match.match_type = 'SINGLES' THEN 'elo_singles'
    ELSE 'elo_mixed_doubles'
END;
-- Calculate Team 1 Avg (Handle NULLs safely)
EXECUTE format(
    '
        SELECT COALESCE(AVG(%I), 1200) FROM profiles 
        WHERE id = ANY($1)',
    v_elo_col
) INTO v_team1_avg USING ARRAY [v_match.player_1, v_match.player_2];
-- Calculate Team 2 Avg
EXECUTE format(
    '
        SELECT COALESCE(AVG(%I), 1200) FROM profiles 
        WHERE id = ANY($1)',
    v_elo_col
) INTO v_team2_avg USING ARRAY [v_match.player_3, v_match.player_4];
team1_elo := v_team1_avg;
team2_elo := v_team2_avg;
-- Calc Prob
-- P(A) = 1 / (1 + 10^((Rb-Ra)/400))
team1_prob := 1.0 / (
    1.0 + power(10.0, (v_team2_avg - v_team1_avg) / 400.0)
);
RETURN NEXT;
END;
$$;
-- 2. Updated calculate_pool_odds with Virtual Liquidity
CREATE OR REPLACE FUNCTION calculate_pool_odds(
        p_team1_total INTEGER,
        p_team2_total INTEGER,
        p_for_team TEXT,
        p_house_rate NUMERIC DEFAULT 0.05,
        p_team1_prob NUMERIC DEFAULT 0.5 -- New argument: Team 1 Win Probability
    ) RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_total_real_pool NUMERIC;
v_seed_amount NUMERIC := 2000.0;
-- "Fun Factor": Virtual Liquidity Amount
-- Virtual Liquidity
v_virtual_team1 NUMERIC;
v_virtual_team2 NUMERIC;
-- Effective Totals
v_effective_total NUMERIC;
v_effective_team_total NUMERIC;
v_raw_odds NUMERIC;
BEGIN -- Calculate Virtual Liquidity based on Probability
-- This anchors the odds at the "Fair Price" when Real Pool is 0.
v_virtual_team1 := v_seed_amount * p_team1_prob;
v_virtual_team2 := v_seed_amount * (1.0 - p_team1_prob);
-- Real Pool
v_total_real_pool := COALESCE(p_team1_total, 0) + COALESCE(p_team2_total, 0);
-- Effective Pool (Real + Virtual)
v_effective_total := v_total_real_pool + v_seed_amount;
IF p_for_team = 'TEAM_1' THEN v_effective_team_total := COALESCE(p_team1_total, 0) + v_virtual_team1;
ELSE v_effective_team_total := COALESCE(p_team2_total, 0) + v_virtual_team2;
END IF;
-- Safety divide
IF v_effective_team_total = 0 THEN RETURN 1.1;
END IF;
-- Calculate Odds
-- Odds = (Effective Total * (1 - HouseEdge)) / Effective Team Total
v_raw_odds := (v_effective_total * (1.0 - p_house_rate)) / v_effective_team_total;
-- Clamp Logic (Minimum 1.1, Max 10.0)
RETURN ROUND(GREATEST(1.1, LEAST(10.0, v_raw_odds)), 2);
END;
$$;
-- 3. Update get_betting_pool to use Prob
CREATE OR REPLACE FUNCTION get_betting_pool(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_pool RECORD;
v_probs RECORD;
BEGIN
SELECT * INTO v_pool
FROM betting_pools
WHERE match_id = p_match_id;
-- Fetch probabilities
SELECT * INTO v_probs
FROM get_match_probability(p_match_id);
IF v_pool IS NULL THEN RETURN jsonb_build_object(
    'success',
    true,
    'team1_total',
    0,
    'team2_total',
    0,
    'team1_odds',
    calculate_pool_odds(0, 0, 'TEAM_1', 0.05, v_probs.team1_prob),
    'team2_odds',
    calculate_pool_odds(0, 0, 'TEAM_2', 0.05, v_probs.team1_prob),
    'house_rate',
    0.05,
    'is_settled',
    false,
    'team1_prob',
    v_probs.team1_prob
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
        v_pool.house_rate,
        v_probs.team1_prob
    ),
    'team2_odds',
    calculate_pool_odds(
        v_pool.team1_total,
        v_pool.team2_total,
        'TEAM_2',
        v_pool.house_rate,
        v_probs.team1_prob
    ),
    'house_rate',
    v_pool.house_rate,
    'team1_prob',
    v_probs.team1_prob
);
END;
$$;
-- 4. Update place_bet_parimutuel to use Prob
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
v_probs RECORD;
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
-- Fetch match probabilities (ELO based)
SELECT * INTO v_probs
FROM get_match_probability(p_match_id);
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
-- Calculate odds at time of bet (Using ELO Prob)
v_current_odds := calculate_pool_odds(
    v_new_team1_total,
    v_new_team2_total,
    p_pick_team,
    v_pool.house_rate,
    v_probs.team1_prob
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
-- Record bet
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
        v_pool.house_rate,
        v_probs.team1_prob
    ),
    'team2_odds',
    calculate_pool_odds(
        v_new_team1_total,
        v_new_team2_total,
        'TEAM_2',
        v_pool.house_rate,
        v_probs.team1_prob
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