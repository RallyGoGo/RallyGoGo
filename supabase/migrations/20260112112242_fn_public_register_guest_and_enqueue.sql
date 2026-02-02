CREATE OR REPLACE FUNCTION public.register_guest_and_enqueue(p_name text, p_ntrp numeric, p_gender text, p_departure_time timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_target_name TEXT;
v_player_id UUID;
v_reused BOOLEAN;
v_initial_elo INT;
v_priority_score INT;
v_queue_exists BOOLEAN;
BEGIN -- 1. Input Sanitization & Setup
v_target_name := TRIM(p_name) || ' (G)';
-- ELO Policy (Must match ratingPolicy.ts)
v_initial_elo := CASE
    WHEN p_ntrp = 1.0 THEN 600
    WHEN p_ntrp = 1.5 THEN 800
    WHEN p_ntrp = 2.0 THEN 1000
    WHEN p_ntrp = 2.5 THEN 1100
    WHEN p_ntrp = 3.0 THEN 1200
    WHEN p_ntrp = 3.5 THEN 1400
    WHEN p_ntrp = 4.0 THEN 1600
    WHEN p_ntrp = 4.5 THEN 1800
    WHEN p_ntrp = 5.0 THEN 2000
    WHEN p_ntrp = 5.5 THEN 2200
    WHEN p_ntrp = 6.0 THEN 2400
    WHEN p_ntrp >= 7.0 THEN 2800
    ELSE 1200 -- Default Fallback
END;
-- Priority Policy (NTRP + 0.25 Boost)
v_priority_score := FLOOR(5000 + ((p_ntrp + 0.25) * 100));
-- 2. Check Existing Guest
SELECT id INTO v_player_id
FROM public.profiles
WHERE name = v_target_name
    AND is_guest = true
LIMIT 1;
IF v_player_id IS NOT NULL THEN -- REUSE
v_reused := true;
ELSE -- CREATE NEW
v_reused := false;
v_player_id := gen_random_uuid();
INSERT INTO public.profiles (
        id,
        email,
        name,
        ntrp,
        gender,
        is_guest,
        role,
        elo_mixed_doubles,
        elo_men_doubles,
        elo_women_doubles,
        elo_singles,
        games_played_today,
        created_at
    )
VALUES (
        v_player_id,
        'guest_' || substring(
            v_player_id::text
            from 1 for 8
        ) || '@temp.temp',
        v_target_name,
        p_ntrp,
        -- RAW NTRP
        p_gender,
        true,
        'member',
        v_initial_elo,
        -- Deterministic ELO
        v_initial_elo,
        v_initial_elo,
        v_initial_elo,
        0,
        NOW()
    );
END IF;
-- 3. Queue Handling
-- Check if already active
SELECT EXISTS (
        SELECT 1
        FROM public.queue
        WHERE player_id = v_player_id
            AND is_active = true
    ) INTO v_queue_exists;
IF NOT v_queue_exists THEN
INSERT INTO public.queue (
        player_id,
        joined_at,
        is_active,
        priority_score,
        departure_time
    )
VALUES (
        v_player_id,
        NOW(),
        true,
        v_priority_score,
        p_departure_time
    );
END IF;
-- 4. Return Result
RETURN jsonb_build_object(
    'player_id',
    v_player_id,
    'reused',
    v_reused,
    'initial_elo',
    v_initial_elo
);
END;
$function$;

