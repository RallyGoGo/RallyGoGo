-- ============================================================================
-- 게스트 대기열 삭제 RPC
-- 인증된 유저가 is_guest=true인 플레이어를 큐에서 제거
-- Supabase SQL Editor에서 실행
-- ============================================================================
CREATE OR REPLACE FUNCTION remove_guest_from_queue(p_guest_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_target RECORD;
v_deleted INTEGER;
BEGIN -- 1. 인증 확인
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- 2. 대상 프로필 확인
SELECT id,
    name,
    is_guest INTO v_target
FROM profiles
WHERE id = p_guest_id;
IF v_target IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'PROFILE_NOT_FOUND',
    'message',
    '해당 프로필을 찾을 수 없습니다.'
);
END IF;
-- 3. 게스트만 삭제 가능 (정규 회원 보호)
IF NOT v_target.is_guest THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'NOT_A_GUEST',
    'message',
    '게스트만 대기열에서 삭제할 수 있습니다.'
);
END IF;
-- 4. 큐에서 삭제
DELETE FROM queue
WHERE player_id = p_guest_id;
GET DIAGNOSTICS v_deleted = ROW_COUNT;
IF v_deleted = 0 THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'NOT_IN_QUEUE',
    'message',
    '해당 게스트가 대기열에 없습니다.'
);
END IF;
RETURN jsonb_build_object(
    'success',
    true,
    'guest_id',
    p_guest_id,
    'guest_name',
    v_target.name,
    'message',
    v_target.name || '님이 대기열에서 삭제되었습니다.'
);
END;
$$;
GRANT EXECUTE ON FUNCTION remove_guest_from_queue(UUID) TO authenticated;