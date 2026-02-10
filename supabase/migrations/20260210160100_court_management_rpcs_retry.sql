-- ========================================================================
-- V9.7.2 Court Management RPCs
-- Purpose: Strict RPC Model - Replace client-side direct writes
-- ========================================================================
-- 1. Create Match RPC
CREATE OR REPLACE FUNCTION public.create_match(
    p_court_name TEXT,
    p_player_ids UUID [],
    p_match_category TEXT
  ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match_id UUID;
v_player_count INT;
BEGIN v_player_count := array_length(p_player_ids, 1);
IF v_player_count NOT IN (2, 4) THEN RETURN jsonb_build_object('error', 'INVALID_PLAYER_COUNT');
END IF;
IF p_match_category NOT IN ('SINGLES', 'MEN_D', 'WOMEN_D', 'MIXED') THEN RETURN jsonb_build_object('error', 'INVALID_CATEGORY');
END IF;
INSERT INTO public.matches (
    court_name,
    status,
    match_category,
    player_1,
    player_2,
    player_3,
    player_4,
    created_at
  )
VALUES (
    p_court_name,
    'DRAFT',
    p_match_category,
    p_player_ids [1],
    CASE
      WHEN v_player_count = 4 THEN p_player_ids [2]
      ELSE NULL
    END,
    CASE
      WHEN v_player_count = 4 THEN p_player_ids [3]
      ELSE p_player_ids [2]
    END,
    CASE
      WHEN v_player_count = 4 THEN p_player_ids [4]
      ELSE NULL
    END,
    NOW()
  )
RETURNING id INTO v_match_id;
DELETE FROM public.queue
WHERE player_id = ANY(p_player_ids)
  AND is_active = true;
RETURN jsonb_build_object('success', true, 'match_id', v_match_id);
END;
$$;
-- 2. Start Match RPC
CREATE OR REPLACE FUNCTION public.start_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
BEGIN
SELECT * INTO v_match
FROM public.matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status != 'DRAFT' THEN RETURN jsonb_build_object('error', 'MATCH_NOT_DRAFT');
END IF;
UPDATE public.matches
SET status = 'PLAYING',
  start_time = NOW(),
  betting_closes_at = NOW() + INTERVAL '5 minutes'
WHERE id = p_match_id;
RETURN jsonb_build_object('success', true);
END;
$$;
-- 3. Cancel Match RPC
CREATE OR REPLACE FUNCTION public.cancel_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
v_player_ids UUID [];
BEGIN
SELECT * INTO v_match
FROM public.matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status NOT IN ('DRAFT', 'SCORING') THEN RETURN jsonb_build_object('error', 'CANNOT_CANCEL');
END IF;
v_player_ids := ARRAY [v_match.player_1, v_match.player_2, v_match.player_3, v_match.player_4];
v_player_ids := array_remove(v_player_ids, NULL);
INSERT INTO public.queue (player_id, priority_score, joined_at, is_active)
SELECT unnest(v_player_ids),
  1000,
  NOW(),
  true ON CONFLICT (player_id) DO
UPDATE
SET is_active = true,
  joined_at = NOW();
DELETE FROM public.matches
WHERE id = p_match_id;
RETURN jsonb_build_object('success', true);
END;
$$;
-- 4. Swap Player RPC
CREATE OR REPLACE FUNCTION public.swap_player(
    p_match_id UUID,
    p_old_player_id UUID,
    p_new_player_id UUID
  ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
v_col TEXT;
BEGIN
SELECT * INTO v_match
FROM public.matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status != 'DRAFT' THEN RETURN jsonb_build_object('error', 'MATCH_NOT_DRAFT');
END IF;
IF v_match.player_1 = p_old_player_id THEN v_col := 'player_1';
ELSIF v_match.player_2 = p_old_player_id THEN v_col := 'player_2';
ELSIF v_match.player_3 = p_old_player_id THEN v_col := 'player_3';
ELSIF v_match.player_4 = p_old_player_id THEN v_col := 'player_4';
ELSE RETURN jsonb_build_object('error', 'PLAYER_NOT_IN_MATCH');
END IF;
EXECUTE format(
  'UPDATE public.matches SET %I = $1 WHERE id = $2',
  v_col
) USING p_new_player_id,
p_match_id;
DELETE FROM public.queue
WHERE player_id = p_new_player_id
  AND is_active = true;
IF p_old_player_id IS NOT NULL THEN
INSERT INTO public.queue (player_id, priority_score, joined_at, is_active)
VALUES (p_old_player_id, 1000, NOW(), true) ON CONFLICT (player_id) DO
UPDATE
SET is_active = true,
  joined_at = NOW();
END IF;
RETURN jsonb_build_object('success', true);
END;
$$;
-- Grant permissions
GRANT EXECUTE ON FUNCTION public.create_match TO authenticated,
  service_role;
GRANT EXECUTE ON FUNCTION public.start_match TO authenticated,
  service_role;
GRANT EXECUTE ON FUNCTION public.cancel_match TO authenticated,
  service_role;
GRANT EXECUTE ON FUNCTION public.swap_player TO authenticated,
  service_role;
-- 5. End Match RPC (PLAYING → SCORING)
CREATE OR REPLACE FUNCTION public.end_match(p_match_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_match RECORD;
BEGIN
SELECT * INTO v_match
FROM public.matches
WHERE id = p_match_id FOR
UPDATE;
IF v_match IS NULL THEN RETURN jsonb_build_object('error', 'MATCH_NOT_FOUND');
END IF;
IF v_match.status != 'PLAYING' THEN RETURN jsonb_build_object('error', 'MATCH_NOT_PLAYING');
END IF;
UPDATE public.matches
SET status = 'SCORING'
WHERE id = p_match_id;
RETURN jsonb_build_object('success', true);
END;
$$;
-- 6. Report Score RPC (for transition with metadata)
CREATE OR REPLACE FUNCTION public.report_score(
    p_match_id UUID,
    p_winner_team TEXT,
    p_match_type TEXT
  ) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$ BEGIN IF p_winner_team NOT IN ('TEAM_1', 'TEAM_2', 'DRAW') THEN RETURN jsonb_build_object('error', 'INVALID_WINNER');
END IF;
IF p_match_type NOT IN ('REGULAR', 'TOURNAMENT') THEN RETURN jsonb_build_object('error', 'INVALID_TYPE');
END IF;
UPDATE public.matches
SET winner_team = p_winner_team,
  match_type = p_match_type
WHERE id = p_match_id;
RETURN jsonb_build_object('success', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.end_match TO authenticated,
  service_role;
GRANT EXECUTE ON FUNCTION public.report_score(UUID, TEXT, TEXT) TO authenticated,
  service_role;