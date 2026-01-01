import { supabase } from '../lib/supabase';

export type Bet = {
    id: string;
    match_id: string;
    pick_team: 'TEAM_1' | 'TEAM_2';
    amount: number;
    odds_at_bet: number;
    result: 'PENDING' | 'WIN' | 'LOSE' | 'DRAW' | 'CANCELLED';
    created_at: string;
    match?: any; // Joined match data
};

export const BettingSystem = {
    /**
     * Calculate decimal odds based on ELO difference.
     * Uses a logistic function probability + margin.
     * P(A) = 1 / (1 + 10^((Rb-Ra)/400))
     * Odds = (1 / P(A)) * MarginFactor (e.g. 0.95 for house edge)
     */
    calculateOdds: (eloTeam1: number, eloTeam2: number): { team1: number, team2: number } => {
        const RA = eloTeam1 || 1200;
        const RB = eloTeam2 || 1200;

        const probTeam1 = 1 / (1 + Math.pow(10, (RB - RA) / 400));
        const probTeam2 = 1 - probTeam1;

        // Apply slight House Edge (Return 95% of pool theoretic)
        // Odds = 0.95 / Prob
        // Clamp min/max odds to avoid 1.01 or 100.0
        const clamp = (o: number) => Math.min(Math.max(Number(o.toFixed(2)), 1.1), 10.0);

        return {
            team1: clamp(0.95 / probTeam1),
            team2: clamp(0.95 / probTeam2)
        };
    },

    /**
     * Fetch user's betting history
     */
    fetchMyBets: async (userId: string) => {
        const { data, error } = await supabase
            .from('bets')
            .select(`
                *,
                match:matches!match_id (
                    player_1, player_2, player_3, player_4,
                    winner_team, score_team1, score_team2, status
                )
            `)
            .eq('user_id', userId)
            .order('created_at', { ascending: false });

        if (error) throw error;
        // Need to fetch player names separately or assume Client has them?
        // For efficiency, we just return data and let UI resolve names if needed.
        return data as Bet[];
    },

    /**
     * Place a bet using RPC for atomic transaction
     */
    placeBet: async (matchId: string, userId: string, pick: 'TEAM_1' | 'TEAM_2', amount: number, odds: number) => {
        const { data, error } = await supabase.rpc('place_bet', {
            p_match_id: matchId,
            p_user_id: userId,
            p_pick_team: pick,
            p_amount: amount,
            p_odds: odds
        });

        if (error) throw error;
        return data; // { success: true, new_balance: 1000 }
    }
};
