-- ========================================================================
-- 20260106_standardize_schema.sql
-- ========================================================================
-- PROJECT AUTHORITY: Standardization & Cleanup
-- 1. Recreate 'elo_history' with strict naming (created_at).
-- 2. Ensure consistency across all tables.
-- ========================================================================
-- 1. ELO HISTORY (Recreate for Purity)
DROP TABLE IF EXISTS public.elo_history;
CREATE TABLE public.elo_history (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    player_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    match_type VARCHAR NOT NULL,
    -- 'MEN_D', 'WOMEN_D', 'MIXED', 'SINGLES'
    elo_score INT NOT NULL,
    -- The score AFTER the update
    delta INT NOT NULL,
    -- The change (+15, -12)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() -- STANDARD NAME
);
-- Enable RLS
ALTER TABLE public.elo_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Elo history viewable by everyone" ON public.elo_history FOR
SELECT USING (true);
-- 2. REFRESH RPC (Ensure it uses the correct columns)
-- We need to replace the function to ensure it targets 'created_at' matching default
-- (The previous RPC didn't specify the timestamp column, so it used default, which is good.
-- But we'll replace it just to be 100% sure it aligns with the dropped table).
CREATE OR REPLACE FUNCTION public.process_match_completion(
        p_match_id UUID,
        p_reporter_id UUID,
        p_team1_score INT,
        p_team2_score INT,
        p_elo_updates JSONB,
        p_queue_inserts JSONB,
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
-- Apply ELO Updates
FOR v_item IN
SELECT *
FROM jsonb_array_elements(p_elo_updates) LOOP
UPDATE public.profiles
SET elo_mixed_doubles = COALESCE(elo_mixed_doubles, 1200) + (v_item->>'delta')::INT,
    games_played_today = COALESCE(games_played_today, 0) + 1
WHERE id = (v_item->>'id')::UUID;
-- Insert History (Standardized)
INSERT INTO public.elo_history (
        player_id,
        match_type,
        elo_score,
        delta,
        created_at
    )
VALUES (
        (v_item->>'id')::UUID,
        v_match.match_category,
        (
            SELECT elo_mixed_doubles
            FROM public.profiles
            WHERE id =(v_item->>'id')::UUID
        ),
        (v_item->>'delta')::INT,
        NOW()
    );
END LOOP;
-- Upsert Queue
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
NOTIFY pgrst,
'reload schema';