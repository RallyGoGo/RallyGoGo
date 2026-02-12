-- ============================================================================
-- 게임 수 즉시 초기화 + 일일 리셋 22:00 KST 기준으로 변경
-- Supabase SQL Editor에서 실행
-- ============================================================================
-- 1. 즉시 초기화: 모든 프로필의 games_played_today를 0으로 리셋
UPDATE profiles
SET games_played_today = 0;
-- 2. check_and_reset_daily를 22:00 KST 기준으로 변경
-- 기존: 자정(00:00) 기준으로 날짜 비교
-- 변경: +2시간 오프셋을 적용하여 22:00 KST에 "다음 날"로 판정
CREATE OR REPLACE FUNCTION check_and_reset_daily() RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_last_reset TEXT;
v_today TEXT;
v_did_reset BOOLEAN := false;
BEGIN -- ✅ 22:00 KST 기준: now() + 2시간으로 "운영 날짜"를 계산
-- 예: 21:59 KST → 23:59 → 같은 날 → 리셋 안 함
-- 예: 22:01 KST → 00:01 → 다음 날 → 리셋 수행
BEGIN v_today := to_char(
    (now() AT TIME ZONE 'Asia/Seoul') + interval '2 hours',
    'YYYY-MM-DD'
);
EXCEPTION
WHEN OTHERS THEN v_today := to_char(now() + interval '2 hours', 'YYYY-MM-DD');
END;
BEGIN
SELECT value_text INTO v_last_reset
FROM system_flags
WHERE key = 'last_daily_reset';
IF v_last_reset IS NULL
OR v_last_reset != v_today THEN -- 게임 수 초기화
UPDATE profiles
SET games_played_today = 0;
-- 플래그 업데이트
INSERT INTO system_flags (key, value, value_text, description)
VALUES (
        'last_daily_reset',
        true,
        v_today,
        'Daily stats reset date (22:00 KST)'
    ) ON CONFLICT (key) DO
UPDATE
SET value_text = v_today,
    updated_at = now();
v_did_reset := true;
END IF;
EXCEPTION
WHEN OTHERS THEN RAISE WARNING 'check_and_reset_daily failed: %',
SQLERRM;
END;
RETURN v_did_reset;
END;
$$;
GRANT EXECUTE ON FUNCTION check_and_reset_daily() TO authenticated;