-- ============================================================================
-- PDCA 함수 정합성 검증 스크립트
-- Supabase SQL Editor에서 실행하세요
-- ============================================================================
-- 1. match_status_t ENUM에 PENDING 포함 여부
SELECT '1. ENUM CHECK' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM pg_enum
            WHERE enumlabel = 'PENDING'
                AND enumtypid = (
                    SELECT oid
                    FROM pg_type
                    WHERE typname = 'match_status_t'
                )
        ) THEN '✅ PASS: PENDING exists'
        ELSE '❌ FAIL: PENDING missing'
    END AS result;
-- 2. check_and_reset_daily 반환타입 확인 (boolean이어야 함)
SELECT '2. check_and_reset_daily RETURN TYPE' AS test,
    pg_get_function_result(oid) AS actual_return,
    CASE
        WHEN pg_get_function_result(oid) = 'boolean' THEN '✅ PASS'
        ELSE '❌ FAIL: expected boolean'
    END AS result
FROM pg_proc
WHERE proname = 'check_and_reset_daily';
-- 3. report_score가 PENDING 전환 포함하는지
SELECT '3. report_score → PENDING' AS test,
    CASE
        WHEN prosrc LIKE '%PENDING%' THEN '✅ PASS: contains PENDING'
        ELSE '❌ FAIL: PENDING not found'
    END AS result
FROM pg_proc
WHERE proname = 'report_score';
-- 4. finish_match_v2가 큐 UPSERT 포함하는지
SELECT '4. finish_match_v2 → queue UPSERT' AS test,
    CASE
        WHEN prosrc LIKE '%INSERT INTO queue%' THEN '✅ PASS: queue UPSERT found'
        ELSE '❌ FAIL: queue UPSERT missing'
    END AS result
FROM pg_proc
WHERE proname = 'finish_match_v2'
    AND pg_get_function_arguments(oid) LIKE '%uuid%integer%integer%text%';
-- 5. admin_confirm_match가 finish_match_v2 위임하는지
SELECT '5. admin_confirm_match → finish_match_v2 delegation' AS test,
    CASE
        WHEN prosrc LIKE '%finish_match_v2%' THEN '✅ PASS: delegates to finish_match_v2'
        ELSE '❌ FAIL: independent impl'
    END AS result
FROM pg_proc
WHERE proname = 'admin_confirm_match';
-- 6. join_queue가 check_and_reset_daily 호출하는지
SELECT '6. join_queue → check_and_reset_daily' AS test,
    CASE
        WHEN prosrc LIKE '%check_and_reset_daily%' THEN '✅ PASS'
        ELSE '❌ FAIL: not calling daily reset'
    END AS result
FROM pg_proc
WHERE proname = 'join_queue'
    AND pg_get_function_arguments(oid) LIKE '%numeric%timestamp%';
-- 7. 전체 함수 시그니처 덤프 (참고용)
SELECT proname,
    pg_get_function_arguments(oid) AS args,
    pg_get_function_result(oid) AS returns
FROM pg_proc
WHERE proname IN (
        'report_score',
        'finish_match_v2',
        'check_and_reset_daily',
        'admin_confirm_match',
        'join_queue'
    )
ORDER BY proname;