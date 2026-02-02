CREATE OR REPLACE FUNCTION public.admin_set_system_flag(p_key text, p_value boolean, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_old_val BOOLEAN;
v_log_id UUID;
v_system_uuid UUID := '00000000-0000-0000-0000-000000000000';
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
-- 1. Admin Verification
IF v_current_uid IS NULL
OR v_current_uid != p_admin_id THEN RETURN jsonb_build_object('error', 'IDENTITY_MISMATCH');
END IF;
IF NOT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = p_admin_id
        AND role = 'admin'
) THEN RETURN jsonb_build_object('error', 'PERMISSION_DENIED');
END IF;
-- 2. Get Old Value
SELECT value INTO v_old_val
FROM public.system_flags
WHERE key = p_key;
-- 3. No-Op Check (Guard)
IF v_old_val IS NOT NULL
AND v_old_val = p_value THEN RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'status',
    'NO_OP',
    'message',
    'Value unchanged'
);
END IF;
-- 4. Update
INSERT INTO public.system_flags (key, value, updated_at)
VALUES (p_key, p_value, NOW()) ON CONFLICT (key) DO
UPDATE
SET value = EXCLUDED.value,
    updated_at = NOW();
-- 5. Audit
INSERT INTO public.admin_operation_log (
        target_type,
        target_id,
        action,
        old_value,
        new_value,
        reason,
        operated_by
    )
VALUES (
        'SYSTEM',
        v_system_uuid,
        'FLAG_CHANGE',
        CASE
            WHEN v_old_val THEN 'true'
            ELSE 'false'
        END,
        CASE
            WHEN p_value THEN 'true'
            ELSE 'false'
        END,
        'Key: ' || p_key,
        p_admin_id
    )
RETURNING id INTO v_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'action_id',
    v_log_id,
    'key',
    p_key,
    'value',
    p_value
);
END;
$function$;

