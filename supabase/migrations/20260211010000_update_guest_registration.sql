-- ============================================================================
-- UPDATE: Guest Registration Logic
-- 1. Prevent Duplicate Active Queue Entries by Name
-- 2. Fix ELO Calculation (Strict Numeric Matching)
-- 3. Maintain existing atomic profile creation/reuse
-- ============================================================================
CREATE OR REPLACE FUNCTION register_guest_and_enqueue(
        p_name TEXT,
        p_ntrp NUMERIC,
        p_gender TEXT,
        p_departure_time TIMESTAMPTZ
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_guest_id UUID;
v_initial_elo INTEGER;
v_priority_score NUMERIC;
v_queue_id UUID;
v_reused BOOLEAN := false;
v_gender_enum gender_t;
v_full_name TEXT;
BEGIN -- ================================================================
-- STEP 1: Identity Check
-- ================================================================
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED',
    'message',
    '로그인이 필요합니다.'
);
END IF;
-- ================================================================
-- STEP 2: Validate Input & Duplicate Check
-- ================================================================
IF p_name IS NULL
OR trim(p_name) = '' THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'INVALID_NAME',
    'message',
    '이름을 입력해주세요.'
);
END IF;
v_full_name := trim(p_name) || ' (G)';
-- 🚨 DUPLICATE CHECK: Check if this name is ALREADY in the ACTIVE queue
-- This looks up ANY profile with this name that is currently in the queue
IF EXISTS (
    SELECT 1
    FROM queue q
        JOIN profiles p ON q.player_id = p.id
    WHERE p.name = v_full_name
        AND q.is_active = true
) THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'DUPLICATE_QUEUE',
    'message',
    '이미 대기열에 등록된 이름입니다.'
);
END IF;
-- Gender Conversion
IF upper(p_gender) IN ('MALE', 'M') THEN v_gender_enum := 'MALE';
ELSIF upper(p_gender) IN ('FEMALE', 'F') THEN v_gender_enum := 'FEMALE';
ELSE v_gender_enum := 'OTHER';
END IF;
-- ================================================================
-- STEP 3: Robust ELO Calculation
-- ================================================================
-- Using ranges to avoid floating point equality issues
IF p_ntrp <= 1.0 THEN v_initial_elo := 600;
ELSIF p_ntrp <= 1.5 THEN v_initial_elo := 800;
ELSIF p_ntrp <= 2.0 THEN v_initial_elo := 1000;
ELSIF p_ntrp <= 2.5 THEN v_initial_elo := 1100;
ELSIF p_ntrp <= 3.0 THEN v_initial_elo := 1200;
ELSIF p_ntrp <= 3.5 THEN v_initial_elo := 1400;
ELSIF p_ntrp <= 4.0 THEN v_initial_elo := 1600;
ELSIF p_ntrp <= 4.5 THEN v_initial_elo := 1800;
ELSIF p_ntrp <= 5.0 THEN v_initial_elo := 2000;
ELSIF p_ntrp <= 5.5 THEN v_initial_elo := 2200;
ELSIF p_ntrp <= 6.0 THEN v_initial_elo := 2400;
ELSIF p_ntrp >= 7.0 THEN v_initial_elo := 2800;
ELSE v_initial_elo := 1200;
END IF;
-- ================================================================
-- STEP 4: Profile Management (Reuse or Create)
-- ================================================================
SELECT id INTO v_guest_id
FROM profiles
WHERE is_guest = true
    AND name = v_full_name
LIMIT 1;
IF v_guest_id IS NOT NULL THEN v_reused := true;
-- Update ELO to match new NTRP (Optional: User might want fresh start logic? 
-- But reusing profile implies continuity. 
-- For guests, re-setting ELO based on current NTRP helps balance if they improved/got worse?
-- Let's UPDATE the ELO to the new calculated value for the session to ensure correct balancing.)
UPDATE profiles
SET ntrp = p_ntrp,
    gender = v_gender_enum,
    elo_mixed_doubles = v_initial_elo,
    elo_mens_doubles = v_initial_elo,
    elo_womens_doubles = v_initial_elo,
    elo_singles = v_initial_elo
WHERE id = v_guest_id;
ELSE v_guest_id := gen_random_uuid();
INSERT INTO profiles (
        id,
        name,
        ntrp,
        gender,
        is_guest,
        elo_mixed_doubles,
        elo_mens_doubles,
        elo_womens_doubles,
        elo_singles
    )
VALUES (
        v_guest_id,
        v_full_name,
        p_ntrp,
        v_gender_enum,
        true,
        v_initial_elo,
        v_initial_elo,
        v_initial_elo,
        v_initial_elo
    );
END IF;
-- ================================================================
-- STEP 5: Calculate Priority & Enqueue
-- ================================================================
v_priority_score := 500;
IF p_departure_time IS NOT NULL THEN
DECLARE diff_mins NUMERIC;
BEGIN diff_mins := EXTRACT(
    EPOCH
    FROM (p_departure_time - now())
) / 60;
IF diff_mins > 0
AND diff_mins <= 40 THEN v_priority_score := v_priority_score + 70;
END IF;
END;
END IF;
INSERT INTO queue (
        player_id,
        priority_score,
        departure_time,
        is_active,
        joined_at
    )
VALUES (
        v_guest_id,
        v_priority_score,
        p_departure_time,
        true,
        now()
    )
RETURNING id INTO v_queue_id;
RETURN jsonb_build_object(
    'success',
    true,
    'player_id',
    v_guest_id,
    'queue_id',
    v_queue_id,
    'reused',
    v_reused,
    'initial_elo',
    v_initial_elo,
    'message',
    CASE
        WHEN v_reused THEN '기존 게스트 프로필 사용 (ELO 갱신).'
        ELSE '새 게스트 등록 완료!'
    END
);
END;
$$;