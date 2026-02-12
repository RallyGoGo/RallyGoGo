-- =============================================================================
-- FULL RESET (Season Restart)
-- Purpose: Delete ALL game data and RESET profiles to initial state.
-- Use this for official launch preparation.
-- =============================================================================
BEGIN;
-- 1. Delete all game-related data
DELETE FROM match_audit_log;
DELETE FROM elo_history;
DELETE FROM bets;
DELETE FROM match_events;
DELETE FROM matches CASCADE;
DELETE FROM queue;
DELETE FROM notices;
DELETE FROM admin_operation_log;
-- 2. Reset Profiles (Keep accounts, reset stats)
-- 모든 유저의 ELO를 1200으로, 전적을 0으로 초기화합니다.
UPDATE profiles
SET elo_mens_doubles = 1200,
    elo_womens_doubles = 1200,
    elo_mixed_doubles = 1200,
    elo_singles = 1200,
    ntrp = 2.5,
    -- 선택 사항: NTRP도 기본값으로 돌리려면 주석 해제 (기본값: 유지)
    games_played = 0,
    games_won = 0,
    games_lost = 0,
    draws = 0,
    streak = 0,
    best_streak = 0,
    games_played_today = 0,
    updated_at = now();
COMMIT;
-- 3. (Optional) Delete Guest Accounts
-- 게스트 계정을 삭제하고 싶다면 아래 주석을 해제하고 실행하세요.
-- DELETE FROM profiles WHERE is_guest = true;