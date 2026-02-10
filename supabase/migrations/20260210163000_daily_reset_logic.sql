-- Create system_state table to track system events like daily reset
CREATE TABLE IF NOT EXISTS public.system_state (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.system_state ENABLE ROW LEVEL SECURITY;
-- Drop existing policies to ensure idempotency
DROP POLICY IF EXISTS "Everyone can read system_state" ON public.system_state;
DROP POLICY IF EXISTS "Admin/Service can update system_state" ON public.system_state;
-- Allow anyone to read system state (needed for client checks)
CREATE POLICY "Everyone can read system_state" ON public.system_state FOR
SELECT USING (true);
-- Only service_role or admin (via RPC) can update
CREATE POLICY "Admin/Service can update system_state" ON public.system_state FOR ALL USING (
    (
        select auth.uid()
    ) IN (
        SELECT id
        FROM public.profiles
        WHERE role = 'admin'
    )
);
-- RPC to check and perform daily reset
CREATE OR REPLACE FUNCTION public.check_and_reset_daily() RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER -- Runs as owner (admin) to bypass RLS on profiles update if needed
    AS $$
DECLARE v_last_reset TEXT;
v_today TEXT;
v_current_hour INTEGER;
BEGIN v_today := to_char(now(), 'YYYY-MM-DD');
v_current_hour := EXTRACT(
    HOUR
    FROM now() AT TIME ZONE 'Asia/Seoul'
);
-- KST 22:00
-- Only run if it's past 22:00 KST
IF v_current_hour < 22 THEN RETURN FALSE;
END IF;
-- Check last reset date
SELECT value INTO v_last_reset
FROM public.system_state
WHERE key = 'last_daily_reset';
-- If already reset today, do nothing
IF v_last_reset = v_today THEN RETURN FALSE;
END IF;
-- Perform Reset
-- 1. Reset Games Played
UPDATE public.profiles
SET games_played_today = 0;
-- 2. Clear Queue (Deactivate all)
UPDATE public.queue
SET is_active = false
WHERE is_active = true;
-- 3. Update System State
INSERT INTO public.system_state (key, value, updated_at)
VALUES ('last_daily_reset', v_today, now()) ON CONFLICT (key) DO
UPDATE
SET value = EXCLUDED.value,
    updated_at = now();
RETURN TRUE;
END;
$$;
GRANT EXECUTE ON FUNCTION public.check_and_reset_daily() TO authenticated,
    anon;