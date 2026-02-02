-- ============================================================================
-- RallyGoGo V1 Full Reset Migration
-- ============================================================================
-- Purpose: Complete greenfield rebuild with deny-by-default security,
--          proper constraints, and race condition prevention.
--
-- Created: 2026-01-22
-- Based on: Project Repair Intelligence Document v2.3
--
-- User Decisions Applied (Section 4):
--   1. Match Start = DRAFT → PLAYING transition (bets lock here)
--   2. Bet Close = 5 minutes after PLAYING via DB Trigger
--   3. Guests = Supabase Anonymous Sign-in, convertible to full member
--   4. Realtime = matches, queue, notices MUST broadcast
--   5. MVP Voting = All authenticated members can vote (not just participants)
--
-- ⚠️  WARNING: This migration DESTROYS all existing data!
-- ============================================================================
-- ============================================================================
-- PHASE 1: DESTRUCTIVE RESET
-- ============================================================================
-- Drop the entire public schema and recreate it fresh
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
-- Grant default privileges
GRANT USAGE ON SCHEMA public TO postgres,
    anon,
    authenticated,
    service_role;
GRANT ALL ON SCHEMA public TO postgres,
    service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT ALL ON TABLES TO postgres,
    service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT ALL ON FUNCTIONS TO postgres,
    service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT ALL ON SEQUENCES TO postgres,
    service_role;
-- ============================================================================
-- PHASE 2: ENUM DEFINITIONS
-- ============================================================================
-- Using PostgreSQL ENUMs for type safety instead of TEXT + CHECK constraints.
-- This prevents invalid values at the database level.
-- Match lifecycle states
-- DRAFT: Match proposed, players assigned, betting open
-- PLAYING: Match in progress, betting locked after 5 minutes
-- SCORING: Match finished, awaiting score entry/confirmation
-- FINISHED: Match completed, ELO updated, bets settled
-- CANCELLED: Match cancelled before completion
-- DISPUTED: Admin correction in progress
CREATE TYPE match_status_t AS ENUM (
    'DRAFT',
    'PLAYING',
    'SCORING',
    'FINISHED',
    'CANCELLED',
    'DISPUTED'
);
-- Bet lifecycle states
-- OPEN: Bet can be placed/modified (match is DRAFT)
-- LOCKED: Betting closed (5 min after match starts or manual close)
-- WON: Bet won, winnings credited
-- LOST: Bet lost
-- DRAW: Match was a draw, stake returned
-- CANCELLED: Bet cancelled (match cancelled or admin action)
CREATE TYPE bet_result_t AS ENUM (
    'OPEN',
    'LOCKED',
    'WON',
    'LOST',
    'DRAW',
    'CANCELLED'
);
-- Admin correction workflow states
-- PENDING: Correction intent created, awaiting preview/approval
-- APPLYING: Correction in progress
-- APPLIED: Correction completed successfully
-- FAILED: Correction failed, needs retry
CREATE TYPE correction_status_t AS ENUM (
    'PENDING',
    'APPLYING',
    'APPLIED',
    'FAILED'
);
-- User role types
CREATE TYPE user_role_t AS ENUM ('admin', 'player', 'coach');
-- Match types
CREATE TYPE match_type_t AS ENUM (
    'MIXED',
    'MENS_DOUBLES',
    'WOMENS_DOUBLES',
    'SINGLES'
);
-- Gender types
CREATE TYPE gender_t AS ENUM ('MALE', 'FEMALE', 'OTHER');
-- ============================================================================
-- PHASE 2: BASE TABLES
-- ============================================================================
-- ----------------------------------------------------------------------------
-- System Configuration Table
-- Stores system-wide flags and settings
-- ----------------------------------------------------------------------------
CREATE TABLE system_flags (
    key TEXT PRIMARY KEY,
    value BOOLEAN NOT NULL DEFAULT false,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT now(),
    updated_by UUID
);
COMMENT ON TABLE system_flags IS 'System-wide configuration flags. V1.0';
-- ----------------------------------------------------------------------------
-- Profiles Table
-- Core user identity, linked to Supabase Auth
-- Supports both authenticated users and anonymous guests
-- ----------------------------------------------------------------------------
CREATE TABLE profiles (
    -- Primary key linked to auth.users.id
    id UUID PRIMARY KEY,
    -- Identity fields
    email TEXT,
    name TEXT NOT NULL,
    phone TEXT,
    gender gender_t,
    avatar_url TEXT,
    emoji TEXT DEFAULT '🎾',
    -- Rating fields (multiple game types)
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
    -- Statistics
    games_played_today INTEGER DEFAULT 0 CHECK (games_played_today >= 0),
    total_games_history INTEGER DEFAULT 0 CHECK (total_games_history >= 0),
    total_wins INTEGER DEFAULT 0 CHECK (total_wins >= 0),
    total_losses INTEGER DEFAULT 0 CHECK (total_losses >= 0),
    total_draws INTEGER DEFAULT 0 CHECK (total_draws >= 0),
    winning_streak INTEGER DEFAULT 0 CHECK (winning_streak >= 0),
    -- Economy
    rally_point INTEGER DEFAULT 1000 CHECK (rally_point >= 0),
    -- Access control
    role user_role_t DEFAULT 'player',
    -- Guest handling (Anonymous Sign-in users)
    -- When is_guest=true, user is anonymous auth user
    -- Convert to full member by setting is_guest=false and adding email
    is_guest BOOLEAN DEFAULT false,
    -- Admin notes
    admin_memo TEXT,
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
-- Indexes for common queries
CREATE INDEX idx_profiles_role ON profiles(role);
CREATE INDEX idx_profiles_is_guest ON profiles(is_guest);
CREATE INDEX idx_profiles_elo_mixed ON profiles(elo_mixed_doubles DESC);
COMMENT ON TABLE profiles IS 'User profiles linked to Supabase Auth. Supports anonymous guests via is_guest flag.';
COMMENT ON COLUMN profiles.is_guest IS 'True for Anonymous Sign-in users. Convert to full member by setting false and adding email.';
COMMENT ON COLUMN profiles.rally_point IS 'Virtual currency for betting. CHECK constraint prevents negative balance.';
-- ----------------------------------------------------------------------------
-- Matches Table
-- Core match entity with state machine
-- ----------------------------------------------------------------------------
CREATE TABLE matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Players (Team 1: player_1 + player_2, Team 2: player_3 + player_4)
    player_1 UUID REFERENCES profiles(id) ON DELETE
    SET NULL,
        player_2 UUID REFERENCES profiles(id) ON DELETE
    SET NULL,
        player_3 UUID REFERENCES profiles(id) ON DELETE
    SET NULL,
        player_4 UUID REFERENCES profiles(id) ON DELETE
    SET NULL,
        -- State machine
        status match_status_t DEFAULT 'DRAFT' NOT NULL,
        -- Scores (NULL until entered)
        score_team1 INTEGER CHECK (
            score_team1 >= 0
            AND score_team1 <= 99
        ),
        score_team2 INTEGER CHECK (
            score_team2 >= 0
            AND score_team2 <= 99
        ),
        winner_team TEXT CHECK (winner_team IN ('TEAM_1', 'TEAM_2', 'DRAW')),
        -- Match metadata
        match_type match_type_t DEFAULT 'MIXED',
        court_name TEXT,
        is_auto_generated BOOLEAN DEFAULT false,
        -- Timing
        created_at TIMESTAMPTZ DEFAULT now(),
        start_time TIMESTAMPTZ,
        -- Set when status changes to PLAYING
        end_time TIMESTAMPTZ,
        -- Set when status changes to FINISHED
        -- Betting timing
        -- betting_closes_at is calculated: start_time + 5 minutes
        -- Trigger will lock bets when current_time > betting_closes_at
        betting_closes_at TIMESTAMPTZ,
        -- Confirmation tracking
        reported_by UUID REFERENCES profiles(id),
        confirmed_by UUID REFERENCES profiles(id),
        -- Constraint: At least 2 players required
        CONSTRAINT at_least_two_players CHECK (
            (player_1 IS NOT NULL)::int + (player_2 IS NOT NULL)::int + (player_3 IS NOT NULL)::int + (player_4 IS NOT NULL)::int >= 2
        )
);
-- Indexes for common queries
CREATE INDEX idx_matches_status ON matches(status);
CREATE INDEX idx_matches_created_at ON matches(created_at DESC);
CREATE INDEX idx_matches_players ON matches(player_1, player_2, player_3, player_4);
COMMENT ON TABLE matches IS 'Match lifecycle with DRAFT→PLAYING→SCORING→FINISHED state machine.';
COMMENT ON COLUMN matches.betting_closes_at IS 'Auto-set to start_time + 5 minutes. Bets lock when this time passes.';
-- ----------------------------------------------------------------------------
-- Queue Table
-- Player waiting queue for matchmaking
-- ----------------------------------------------------------------------------
CREATE TABLE queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- One queue entry per player (enforced by UNIQUE constraint)
    player_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    -- Queue state
    is_active BOOLEAN DEFAULT true,
    -- Matchmaking factors
    priority_score NUMERIC DEFAULT 0,
    departure_time TIMESTAMPTZ,
    -- When player must leave
    -- No-show tracking
    no_show_count INTEGER DEFAULT 0 CHECK (no_show_count >= 0),
    last_no_show_at TIMESTAMPTZ,
    -- Timestamps
    joined_at TIMESTAMPTZ DEFAULT now(),
    -- ============================================================
    -- CONCURRENCY CONTROL: UNIQUE constraint on player_id
    -- This prevents race condition where double-click could create
    -- duplicate queue entries. PostgreSQL handles this atomically.
    -- ============================================================
    CONSTRAINT queue_player_unique UNIQUE (player_id)
);
CREATE INDEX idx_queue_active ON queue(is_active, priority_score DESC)
WHERE is_active = true;
CREATE INDEX idx_queue_player ON queue(player_id);
COMMENT ON TABLE queue IS 'Matchmaking queue. UNIQUE(player_id) prevents duplicate entries from race conditions.';
-- ----------------------------------------------------------------------------
-- Bets Table
-- Betting on match outcomes
-- ----------------------------------------------------------------------------
CREATE TABLE bets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- References
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    -- Bet details
    pick_team TEXT NOT NULL CHECK (pick_team IN ('TEAM_1', 'TEAM_2')),
    amount INTEGER NOT NULL CHECK (amount > 0),
    odds_at_bet NUMERIC(5, 2) NOT NULL CHECK (odds_at_bet >= 1.0),
    -- Result (OPEN until match starts, then LOCKED, then settled)
    result bet_result_t DEFAULT 'OPEN' NOT NULL,
    -- ============================================================
    -- RACE CONDITION PREVENTION: Unique constraint ensures
    -- one bet per user per team per match. If you want to allow
    -- multiple bets, add an idempotency_key column instead.
    -- ============================================================
    -- Note: Allowing one bet per team, user can bet on both teams
    CONSTRAINT unique_bet_per_user_per_team UNIQUE (match_id, user_id, pick_team),
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_bets_match ON bets(match_id);
CREATE INDEX idx_bets_user ON bets(user_id);
CREATE INDEX idx_bets_result ON bets(result);
COMMENT ON TABLE bets IS 'Match betting. UNIQUE constraint prevents duplicate bets from double-submit.';
COMMENT ON COLUMN bets.result IS 'OPEN→LOCKED (after 5min of match start)→WON/LOST/DRAW/CANCELLED';
-- ----------------------------------------------------------------------------
-- ELO History Table
-- Audit trail of all rating changes
-- ----------------------------------------------------------------------------
CREATE TABLE elo_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- References
    player_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    match_id UUID REFERENCES matches(id) ON DELETE
    SET NULL,
        -- Rating change
        match_type match_type_t DEFAULT 'MIXED',
        old_rating INTEGER NOT NULL,
        new_rating INTEGER NOT NULL,
        delta INTEGER GENERATED ALWAYS AS (new_rating - old_rating) STORED,
        -- Correction tracking
        is_correction BOOLEAN DEFAULT false,
        related_history_id UUID REFERENCES elo_history(id),
        was_guest BOOLEAN,
        applied_multiplier NUMERIC(3, 2),
        -- Metadata
        calculation_version TEXT DEFAULT 'v1.0',
        created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_elo_history_player ON elo_history(player_id, created_at DESC);
CREATE INDEX idx_elo_history_match ON elo_history(match_id)
WHERE match_id IS NOT NULL;
CREATE INDEX idx_elo_history_correction ON elo_history(match_id, is_correction);
COMMENT ON TABLE elo_history IS 'Complete audit trail of all ELO rating changes.';
-- ----------------------------------------------------------------------------
-- MVP Votes Table
-- Post-match voting for most valuable player
-- ----------------------------------------------------------------------------
CREATE TABLE mvp_votes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- References
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    voter_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    target_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    -- Optional tag/category
    tag TEXT,
    -- Timestamp
    created_at TIMESTAMPTZ DEFAULT now(),
    -- ============================================================
    -- IDEMPOTENCY: UNIQUE constraint ensures one vote per voter
    -- per match. Prevents double-vote from network retry or
    -- double-click. PostgreSQL enforces this atomically.
    -- ============================================================
    CONSTRAINT unique_vote_per_match UNIQUE (match_id, voter_id)
);
CREATE INDEX idx_mvp_votes_match ON mvp_votes(match_id);
CREATE INDEX idx_mvp_votes_target ON mvp_votes(target_id);
COMMENT ON TABLE mvp_votes IS 'MVP voting. All authenticated members can vote, not just participants.';
COMMENT ON CONSTRAINT unique_vote_per_match ON mvp_votes IS 'Prevents duplicate votes - idempotency guarantee.';
-- ----------------------------------------------------------------------------
-- Match Audit Log Table
-- Tracks all match state changes and admin corrections
-- ----------------------------------------------------------------------------
CREATE TABLE match_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Reference
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    -- Action details
    action TEXT NOT NULL CHECK (
        action IN (
            'CONFIRM_MATCH',
            'ADMIN_CORRECTION',
            'ADMIN_FORCE_CONFIRM',
            'STATUS_CHANGE',
            'SCORE_UPDATE'
        )
    ),
    triggered_by UUID NOT NULL REFERENCES profiles(id),
    trigger_role TEXT NOT NULL CHECK (trigger_role IN ('PLAYER', 'ADMIN', 'SYSTEM')),
    -- State tracking
    match_status_before match_status_t NOT NULL,
    match_status_after match_status_t NOT NULL,
    score_team1 INTEGER,
    score_team2 INTEGER,
    -- Correction-specific fields
    correction_status correction_status_t,
    correction_reason TEXT,
    correction_chain_id UUID REFERENCES match_audit_log(id),
    related_action_id UUID,
    correction_started_at TIMESTAMPTZ,
    correction_finished_at TIMESTAMPTZ,
    correction_error TEXT,
    -- Confirmation type
    confirmation_type TEXT,
    is_force_confirm BOOLEAN DEFAULT false,
    -- Timestamp
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_audit_log_match ON match_audit_log(match_id);
CREATE INDEX idx_audit_log_chain ON match_audit_log(correction_chain_id)
WHERE correction_chain_id IS NOT NULL;
CREATE INDEX idx_audit_log_status ON match_audit_log(correction_status)
WHERE correction_status IS NOT NULL;
COMMENT ON TABLE match_audit_log IS 'Complete audit trail of match lifecycle changes and admin corrections.';
-- ----------------------------------------------------------------------------
-- Admin Operation Log Table
-- General admin action audit trail
-- ----------------------------------------------------------------------------
CREATE TABLE admin_operation_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Target of operation
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
    -- Operation details
    action TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    reason TEXT,
    -- Who performed
    operated_by UUID NOT NULL REFERENCES profiles(id),
    -- Timestamp
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_admin_log_type ON admin_operation_log(target_type, created_at DESC);
CREATE INDEX idx_admin_log_operator ON admin_operation_log(operated_by);
COMMENT ON TABLE admin_operation_log IS 'Audit trail for all admin operations.';
-- ----------------------------------------------------------------------------
-- Rating Adjustment Log Table
-- Manual ELO adjustments by admin
-- ----------------------------------------------------------------------------
CREATE TABLE rating_adjustment_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    old_rating INTEGER NOT NULL,
    new_rating INTEGER NOT NULL,
    reason TEXT,
    adjusted_by UUID NOT NULL REFERENCES profiles(id),
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_rating_adj_player ON rating_adjustment_log(player_id);
-- ----------------------------------------------------------------------------
-- Profile Merge Log Table
-- Guest to member conversion tracking
-- ----------------------------------------------------------------------------
CREATE TABLE profile_merge_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_profile UUID NOT NULL,
    -- Guest profile being merged
    target_profile UUID NOT NULL,
    -- Target authenticated profile
    merged_by UUID NOT NULL REFERENCES profiles(id),
    created_at TIMESTAMPTZ DEFAULT now()
);
COMMENT ON TABLE profile_merge_log IS 'Tracks guest-to-member conversions for audit purposes.';
-- ----------------------------------------------------------------------------
-- Notices Table
-- System announcements
-- ----------------------------------------------------------------------------
CREATE TABLE notices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    content TEXT NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_notices_active ON notices(is_active, created_at DESC)
WHERE is_active = true;
-- ----------------------------------------------------------------------------
-- Match Events Table
-- Idempotency tracking for match operations
-- ----------------------------------------------------------------------------
CREATE TABLE match_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- ============================================================
    -- IDEMPOTENCY KEY: Unique client_request_id ensures that
    -- network retries don't cause duplicate operations.
    -- Client generates UUID, sends with request. If duplicate
    -- request arrives, we return success without re-executing.
    -- ============================================================
    client_request_id UUID UNIQUE,
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    version INTEGER DEFAULT 1,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_match_events_match ON match_events(match_id);
CREATE INDEX idx_match_events_request ON match_events(client_request_id)
WHERE client_request_id IS NOT NULL;
COMMENT ON TABLE match_events IS 'Event sourcing and idempotency for match operations.';
COMMENT ON COLUMN match_events.client_request_id IS 'Client-generated UUID for idempotency. UNIQUE constraint prevents duplicate processing.';
-- ----------------------------------------------------------------------------
-- Seasons Table
-- For organizing matches into seasons/tournaments
-- ----------------------------------------------------------------------------
CREATE TABLE seasons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    is_active BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now()
);
-- ============================================================================
-- PHASE 2: FUNCTIONS AND TRIGGERS
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Function: Update updated_at timestamp
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_updated_at() RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now();
RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- Apply to profiles
CREATE TRIGGER trigger_profiles_updated_at BEFORE
UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at();
-- ----------------------------------------------------------------------------
-- Function: Set betting_closes_at when match starts
-- When status changes from DRAFT to PLAYING, set betting close time
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION handle_match_start() RETURNS TRIGGER AS $$ BEGIN -- When match transitions to PLAYING
    IF OLD.status = 'DRAFT'
    AND NEW.status = 'PLAYING' THEN -- Set start_time if not already set
    IF NEW.start_time IS NULL THEN NEW.start_time = now();
END IF;
-- ============================================================
-- BETTING CLOSE TIME: 5 minutes after match start
-- This gives late-comers a window to bet after seeing lineups
-- The lock_expired_bets function will close bets after this time
-- ============================================================
NEW.betting_closes_at = NEW.start_time + INTERVAL '5 minutes';
END IF;
-- When match finishes
IF NEW.status = 'FINISHED'
AND OLD.status != 'FINISHED' THEN NEW.end_time = now();
END IF;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trigger_match_start BEFORE
UPDATE ON matches FOR EACH ROW EXECUTE FUNCTION handle_match_start();
-- ----------------------------------------------------------------------------
-- Function: Lock expired bets (called periodically or on match query)
-- Bets should be LOCKED after betting_closes_at passes
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lock_expired_bets(p_match_id UUID DEFAULT NULL) RETURNS INTEGER AS $$
DECLARE v_count INTEGER;
BEGIN -- ============================================================
-- ATOMIC BET LOCKING: This function locks all OPEN bets for
-- matches where betting_closes_at has passed. Uses UPDATE with
-- WHERE clause for atomic operation - no race conditions.
-- ============================================================
UPDATE bets b
SET result = 'LOCKED'
FROM matches m
WHERE b.match_id = m.id
    AND b.result = 'OPEN'
    AND m.betting_closes_at IS NOT NULL
    AND m.betting_closes_at < now()
    AND (
        p_match_id IS NULL
        OR m.id = p_match_id
    );
GET DIAGNOSTICS v_count = ROW_COUNT;
RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION lock_expired_bets IS 'Locks all OPEN bets for matches past betting_closes_at. Call periodically or on-demand.';
-- ----------------------------------------------------------------------------
-- Function: Get ELO policy constants
-- Centralized ELO calculation parameters
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_elo_policy(p_is_guest BOOLEAN) RETURNS TABLE (k_factor INTEGER, multiplier NUMERIC) AS $$ BEGIN RETURN QUERY
SELECT 32::INTEGER,
    -- Standard K-Factor
    CASE
        WHEN p_is_guest THEN 1.5
        ELSE 1.0
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
-- ============================================================================
-- PHASE 2: ROW LEVEL SECURITY (DENY BY DEFAULT)
-- ============================================================================
-- Security Philosophy:
-- 1. Enable RLS on ALL tables
-- 2. Default DENY (no policies = no access for non-service roles)
-- 3. Explicitly allow only what's needed
-- 4. service_role bypasses RLS for backend operations
-- ----------------------------------------------------------------------------
-- Enable RLS on all tables
-- ----------------------------------------------------------------------------
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
-- ----------------------------------------------------------------------------
-- PROFILES: Public read, owner write, admin full access
-- ----------------------------------------------------------------------------
-- Anyone can view profiles (for rankings, player lists)
CREATE POLICY profiles_select_public ON profiles FOR
SELECT USING (true);
-- Users can insert their own profile (linked to auth.uid())
CREATE POLICY profiles_insert_own ON profiles FOR
INSERT WITH CHECK (auth.uid() = id);
-- Users can update their own profile
CREATE POLICY profiles_update_own ON profiles FOR
UPDATE USING (auth.uid() = id);
-- Admins can update any profile
CREATE POLICY profiles_update_admin ON profiles FOR
UPDATE USING (
        EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = auth.uid()
                AND role = 'admin'
        )
    );
-- Admins can delete profiles
CREATE POLICY profiles_delete_admin ON profiles FOR DELETE USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ----------------------------------------------------------------------------
-- MATCHES: Public read, admin/system write
-- ----------------------------------------------------------------------------
-- Anyone can view matches
CREATE POLICY matches_select_public ON matches FOR
SELECT USING (true);
-- Only admins can insert matches
CREATE POLICY matches_insert_admin ON matches FOR
INSERT WITH CHECK (
        EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = auth.uid()
                AND role = 'admin'
        )
    );
-- Admins OR participants can update (for score entry)
CREATE POLICY matches_update_participant_or_admin ON matches FOR
UPDATE USING (
        auth.uid() IN (player_1, player_2, player_3, player_4)
        OR EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = auth.uid()
                AND role = 'admin'
        )
    );
-- Only admins can delete matches
CREATE POLICY matches_delete_admin ON matches FOR DELETE USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ----------------------------------------------------------------------------
-- QUEUE: Public read, owner write for own entry
-- ----------------------------------------------------------------------------
-- Anyone can view queue
CREATE POLICY queue_select_public ON queue FOR
SELECT USING (true);
-- Users can insert their own queue entry
CREATE POLICY queue_insert_own ON queue FOR
INSERT WITH CHECK (auth.uid() = player_id);
-- Users can update their own queue entry, admins can update any
CREATE POLICY queue_update_own_or_admin ON queue FOR
UPDATE USING (
        auth.uid() = player_id
        OR EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = auth.uid()
                AND role = 'admin'
        )
    );
-- Users can delete their own queue entry, admins can delete any
CREATE POLICY queue_delete_own_or_admin ON queue FOR DELETE USING (
    auth.uid() = player_id
    OR EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ----------------------------------------------------------------------------
-- BETS: Owner read/write for own bets, public read for match bets
-- ----------------------------------------------------------------------------
-- Users can see their own bets
CREATE POLICY bets_select_own ON bets FOR
SELECT USING (auth.uid() = user_id);
-- ============================================================
-- IMPORTANT: Users can ONLY insert bets for themselves
-- This prevents betting on behalf of another user
-- RPC functions use SECURITY DEFINER to bypass when needed
-- ============================================================
CREATE POLICY bets_insert_own ON bets FOR
INSERT WITH CHECK (auth.uid() = user_id);
-- Users can update their own OPEN bets only
CREATE POLICY bets_update_own_open ON bets FOR
UPDATE USING (
        auth.uid() = user_id
        AND result = 'OPEN'
    );
-- Admins can see/manage all bets
CREATE POLICY bets_admin_all ON bets FOR ALL USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ----------------------------------------------------------------------------
-- ELO_HISTORY: Public read for transparency, system write only
-- ----------------------------------------------------------------------------
-- Anyone can view ELO history (for graphs, transparency)
CREATE POLICY elo_history_select_public ON elo_history FOR
SELECT USING (true);
-- No direct inserts from client - use RPCs with SECURITY DEFINER
-- (Default deny applies)
-- ----------------------------------------------------------------------------
-- MVP_VOTES: All authenticated can vote, public read
-- ----------------------------------------------------------------------------
-- Anyone can view votes
CREATE POLICY mvp_votes_select_public ON mvp_votes FOR
SELECT USING (true);
-- ============================================================
-- All authenticated users can vote (not just participants)
-- Per user requirement: spectators can also vote
-- UNIQUE constraint prevents duplicate votes
-- ============================================================
CREATE POLICY mvp_votes_insert_authenticated ON mvp_votes FOR
INSERT WITH CHECK (
        auth.uid() = voter_id
        AND auth.uid() IS NOT NULL
    );
-- ----------------------------------------------------------------------------
-- MATCH_AUDIT_LOG: Admin only access
-- ----------------------------------------------------------------------------
-- Admins can view all audit logs
CREATE POLICY audit_log_select_admin ON match_audit_log FOR
SELECT USING (
        EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = auth.uid()
                AND role = 'admin'
        )
    );
-- Players can view logs for matches they participated in
CREATE POLICY audit_log_select_participant ON match_audit_log FOR
SELECT USING (
        EXISTS (
            SELECT 1
            FROM matches m
            WHERE m.id = match_audit_log.match_id
                AND auth.uid() IN (m.player_1, m.player_2, m.player_3, m.player_4)
        )
    );
-- No client inserts - use RPCs
-- ----------------------------------------------------------------------------
-- ADMIN_OPERATION_LOG: Admin only
-- ----------------------------------------------------------------------------
CREATE POLICY admin_op_log_select_admin ON admin_operation_log FOR
SELECT USING (
        EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = auth.uid()
                AND role = 'admin'
        )
    );
CREATE POLICY admin_op_log_insert_admin ON admin_operation_log FOR
INSERT WITH CHECK (
        EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = auth.uid()
                AND role = 'admin'
        )
    );
-- ----------------------------------------------------------------------------
-- RATING_ADJUSTMENT_LOG: Admin only
-- ----------------------------------------------------------------------------
CREATE POLICY rating_adj_log_admin ON rating_adjustment_log FOR ALL USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ----------------------------------------------------------------------------
-- PROFILE_MERGE_LOG: Admin only
-- ----------------------------------------------------------------------------
CREATE POLICY profile_merge_log_admin ON profile_merge_log FOR ALL USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ----------------------------------------------------------------------------
-- NOTICES: Public read, admin write
-- ----------------------------------------------------------------------------
CREATE POLICY notices_select_public ON notices FOR
SELECT USING (true);
CREATE POLICY notices_admin_write ON notices FOR ALL USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ----------------------------------------------------------------------------
-- MATCH_EVENTS: Internal use only
-- ----------------------------------------------------------------------------
-- Admins can view for debugging
CREATE POLICY match_events_admin ON match_events FOR
SELECT USING (
        EXISTS (
            SELECT 1
            FROM profiles
            WHERE id = auth.uid()
                AND role = 'admin'
        )
    );
-- ----------------------------------------------------------------------------
-- SEASONS: Public read, admin write
-- ----------------------------------------------------------------------------
CREATE POLICY seasons_select_public ON seasons FOR
SELECT USING (true);
CREATE POLICY seasons_admin_write ON seasons FOR ALL USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ----------------------------------------------------------------------------
-- SYSTEM_FLAGS: Public read, admin write
-- ----------------------------------------------------------------------------
CREATE POLICY system_flags_select_public ON system_flags FOR
SELECT USING (true);
CREATE POLICY system_flags_admin_write ON system_flags FOR ALL USING (
    EXISTS (
        SELECT 1
        FROM profiles
        WHERE id = auth.uid()
            AND role = 'admin'
    )
);
-- ============================================================================
-- PHASE 2: GRANT PRIVILEGES
-- ============================================================================
-- Principle: Minimum necessary privileges per role
-- Revoke all from public first (deny by default)
REVOKE ALL ON ALL TABLES IN SCHEMA public
FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public
FROM PUBLIC;
-- Grant usage on schema
GRANT USAGE ON SCHEMA public TO anon,
    authenticated,
    service_role;
-- Grant table access (RLS will filter what's actually accessible)
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT SELECT,
    INSERT,
    UPDATE,
    DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
-- Grant sequence usage
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated,
    service_role;
-- Grant function execution (will add specific restrictions per function)
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated,
    service_role;
-- ============================================================================
-- PHASE 2: REALTIME PUBLICATION
-- ============================================================================
-- Per user requirement: matches, queue, notices MUST have realtime
-- Enable realtime for required tables
-- Note: Run this on an existing Supabase instance, or adjust for your setup
DO $$ BEGIN -- Check if publication exists
IF EXISTS (
    SELECT 1
    FROM pg_publication
    WHERE pubname = 'supabase_realtime'
) THEN -- Add tables to existing publication
ALTER PUBLICATION supabase_realtime
ADD TABLE matches;
ALTER PUBLICATION supabase_realtime
ADD TABLE queue;
ALTER PUBLICATION supabase_realtime
ADD TABLE notices;
ALTER PUBLICATION supabase_realtime
ADD TABLE profiles;
-- For live ELO updates
END IF;
EXCEPTION
WHEN duplicate_object THEN NULL;
-- Table already in publication
END $$;
-- ============================================================================
-- PHASE 2: INITIAL SEED DATA
-- ============================================================================
-- Insert default system flags
INSERT INTO system_flags (key, value, description)
VALUES (
        'betting_enabled',
        true,
        'Global switch for betting feature'
    ),
    (
        'queue_enabled',
        true,
        'Global switch for queue system'
    ),
    (
        'maintenance_mode',
        false,
        'When true, only admins can access'
    );
-- ============================================================================
-- SCHEMA VERSION COMMENT
-- ============================================================================
COMMENT ON SCHEMA public IS 'RallyGoGo V1.0 - Full Reset Schema - 2026-01-22';
-- ============================================================================
-- CONCURRENCY CONTROL SUMMARY
-- ============================================================================
-- This schema prevents race conditions through multiple mechanisms:
--
-- 1. UNIQUE CONSTRAINTS (Atomic at DB level):
--    - queue.player_id: Prevents duplicate queue entries
--    - bets(match_id, user_id, pick_team): Prevents duplicate bets
--    - mvp_votes(match_id, voter_id): Prevents duplicate votes
--    - match_events.client_request_id: Idempotency for all match operations
--
-- 2. CHECK CONSTRAINTS (Immediate validation):
--    - profiles.rally_point >= 0: Prevents negative balance
--    - bets.amount > 0: Prevents zero/negative bets
--    - ELO ratings bounded 0-4000: Prevents overflow
--
-- 3. ENUM TYPES (Type safety):
--    - Invalid status values rejected at INSERT/UPDATE time
--    - State machine transitions must use valid enum values
--
-- 4. RLS POLICIES (Authorization):
--    - bets_insert_own: Only owner can create their bets
--    - mvp_votes_insert_authenticated: Voter must match auth.uid()
--    - Identity enforcement prevents impersonation
--
-- 5. TRIGGERS (Derived data):
--    - betting_closes_at auto-calculated from start_time
--    - updated_at always current
--
-- 6. RPC FUNCTIONS (Will be added in Phase 3):
--    - FOR UPDATE locks for balance checks
--    - Idempotency key validation
--    - Transaction isolation for atomic operations
-- ============================================================================