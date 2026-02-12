-- ============================================================================
-- report_score 중복 오버로드 제거
-- PDCA 기준 버전만 남기고 나머지 제거
-- Supabase SQL Editor에서 실행하세요
-- ============================================================================
-- 1. 3인자 버전 제거 (p_winner 없는 구버전)
DROP FUNCTION IF EXISTS report_score(UUID, INTEGER, INTEGER);
-- 2. text, text 버전 제거 (완전히 다른 시그니처)
DROP FUNCTION IF EXISTS report_score(UUID, TEXT, TEXT);
-- 3. 확인: PDCA 4인자 버전만 남아있는지 검증
SELECT proname,
    pg_get_function_arguments(oid) AS args,
    pg_get_function_result(oid) AS returns
FROM pg_proc
WHERE proname = 'report_score';
-- 예상 결과: 1행만, args = "p_match_id uuid, p_team1_score integer, p_team2_score integer, p_winner text"