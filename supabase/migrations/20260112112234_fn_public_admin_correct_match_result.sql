CREATE OR REPLACE FUNCTION public.admin_correct_match_result(p_match_id uuid, p_correct_score1 integer, p_correct_score2 integer, p_admin_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_match_exists BOOLEAN;
v_log_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
-- Hardening
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
SELECT EXISTS(
        SELECT 1
        FROM public.matches
        WHERE id = p_match_id
            AND status = 'FINISHED'
    ) INTO v_match_exists;
IF NOT v_match_exists THEN RETURN jsonb_build_object('error', 'MATCH_NOT_FOUND_OR_NOT_FINISHED');
END IF;
INSERT INTO public.match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        confirmation_type,
        is_force_confirm,
        match_status_before,
        match_status_after,
        score_team1,
        score_team2,
        correction_reason
    )
VALUES (
        p_match_id,
        'ADMIN_CORRECTION',
        p_admin_id,
        'ADMIN',
        'ADMIN_CORRECTION',
        true,
        'FINISHED',
        'FINISHED',
        p_correct_score1,
        p_correct_score2,
        p_reason
    )
RETURNING id INTO v_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'version',
    'V9.1',
    'action_id',
    v_log_id
);
END;
$function$;

