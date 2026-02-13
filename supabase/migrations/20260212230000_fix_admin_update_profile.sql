-- =============================================================================
-- FIX: Update Profile Logic & Remove Admin Check
-- 1. Remove strict admin check (allow authenticated users to update profiles via this Admin Dashboard function)
-- 2. When NTRP is updated, auto-calculate and RESET ELO scores based on new NTRP.
--    Formula: ELO = NTRP * 400
-- =============================================================================
CREATE OR REPLACE FUNCTION admin_update_profile(
        p_profile_id UUID,
        p_name TEXT DEFAULT NULL,
        p_gender TEXT DEFAULT NULL,
        p_ntrp NUMERIC DEFAULT NULL,
        p_role TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_user_id UUID;
v_old_values JSONB;
v_current_ntrp NUMERIC;
v_new_elo INT;
BEGIN -- 1. Authentication Check
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'AUTHENTICATION_REQUIRED'
);
END IF;
-- [REMOVED] Strict Admin Check to allow usage via PIN-protected Dashboard for non-admin DB roles
-- IF v_user_role IS NULL OR v_user_role != 'admin' THEN ... END IF;
-- 2. Fetch Old Values
SELECT jsonb_build_object(
        'name',
        name,
        'gender',
        gender,
        'ntrp',
        ntrp,
        'role',
        role
    ),
    ntrp INTO v_old_values,
    v_current_ntrp
FROM profiles
WHERE id = p_profile_id;
IF v_old_values IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PROFILE_NOT_FOUND');
END IF;
-- 3. Calculate New ELO if NTRP Changed
v_new_elo := NULL;
IF p_ntrp IS NOT NULL
AND p_ntrp != v_current_ntrp THEN v_new_elo := ROUND(p_ntrp * 400);
END IF;
-- 4. Update Profile
UPDATE profiles
SET name = COALESCE(p_name, name),
    gender = COALESCE(p_gender::gender_t, gender),
    ntrp = COALESCE(p_ntrp, ntrp),
    role = COALESCE(p_role::user_role_t, role),
    -- Update ELOs if NTRP changed
    elo_mens_doubles = CASE
        WHEN v_new_elo IS NOT NULL THEN v_new_elo
        ELSE elo_mens_doubles
    END,
    elo_womens_doubles = CASE
        WHEN v_new_elo IS NOT NULL THEN v_new_elo
        ELSE elo_womens_doubles
    END,
    elo_mixed_doubles = CASE
        WHEN v_new_elo IS NOT NULL THEN v_new_elo
        ELSE elo_mixed_doubles
    END,
    elo_singles = CASE
        WHEN v_new_elo IS NOT NULL THEN v_new_elo
        ELSE elo_singles
    END,
    updated_at = now()
WHERE id = p_profile_id;
-- 5. User Feedback Message
DECLARE v_msg TEXT := '프로필이 수정되었습니다.';
BEGIN IF v_new_elo IS NOT NULL THEN v_msg := '프로필 수정 및 ELO 점수가 초기화되었습니다 (' || v_new_elo || '점)';
END IF;
-- Audit Log (Optional, keep it simple)
INSERT INTO admin_operation_log (
        operated_by,
        action,
        target_type,
        target_id,
        old_value,
        new_value
    )
VALUES (
        v_user_id,
        'UPDATE_PROFILE',
        'profiles',
        p_profile_id,
        v_old_values::text,
        jsonb_build_object(
            'name',
            p_name,
            'ntrp',
            p_ntrp,
            'new_elo',
            v_new_elo
        )::text
    );
RETURN jsonb_build_object('success', true, 'message', v_msg);
END;
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;