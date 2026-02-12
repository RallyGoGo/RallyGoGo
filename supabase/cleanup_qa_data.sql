-- ============================================================================
-- QA 시뮬레이션 데이터 정리
-- Supabase SQL Editor에서 실행
-- ============================================================================
-- 1. QA 매치 삭제
DELETE FROM matches
WHERE court_name = 'QA Court A';
-- 2. QA 플레이어 큐에서 제거
DELETE FROM queue
WHERE player_id IN (
        SELECT id
        FROM profiles
        WHERE name LIKE 'QA_Player_% (G)'
    );
-- 3. QA 플레이어 프로필 삭제
DELETE FROM profiles
WHERE name LIKE 'QA_Player_% (G)';
-- 4. 확인
SELECT 'QA cleanup done' AS result,
    (
        SELECT count(*)
        FROM matches
        WHERE court_name = 'QA Court A'
    ) AS remaining_matches,
    (
        SELECT count(*)
        FROM profiles
        WHERE name LIKE 'QA_Player_% (G)'
    ) AS remaining_profiles;