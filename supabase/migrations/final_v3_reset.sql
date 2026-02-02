-- ============================================================================
-- RallyGoGo V3 Complete Reset - Single Execution File
-- ============================================================================
-- Date: 2026-01-23
-- Purpose: Complete DB reset with V3 schema, all RPCs, RLS, and seed data
-- 
-- USAGE: Run this ENTIRE file in Supabase SQL Editor
-- WARNING: This will DELETE ALL EXISTING DATA!
-- ============================================================================
-- ============================================================================
-- STEP 1: HARD RESET - Complete Schema Destruction
-- ============================================================================
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO anon;
GRANT ALL ON SCHEMA public TO authenticated;
GRANT ALL ON SCHEMA public TO service_role;
-- Required Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- ============================================================================
-- STEP 2: ENUM TYPE DEFINITIONS (V3)
-- ============================================================================
CREATE TYPE match_status_t AS ENUM (
    'DRAFT',
    'PLAYING',
    'SCORING',
    'FINISHED',
    'CANCELLED',
    'DISPUTED'
);
CREATE TYPE bet_result_t AS ENUM (
    'OPEN',
    'LOCKED',
    'WON',
    'LOST',
    'DRAW',
    'CANCELLED'
);
CREATE TYPE correction_status_t AS ENUM ('PENDING', 'APPLYING', 'APPLIED', 'FAILED');
CREATE TYPE user_role_t AS ENUM ('admin', 'player', 'coach');
CREATE TYPE match_type_t AS ENUM (
    'MIXED',
    'MENS_DOUBLES',
    'WOMENS_DOUBLES',
    'SINGLES'
);
CREATE TYPE gender_t AS ENUM ('MALE', 'FEMALE', 'OTHER');
-- ============================================================================
-- STEP 3: BASE TABLES
-- ============================================================================
-- System Flags
CREATE TABLE system_flags (
    key TEXT PRIMARY KEY,
    value BOOLEAN NOT NULL DEFAULT false,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT now(),
    updated_by UUID
);
-- Profiles (V3 column names: elo_mens_doubles, elo_womens_doubles)
CREATE TABLE profiles (
    id UUID PRIMARY KEY,
    email TEXT,
    name TEXT NOT NULL,
    phone TEXT,
    gender gender_t,
    avatar_url TEXT,
    emoji TEXT DEFAULT '🎾',
    ntrp NUMERIC(2, 1) CHECK (
        ntrp >= 1.0
        AND ntrp <= 7.0
    ),
    elo_mixed_doubles INTEGER DEFAULT 1200 CHECK (
        elo_mixed_doubles >= 0
        AND elo_mixed_doubles <= 4000
    ),
    elo_mens_doubles INTEGER DEFAULT 1200 CHECK (
        elo_mens_doubles >= 0
        AND elo_mens_doubles <= 4000
    ),
    elo_womens_doubles INTEGER DEFAULT 1200 CHECK (
        elo_womens_doubles >= 0
        AND elo_womens_doubles <= 4000
    ),
    elo_singles INTEGER DEFAULT 1200 CHECK (
        elo_singles >= 0
        AND elo_singles <= 4000
    ),
    games_played_today INTEGER DEFAULT 0 CHECK (games_played_today >= 0),
    total_games_history INTEGER DEFAULT 0 CHECK (total_games_history >= 0),
    total_wins INTEGER DEFAULT 0 CHECK (total_wins >= 0),
    total_losses INTEGER DEFAULT 0 CHECK (total_losses >= 0),
    total_draws INTEGER DEFAULT 0 CHECK (total_draws >= 0),
    winning_streak INTEGER DEFAULT 0 CHECK (winning_streak >= 0),
    rally_point INTEGER DEFAULT 1000 CHECK (rally_point >= 0),
    role user_role_t DEFAULT 'player',
    is_guest BOOLEAN DEFAULT false,
    admin_memo TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_profiles_role ON profiles(role);
CREATE INDEX idx_profiles_is_guest ON profiles(is_guest);
CREATE INDEX idx_profiles_elo_mixed ON profiles(elo_mixed_doubles DESC);
-- Matches
CREATE TABLE matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    player_1 UUID REFERENCES profiles(id) ON DELETE
    SET NULL,
        player_2 UUID REFERENCES profiles(id) ON DELETE
    SET NULL,
        player_3 UUID REFERENCES profiles(id) ON DELETE
    SET NULL,
        player_4 UUID REFERENCES profiles(id) ON DELETE
    SET NULL,
        status match_status_t DEFAULT 'DRAFT' NOT NULL,
        score_team1 INTEGER CHECK (
            score_team1 >= 0
            AND score_team1 <= 99
        ),
        score_team2 INTEGER CHECK (
            score_team2 >= 0
            AND score_team2 <= 99
        ),
        winner_team TEXT CHECK (winner_team IN ('TEAM_1', 'TEAM_2', 'DRAW')),
        match_type match_type_t DEFAULT 'MIXED',
        court_name TEXT,
        is_auto_generated BOOLEAN DEFAULT false,
        created_at TIMESTAMPTZ DEFAULT now(),
        start_time TIMESTAMPTZ,
        end_time TIMESTAMPTZ,
        betting_closes_at TIMESTAMPTZ,
        reported_by UUID REFERENCES profiles(id),
        confirmed_by UUID REFERENCES profiles(id),
        CONSTRAINT at_least_two_players CHECK (
            (player_1 IS NOT NULL)::int + (player_2 IS NOT NULL)::int + (player_3 IS NOT NULL)::int + (player_4 IS NOT NULL)::int >= 2
        )
);
CREATE INDEX idx_matches_status ON matches(status);
CREATE INDEX idx_matches_created_at ON matches(created_at DESC);
-- Queue
CREATE TABLE queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    is_active BOOLEAN DEFAULT true,
    priority_score NUMERIC DEFAULT 0,
    departure_time TIMESTAMPTZ,
    no_show_count INTEGER DEFAULT 0 CHECK (no_show_count >= 0),
    last_no_show_at TIMESTAMPTZ,
    joined_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT queue_player_unique UNIQUE (player_id)
);
CREATE INDEX idx_queue_active ON queue(is_active, priority_score DESC)
WHERE is_active = true;
CREATE INDEX idx_queue_player ON queue(player_id);
-- Bets
CREATE TABLE bets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    pick_team TEXT NOT NULL CHECK (pick_team IN ('TEAM_1', 'TEAM_2')),
    amount INTEGER NOT NULL CHECK (amount > 0),
    odds_at_bet NUMERIC(5, 2) NOT NULL CHECK (odds_at_bet >= 1.0),
    result bet_result_t DEFAULT 'OPEN' NOT NULL,
    CONSTRAINT unique_bet_per_user_per_team UNIQUE (match_id, user_id, pick_team),
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_bets_match ON bets(match_id);
CREATE INDEX idx_bets_user ON bets(user_id);
-- ELO History
CREATE TABLE elo_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    match_id UUID REFERENCES matches(id) ON DELETE
    SET NULL,
        match_type match_type_t DEFAULT 'MIXED',
        old_rating INTEGER NOT NULL,
        new_rating INTEGER NOT NULL,
        delta INTEGER GENERATED ALWAYS AS (new_rating - old_rating) STORED,
        is_correction BOOLEAN DEFAULT false,
        related_history_id UUID REFERENCES elo_history(id),
        was_guest BOOLEAN,
        applied_multiplier NUMERIC(3, 2),
        calculation_version TEXT DEFAULT 'v3.0',
        created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_elo_history_player ON elo_history(player_id, created_at DESC);
-- MVP Votes
CREATE TABLE mvp_votes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    voter_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    target_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    tag TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT unique_vote_per_match UNIQUE (match_id, voter_id)
);
CREATE INDEX idx_mvp_votes_match ON mvp_votes(match_id);
-- Match Audit Log
CREATE TABLE match_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    action TEXT NOT NULL CHECK (
        action IN (
            'CONFIRM_MATCH',
            'ADMIN_CORRECTION',
            'ADMIN_FORCE_CONFIRM',
            'STATUS_CHANGE',
            'SCORE_UPDATE',
            'CANCEL_MATCH'
        )
    ),
    triggered_by UUID NOT NULL REFERENCES profiles(id),
    trigger_role TEXT NOT NULL CHECK (trigger_role IN ('PLAYER', 'ADMIN', 'SYSTEM')),
    match_status_before match_status_t NOT NULL,
    match_status_after match_status_t NOT NULL,
    score_team1 INTEGER,
    score_team2 INTEGER,
    correction_status correction_status_t,
    correction_reason TEXT,
    confirmation_type TEXT,
    is_force_confirm BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_audit_log_match ON match_audit_log(match_id);
-- Admin Operation Log
CREATE TABLE admin_operation_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_type TEXT NOT NULL CHECK (
        target_type IN (
            'PROFILE',
            'MATCH',
            'QUEUE',
            'BET',
            'SYSTEM',
            'ELO'
        )
    ),
    target_id UUID,
    action TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    reason TEXT,
    operated_by UUID NOT NULL REFERENCES profiles(id),
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_admin_log_type ON admin_operation_log(target_type, created_at DESC);
-- Rating Adjustment Log
CREATE TABLE rating_adjustment_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    old_rating INTEGER NOT NULL,
    new_rating INTEGER NOT NULL,
    reason TEXT,
    adjusted_by UUID NOT NULL REFERENCES profiles(id),
    created_at TIMESTAMPTZ DEFAULT now()
);
-- Profile Merge Log
CREATE TABLE profile_merge_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_profile UUID NOT NULL,
    target_profile UUID NOT NULL,
    merged_by UUID NOT NULL REFERENCES profiles(id),
    created_at TIMESTAMPTZ DEFAULT now()
);
-- Notices
CREATE TABLE notices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    content TEXT NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_notices_active ON notices(is_active, created_at DESC)
WHERE is_active = true;
-- Match Events (Idempotency)
CREATE TABLE match_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_request_id UUID UNIQUE,
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    version INTEGER DEFAULT 1,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_match_events_match ON match_events(match_id);
-- Seasons
CREATE TABLE seasons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    is_active BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now()
);
-- ============================================================================
-- STEP 4: TRIGGERS
-- ============================================================================
-- Update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at() RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now();
RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trigger_profiles_updated_at BEFORE
UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at();
-- Set betting_closes_at when match starts
CREATE OR REPLACE FUNCTION handle_match_start() RETURNS TRIGGER AS $$ BEGIN IF OLD.status = 'DRAFT'
    AND NEW.status = 'PLAYING' THEN IF NEW.start_time IS NULL THEN NEW.start_time = now();
END IF;
NEW.betting_closes_at = NEW.start_time + INTERVAL '5 minutes';
END IF;
IF NEW.status = 'FINISHED'
AND OLD.status != 'FINISHED' THEN NEW.end_time = now();
END IF;
IF NEW.status = 'SCORING'
AND OLD.status = 'PLAYING' THEN NEW.end_time = now();
END IF;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trigger_match_start BEFORE
UPDATE ON matches FOR EACH ROW EXECUTE FUNCTION handle_match_start();
-- ============================================================================
-- STEP 5: ROW LEVEL SECURITY
-- ============================================================================
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE bets ENABLE ROW LEVEL SECURITY;
ALTER TABLE elo_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE mvp_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE match_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_operation_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE rating_adjustment_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE profile_merge_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE notices ENABLE ROW LEVEL SECURITY;
ALTER TABLE match_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE seasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_flags ENABLE ROW LEVEL SECURITY;

-- PROFILES
CREATE POLICY profiles_select_public ON profiles FOR SELECT USING (true);
CREATE POLICY profiles_insert_own ON profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY profiles_update_own ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY profiles_update_admin ON profiles FOR UPDATE USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);
CREATE POLICY profiles_delete_admin ON profiles FOR DELETE USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- MATCHES
CREATE POLICY matches_select_public ON matches FOR SELECT USING (true);
CREATE POLICY matches_insert_admin ON matches FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);
CREATE POLICY matches_update_participant_or_admin ON matches FOR UPDATE USING (
    auth.uid() IN (player_1, player_2, player_3, player_4)
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);
CREATE POLICY matches_delete_admin ON matches FOR DELETE USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- QUEUE
CREATE POLICY queue_select_public ON queue FOR SELECT USING (true);
CREATE POLICY queue_insert_own ON queue FOR INSERT WITH CHECK (auth.uid() = player_id);
CREATE POLICY queue_update_own_or_admin ON queue FOR UPDATE USING (
    auth.uid() = player_id OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);
CREATE POLICY queue_delete_own_or_admin ON queue FOR DELETE USING (
    auth.uid() = player_id OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- BETS
CREATE POLICY bets_select_own ON bets FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY bets_insert_own ON bets FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY bets_update_own_open ON bets FOR UPDATE USING (auth.uid() = user_id AND result = 'OPEN');
CREATE POLICY bets_admin_all ON bets FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- ELO_HISTORY
CREATE POLICY elo_history_select_public ON elo_history FOR SELECT USING (true);

-- MVP_VOTES
CREATE POLICY mvp_votes_select_public ON mvp_votes FOR SELECT USING (true);
CREATE POLICY mvp_votes_insert_authenticated ON mvp_votes FOR INSERT WITH CHECK (auth.uid() = voter_id AND auth.uid() IS NOT NULL);

-- MATCH_AUDIT_LOG
CREATE POLICY audit_log_select_admin ON match_audit_log FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);
CREATE POLICY audit_log_select_participant ON match_audit_log FOR SELECT USING (
    EXISTS (SELECT 1 FROM matches m WHERE m.id = match_audit_log.match_id AND auth.uid() IN (m.player_1, m.player_2, m.player_3, m.player_4))
);

-- ADMIN_OPERATION_LOG
CREATE POLICY admin_op_log_select_admin ON admin_operation_log FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);
CREATE POLICY admin_op_log_insert_admin ON admin_operation_log FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- RATING_ADJUSTMENT_LOG
CREATE POLICY rating_adj_log_admin ON rating_adjustment_log FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- PROFILE_MERGE_LOG
CREATE POLICY profile_merge_log_admin ON profile_merge_log FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- NOTICES
CREATE POLICY notices_select_public ON notices FOR SELECT USING (true);
CREATE POLICY notices_admin_write ON notices FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- MATCH_EVENTS
CREATE POLICY match_events_admin ON match_events FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- SEASONS
CREATE POLICY seasons_select_public ON seasons FOR SELECT USING (true);
CREATE POLICY seasons_admin_write ON seasons FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- SYSTEM_FLAGS
CREATE POLICY system_flags_select_public ON system_flags FOR SELECT USING (true);
CREATE POLICY system_flags_admin_write ON system_flags FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- ============================================================================
-- STEP 6: GRANT PRIVILEGES
-- ============================================================================
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

-- ============================================================================
-- STEP 7: HELPER FUNCTIONS
-- ============================================================================
CREATE OR REPLACE FUNCTION get_current_user_id() RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
    RETURN auth.uid();
END;
$$;

CREATE OR REPLACE FUNCTION lock_expired_bets(p_match_id UUID DEFAULT NULL) RETURNS INTEGER AS $$
DECLARE v_count INTEGER;
BEGIN
    UPDATE bets b SET result = 'LOCKED'
    FROM matches m
    WHERE b.match_id = m.id
      AND b.result = 'OPEN'
      AND m.betting_closes_at IS NOT NULL
      AND m.betting_closes_at < now()
      AND (p_match_id IS NULL OR m.id = p_match_id);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- STEP 8: RPC - JOIN_QUEUE
-- ============================================================================
CREATE OR REPLACE FUNCTION join_queue(
    p_priority_score NUMERIC DEFAULT 0,
    p_departure_time TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID;
    v_profile RECORD;
    v_queue_id UUID;
    v_existing_queue RECORD;
    v_active_match RECORD;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED', 'message', '로그인이 필요합니다.');
    END IF;

    SELECT * INTO v_profile FROM profiles WHERE id = v_user_id;
    IF v_profile IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'PROFILE_NOT_FOUND', 'message', '프로필을 먼저 생성해주세요.');
    END IF;

    SELECT * INTO v_existing_queue FROM queue WHERE player_id = v_user_id AND is_active = true;
    IF v_existing_queue IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ALREADY_IN_QUEUE', 'message', '이미 대기열에 등록되어 있습니다.', 'queue_id', v_existing_queue.id);
    END IF;

    SELECT * INTO v_active_match FROM matches
    WHERE status NOT IN ('FINISHED', 'CANCELLED')
      AND (player_1 = v_user_id OR player_2 = v_user_id OR player_3 = v_user_id OR player_4 = v_user_id)
    LIMIT 1;
    IF v_active_match IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ALREADY_IN_MATCH', 'message', '진행 중인 경기가 있습니다.', 'match_id', v_active_match.id);
    END IF;

    BEGIN
        INSERT INTO queue (player_id, priority_score, departure_time, is_active, joined_at)
        VALUES (v_user_id, COALESCE(p_priority_score, 0), p_departure_time, true, now())
        RETURNING id INTO v_queue_id;
    EXCEPTION WHEN unique_violation THEN
        SELECT id INTO v_queue_id FROM queue WHERE player_id = v_user_id;
        RETURN jsonb_build_object('success', true, 'queue_id', v_queue_id, 'was_duplicate', true);
    END;

    RETURN jsonb_build_object('success', true, 'queue_id', v_queue_id, 'player_id', v_user_id, 'is_guest', v_profile.is_guest, 'message', '대기열에 등록되었습니다.');
END;
$$;

-- ============================================================================
-- STEP 9: RPC - LEAVE_QUEUE
-- ============================================================================
CREATE OR REPLACE FUNCTION leave_queue() RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID;
    v_deleted_count INTEGER;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;
    DELETE FROM queue WHERE player_id = v_user_id;
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    IF v_deleted_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'NOT_IN_QUEUE', 'message', '대기열에 없습니다.');
    END IF;
    RETURN jsonb_build_object('success', true, 'message', '대기열에서 나왔습니다.');
END;
$$;

-- ============================================================================
-- STEP 10: RPC - START_MATCH (DRAFT → PLAYING)
-- ============================================================================
CREATE OR REPLACE FUNCTION start_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_match RECORD;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    SELECT EXISTS(SELECT 1 FROM profiles WHERE id = v_user_id AND role = 'admin') INTO v_is_admin;
    IF NOT v_is_admin THEN
        RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
    END IF;

    SELECT * INTO v_match FROM matches WHERE id = p_match_id FOR UPDATE;
    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
    END IF;
    IF v_match.status != 'DRAFT' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'message', 'DRAFT 상태만 시작 가능. 현재: ' || v_match.status);
    END IF;

    UPDATE matches SET status = 'PLAYING' WHERE id = p_match_id;
    SELECT * INTO v_match FROM matches WHERE id = p_match_id;

    RETURN jsonb_build_object('success', true, 'match_id', p_match_id, 'status', 'PLAYING', 'start_time', v_match.start_time, 'betting_closes_at', v_match.betting_closes_at, 'message', '경기가 시작되었습니다.');
END;
$$;

-- ============================================================================
-- STEP 11: RPC - END_MATCH (PLAYING → SCORING) **CRITICAL FIX**
-- ============================================================================
CREATE OR REPLACE FUNCTION end_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID;
    v_match RECORD;
    v_is_participant BOOLEAN;
    v_is_admin BOOLEAN;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED', 'message', '로그인이 필요합니다.');
    END IF;

    SELECT * INTO v_match FROM matches WHERE id = p_match_id FOR UPDATE;
    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND', 'message', '경기를 찾을 수 없습니다.');
    END IF;

    IF v_match.status != 'PLAYING' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'message', '진행 중인 경기만 종료할 수 있습니다. 현재: ' || v_match.status::TEXT);
    END IF;

    v_is_participant := v_user_id IN (v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4);
    SELECT EXISTS(SELECT 1 FROM profiles WHERE id = v_user_id AND role = 'admin') INTO v_is_admin;

    IF NOT v_is_participant AND NOT v_is_admin THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'message', '경기 참가자 또는 관리자만 종료할 수 있습니다.');
    END IF;

    UPDATE matches SET status = 'SCORING', end_time = now() WHERE id = p_match_id;

    RETURN jsonb_build_object('success', true, 'match_id', p_match_id, 'new_status', 'SCORING', 'end_time', now(), 'message', '경기가 종료되었습니다. 점수를 입력해주세요.');
END;
$$;

-- ============================================================================
-- STEP 12: RPC - REGISTER_GUEST_AND_ENQUEUE **CRITICAL FIX**
-- ============================================================================
CREATE OR REPLACE FUNCTION register_guest_and_enqueue(
    p_name TEXT,
    p_ntrp NUMERIC,
    p_gender TEXT,
    p_departure_time TIMESTAMPTZ
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID;
    v_guest_id UUID;
    v_initial_elo INTEGER;
    v_priority_score NUMERIC;
    v_queue_id UUID;
    v_reused BOOLEAN := false;
    v_gender_enum gender_t;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED', 'message', '로그인이 필요합니다.');
    END IF;

    IF p_name IS NULL OR trim(p_name) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_NAME', 'message', '이름을 입력해주세요.');
    END IF;

    IF p_ntrp IS NULL OR p_ntrp < 1.0 OR p_ntrp > 7.0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_NTRP', 'message', 'NTRP는 1.0~7.0 사이여야 합니다.');
    END IF;

    IF upper(p_gender) IN ('MALE', 'M', 'Male') THEN v_gender_enum := 'MALE';
    ELSIF upper(p_gender) IN ('FEMALE', 'F', 'Female') THEN v_gender_enum := 'FEMALE';
    ELSE v_gender_enum := 'OTHER';
    END IF;

    v_initial_elo := CASE
        WHEN p_ntrp = 1.0 THEN 600 WHEN p_ntrp = 1.5 THEN 800 WHEN p_ntrp = 2.0 THEN 1000
        WHEN p_ntrp = 2.5 THEN 1100 WHEN p_ntrp = 3.0 THEN 1200 WHEN p_ntrp = 3.5 THEN 1400
        WHEN p_ntrp = 4.0 THEN 1600 WHEN p_ntrp = 4.5 THEN 1800 WHEN p_ntrp = 5.0 THEN 2000
        WHEN p_ntrp = 5.5 THEN 2200 WHEN p_ntrp = 6.0 THEN 2400 WHEN p_ntrp = 7.0 THEN 2800
        ELSE 1200
    END;

    SELECT id INTO v_guest_id FROM profiles WHERE is_guest = true AND lower(trim(name)) = lower(trim(p_name)) LIMIT 1;

    IF v_guest_id IS NOT NULL THEN
        v_reused := true;
        UPDATE queue SET departure_time = p_departure_time, is_active = true WHERE player_id = v_guest_id;
        IF FOUND THEN
            SELECT id INTO v_queue_id FROM queue WHERE player_id = v_guest_id;
            RETURN jsonb_build_object('success', true, 'player_id', v_guest_id, 'queue_id', v_queue_id, 'reused', true, 'initial_elo', v_initial_elo, 'message', '기존 게스트 대기열 업데이트.');
        END IF;
    ELSE
        v_guest_id := gen_random_uuid();
        INSERT INTO profiles (id, name, ntrp, gender, is_guest, elo_mixed_doubles, elo_mens_doubles, elo_womens_doubles, elo_singles)
        VALUES (v_guest_id, trim(p_name) || ' (G)', p_ntrp, v_gender_enum, true, v_initial_elo, v_initial_elo, v_initial_elo, v_initial_elo);
    END IF;

    v_priority_score := 500;
    IF p_departure_time IS NOT NULL THEN
        DECLARE diff_mins NUMERIC;
        BEGIN
            diff_mins := EXTRACT(EPOCH FROM (p_departure_time - now())) / 60;
            IF diff_mins > 0 AND diff_mins <= 40 THEN v_priority_score := v_priority_score + 70; END IF;
        END;
    END IF;

    BEGIN
        INSERT INTO queue (player_id, priority_score, departure_time, is_active, joined_at)
        VALUES (v_guest_id, v_priority_score, p_departure_time, true, now())
        RETURNING id INTO v_queue_id;
    EXCEPTION WHEN unique_violation THEN
        SELECT id INTO v_queue_id FROM queue WHERE player_id = v_guest_id;
        v_reused := true;
    END;

    RETURN jsonb_build_object('success', true, 'player_id', v_guest_id, 'queue_id', v_queue_id, 'reused', v_reused, 'initial_elo', v_initial_elo, 'message', CASE WHEN v_reused THEN '기존 게스트 프로필 사용.' ELSE '새 게스트 등록 완료!' END);
END;
$$;

-- ============================================================================
-- STEP 13: RPC - CANCEL_MATCH
-- ============================================================================
CREATE OR REPLACE FUNCTION cancel_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID;
    v_match RECORD;
    v_is_admin BOOLEAN;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    SELECT EXISTS(SELECT 1 FROM profiles WHERE id = v_user_id AND role = 'admin') INTO v_is_admin;
    IF NOT v_is_admin THEN
        RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED', 'message', '관리자만 경기를 취소할 수 있습니다.');
    END IF;

    SELECT * INTO v_match FROM matches WHERE id = p_match_id FOR UPDATE;
    IF v_match IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
    END IF;

    IF v_match.status NOT IN ('DRAFT', 'PLAYING', 'SCORING') THEN
        RETURN jsonb_build_object('success', false, 'error', 'CANNOT_CANCEL', 'message', '이 상태에서는 취소할 수 없습니다: ' || v_match.status::TEXT);
    END IF;

    UPDATE matches SET status = 'CANCELLED' WHERE id = p_match_id;

    UPDATE bets SET result = 'CANCELLED' WHERE match_id = p_match_id AND result IN ('OPEN', 'LOCKED');
    UPDATE profiles p SET rally_point = p.rally_point + b.amount FROM bets b WHERE b.match_id = p_match_id AND b.result = 'CANCELLED' AND p.id = b.user_id;

    INSERT INTO match_audit_log (match_id, action, triggered_by, trigger_role, match_status_before, match_status_after, confirmation_type)
    VALUES (p_match_id, 'CANCEL_MATCH', v_user_id, 'ADMIN', v_match.status, 'CANCELLED', 'ADMIN_CANCEL');

    RETURN jsonb_build_object('success', true, 'match_id', p_match_id, 'message', '경기가 취소되었습니다.');
END;
$$;

-- ============================================================================
-- STEP 14: RPC - REPORT_SCORE
-- ============================================================================
CREATE OR REPLACE FUNCTION report_score(p_match_id UUID, p_team1_score INTEGER, p_team2_score INTEGER, p_winner TEXT DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID;
    v_match RECORD;
    v_is_participant BOOLEAN;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED'); END IF;

    SELECT * INTO v_match FROM matches WHERE id = p_match_id FOR UPDATE;
    IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND'); END IF;

    IF v_match.status != 'SCORING' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'message', '점수 입력은 SCORING 상태에서만 가능합니다.');
    END IF;

    v_is_participant := v_user_id IN (v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4);
    IF NOT v_is_participant THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;

    UPDATE matches SET score_team1 = p_team1_score, score_team2 = p_team2_score,
        winner_team = COALESCE(p_winner, CASE WHEN p_team1_score > p_team2_score THEN 'TEAM_1' WHEN p_team2_score > p_team1_score THEN 'TEAM_2' ELSE 'DRAW' END)
    WHERE id = p_match_id;

    RETURN jsonb_build_object('success', true, 'match_id', p_match_id, 'score_team1', p_team1_score, 'score_team2', p_team2_score, 'message', '점수가 기록되었습니다.');
END;
$$;

-- ============================================================================
-- STEP 15: RPC - CREATE_MATCH_DRAFT (Admin)
-- ============================================================================
CREATE OR REPLACE FUNCTION create_match_draft(p_player_ids UUID[], p_match_type match_type_t DEFAULT 'MIXED', p_court_name TEXT DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_match_id UUID;
    v_player_count INTEGER;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED'); END IF;

    SELECT EXISTS(SELECT 1 FROM profiles WHERE id = v_user_id AND role = 'admin') INTO v_is_admin;
    IF NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED'); END IF;

    v_player_count := array_length(p_player_ids, 1);
    IF v_player_count IS NULL OR v_player_count < 2 OR v_player_count > 4 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_PLAYER_COUNT', 'message', '2~4명의 플레이어를 선택해주세요.');
    END IF;

    INSERT INTO matches (player_1, player_2, player_3, player_4, status, match_type, court_name, created_at)
    VALUES (p_player_ids[1], p_player_ids[2], CASE WHEN v_player_count >= 3 THEN p_player_ids[3] ELSE NULL END, CASE WHEN v_player_count >= 4 THEN p_player_ids[4] ELSE NULL END, 'DRAFT', p_match_type, p_court_name, now())
    RETURNING id INTO v_match_id;

    DELETE FROM queue WHERE player_id = ANY(p_player_ids);

    RETURN jsonb_build_object('success', true, 'match_id', v_match_id, 'players', p_player_ids, 'status', 'DRAFT', 'message', '매치가 생성되었습니다.');
END;
$$;

-- ============================================================================
-- STEP 16: RPC - SETTLE_MATCH_BETS (Internal Helper)
-- ============================================================================
CREATE OR REPLACE FUNCTION settle_match_bets(p_match_id UUID, p_winner_team TEXT) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bet RECORD; v_winnings INTEGER; v_settled_count INTEGER := 0;
BEGIN
    FOR v_bet IN SELECT * FROM bets WHERE match_id = p_match_id AND result IN ('OPEN', 'LOCKED') FOR UPDATE LOOP
        IF p_winner_team = 'DRAW' THEN
            UPDATE bets SET result = 'DRAW' WHERE id = v_bet.id;
            UPDATE profiles SET rally_point = rally_point + v_bet.amount WHERE id = v_bet.user_id;
            v_settled_count := v_settled_count + 1;
        ELSIF p_winner_team = v_bet.pick_team THEN
            v_winnings := FLOOR(v_bet.amount * v_bet.odds_at_bet);
            UPDATE bets SET result = 'WON' WHERE id = v_bet.id;
            UPDATE profiles SET rally_point = rally_point + v_winnings WHERE id = v_bet.user_id;
            v_settled_count := v_settled_count + 1;
        ELSE
            UPDATE bets SET result = 'LOST' WHERE id = v_bet.id;
            v_settled_count := v_settled_count + 1;
        END IF;
    END LOOP;
    RETURN v_settled_count;
END;
$$;

-- ============================================================================
-- STEP 17: RPC - FINISH_MATCH_V2 (Complete Match with ELO + Bets)
-- ============================================================================
CREATE OR REPLACE FUNCTION finish_match_v2(p_match_id UUID, p_team1_score INTEGER, p_team2_score INTEGER, p_confirmation_type TEXT DEFAULT 'NORMAL_CONFIRM') RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user_id UUID; v_match RECORD; v_is_admin BOOLEAN; v_is_participant BOOLEAN;
    v_winner_team TEXT; v_all_player_ids UUID[]; v_team1_ids UUID[]; v_team2_ids UUID[];
    v_team1_rating NUMERIC := 0; v_team2_rating NUMERIC := 0; v_p1_expected NUMERIC; v_p1_actual NUMERIC;
    v_base_delta NUMERIC; v_k_factor INTEGER := 32; v_bets_settled INTEGER; v_status_before TEXT;
    v_profile RECORD; is_team1 BOOLEAN; final_delta INTEGER; old_rating INTEGER; new_rating INTEGER; multiplier NUMERIC := 1.0;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED'); END IF;
    IF p_team1_score < 0 OR p_team1_score > 99 OR p_team2_score < 0 OR p_team2_score > 99 OR (p_team1_score = 0 AND p_team2_score = 0) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_SCORE', 'message', '유효하지 않은 점수입니다.');
    END IF;

    SELECT * INTO v_match FROM matches WHERE id = p_match_id FOR UPDATE;
    IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND'); END IF;
    IF v_match.status = 'FINISHED' THEN RETURN jsonb_build_object('success', false, 'error', 'ALREADY_FINISHED', 'message', '이미 종료된 경기입니다.'); END IF;
    v_status_before := v_match.status::TEXT;

    v_team1_ids := ARRAY[v_match.player_1, v_match.player_2];
    v_team2_ids := ARRAY[v_match.player_3, v_match.player_4];
    v_all_player_ids := v_team1_ids || v_team2_ids;
    SELECT array_agg(x) INTO v_all_player_ids FROM unnest(v_all_player_ids) x WHERE x IS NOT NULL;
    SELECT array_agg(x) INTO v_team1_ids FROM unnest(v_team1_ids) x WHERE x IS NOT NULL;
    SELECT array_agg(x) INTO v_team2_ids FROM unnest(v_team2_ids) x WHERE x IS NOT NULL;

    v_is_participant := v_user_id = ANY(v_all_player_ids);
    SELECT EXISTS(SELECT 1 FROM profiles WHERE id = v_user_id AND role = 'admin') INTO v_is_admin;
    
    IF p_confirmation_type = 'NORMAL_CONFIRM' THEN
        IF NOT v_is_participant THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'message', '경기 참가자만 결과를 입력할 수 있습니다.'); END IF;
    ELSIF p_confirmation_type = 'ADMIN_FORCE_CONFIRM' THEN
        IF NOT v_is_admin THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED'); END IF;
    END IF;

    IF p_team1_score > p_team2_score THEN v_winner_team := 'TEAM_1'; v_p1_actual := 1.0;
    ELSIF p_team2_score > p_team1_score THEN v_winner_team := 'TEAM_2'; v_p1_actual := 0.0;
    ELSE v_winner_team := 'DRAW'; v_p1_actual := 0.5; END IF;

    SELECT COALESCE(AVG(elo_mixed_doubles), 1200) INTO v_team1_rating FROM profiles WHERE id = ANY(v_team1_ids);
    SELECT COALESCE(AVG(elo_mixed_doubles), 1200) INTO v_team2_rating FROM profiles WHERE id = ANY(v_team2_ids);
    v_p1_expected := 1.0 / (1.0 + power(10.0, (v_team2_rating - v_team1_rating) / 400.0));
    v_base_delta := v_k_factor * (v_p1_actual - v_p1_expected);

    FOR v_profile IN SELECT * FROM profiles WHERE id = ANY(v_all_player_ids) FOR UPDATE LOOP
        is_team1 := v_profile.id = ANY(v_team1_ids);
        old_rating := COALESCE(v_profile.elo_mixed_doubles, 1200);
        IF is_team1 THEN final_delta := ROUND(v_base_delta); ELSE final_delta := ROUND(v_base_delta * -1); END IF;
        IF v_profile.is_guest THEN multiplier := 1.5; final_delta := ROUND(final_delta * multiplier); END IF;
        new_rating := GREATEST(0, LEAST(4000, old_rating + final_delta));
        UPDATE profiles SET elo_mixed_doubles = new_rating, games_played_today = COALESCE(games_played_today, 0) + 1, total_games_history = COALESCE(total_games_history, 0) + 1,
            total_wins = total_wins + CASE WHEN (is_team1 AND v_winner_team = 'TEAM_1') OR (NOT is_team1 AND v_winner_team = 'TEAM_2') THEN 1 ELSE 0 END,
            total_losses = total_losses + CASE WHEN (is_team1 AND v_winner_team = 'TEAM_2') OR (NOT is_team1 AND v_winner_team = 'TEAM_1') THEN 1 ELSE 0 END,
            total_draws = total_draws + CASE WHEN v_winner_team = 'DRAW' THEN 1 ELSE 0 END,
            winning_streak = CASE WHEN ((is_team1 AND v_winner_team = 'TEAM_1') OR (NOT is_team1 AND v_winner_team = 'TEAM_2')) THEN COALESCE(winning_streak, 0) + 1 ELSE 0 END
        WHERE id = v_profile.id;
        INSERT INTO elo_history (player_id, match_id, match_type, old_rating, new_rating, was_guest, applied_multiplier) VALUES (v_profile.id, p_match_id, v_match.match_type, old_rating, new_rating, v_profile.is_guest, multiplier);
    END LOOP;

    UPDATE matches SET status = 'FINISHED', score_team1 = p_team1_score, score_team2 = p_team2_score, winner_team = v_winner_team, confirmed_by = v_user_id, end_time = now() WHERE id = p_match_id;
    SELECT settle_match_bets(p_match_id, v_winner_team) INTO v_bets_settled;
    DELETE FROM queue WHERE player_id = ANY(v_all_player_ids);
    INSERT INTO match_audit_log (match_id, action, triggered_by, trigger_role, match_status_before, match_status_after, score_team1, score_team2, confirmation_type, is_force_confirm)
    VALUES (p_match_id, 'CONFIRM_MATCH', v_user_id, CASE WHEN v_is_admin THEN 'ADMIN' ELSE 'PLAYER' END, v_status_before::match_status_t, 'FINISHED', p_team1_score, p_team2_score, p_confirmation_type, p_confirmation_type = 'ADMIN_FORCE_CONFIRM');

    RETURN jsonb_build_object('success', true, 'match_id', p_match_id, 'winner_team', v_winner_team, 'bets_settled', v_bets_settled, 'mvp_voting_open', true, 'message', '경기가 종료되었습니다. MVP 투표가 시작되었습니다!');
END;
$$;

-- ============================================================================
-- STEP 18: RPC - PLACE_BET_V2
-- ============================================================================
CREATE OR REPLACE FUNCTION place_bet_v2(p_match_id UUID, p_pick_team TEXT, p_amount INTEGER) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user_id UUID; v_match RECORD; v_profile RECORD; v_odds NUMERIC; v_bet_id UUID; v_team1_elo INTEGER; v_team2_elo INTEGER; prob_team1 NUMERIC; prob_team2 NUMERIC;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED'); END IF;
    IF p_pick_team NOT IN ('TEAM_1', 'TEAM_2') THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_PICK_TEAM'); END IF;
    IF p_amount <= 0 THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_AMOUNT'); END IF;

    SELECT * INTO v_match FROM matches WHERE id = p_match_id FOR UPDATE;
    IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND'); END IF;
    IF v_match.status NOT IN ('DRAFT', 'PLAYING') THEN RETURN jsonb_build_object('success', false, 'error', 'BETTING_CLOSED_STATUS'); END IF;
    IF v_match.status = 'PLAYING' AND v_match.betting_closes_at IS NOT NULL AND now() > v_match.betting_closes_at THEN
        RETURN jsonb_build_object('success', false, 'error', 'BETTING_CLOSED_TIME', 'message', '베팅 마감 시간이 지났습니다.');
    END IF;

    SELECT * INTO v_profile FROM profiles WHERE id = v_user_id FOR UPDATE;
    IF v_profile IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PROFILE_NOT_FOUND'); END IF;
    IF v_profile.rally_point < p_amount THEN RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_BALANCE', 'message', '포인트가 부족합니다. 현재: ' || v_profile.rally_point); END IF;

    SELECT COALESCE(p1.elo_mixed_doubles, 1200) + COALESCE(p2.elo_mixed_doubles, 1200) INTO v_team1_elo FROM profiles p1, profiles p2 WHERE p1.id = v_match.player_1 AND p2.id = v_match.player_2;
    IF v_team1_elo IS NULL THEN v_team1_elo := 2400; END IF;
    SELECT COALESCE(p3.elo_mixed_doubles, 1200) + COALESCE(p4.elo_mixed_doubles, 1200) INTO v_team2_elo FROM profiles p3, profiles p4 WHERE p3.id = v_match.player_3 AND p4.id = v_match.player_4;
    IF v_team2_elo IS NULL THEN v_team2_elo := 2400; END IF;
    prob_team1 := 1.0 / (1.0 + power(10.0, (v_team2_elo - v_team1_elo) / 800.0));
    prob_team2 := 1.0 - prob_team1;
    IF p_pick_team = 'TEAM_1' THEN v_odds := LEAST(GREATEST(0.95 / prob_team1, 1.1), 10.0); ELSE v_odds := LEAST(GREATEST(0.95 / prob_team2, 1.1), 10.0); END IF;
    v_odds := ROUND(v_odds, 2);

    UPDATE profiles SET rally_point = rally_point - p_amount WHERE id = v_user_id;
    BEGIN
        INSERT INTO bets (match_id, user_id, pick_team, amount, odds_at_bet, result) VALUES (p_match_id, v_user_id, p_pick_team, p_amount, v_odds, 'OPEN') RETURNING id INTO v_bet_id;
    EXCEPTION WHEN unique_violation THEN
        UPDATE profiles SET rally_point = rally_point + p_amount WHERE id = v_user_id;
        RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_BET', 'message', '이미 해당 팀에 베팅하셨습니다.');
    END;

    RETURN jsonb_build_object('success', true, 'bet_id', v_bet_id, 'new_balance', v_profile.rally_point - p_amount, 'odds', v_odds, 'amount', p_amount, 'pick_team', p_pick_team);
END;
$$;

-- ============================================================================
-- STEP 19: RPC - CAST_MVP_VOTE
-- ============================================================================
CREATE OR REPLACE FUNCTION cast_mvp_vote(p_match_id UUID, p_target_id UUID, p_tag TEXT DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user_id UUID; v_match RECORD; v_vote_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED'); END IF;
    SELECT * INTO v_match FROM matches WHERE id = p_match_id;
    IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND'); END IF;
    IF v_match.status != 'FINISHED' THEN RETURN jsonb_build_object('success', false, 'error', 'VOTING_NOT_OPEN', 'message', '경기가 종료된 후에 투표할 수 있습니다.'); END IF;
    IF p_target_id NOT IN (v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_TARGET', 'message', '해당 경기 참가자에게만 투표할 수 있습니다.');
    END IF;
    BEGIN
        INSERT INTO mvp_votes (match_id, voter_id, target_id, tag) VALUES (p_match_id, v_user_id, p_target_id, p_tag) RETURNING id INTO v_vote_id;
    EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('success', false, 'error', 'ALREADY_VOTED', 'message', '이미 투표하셨습니다.');
    END;
    RETURN jsonb_build_object('success', true, 'vote_id', v_vote_id, 'message', 'MVP 투표가 완료되었습니다.');
END;
$$;

-- ============================================================================
-- STEP 20: REALTIME PUBLICATION
-- ============================================================================
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE matches;
        ALTER PUBLICATION supabase_realtime ADD TABLE queue;
        ALTER PUBLICATION supabase_realtime ADD TABLE notices;
        ALTER PUBLICATION supabase_realtime ADD TABLE profiles;
    END IF;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ============================================================================
-- STEP 21: SEED DATA - Admin + Test Players
-- ============================================================================
DO $$
DECLARE
    v_admin_id UUID := '00000000-0000-0000-0000-000000000001';
    v_player1_id UUID := '11111111-1111-1111-1111-111111111111';
    v_player2_id UUID := '22222222-2222-2222-2222-222222222222';
    v_player3_id UUID := '33333333-3333-3333-3333-333333333333';
    v_player4_id UUID := '44444444-4444-4444-4444-444444444444';
    v_player5_id UUID := '55555555-5555-5555-5555-555555555555';
    v_player6_id UUID := '66666666-6666-6666-6666-666666666666';
BEGIN
    -- Admin Profile
    INSERT INTO profiles (id, email, name, gender, ntrp, elo_mixed_doubles, rally_point, role, is_guest, emoji, created_at)
    VALUES (v_admin_id, 'admin@rallygogo.com', '관리자', 'MALE', 4.0, 1500, 10000, 'admin', false, '👑', now())
    ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email, name = EXCLUDED.name, role = EXCLUDED.role;

    -- Player 1: High ELO
    INSERT INTO profiles (id, email, name, gender, ntrp, elo_mixed_doubles, rally_point, role, is_guest, emoji, total_wins, total_losses, total_games_history)
    VALUES (v_player1_id, 'player1@test.com', '김테니스', 'MALE', 4.5, 1650, 1000, 'player', false, '🎾', 15, 5, 20)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    -- Player 2: Medium-High ELO
    INSERT INTO profiles (id, email, name, gender, ntrp, elo_mixed_doubles, rally_point, role, is_guest, emoji, total_wins, total_losses, total_games_history)
    VALUES (v_player2_id, 'player2@test.com', '이배드민턴', 'FEMALE', 4.0, 1450, 1000, 'player', false, '🏸', 12, 8, 20)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    -- Player 3: Medium ELO
    INSERT INTO profiles (id, email, name, gender, ntrp, elo_mixed_doubles, rally_point, role, is_guest, emoji, total_wins, total_losses, total_games_history)
    VALUES (v_player3_id, 'player3@test.com', '박스매시', 'MALE', 3.5, 1250, 1000, 'player', false, '💪', 10, 10, 20)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    -- Player 4: Lower ELO (new player)
    INSERT INTO profiles (id, email, name, gender, ntrp, elo_mixed_doubles, rally_point, role, is_guest, emoji, total_wins, total_losses, total_games_history)
    VALUES (v_player4_id, 'player4@test.com', '최루키', 'FEMALE', 3.0, 1100, 1000, 'player', false, '🌟', 5, 10, 15)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    -- Player 5: Queue testing
    INSERT INTO profiles (id, email, name, gender, ntrp, elo_mixed_doubles, rally_point, role, is_guest, emoji)
    VALUES (v_player5_id, 'player5@test.com', '정대기', 'MALE', 3.5, 1300, 1000, 'player', false, '⏳')
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    -- Player 6: Guest player
    INSERT INTO profiles (id, email, name, gender, ntrp, elo_mixed_doubles, rally_point, role, is_guest, emoji)
    VALUES (v_player6_id, 'guest_66666666@temp.temp', '손님 (G)', 'FEMALE', 3.0, 1150, 500, 'player', true, '👤')
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    -- Queue entries
    INSERT INTO queue (player_id, priority_score, is_active, joined_at) VALUES (v_player5_id, 500, true, now() - INTERVAL '5 minutes') ON CONFLICT (player_id) DO UPDATE SET is_active = true;
    INSERT INTO queue (player_id, priority_score, is_active, joined_at, departure_time) VALUES (v_player6_id, 450, true, now() - INTERVAL '3 minutes', now() + INTERVAL '2 hours') ON CONFLICT (player_id) DO UPDATE SET is_active = true;

    RAISE NOTICE 'Created admin + 6 player profiles';
END $$;

-- System Flags
INSERT INTO system_flags (key, value, description) VALUES
    ('betting_enabled', true, 'Global switch for betting feature'),
    ('queue_enabled', true, 'Global switch for queue system'),
    ('maintenance_mode', false, 'When true, only admins can access')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- Welcome Notice
INSERT INTO notices (content, is_active) VALUES ('🎾 RallyGoGo V3 시스템이 초기화되었습니다. 테스트를 시작하세요!', true);

-- ============================================================================
-- STEP 22: SCHEMA VERSION COMMENT
-- ============================================================================
COMMENT ON SCHEMA public IS 'RallyGoGo V3.0 - Complete Reset - 2026-01-23. All RPCs included: join_queue, leave_queue, start_match, end_match, register_guest_and_enqueue, cancel_match, report_score, create_match_draft, finish_match_v2, place_bet_v2, cast_mvp_vote';

-- ============================================================================
-- ✅ MIGRATION COMPLETE!
-- ============================================================================
-- Run this SQL in Supabase SQL Editor to reset your database.
-- After running, restart your frontend dev server.
-- 
-- Test accounts (create in Supabase Auth Dashboard):
--   - admin@rallygogo.com (Admin)
--   - player1~5@test.com (Players)
-- ============================================================================
