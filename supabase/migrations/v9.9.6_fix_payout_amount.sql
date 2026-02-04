-- ============================================================================
-- V9.9.6 HOTFIX - Fix betting payout_amount not being recorded
-- Date: 2026-02-04
-- ============================================================================
-- ISSUE: WIN shows (+0) because payout_amount was never set in settle_match_bets
-- SOLUTION: Update payout_amount when settling bets
-- ============================================================================
DROP FUNCTION IF EXISTS settle_match_bets(UUID, TEXT);
CREATE OR REPLACE FUNCTION settle_match_bets(p_match_id UUID, p_winner_team TEXT) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_bet RECORD;
v_winnings INTEGER;
v_settled_count INTEGER := 0;
BEGIN RAISE NOTICE '[settle_match_bets] Starting: match=%, winner=%',
p_match_id,
p_winner_team;
FOR v_bet IN
SELECT *
FROM bets
WHERE match_id = p_match_id
    AND result IN ('OPEN', 'LOCKED') FOR
UPDATE LOOP RAISE NOTICE '[settle_match_bets] Processing bet: id=%, pick=%, amount=%, odds=%',
    v_bet.id,
    v_bet.pick_team,
    v_bet.amount,
    v_bet.odds_at_bet;
IF p_winner_team = 'DRAW' THEN -- DRAW: Return original bet
UPDATE bets
SET result = 'DRAW',
    payout_amount = v_bet.amount -- ✨ FIX: Record payout
WHERE id = v_bet.id;
UPDATE profiles
SET rally_point = rally_point + v_bet.amount
WHERE id = v_bet.user_id;
v_settled_count := v_settled_count + 1;
ELSIF p_winner_team = v_bet.pick_team THEN -- WON: Calculate winnings based on odds
v_winnings := FLOOR(v_bet.amount * COALESCE(v_bet.odds_at_bet, 1.5));
UPDATE bets
SET result = 'WON',
    payout_amount = v_winnings -- ✨ FIX: Record payout
WHERE id = v_bet.id;
UPDATE profiles
SET rally_point = rally_point + v_winnings
WHERE id = v_bet.user_id;
v_settled_count := v_settled_count + 1;
RAISE NOTICE '[settle_match_bets] WON: user=%, payout=%',
v_bet.user_id,
v_winnings;
ELSE -- LOST: No payout
UPDATE bets
SET result = 'LOST',
    payout_amount = 0 -- ✨ FIX: Explicitly set to 0
WHERE id = v_bet.id;
v_settled_count := v_settled_count + 1;
END IF;
END LOOP;
RAISE NOTICE '[settle_match_bets] Complete: settled=%',
v_settled_count;
RETURN v_settled_count;
END;
$$;
GRANT EXECUTE ON FUNCTION settle_match_bets(UUID, TEXT) TO authenticated;
-- ============================================================================
-- VERIFICATION: After running, test betting flow:
-- 1. Place bet on a match
-- 2. Finish match with your team winning
-- 3. Check bets table: payout_amount should be set
-- 4. BettingModal should show WIN (+actual amount)
-- ============================================================================