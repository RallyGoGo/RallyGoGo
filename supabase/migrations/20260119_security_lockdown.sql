-- ========================================================================
-- V9.7.2 SECURITY LOCKDOWN (20260119)
-- Purpose: Revoke anon EXECUTE on all admin/match RPCs and views
-- Safe for Supabase CLI db push (single DO block, prepared-statement-safe)
-- ========================================================================
DO $$
DECLARE fn RECORD;
BEGIN -- 1. Revoke from anon AND PUBLIC for all sensitive functions
FOR fn IN
SELECT p.oid,
    n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig
FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
    AND p.proname IN (
        'admin_adjust_rating',
        'admin_apply_match_correction',
        'admin_clear_no_show',
        'admin_correct_match_result',
        'admin_mark_no_show',
        'admin_merge_profile',
        'admin_prepare_undo',
        'admin_preview_match_correction',
        'admin_set_system_flag',
        'finish_match_atomic',
        'process_match_completion'
    ) LOOP -- Revoke from PUBLIC and anon explicitly
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', fn.sig);
EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', fn.sig);
-- Grant only to authenticated and service_role
EXECUTE format(
    'GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role',
    fn.sig
);
END LOOP;
-- 2. Revoke anon from admin views (safe: only if view exists)
BEGIN REVOKE ALL ON public.view_admin_correction_chain
FROM anon;
GRANT SELECT ON public.view_admin_correction_chain TO authenticated,
    service_role;
EXCEPTION
WHEN undefined_table THEN NULL;
END;
BEGIN REVOKE ALL ON public.view_admin_correction_chain_detail
FROM anon;
GRANT SELECT ON public.view_admin_correction_chain_detail TO authenticated,
    service_role;
EXCEPTION
WHEN undefined_table THEN NULL;
END;
BEGIN REVOKE ALL ON public.view_admin_correction_dashboard
FROM anon;
GRANT SELECT ON public.view_admin_correction_dashboard TO authenticated,
    service_role;
EXCEPTION
WHEN undefined_table THEN NULL;
END;
BEGIN REVOKE ALL ON public.view_admin_correction_status
FROM anon;
GRANT SELECT ON public.view_admin_correction_status TO authenticated,
    service_role;
EXCEPTION
WHEN undefined_table THEN NULL;
END;
BEGIN REVOKE ALL ON public.view_admin_correction_log_dashboard
FROM anon;
GRANT SELECT ON public.view_admin_correction_log_dashboard TO authenticated,
    service_role;
EXCEPTION
WHEN undefined_table THEN NULL;
END;
END $$;