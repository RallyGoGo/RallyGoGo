-- =============================================================================
-- HARD RESET (Total Wipeout)
-- Purpose: Delete ALL users (auth.users) and ALL data.
-- WARNING: This will delete every account. You must sign up again.
-- =============================================================================
BEGIN;
-- 1. Game Data (Delete children first to avoid potential FK constraints)
DELETE FROM match_audit_log;
DELETE FROM elo_history;
DELETE FROM bets;
DELETE FROM match_events;
DELETE FROM matches CASCADE;
DELETE FROM queue;
DELETE FROM notices;
DELETE FROM admin_operation_log;
-- 2. Profiles & Auth Accounts
-- profiles 테이블은 auth.users에 종속되어 있으므로, 
-- auth.users를 지우면 CASCADE 설정에 따라 profiles도 지워집니다.
-- 만약 CASCADE가 없다면 profiles를 먼저 지워야 합니다.
DELETE FROM profiles;
-- 3. Delete Supabase Auth Users (Requires Service Role permission)
-- 이 구문은 모든 로그인 계정을 삭제합니다.
DELETE FROM auth.users;
COMMIT;
-- 실행 후:
-- 1. 브라우저의 Local Storage/Cookie를 지우고 새로고침하세요.
-- 2. 회원가입부터 다시 진행해야 합니다.