CREATE OR REPLACE FUNCTION public.admin_prepare_undo(p_target_correction_id uuid, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_target_log public.match_audit_log %ROWTYPE;
v_prev_log public.match_audit_log %ROWTYPE;
v_new_audit_log_id UUID;
v_match_id UUID;
v_current_uid UUID;
BEGIN v_current_uid := auth.uid();
-- Security
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
-- Fetch Target
SELECT * INTO v_target_log
FROM public.match_audit_log
WHERE id = p_target_correction_id;
IF v_target_log IS NULL THEN RETURN jsonb_build_object('error', 'TARGET_NOT_FOUND');
END IF;
-- Validation: Must be APPLIED
IF v_target_log.correction_status != 'APPLIED' THEN RETURN jsonb_build_object('error', 'TARGET_NOT_APPLIED');
END IF;
-- Validation: Must be Latest APPLIED in Chain (Undo Candidate)
-- We can re-use the logic from the view logic or query directly.
-- Query: Is there any APPLIED correction in the same chain created AFTER this target?
IF EXISTS (
    SELECT 1
    FROM public.match_audit_log
    WHERE COALESCE(correction_chain_id, id) = COALESCE(
            v_target_log.correction_chain_id,
            v_target_log.id
        )
        AND correction_status = 'APPLIED'
        AND created_at > v_target_log.created_at
) THEN RETURN jsonb_build_object(
    'error',
    'CHAIN_INTEGRITY_VIOLATION: Traget is not the latest applied correction.'
);
END IF;
v_match_id := v_target_log.match_id;
-- FIND PREVIOUS STATE
-- We need the scores from the audit log entry for this match that immediately precedes the target.
-- This could be a NORMAL_CONFIRM or another ADMIN_CORRECTION.
SELECT * INTO v_prev_log
FROM public.match_audit_log
WHERE match_id = v_match_id
    AND created_at < v_target_log.created_at
ORDER BY created_at DESC
LIMIT 1;
IF v_prev_log IS NULL THEN -- This implies we are trying to undo the very first action?
-- But even normal finishes log an entry.
-- If missing, it means data integrity issue or migration gap.
RETURN jsonb_build_object(
    'error',
    'HISTORY_GAP: Cannot find previous state to revert to.'
);
END IF;
-- CREATE UNDO PENDING LOG
INSERT INTO public.match_audit_log (
        match_id,
        action,
        triggered_by,
        trigger_role,
        score_team1,
        score_team2,
        correction_reason,
        correction_status,
        correction_chain_id
    )
VALUES (
        v_match_id,
        'ADMIN_CORRECTION',
        p_admin_id,
        'ADMIN',
        v_prev_log.score_team1,
        -- The scores we are reverting TO
        v_prev_log.score_team2,
        'UNDO: ' || COALESCE(v_target_log.correction_reason, 'Correction'),
        'PENDING',
        COALESCE(
            v_target_log.correction_chain_id,
            v_target_log.id
        ) -- Bind to same chain
    )
RETURNING id INTO v_new_audit_log_id;
RETURN jsonb_build_object(
    'success',
    true,
    'new_audit_log_id',
    v_new_audit_log_id,
    'reverted_scores',
    jsonb_build_object(
        'team1',
        v_prev_log.score_team1,
        'team2',
        v_prev_log.score_team2
    )
);
END;
$function$;

