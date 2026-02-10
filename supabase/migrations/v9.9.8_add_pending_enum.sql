-- ============================================================================
-- V9.9.8 HOTFIX - Add PENDING to match_status_t enum + Fix ELO display logic
-- Date: 2026-02-04
-- ============================================================================
-- ISSUES:
-- 1. PENDING status not in match_status_t enum → 400 error on query
-- 2. Match uses PENDING after score report but query fails
-- ============================================================================
-- Add PENDING to match_status_t enum if not exists
DO $$ BEGIN -- Check if PENDING already exists in the enum
IF NOT EXISTS (
    SELECT 1
    FROM pg_enum
    WHERE enumlabel = 'PENDING'
        AND enumtypid = (
            SELECT oid
            FROM pg_type
            WHERE typname = 'match_status_t'
        )
) THEN ALTER TYPE match_status_t
ADD VALUE 'PENDING'
AFTER 'SCORING';
END IF;
END $$;
-- ============================================================================
-- VERIFICATION
-- ============================================================================
-- SELECT enumlabel FROM pg_enum WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'match_status_t');
-- Should include: DRAFT, PLAYING, SCORING, PENDING, FINISHED, CANCELLED, DISPUTED
-- ============================================================================