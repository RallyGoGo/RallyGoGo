-- ============================================================================
-- UPDATE: Limit Betting Time to 5 Minutes After Match Start
-- 1. Add betting_closes_at column (if not exists)
-- 2. Update start_match to set betting_closes_at = now() + 5 min
-- 3. Update place_bet_parimutuel to enforce betting_closes_at
-- ============================================================================
-- 1. Add Column
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'matches'
        AND column_name = 'betting_closes_at'
) THEN
ALTER TABLE matches
ADD COLUMN betting_closes_at TIMESTAMPTZ;
END IF;
END $$;
-- 2. Update START_MATCH
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
    'DRAFT 상태만 시작 가능. 현재: ' || v_match.status
);
END IF;
-- UPDATE STATUS & SET BETTING DEADLINE
UPDATE matches
SET status = 'PLAYING',
    start_time = now(),
    betting_closes_at = now() + interval '5 minutes'
WHERE id = p_match_id;
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
    '경기가 시작되었습니다. (배팅 5분간 가능)'
);
END;
$$;
-- 3. Update PLACE_BET_PARIMUTUEL to enforce deadline
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
BEGIN IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
IF p_pick_team NOT IN ('TEAM_1', 'TEAM_2') THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_PICK_TEAM');
END IF;
IF p_amount <= 0
OR p_amount > 10000 THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_AMOUNT');
END IF;
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- CHECK STATUS
IF v_match.status NOT IN ('DRAFT', 'PLAYING') THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'BETTING_CLOSED_STATUS',
    'message',
    '현재 배팅 가능한 상태가 아닙니다.'
);
END IF;
-- CHECK TIME DEADLINE (New)
IF v_match.betting_closes_at IS NOT NULL
AND v_match.betting_closes_at < now() THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'BETTING_CLOSED_TIME',
    'message',
    '배팅 시간이 마감되었습니다.'
);
END IF;
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
    'INSUFFICIENT_BALANCE'
);
END IF;
-- Get or create pool
INSERT INTO betting_pools (match_id)
VALUES (p_match_id) ON CONFLICT (match_id) DO NOTHING;
SELECT * INTO v_pool
FROM betting_pools
WHERE match_id = p_match_id FOR
UPDATE;
IF p_pick_team = 'TEAM_1' THEN v_new_team1_total := v_pool.team1_total + p_amount;
v_new_team2_total := v_pool.team2_total;
ELSE v_new_team1_total := v_pool.team1_total;
v_new_team2_total := v_pool.team2_total + p_amount;
END IF;
v_current_odds := calculate_pool_odds(
    v_new_team1_total,
    v_new_team2_total,
    p_pick_team,
    v_pool.house_rate
);
UPDATE profiles
SET rally_point = rally_point - p_amount
WHERE id = v_user_id;
UPDATE betting_pools
SET team1_total = v_new_team1_total,
    team2_total = v_new_team2_total
WHERE id = v_pool.id;
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