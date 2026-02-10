-- ========================================================================
-- V10.0.0 P1 RPC Migration - Strict RPC Model Compliance
-- Date: 2026-02-10
-- Purpose: Replace all remaining direct frontend DB writes with RPCs
-- ========================================================================
-- ========================================================================
-- 1. remove_expired_from_queue
--    Used by: QueueBoard.tsx auto-exit logic
--    Replaces: supabase.from('queue').delete().in('id', idsToDelete)
-- ========================================================================
CREATE OR REPLACE FUNCTION public.remove_expired_from_queue(p_queue_ids UUID []) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_deleted_count INT;
BEGIN -- Validate input
IF p_queue_ids IS NULL
OR array_length(p_queue_ids, 1) IS NULL THEN RETURN jsonb_build_object('error', 'NO_IDS_PROVIDED');
END IF;
-- Delete expired queue entries
DELETE FROM public.queue
WHERE id = ANY(p_queue_ids)
    AND is_active = true;
GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
RETURN jsonb_build_object(
    'success',
    true,
    'deleted_count',
    v_deleted_count
);
END;
$$;
GRANT EXECUTE ON FUNCTION public.remove_expired_from_queue TO authenticated,
    service_role;
-- ========================================================================
-- 2. create_profile
--    Used by: Auth.tsx signup flow (Case B: new member)
--    Replaces: supabase.from('profiles').insert({ ... })
-- ========================================================================
CREATE OR REPLACE FUNCTION public.create_profile(
        p_name TEXT,
        p_ntrp NUMERIC,
        p_gender TEXT
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID;
v_initial_elo INT;
BEGIN -- Get authenticated user ID
v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object('error', 'NOT_AUTHENTICATED');
END IF;
-- Validate gender
IF p_gender NOT IN ('MALE', 'FEMALE') THEN RETURN jsonb_build_object('error', 'INVALID_GENDER');
END IF;
-- Calculate initial ELO from NTRP (mirrors ratingPolicy.ts)
v_initial_elo := CASE
    p_ntrp
    WHEN 1.0 THEN 600
    WHEN 1.5 THEN 800
    WHEN 2.0 THEN 1000
    WHEN 2.5 THEN 1100
    WHEN 3.0 THEN 1200
    WHEN 3.5 THEN 1400
    WHEN 4.0 THEN 1600
    WHEN 4.5 THEN 1800
    WHEN 5.0 THEN 2000
    WHEN 5.5 THEN 2200
    WHEN 6.0 THEN 2400
    WHEN 7.0 THEN 2800
    ELSE CASE
        WHEN p_ntrp < 2.5 THEN 1000
        WHEN p_ntrp > 7.0 THEN 3000
        ELSE 1200
    END
END;
-- Insert profile
INSERT INTO public.profiles (
        id,
        name,
        ntrp,
        gender,
        elo_mens_doubles,
        elo_womens_doubles,
        elo_mixed_doubles,
        elo_singles,
        is_guest
    )
VALUES (
        v_user_id,
        p_name,
        p_ntrp,
        p_gender::gender_t,
        v_initial_elo,
        v_initial_elo,
        v_initial_elo,
        v_initial_elo,
        false
    );
RETURN jsonb_build_object('success', true, 'initial_elo', v_initial_elo);
EXCEPTION
WHEN unique_violation THEN RETURN jsonb_build_object('error', 'PROFILE_ALREADY_EXISTS');
END;
$$;
GRANT EXECUTE ON FUNCTION public.create_profile TO authenticated,
    service_role;
-- ========================================================================
-- 3. convert_guest_to_member
--    Used by: Auth.tsx signup flow (Case A: guest → member conversion)
--    Replaces: supabase.from('profiles').update({ id, email, name, is_guest }).eq('id', guestId)
-- ========================================================================
CREATE OR REPLACE FUNCTION public.convert_guest_to_member(
        p_guest_id UUID,
        p_name TEXT,
        p_email TEXT
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID;
v_guest RECORD;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object('error', 'NOT_AUTHENTICATED');
END IF;
-- Verify guest exists
SELECT * INTO v_guest
FROM public.profiles
WHERE id = p_guest_id
    AND is_guest = true;
IF v_guest IS NULL THEN RETURN jsonb_build_object('error', 'GUEST_NOT_FOUND');
END IF;
-- Update guest profile to member (ELO and game history preserved)
UPDATE public.profiles
SET id = v_user_id,
    email = p_email,
    name = p_name,
    is_guest = false
WHERE id = p_guest_id;
RETURN jsonb_build_object(
    'success',
    true,
    'inherited_elo',
    COALESCE(v_guest.elo_mixed_doubles, 1200),
    'total_games',
    COALESCE(v_guest.total_games_history, 0)
);
END;
$$;
GRANT EXECUTE ON FUNCTION public.convert_guest_to_member TO authenticated,
    service_role;
-- ========================================================================
-- 4. admin_add_notice / admin_delete_notice
--    Used by: AdminDashboard.tsx notice management
--    Replaces: supabase.from('notices').insert/delete
-- ========================================================================
CREATE OR REPLACE FUNCTION public.admin_add_notice(p_content TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID;
v_role TEXT;
v_notice_id UUID;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object('error', 'NOT_AUTHENTICATED');
END IF;
-- Check admin role
SELECT role::TEXT INTO v_role
FROM public.profiles
WHERE id = v_user_id;
IF v_role != 'admin' THEN RETURN jsonb_build_object('error', 'NOT_ADMIN');
END IF;
INSERT INTO public.notices (content, is_active)
VALUES (p_content, true)
RETURNING id INTO v_notice_id;
RETURN jsonb_build_object('success', true, 'notice_id', v_notice_id);
END;
$$;
CREATE OR REPLACE FUNCTION public.admin_delete_notice(p_notice_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID;
v_role TEXT;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object('error', 'NOT_AUTHENTICATED');
END IF;
-- Check admin role
SELECT role::TEXT INTO v_role
FROM public.profiles
WHERE id = v_user_id;
IF v_role != 'admin' THEN RETURN jsonb_build_object('error', 'NOT_ADMIN');
END IF;
DELETE FROM public.notices
WHERE id = p_notice_id;
RETURN jsonb_build_object('success', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_add_notice TO authenticated,
    service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_notice TO authenticated,
    service_role;
-- ========================================================================
-- 5. update_my_profile
--    Used by: MyStatsModal.tsx emoji/avatar save
--    Replaces: supabase.from('profiles').update({ emoji, avatar_url }).eq('id', user.id)
-- ========================================================================
CREATE OR REPLACE FUNCTION public.update_my_profile(
        p_emoji TEXT DEFAULT NULL,
        p_avatar_url TEXT DEFAULT NULL
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID;
BEGIN v_user_id := auth.uid();
IF v_user_id IS NULL THEN RETURN jsonb_build_object('error', 'NOT_AUTHENTICATED');
END IF;
UPDATE public.profiles
SET emoji = COALESCE(p_emoji, emoji),
    avatar_url = COALESCE(p_avatar_url, avatar_url)
WHERE id = v_user_id;
RETURN jsonb_build_object('success', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.update_my_profile TO authenticated,
    service_role;