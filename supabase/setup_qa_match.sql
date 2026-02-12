-- ============================================================================
-- RallyGoGo QA Data Setup Script
-- 목적: 웹 UI에서 E2E 테스트를 수행할 수 있도록 'PLAYING' 상태의 매치를 생성
-- 실행: Supabase SQL Editor에서 전체 선택 후 실행 (Run)
-- 특징: 직접 INSERT를 사용하여 인증 오류(AUTHENTICATION_REQUIRED) 회피
-- ============================================================================
DO $$
DECLARE v_p1_id UUID;
v_p2_id UUID;
v_p3_id UUID;
v_p4_id UUID;
v_match_id UUID;
BEGIN RAISE NOTICE '🚀 QA 데이터 셋업 시작';
-- 1. 대기열 초기화 (선택 사항: 테스트 환경 정돈)
DELETE FROM queue;
RAISE NOTICE '✅ 대기열 초기화 완료';
-- 2. 테스트용 게스트 프로필 생성 (존재하면 ID 재사용)
-- Player 1
SELECT id INTO v_p1_id
FROM profiles
WHERE name = 'QA_Player_1 (G)';
IF v_p1_id IS NULL THEN
INSERT INTO profiles (
        id,
        name,
        ntrp,
        gender,
        is_guest,
        elo_mixed_doubles
    )
VALUES (
        gen_random_uuid(),
        'QA_Player_1 (G)',
        4.0,
        'MALE',
        true,
        1200
    )
RETURNING id INTO v_p1_id;
END IF;
-- Player 2
SELECT id INTO v_p2_id
FROM profiles
WHERE name = 'QA_Player_2 (G)';
IF v_p2_id IS NULL THEN
INSERT INTO profiles (
        id,
        name,
        ntrp,
        gender,
        is_guest,
        elo_mixed_doubles
    )
VALUES (
        gen_random_uuid(),
        'QA_Player_2 (G)',
        4.5,
        'MALE',
        true,
        1200
    )
RETURNING id INTO v_p2_id;
END IF;
-- Player 3
SELECT id INTO v_p3_id
FROM profiles
WHERE name = 'QA_Player_3 (G)';
IF v_p3_id IS NULL THEN
INSERT INTO profiles (
        id,
        name,
        ntrp,
        gender,
        is_guest,
        elo_mixed_doubles
    )
VALUES (
        gen_random_uuid(),
        'QA_Player_3 (G)',
        3.5,
        'FEMALE',
        true,
        1200
    )
RETURNING id INTO v_p3_id;
END IF;
-- Player 4
SELECT id INTO v_p4_id
FROM profiles
WHERE name = 'QA_Player_4 (G)';
IF v_p4_id IS NULL THEN
INSERT INTO profiles (
        id,
        name,
        ntrp,
        gender,
        is_guest,
        elo_mixed_doubles
    )
VALUES (
        gen_random_uuid(),
        'QA_Player_4 (G)',
        3.0,
        'FEMALE',
        true,
        1200
    )
RETURNING id INTO v_p4_id;
END IF;
RAISE NOTICE '✅ QA 플레이어 준비 완료: %, %, %, %',
v_p1_id,
v_p2_id,
v_p3_id,
v_p4_id;
-- 3. 'PLAYING' 상태의 매치 생성 (직접 INSERT)
INSERT INTO matches (
        player_1,
        player_2,
        player_3,
        player_4,
        match_type,
        status,
        court_name,
        start_time
    )
VALUES (
        v_p1_id,
        v_p2_id,
        v_p3_id,
        v_p4_id,
        'MIXED',
        'PLAYING',
        'QA Court A',
        now()
    )
RETURNING id INTO v_match_id;
RAISE NOTICE '✅ QA 매치 생성 완료 (PLAYING 상태)';
RAISE NOTICE 'MATCH ID: %',
v_match_id;
RAISE NOTICE '👉 이제 웹 브라우저에서 로그인(관리자) 후 CourtBoard를 확인하세요.';
RAISE NOTICE '1. "QA Court A"에서 "Report Score" 버튼 클릭 -> 점수 입력 (예: 6:4)';
RAISE NOTICE '2. 상태가 "PENDING"으로 바뀌는지 확인';
RAISE NOTICE '3. Dashboard 또는 배너에서 "Review/Confirm" 클릭 -> 승인';
RAISE NOTICE '4. 매치가 사라지고, QueueBoard에 4명의 플레이어가 복귀했는지 확인';
END $$;