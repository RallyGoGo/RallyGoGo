-- ============================================================================
-- RallyGoGo V9.8.2 HOTFIX
-- Date: 2026-02-04
-- Purpose: Fix admin_confirm_match to properly update ELO and settle bets
-- ============================================================================
-- PROBLEM: admin_confirm_match only changes status to FINISHED but does NOT:
-- 1. Update player ELO ratings
-- 2. Settle bets
-- 3. Remove players from queue
--
-- SOLUTION: Call finish_match_v2 internally for ELO + bets processing
-- ============================================================================
DROP FUNCTION IF EXISTS admin_confirm_match(UUID);
CREATE OR REPLACE FUNCTION admin_confirm_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_match RECORD;
v_user_id UUID := auth.uid();
v_user_role TEXT;
v_result JSONB;
BEGIN -- [Auth Check]
SELECT role INTO v_user_role
FROM profiles
WHERE id = v_user_id;
IF v_user_role IS NULL
OR v_user_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
-- [Fetch Match]
SELECT * INTO v_match
FROM matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'MATCH_NOT_FOUND');
END IF;
-- [Already Finished Check]
IF v_match.status = 'FINISHED' THEN RETURN jsonb_build_object('success', false, 'error', 'ALREADY_FINISHED');
END IF;
-- [Score Check] - Must have scores to confirm
IF v_match.score_team1 IS NULL
OR v_match.score_team2 IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'SCORE_REQUIRED',
    'message',
    '점수가 입력되지 않았습니다. 먼저 점수를 입력해주세요.'
);
END IF;
-- [Delegate to finish_match_v2 with admin confirmation type]
-- This ensures ELO updates, bet settlement, and queue cleanup all happen
v_result := finish_match_v2(
    p_match_id,
    COALESCE(v_match.score_team1, 0),
    COALESCE(v_match.score_team2, 0),
    'ADMIN_FORCE_CONFIRM'
);
RETURN v_result;
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INTERNAL_ERROR',
    'sqlstate',
    SQLSTATE,
    'message',
    SQLERRM
);
END;
$$;
-- Ensure permissions
GRANT EXECUTE ON FUNCTION admin_confirm_match(UUID) TO authenticated;
-- ============================================================================
-- VERIFICATION QUERY (run after migration):
-- SELECT prosrc FROM pg_proc WHERE proname = 'admin_confirm_match' LIMIT 1;
-- Should contain 'finish_match_v2' in the function body
-- ============================================================================