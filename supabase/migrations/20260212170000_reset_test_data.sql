-- =============================================================================
-- Reset All Test Data
-- Purpose: Clear matches, queue, bets, etc. for fresh field testing
-- WARNING: This will delete all game data. Use with caution.
-- =============================================================================
-- 1. Clear Queue
DELETE FROM queue;
-- 2. Clear Bets (if exists, usually linked to matches)
DELETE FROM bets;
-- 3. Clear Matches (active + finished)
DELETE FROM matches;
-- 4. Clear Match Audit Logs
DELETE FROM match_audit_log;
-- 5. Clear ELO History (Optional - if you want to keep profiles but reset history)
-- DELETE FROM elo_history; 
-- 6. Reset Profile Stats (Optional - to start season fresh)
/*
 UPDATE profiles
 SET games_played = 0,
 games_won = 0,
 games_lost = 0,
 streak = 0,
 best_streak = 0,
 elo_mens_doubles = 1200,
 elo_womens_doubles = 1200,
 elo_mixed_doubles = 1200,
 elo_singles = 1200;
 */
-- 7. Clear Notices (Optional)
-- DELETE FROM notices;