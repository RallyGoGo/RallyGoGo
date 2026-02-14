-- ============================================================================
-- Fix: Queue expiry handled on server time + repair missing departure_time
-- Date: 2026-02-14
--
-- Goals:
-- 1) Remove dependence on client clock for queue expiry.
-- 2) Repair active queue rows with NULL departure_time so UI does not show '-'.
-- 3) Keep compatibility with existing RPC name remove_expired_from_queue.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.remove_expired_from_queue(
    p_queue_ids UUID[] DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_now TIMESTAMPTZ := now();
    v_deleted_count INT := 0;
    v_repaired_count INT := 0;
    v_rec RECORD;
    v_dep TIMESTAMPTZ;
BEGIN
    -- 1) Repair NULL departure_time on active queue rows.
    --    Priority:
    --    (a) restore from latest matches.player_departure_times
    --    (b) fallback to joined_at + 2 hours
    FOR v_rec IN
        SELECT q.id, q.player_id, q.joined_at
        FROM public.queue q
        WHERE q.is_active = true
          AND q.departure_time IS NULL
    LOOP
        v_dep := NULL;

        BEGIN
            SELECT (m.player_departure_times ->> v_rec.player_id::text)::timestamptz
              INTO v_dep
              FROM public.matches m
             WHERE m.player_departure_times IS NOT NULL
               AND m.player_departure_times ? v_rec.player_id::text
             ORDER BY m.created_at DESC
             LIMIT 1;
        EXCEPTION
            WHEN OTHERS THEN
                v_dep := NULL;
        END;

        IF v_dep IS NULL THEN
            v_dep := COALESCE(v_rec.joined_at, v_now) + INTERVAL '2 hours';
        END IF;

        UPDATE public.queue
        SET departure_time = v_dep
        WHERE id = v_rec.id;

        v_repaired_count := v_repaired_count + 1;
    END LOOP;

    -- 2) Server-side expiry deletion.
    --    If IDs are provided, still enforce server expiry condition.
    IF p_queue_ids IS NOT NULL AND array_length(p_queue_ids, 1) IS NOT NULL THEN
        DELETE FROM public.queue
        WHERE id = ANY(p_queue_ids)
          AND is_active = true
          AND departure_time IS NOT NULL
          AND departure_time <= v_now;
    ELSE
        DELETE FROM public.queue
        WHERE is_active = true
          AND departure_time IS NOT NULL
          AND departure_time <= v_now;
    END IF;

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'deleted_count', v_deleted_count,
        'repaired_count', v_repaired_count,
        'server_now', v_now
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.remove_expired_from_queue(UUID[]) TO authenticated, service_role;

