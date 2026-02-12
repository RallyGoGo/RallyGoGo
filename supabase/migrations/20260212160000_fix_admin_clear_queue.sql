-- Fix admin_clear_queue: Add WHERE clause for safety
-- PDCA Step 1: Fix "DELETE requires a WHERE clause" error
CREATE OR REPLACE FUNCTION admin_clear_queue() RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_user_id UUID := auth.uid();
v_user_role TEXT;
v_deleted_count INT;
BEGIN -- [Auth Check]
SELECT role INTO v_user_role
FROM profiles
WHERE id = v_user_id;
IF v_user_role IS NULL
OR v_user_role != 'admin' THEN RETURN jsonb_build_object('success', false, 'error', 'ADMIN_REQUIRED');
END IF;
-- [Delete All Queue Entries with WHERE clause]
DELETE FROM queue
WHERE true;
-- Explicitly deleting all rows
GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
-- [Audit Log]
INSERT INTO admin_operation_log (
        operated_by,
        action,
        target_type,
        new_value
    )
VALUES (
        v_user_id,
        'CLEAR_QUEUE',
        'queue',
        jsonb_build_object('deleted_count', v_deleted_count)::text
    );
RETURN jsonb_build_object(
    'success',
    true,
    'deleted_count',
    v_deleted_count
);
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;