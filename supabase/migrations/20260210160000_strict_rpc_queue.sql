-- Migration: v9.9.5_strict_rpc_queue
-- Description: Implement update_queue_departure_time RPC for strict RPC compliance.
CREATE OR REPLACE FUNCTION update_queue_departure_time(
        p_queue_id UUID,
        p_departure_time TIMESTAMPTZ
    ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_player_id UUID;
v_updated_count INT;
BEGIN -- 1. Check ownership and existence
SELECT player_id INTO v_player_id
FROM queue
WHERE id = p_queue_id;
IF v_player_id IS NULL THEN RETURN jsonb_build_object(
    'success',
    false,
    'error',
    'QUEUE_ITEM_NOT_FOUND'
);
END IF;
-- Ensure the user owns this queue item OR is an admin
IF v_player_id != auth.uid()
AND NOT EXISTS (
    SELECT 1
    FROM profiles
    WHERE id = auth.uid()
        AND role = 'admin'
) THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
END IF;
-- 2. Update
UPDATE queue
SET departure_time = p_departure_time,
    updated_at = now()
WHERE id = p_queue_id;
GET DIAGNOSTICS v_updated_count = ROW_COUNT;
IF v_updated_count = 0 THEN RETURN jsonb_build_object('success', false, 'error', 'UPDATE_FAILED');
END IF;
RETURN jsonb_build_object('success', true);
EXCEPTION
WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;