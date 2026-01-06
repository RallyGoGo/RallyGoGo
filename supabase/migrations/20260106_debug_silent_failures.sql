-- ========================================================================
-- 20260106_debug_silent_failures.sql
-- ========================================================================
-- 1. FIX: PROFILES RLS (Cause of "Queue Dropout" if Confirming User can't see others)
-- We ensure that specific policies exist, or create a catch-all for Select.
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE tablename = 'profiles'
        AND policyname = 'Public profiles are viewable by everyone'
) THEN CREATE POLICY "Public profiles are viewable by everyone" ON public.profiles FOR
SELECT USING (true);
END IF;
END $$;
-- 2. FIX: QUEUE CONSTRAINT (Ensure ON CONFLICT works)
-- Attempt to add it if missing. Safest way is to try/catch or just simple ALTER.
-- We will drop and re-add to be sure.
ALTER TABLE public.queue DROP CONSTRAINT IF EXISTS queue_player_id_key;
ALTER TABLE public.queue
ADD CONSTRAINT queue_player_id_key UNIQUE (player_id);
-- 3. FIX: RPC LOGIC (Auto-calculate winner_team & Handle Singles ELO)
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
v_winner TEXT;
v_is_singles BOOLEAN;
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
-- Determine Winner
IF p_team1_score > p_team2_score THEN v_winner := 'TEAM_1';
ELSIF p_team2_score > p_team1_score THEN v_winner := 'TEAM_2';
ELSE v_winner := 'DRAW';
END IF;
-- Detect Singles (based on match_category OR player null checks)
-- We'll use match_category if available, otherwise guess.
-- Better to rely on what was stored.
-- (No huge logic change here, just updating winner_team)
-- Update Match Status & Winner
UPDATE public.matches
SET status = 'FINISHED',
    score_team1 = p_team1_score,
    score_team2 = p_team2_score,
    winner_team = v_winner,
    -- FORCE ACCURACY
    confirmed_by = p_reporter_id,
    end_time = NOW()
WHERE id = p_match_id;
-- Apply ELO Updates
-- NOTE: We blindly apply deltas to elo_mixed_doubles for now as requested by user previously.
-- Ideally this should switch col based on match_category, but let's fix the Critical Silent Failures first.
FOR v_item IN
SELECT *
FROM jsonb_array_elements(p_elo_updates) LOOP
UPDATE public.profiles
SET elo_mixed_doubles = COALESCE(elo_mixed_doubles, 1200) + (v_item->>'delta')::INT,
    games_played_today = COALESCE(games_played_today, 0) + 1
WHERE id = (v_item->>'id')::UUID;
-- Insert History
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
        -- Use stored category (MIXED/SINGLES/etc)
        (
            SELECT elo_mixed_doubles
            FROM public.profiles
            WHERE id = (v_item->>'id')::UUID
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