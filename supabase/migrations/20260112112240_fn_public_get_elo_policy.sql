CREATE OR REPLACE FUNCTION public.get_elo_policy(p_is_guest boolean)
 RETURNS TABLE(k_factor integer, multiplier numeric)
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$ BEGIN RETURN QUERY
SELECT 32,
    -- Standard K-Factor
    CASE
        WHEN p_is_guest THEN 1.5
        ELSE 1.0
    END;
-- Guest Multiplier (1.5x)
END;
$function$;

