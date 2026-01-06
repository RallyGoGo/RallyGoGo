-- ========================================================================
-- 20260106_rebuild_v3_5.sql
-- ========================================================================
-- PROJECT REBOOT: V3.5 Hybrid Architecture (Atomic Core)
-- 1. Cleanup legacy triggers and constraints
-- 2. Create Audit Log (match_events)
-- 3. Implement 'process_match_completion' RPC (Single Source of Truth)
-- ========================================================================
-- 1. CLEANUP: Drop ALL old triggers, functions, and constraints
DROP TRIGGER IF EXISTS on_match_finish ON public.matches;
DROP FUNCTION IF EXISTS public.handle_match_finish();
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_id_fkey;
-- Allow Guests
-- 2. SCHEMA: Audit Log Table (for V3.5)
CREATE TABLE IF NOT EXISTS public.match_events (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    client_request_id UUID UNIQUE,
    -- Idempotency Key
    match_id UUID NOT NULL,
    event_type VARCHAR NOT NULL,
    version INT DEFAULT 1,
    payload JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
-- Enable RLS for match_events
ALTER TABLE public.match_events ENABLE ROW LEVEL SECURITY;
-- 3. RPC: Master Transaction Function (One-Stop Shop)
CREATE OR REPLACE FUNCTION public.process_match_completion(
        p_match_id UUID,
        p_reporter_id UUID,
        p_team1_score INT,
        p_team2_score INT,
        p_elo_updates JSONB,
        -- Calculated by Client: [{"id": uuid, "delta": int}]
        p_queue_inserts JSONB,
        -- Calculated by Client: [{"player_id": uuid, "priority": int}]
        p_client_request_id UUID
    ) RETURNS JSONB AS $$
DECLARE v_match RECORD;
v_item JSONB;
BEGIN -- Idempotency Check
IF EXISTS (
    SELECT 1
    FROM public.match_events
    WHERE client_request_id = p_client_request_id
) THEN RETURN jsonb_build_object('success', true, 'message', 'Already processed.');
END IF;
-- Lock & Validate
SELECT * INTO v_match
FROM public.matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match.status = 'FINISHED' THEN RETURN jsonb_build_object(
    'success',
    false,
    'message',
    'Match already finished.'
);
END IF;
-- Update Match Status
UPDATE public.matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    confirmed_by = p_reporter_id,
    end_time = NOW()
WHERE id = p_match_id;
-- Apply ELO Updates (Trusting Client Calculation)
FOR v_item IN
SELECT *
FROM jsonb_array_elements(p_elo_updates) LOOP
UPDATE public.profiles
SET elo_mixed_doubles = COALESCE(elo_mixed_doubles, 1200) + (v_item->>'delta')::INT,
    games_played_today = COALESCE(games_played_today, 0) + 1
WHERE id = (v_item->>'id')::UUID;
-- Insert History with Safety Check on existing profiles
INSERT INTO public.elo_history (player_id, match_type, elo_score, delta)
VALUES (
        (v_item->>'id')::UUID,
        v_match.match_category,
        (
            SELECT elo_mixed_doubles
            FROM public.profiles
            WHERE id =(v_item->>'id')::UUID
        ),
        (v_item->>'delta')::INT
    );
END LOOP;
-- Upsert Queue (Return to waiting list)
FOR v_item IN
SELECT *
FROM jsonb_array_elements(p_queue_inserts) LOOP
INSERT INTO public.queue (player_id, joined_at, is_active, priority_score)
VALUES (
        (v_item->>'player_id')::UUID,
        NOW(),
        TRUE,
        (v_item->>'priority')::NUMERIC
    ) ON CONFLICT (player_id) DO
UPDATE
SET joined_at = NOW(),
    is_active = TRUE,
    priority_score = EXCLUDED.priority_score;
END LOOP;
-- Log Event
INSERT INTO public.match_events (client_request_id, match_id, event_type, payload)
VALUES (
        p_client_request_id,
        p_match_id,
        'FINISHED',
        jsonb_build_object(
            'scores',
            jsonb_build_array(p_team1_score, p_team2_score)
        )
    );
RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- 4. REFRESH SCHEMA CACHE
NOTIFY pgrst,
'reload schema';