-- ============================================================================
-- V9.9.2 HOTFIX - Fix trigger column error
-- Date: 2026-02-04
-- ============================================================================
-- ISSUE: trigger_auto_rejoin_queue tries to insert into 'details' column
-- which doesn't exist in match_audit_log table
-- SOLUTION: Remove audit log insert from trigger (keep it simple)
-- ============================================================================
-- ============================================================================
-- STEP 1: Fix trigger - remove problematic audit log insert
-- ============================================================================
DROP TRIGGER IF EXISTS trg_auto_rejoin_queue ON matches;
DROP FUNCTION IF EXISTS trigger_auto_rejoin_queue();
CREATE OR REPLACE FUNCTION trigger_auto_rejoin_queue() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_result JSONB;
BEGIN -- Only trigger when status changes TO 'FINISHED'
IF NEW.status = 'FINISHED'
AND (
    OLD.status IS DISTINCT
    FROM 'FINISHED'
) THEN -- Call rejoin function
v_result := rejoin_queue_after_match(NEW.id);
-- Just log to console (no table insert to avoid column issues)
RAISE NOTICE '[Auto-Rejoin] Match %: %',
NEW.id,
v_result;
END IF;
RETURN NEW;
EXCEPTION
WHEN OTHERS THEN -- Log error but don't fail the transaction
RAISE NOTICE '[Auto-Rejoin ERROR] Match %: % (SQLSTATE: %)',
NEW.id,
SQLERRM,
SQLSTATE;
RETURN NEW;
END;
$$;
CREATE TRIGGER trg_auto_rejoin_queue
AFTER
UPDATE ON matches FOR EACH ROW EXECUTE FUNCTION trigger_auto_rejoin_queue();
-- ============================================================================
-- VERIFICATION
-- ============================================================================
-- SELECT trigger_name FROM information_schema.triggers WHERE trigger_name = 'trg_auto_rejoin_queue';
-- ============================================================================