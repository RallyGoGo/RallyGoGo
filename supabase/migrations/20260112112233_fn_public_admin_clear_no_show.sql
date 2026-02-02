CREATE OR REPLACE FUNCTION public.admin_clear_no_show(p_player_id uuid, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_old_count INT;
v_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
-- 1. Identity & Admin Check (Hardened)
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
-- 2. Get Old Value (Locking)
SELECT no_show_count INTO v_old_count
FROM public.queue
WHERE player_id = p_player_id FOR
UPDATE;
IF v_old_count IS NULL THEN v_old_count := 0;
END IF;
-- 3. Update
UPDATE public.queue
SET no_show_count = 0
WHERE player_id = p_player_id;
-- 4. Audit (New Table)
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
        'QUEUE',
        p_player_id,
        'CLEAR_NO_SHOW',
        v_old_count::text,
        '0',
        'Admin Manual Clear',
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
    'old_count',
    v_old_count
);
END;
$function$;

