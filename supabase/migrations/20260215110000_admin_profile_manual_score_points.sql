-- ========================================================================
-- Admin Profile Update: Manual ELO Input + Rally Point Adjustment
-- Date: 2026-02-15
-- Purpose: Stop forced NTRP->ELO reset and allow direct score/point control
-- ========================================================================

DROP FUNCTION IF EXISTS public.admin_update_profile(UUID, TEXT, TEXT, NUMERIC, TEXT);

CREATE OR REPLACE FUNCTION public.admin_update_profile(
    p_profile_id UUID,
    p_name TEXT DEFAULT NULL,
    p_gender TEXT DEFAULT NULL,
    p_ntrp NUMERIC DEFAULT NULL,
    p_role TEXT DEFAULT NULL,
    p_elo_mens_doubles INTEGER DEFAULT NULL,
    p_elo_womens_doubles INTEGER DEFAULT NULL,
    p_elo_mixed_doubles INTEGER DEFAULT NULL,
    p_elo_singles INTEGER DEFAULT NULL,
    p_rally_point_delta INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_old_values JSONB;
    v_new_rally_point INTEGER;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTHENTICATION_REQUIRED');
    END IF;

    IF p_gender IS NOT NULL AND p_gender NOT IN ('MALE', 'FEMALE', 'OTHER') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_GENDER');
    END IF;

    IF p_role IS NOT NULL AND p_role NOT IN ('player', 'coach', 'admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ROLE');
    END IF;

    IF p_ntrp IS NOT NULL AND (p_ntrp < 1.0 OR p_ntrp > 7.0) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_NTRP');
    END IF;

    IF p_elo_mens_doubles IS NOT NULL AND (p_elo_mens_doubles < 0 OR p_elo_mens_doubles > 5000) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ELO_MENS');
    END IF;

    IF p_elo_womens_doubles IS NOT NULL AND (p_elo_womens_doubles < 0 OR p_elo_womens_doubles > 5000) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ELO_WOMENS');
    END IF;

    IF p_elo_mixed_doubles IS NOT NULL AND (p_elo_mixed_doubles < 0 OR p_elo_mixed_doubles > 5000) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ELO_MIXED');
    END IF;

    IF p_elo_singles IS NOT NULL AND (p_elo_singles < 0 OR p_elo_singles > 5000) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ELO_SINGLES');
    END IF;

    SELECT jsonb_build_object(
               'name', name,
               'gender', gender,
               'ntrp', ntrp,
               'role', role,
               'elo_mens_doubles', elo_mens_doubles,
               'elo_womens_doubles', elo_womens_doubles,
               'elo_mixed_doubles', elo_mixed_doubles,
               'elo_singles', elo_singles,
               'rally_point', rally_point
           )
      INTO v_old_values
      FROM public.profiles
     WHERE id = p_profile_id;

    IF v_old_values IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'PROFILE_NOT_FOUND');
    END IF;

    UPDATE public.profiles
       SET name = COALESCE(p_name, name),
           gender = CASE
               WHEN p_gender IS NULL THEN gender
               ELSE p_gender::gender_t
           END,
           ntrp = COALESCE(p_ntrp, ntrp),
           role = CASE
               WHEN p_role IS NULL THEN role
               ELSE p_role::user_role_t
           END,
           elo_mens_doubles = COALESCE(p_elo_mens_doubles, elo_mens_doubles),
           elo_womens_doubles = COALESCE(p_elo_womens_doubles, elo_womens_doubles),
           elo_mixed_doubles = COALESCE(p_elo_mixed_doubles, elo_mixed_doubles),
           elo_singles = COALESCE(p_elo_singles, elo_singles),
           rally_point = CASE
               WHEN p_rally_point_delta IS NULL THEN rally_point
               ELSE GREATEST(0, COALESCE(rally_point, 0) + p_rally_point_delta)
           END,
           updated_at = now()
     WHERE id = p_profile_id
     RETURNING rally_point INTO v_new_rally_point;

    BEGIN
        INSERT INTO public.admin_operation_log (
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
            'PROFILE',
            p_profile_id,
            v_old_values::text,
            jsonb_build_object(
                'name', p_name,
                'gender', p_gender,
                'ntrp', p_ntrp,
                'role', p_role,
                'elo_mens_doubles', p_elo_mens_doubles,
                'elo_womens_doubles', p_elo_womens_doubles,
                'elo_mixed_doubles', p_elo_mixed_doubles,
                'elo_singles', p_elo_singles,
                'rally_point_delta', p_rally_point_delta,
                'new_rally_point', v_new_rally_point
            )::text
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'admin_update_profile operation log failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object(
        'success', true,
        'message', '프로필이 수정되었습니다.',
        'new_rally_point', v_new_rally_point
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_profile(
    UUID,
    TEXT,
    TEXT,
    NUMERIC,
    TEXT,
    INTEGER,
    INTEGER,
    INTEGER,
    INTEGER,
    INTEGER
) TO authenticated, service_role;
