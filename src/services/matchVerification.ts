import { supabase } from '../lib/supabase';
import { v4 as uuidv4 } from 'uuid';
import { calculateMatchDeltas, PlayerInput } from '../utils/glicko';
import { Database } from '../types/supabase';

// Helper types
type Profile = Database['public']['Tables']['profiles']['Row'];
type Match = Database['public']['Tables']['matches']['Row'];

// 1. Report Match Result
export const reportMatchResult = async (matchId: string, scoreTeam1: number, scoreTeam2: number, reporterId: string) => {
    const { data, error } = await supabase
        .from('matches')
        .update({
            score_team1: scoreTeam1,
            score_team2: scoreTeam2,
            reported_by: reporterId,
            status: 'PENDING',
            court_name: null, // INSTANT RELEASE
            end_time: new Date().toISOString()
        })
        .eq('id', matchId)
        .select()
        .maybeSingle();

    if (error) throw error;
    return data;
};

// 2. Confirm Match Result (V3.5)
export const confirmMatchResult = async (matchId: string, confirmerId: string, isAdmin: boolean = false) => {
    // A. FETCH MATCH
    const { data: match, error: matchError } = await supabase
        .from('matches')
        .select('*')
        .eq('id', matchId)
        .maybeSingle();

    if (matchError || !match) throw new Error('Match not found');
    if (match.status === 'FINISHED') throw new Error('Match already finished');

    const m = match as Match; // Cast to Strict Type

    // B. SECURITY CHECK
    const team1Ids = [m.player_1, m.player_2].filter(Boolean) as string[];
    const team2Ids = [m.player_3, m.player_4].filter(Boolean) as string[];
    const allPlayerIds = [...team1Ids, ...team2Ids];

    if (!isAdmin) {
        if (!m.reported_by) throw new Error('Match not reported');
        if (!allPlayerIds.includes(confirmerId)) throw new Error('Permission denied');
    }

    // C. FETCH PROFILES
    const { data: profiles, error: pError } = await supabase
        .from('profiles')
        .select('*') // Select all for simplicity
        .in('id', allPlayerIds);

    if (pError || !profiles) throw new Error('Failed to load profiles');
    const getP = (id: string) => (profiles as Profile[]).find(p => p.id === id);
    console.log(`🔍 Profiles Loaded: ${profiles?.length || 0} / ${allPlayerIds.length} requested.`);
    if (profiles?.length !== allPlayerIds.length) {
        console.warn("⚠️ Warning: Some profiles could not be loaded. Check RLS policies.");
    }

    // D. CALCULATE LOGIC
    // ELO
    const toInput = (ids: string[]): PlayerInput[] => ids.map(id => {
        const p = getP(id);
        // Default to 1200 if missing
        return {
            id,
            rating: p?.elo_mixed_doubles ?? 1200,
            isGuest: p?.is_guest ?? false
        };
    });

    const eloUpdates = calculateMatchDeltas(
        toInput(team1Ids),
        toInput(team2Ids),
        m.score_team1 || 0,
        m.score_team2 || 0
    );

    // QUEUE
    const queueInserts = allPlayerIds.map(id => {
        const p = getP(id);
        if (!p) return null;

        const nextGameCount = (p.games_played_today || 0) + 1;
        // Priority Algo: 10000 - (Games * 1000) + (NTRP * 10) + (Guest Bonus)
        const baseNtrp = p.ntrp || 3.0;
        const guestBonus = p.is_guest ? 100 : 0;

        // Ensure priority is calculated as a valid, finite number.
        let priority = 10000 - (nextGameCount * 1000) + (baseNtrp * 10) + guestBonus;
        if (!Number.isFinite(priority)) priority = 5000; // Fallback if calculation fails

        return { player_id: id, priority: Math.floor(priority) };
    }).filter((item): item is { player_id: string; priority: number } => item !== null);

    // E. EXECUTE REMOTE
    console.log("🚀 Sending Queue Payload:", queueInserts);
    const requestId = uuidv4();
    const { data: rpcRes, error: rpcError } = await supabase.rpc('process_match_completion', {
        p_match_id: matchId,
        p_reporter_id: confirmerId, // Confirmer signs the transaction
        p_team1_score: m.score_team1,
        p_team2_score: m.score_team2,
        p_elo_updates: eloUpdates,
        p_queue_inserts: queueInserts,
        p_client_request_id: requestId
    });

    if (rpcError) throw rpcError;
    return { success: true, message: 'Tx Complete', debug: rpcRes };
};

export const rejectMatchResult = async (matchId: string, rejectorId: string) => {
    const { error } = await supabase
        .from('matches')
        .update({ status: 'DISPUTED', confirmed_by: null })
        .eq('id', matchId);
    if (error) throw error;
    return { success: true };
};

export const adminForceConfirm = async (matchId: string, adminId: string) => {
    return await confirmMatchResult(matchId, adminId, true);
};