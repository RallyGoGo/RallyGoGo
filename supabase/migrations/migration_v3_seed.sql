-- ============================================================================
-- RallyGoGo V3 Seed Data Migration
-- ============================================================================
-- Purpose: Populate database with test data for development and testing
--
-- Created: 2026-01-22
-- Depends on: migration_v1_full_reset.sql, migration_v2_logic.sql
--
-- ⚠️  NOTE: This only populates `profiles` table, not `auth.users`.
--           You must create corresponding auth users manually or via Supabase Dashboard.
--
-- Test Accounts (create these in Supabase Auth Dashboard):
--   - admin@rallygogo.com (Admin)
--   - player1@test.com ~ player4@test.com (Players)
-- ============================================================================
-- ============================================================================
-- DETERMINISTIC UUIDs FOR TESTING
-- Using fixed UUIDs so data can be referenced consistently
-- ============================================================================
-- Admin UUID (create auth user with this ID or update after creation)
-- In production: link to actual auth.users.id
DO $$
DECLARE -- Fixed UUIDs for deterministic testing
    v_admin_id UUID := '00000000-0000-0000-0000-000000000001';
v_player1_id UUID := '11111111-1111-1111-1111-111111111111';
v_player2_id UUID := '22222222-2222-2222-2222-222222222222';
v_player3_id UUID := '33333333-3333-3333-3333-333333333333';
v_player4_id UUID := '44444444-4444-4444-4444-444444444444';
v_player5_id UUID := '55555555-5555-5555-5555-555555555555';
v_player6_id UUID := '66666666-6666-6666-6666-666666666666';
v_match_playing_id UUID := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
v_match_finished_id UUID := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
BEGIN -- ========================================================================
-- 1. ADMIN PROFILE
-- ========================================================================
INSERT INTO profiles (
        id,
        email,
        name,
        gender,
        ntrp,
        elo_mixed_doubles,
        rally_point,
        role,
        is_guest,
        emoji,
        created_at
    )
VALUES (
        v_admin_id,
        'admin@rallygogo.com',
        '관리자',
        'MALE',
        4.0,
        1500,
        10000,
        -- Admin gets more RP for testing
        'admin',
        false,
        '👑',
        now()
    ) ON CONFLICT (id) DO
UPDATE
SET email = EXCLUDED.email,
    name = EXCLUDED.name,
    role = EXCLUDED.role;
RAISE NOTICE 'Created admin profile: %',
v_admin_id;
-- ========================================================================
-- 2. PLAYER PROFILES (4 main + 2 for queue)
-- ========================================================================
-- Player 1: High ELO player
INSERT INTO profiles (
        id,
        email,
        name,
        gender,
        ntrp,
        elo_mixed_doubles,
        rally_point,
        role,
        is_guest,
        emoji,
        total_wins,
        total_losses,
        total_games_history
    )
VALUES (
        v_player1_id,
        'player1@test.com',
        '김테니스',
        'MALE',
        4.5,
        1650,
        -- High ELO
        1000,
        'player',
        false,
        '🎾',
        15,
        5,
        20
    ) ON CONFLICT (id) DO
UPDATE
SET name = EXCLUDED.name;
-- Player 2: Medium-High ELO player
INSERT INTO profiles (
        id,
        email,
        name,
        gender,
        ntrp,
        elo_mixed_doubles,
        rally_point,
        role,
        is_guest,
        emoji,
        total_wins,
        total_losses,
        total_games_history
    )
VALUES (
        v_player2_id,
        'player2@test.com',
        '이배드민턴',
        'FEMALE',
        4.0,
        1450,
        1000,
        'player',
        false,
        '🏸',
        12,
        8,
        20
    ) ON CONFLICT (id) DO
UPDATE
SET name = EXCLUDED.name;
-- Player 3: Medium ELO player
INSERT INTO profiles (
        id,
        email,
        name,
        gender,
        ntrp,
        elo_mixed_doubles,
        rally_point,
        role,
        is_guest,
        emoji,
        total_wins,
        total_losses,
        total_games_history
    )
VALUES (
        v_player3_id,
        'player3@test.com',
        '박스매시',
        'MALE',
        3.5,
        1250,
        1000,
        'player',
        false,
        '💪',
        10,
        10,
        20
    ) ON CONFLICT (id) DO
UPDATE
SET name = EXCLUDED.name;
-- Player 4: Lower ELO player (new player)
INSERT INTO profiles (
        id,
        email,
        name,
        gender,
        ntrp,
        elo_mixed_doubles,
        rally_point,
        role,
        is_guest,
        emoji,
        total_wins,
        total_losses,
        total_games_history
    )
VALUES (
        v_player4_id,
        'player4@test.com',
        '최루키',
        'FEMALE',
        3.0,
        1100,
        1000,
        'player',
        false,
        '🌟',
        5,
        10,
        15
    ) ON CONFLICT (id) DO
UPDATE
SET name = EXCLUDED.name;
-- Player 5: For queue testing
INSERT INTO profiles (
        id,
        email,
        name,
        gender,
        ntrp,
        elo_mixed_doubles,
        rally_point,
        role,
        is_guest,
        emoji
    )
VALUES (
        v_player5_id,
        'player5@test.com',
        '정대기',
        'MALE',
        3.5,
        1300,
        1000,
        'player',
        false,
        '⏳'
    ) ON CONFLICT (id) DO
UPDATE
SET name = EXCLUDED.name;
-- Player 6: Guest player in queue
INSERT INTO profiles (
        id,
        email,
        name,
        gender,
        ntrp,
        elo_mixed_doubles,
        rally_point,
        role,
        is_guest,
        emoji
    )
VALUES (
        v_player6_id,
        'guest_66666666@temp.temp',
        '손님 (G)',
        'FEMALE',
        3.0,
        1150,
        500,
        'player',
        true,
        -- Guest!
        '👤'
    ) ON CONFLICT (id) DO
UPDATE
SET name = EXCLUDED.name;
RAISE NOTICE 'Created 6 player profiles';
-- ========================================================================
-- 3. MATCHES
-- ========================================================================
-- Match 1: PLAYING status (ongoing game with betting open for 5 more minutes)
INSERT INTO matches (
        id,
        player_1,
        player_2,
        player_3,
        player_4,
        status,
        match_type,
        court_name,
        created_at,
        start_time,
        betting_closes_at
    )
VALUES (
        v_match_playing_id,
        v_player1_id,
        -- Team 1
        v_player2_id,
        v_player3_id,
        -- Team 2
        v_player4_id,
        'PLAYING',
        'MIXED',
        'Court A',
        now() - INTERVAL '10 minutes',
        now() - INTERVAL '2 minutes',
        -- Started 2 min ago
        now() + INTERVAL '3 minutes' -- Betting closes in 3 min
    ) ON CONFLICT (id) DO
UPDATE
SET status = EXCLUDED.status;
RAISE NOTICE 'Created PLAYING match: %',
v_match_playing_id;
-- Match 2: FINISHED status (completed game)
INSERT INTO matches (
        id,
        player_1,
        player_2,
        player_3,
        player_4,
        status,
        match_type,
        court_name,
        score_team1,
        score_team2,
        winner_team,
        created_at,
        start_time,
        end_time,
        confirmed_by
    )
VALUES (
        v_match_finished_id,
        v_player1_id,
        -- Team 1 (won)
        v_player3_id,
        v_player2_id,
        -- Team 2
        v_player4_id,
        'FINISHED',
        'MIXED',
        'Court B',
        21,
        15,
        'TEAM_1',
        now() - INTERVAL '2 hours',
        now() - INTERVAL '1 hour 30 minutes',
        now() - INTERVAL '1 hour',
        v_player1_id
    ) ON CONFLICT (id) DO
UPDATE
SET status = EXCLUDED.status;
RAISE NOTICE 'Created FINISHED match: %',
v_match_finished_id;
-- ========================================================================
-- 4. QUEUE (2 players waiting)
-- ========================================================================
-- Player 5 in queue
INSERT INTO queue (player_id, priority_score, is_active, joined_at)
VALUES (
        v_player5_id,
        500,
        true,
        now() - INTERVAL '5 minutes'
    ) ON CONFLICT (player_id) DO
UPDATE
SET is_active = true;
-- Guest Player 6 in queue
INSERT INTO queue (
        player_id,
        priority_score,
        is_active,
        joined_at,
        departure_time
    )
VALUES (
        v_player6_id,
        450,
        true,
        now() - INTERVAL '3 minutes',
        now() + INTERVAL '2 hours'
    ) ON CONFLICT (player_id) DO
UPDATE
SET is_active = true;
RAISE NOTICE 'Added 2 players to queue';
-- ========================================================================
-- 5. BETS (sample bets on the PLAYING match)
-- ========================================================================
-- Admin bet on Team 1
INSERT INTO bets (
        match_id,
        user_id,
        pick_team,
        amount,
        odds_at_bet,
        result
    )
VALUES (
        v_match_playing_id,
        v_admin_id,
        'TEAM_1',
        100,
        1.85,
        'OPEN'
    ) ON CONFLICT (match_id, user_id, pick_team) DO NOTHING;
-- Player 5 bet on Team 2
INSERT INTO bets (
        match_id,
        user_id,
        pick_team,
        amount,
        odds_at_bet,
        result
    )
VALUES (
        v_match_playing_id,
        v_player5_id,
        'TEAM_2',
        200,
        2.10,
        'OPEN'
    ) ON CONFLICT (match_id, user_id, pick_team) DO NOTHING;
RAISE NOTICE 'Created sample bets';
-- ========================================================================
-- 6. ELO HISTORY (for finished match)
-- ========================================================================
INSERT INTO elo_history (
        player_id,
        match_id,
        match_type,
        old_rating,
        new_rating,
        was_guest
    )
VALUES (
        v_player1_id,
        v_match_finished_id,
        'MIXED',
        1630,
        1650,
        false
    ),
    (
        v_player3_id,
        v_match_finished_id,
        'MIXED',
        1230,
        1250,
        false
    ),
    (
        v_player2_id,
        v_match_finished_id,
        'MIXED',
        1470,
        1450,
        false
    ),
    (
        v_player4_id,
        v_match_finished_id,
        'MIXED',
        1120,
        1100,
        false
    );
RAISE NOTICE 'Created ELO history for finished match';
-- ========================================================================
-- 7. MVP VOTES (for finished match)
-- ========================================================================
INSERT INTO mvp_votes (match_id, voter_id, target_id, tag)
VALUES (
        v_match_finished_id,
        v_player2_id,
        v_player1_id,
        'Best Serve'
    ),
    (
        v_match_finished_id,
        v_player3_id,
        v_player1_id,
        'MVP'
    ),
    (
        v_match_finished_id,
        v_player4_id,
        v_player3_id,
        'Good Defense'
    ) ON CONFLICT (match_id, voter_id) DO NOTHING;
RAISE NOTICE 'Created MVP votes';
-- ========================================================================
-- 8. NOTICE
-- ========================================================================
INSERT INTO notices (content, is_active)
VALUES (
        '🔧 시스템 점검 안내: 1월 25일 오전 2시~4시 서버 점검이 예정되어 있습니다.',
        true
    );
RAISE NOTICE 'Created system notice';
-- ========================================================================
-- 9. SYSTEM FLAGS (ensure defaults are set)
-- ========================================================================
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
    ) ON CONFLICT (key) DO
UPDATE
SET value = EXCLUDED.value;
RAISE NOTICE 'System flags configured';
RAISE NOTICE '========================================';
RAISE NOTICE 'SEED DATA COMPLETE!';
RAISE NOTICE '========================================';
RAISE NOTICE 'Admin: admin@rallygogo.com (ID: %)',
v_admin_id;
RAISE NOTICE 'Players: player1~4@test.com';
RAISE NOTICE 'PLAYING Match: %',
v_match_playing_id;
RAISE NOTICE 'FINISHED Match: %',
v_match_finished_id;
RAISE NOTICE '========================================';
END $$;
-- ============================================================================
-- VERIFICATION QUERIES (Run these to verify seed data)
-- ============================================================================
-- Check profiles
-- SELECT id, name, email, role, elo_mixed_doubles, rally_point, is_guest FROM profiles ORDER BY role DESC, elo_mixed_doubles DESC;
-- Check matches
-- SELECT id, status, player_1, player_2, player_3, player_4, score_team1, score_team2 FROM matches;
-- Check queue
-- SELECT q.id, p.name, q.priority_score, q.is_active FROM queue q JOIN profiles p ON q.player_id = p.id;
-- Check bets
-- SELECT b.id, p.name, b.pick_team, b.amount, b.odds_at_bet, b.result FROM bets b JOIN profiles p ON b.user_id = p.id;