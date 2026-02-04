import { useEffect, useState, useMemo } from 'react';
import { supabase } from '../lib/supabase';
// Services
// Services
import { calculatePriorityScore, generateV83Match } from '../services/matchingSystem';

// V3 Helper: Extract error from RPC JSON response
type RpcResponse = { success?: boolean; error?: string; message?: string } | null;
const getRpcError = (data: unknown): string | null => {
    if (data && typeof data === 'object' && 'error' in data) {
        return (data as RpcResponse)?.error || null;
    }
    return null;
};

// Local Types - Match Row from V3 Schema
type Match = {
    id: string;
    created_at: string | null;
    player_1: string | null;
    player_2: string | null;
    player_3: string | null;
    player_4: string | null;
    status: string | null;
    score_team1: number | null;
    score_team2: number | null;
    winner_team: string | null;
    match_category: string | null;
    match_type: string | null;
    reported_by: string | null;
    confirmed_by: string | null;
    start_time: string | null;
    end_time: string | null;
    betting_closes_at: string | null;
    court_name: string | null;
    mvp_voting_open: boolean | null;
    corrections_count: number | null;
};

// Local Profile type
type Profile = {
    id: string;
    name: string | null;
    gender: string | null;
    ntrp: number | null;
    elo_mens_doubles: number | null;
    elo_womens_doubles: number | null;
    elo_mixed_doubles: number | null;
    elo_singles: number | null;
    is_guest: boolean | null;
    games_played_today: number | null;
};

// Queue Type (Custom combination for UI)
// Aligned with matchingSystem.QueueItem
type QueueCandidate = {
    player_id: string;
    priority_score: number;
    joined_at: string;
    departure_time: string;
    profiles: Profile | null; // Safe Fetch
    finalScore: number;
    waitMinutes: number; // Required by matchingSystem.QueueItem
};

// Extends Match with Player Names for UI
interface EnrichedMatch extends Match {
    p1_name: string;
    p2_name: string;
    p3_name: string;
    p4_name: string;
}

import MatchReviewModal from './MatchReviewModal';

// User type for props - only need id for checking participation
type UserProp = { id: string };

export default function CourtBoard({ user }: { user: UserProp | null }) {
    const [courts, setCourts] = useState<string[]>(['Court A', 'Court B']);
    const [activeMatches, setActiveMatches] = useState<EnrichedMatch[]>([]);
    const [loading, setLoading] = useState(false);

    // Score State
    const [scores, setScores] = useState<{ [matchId: string]: { t1: string, t2: string } }>({});

    // Modals
    const [isSwapModalOpen, setIsSwapModalOpen] = useState(false);
    const [swapTarget, setSwapTarget] = useState<{ matchId: string; col: string; oldName: string; oldId: string } | null>(null);
    const [isManualModalOpen, setIsManualModalOpen] = useState(false);
    const [manualTargetCourt, setManualTargetCourt] = useState<string | null>(null);
    const [selectedManualPlayers, setSelectedManualPlayers] = useState<QueueCandidate[]>([]);
    const [queueCandidates, setQueueCandidates] = useState<QueueCandidate[]>([]);
    const [searchTerm, setSearchTerm] = useState('');

    // [New] Match Review Modal State
    const [matchReviewTarget, setMatchReviewTarget] = useState<EnrichedMatch | null>(null);

    // [New] PENDING matches for notification (separate state)
    const [pendingMatches, setPendingMatches] = useState<EnrichedMatch[]>([]);

    // [New] Notification Banner Logic - Show PENDING matches requiring confirmation
    const pendingReviewMatch = useMemo(() => user ? pendingMatches.find(m =>
        m.status === 'PENDING' &&
        ([m.player_1, m.player_2, m.player_3, m.player_4].includes(user.id))
    ) : null, [user, pendingMatches]);

    // Check if I am the opponent (needs to confirm) or reporter (waiting)
    const isPendingOpponent = pendingReviewMatch && user && pendingReviewMatch.reported_by !== user.id;

    // Fetch PENDING matches for notification banner
    const fetchPendingMatches = async () => {
        // Note: PENDING status may not be in TypeScript types, use 'as' workaround
        const { data } = await supabase
            .from('matches')
            .select('*')
            .eq('status', 'PENDING' as 'DRAFT'); // TypeScript workaround for PENDING enum

        if (data && data.length > 0) {
            // Get player names
            const allPlayerIds = new Set<string>();
            data.forEach((m) => {
                if (m.player_1) allPlayerIds.add(m.player_1);
                if (m.player_2) allPlayerIds.add(m.player_2);
                if (m.player_3) allPlayerIds.add(m.player_3);
                if (m.player_4) allPlayerIds.add(m.player_4);
            });

            const { data: profiles } = await supabase
                .from('profiles')
                .select('*')
                .in('id', Array.from(allPlayerIds));

            const profileMap = new Map((profiles || []).map((p) => [p.id, p.name]));

            const enriched = data.map((m) => ({
                ...m,
                p1_name: (m.player_1 ? profileMap.get(m.player_1) : '') || 'Unknown',
                p2_name: (m.player_2 ? profileMap.get(m.player_2) : '') || 'Unknown',
                p3_name: (m.player_3 ? profileMap.get(m.player_3) : '') || 'Unknown',
                p4_name: (m.player_4 ? profileMap.get(m.player_4) : '') || 'Unknown',
            })) as unknown as EnrichedMatch[];

            setPendingMatches(enriched);
        } else {
            setPendingMatches([]);
        }
    };

    useEffect(() => {
        fetchMatches();
        fetchPendingMatches();
        const channel = supabase.channel('public:matches')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => {
                fetchMatches();
                fetchPendingMatches();
            })
            .subscribe();
        return () => { supabase.removeChannel(channel); };
    }, []);


    // --- DATA FETCHING (SAFE 406 PREVENTION) ---
    // V9.9.6: Exclude PENDING matches - court is released once score is submitted
    const fetchMatches = async () => {
        // Explicitly cast or allow inference if supabase client is typed (which we will verify next)
        const { data } = await supabase
            .from('matches')
            .select('*')
            .in('status', ['DRAFT', 'PLAYING', 'SCORING']); // Only show matches that are actively using the court

        const matchData = data as EnrichedMatch[] | null;

        if (!matchData) return;

        const allPlayerIds = new Set<string>();
        matchData.forEach((m) => {
            if (m.player_1) allPlayerIds.add(m.player_1);
            if (m.player_2) allPlayerIds.add(m.player_2);
            if (m.player_3) allPlayerIds.add(m.player_3);
            if (m.player_4) allPlayerIds.add(m.player_4);
        });

        if (allPlayerIds.size > 0) {
            const { data: profiles } = await supabase
                .from('profiles')
                .select('*')
                .in('id', Array.from(allPlayerIds));

            const profileMap = new Map((profiles || []).map((p) => [p.id, p.name]));

            const enriched = matchData.map((m) => ({
                ...m,
                p1_name: (m.player_1 ? profileMap.get(m.player_1) : '') || 'Unknown',
                p2_name: (m.player_2 ? profileMap.get(m.player_2) : '') || 'Unknown',
                p3_name: (m.player_3 ? profileMap.get(m.player_3) : '') || 'Unknown',
                p4_name: (m.player_4 ? profileMap.get(m.player_4) : '') || 'Unknown',
            })) as EnrichedMatch[];
            setActiveMatches(enriched);
        } else {
            // Need to cast the initial data if no players found
            const enriched = matchData.map((m) => ({
                ...m, p1_name: '', p2_name: '', p3_name: '', p4_name: ''
            })) as EnrichedMatch[];
            setActiveMatches(enriched);
        }
    };

    const getSmartSortedQueue = async () => {
        const { data } = await supabase
            .from('queue')
            .select(`*, profiles (*)`)
            .eq('is_active', true);

        // Safe type assertion for joined query result
        type QueueWithProfile = {
            player_id: string;
            priority_score: number;
            joined_at: string;
            departure_time: string;
            profiles: Profile | null;
        };
        const queueData = (data ?? []) as QueueWithProfile[];

        const scored = queueData.map((item) => ({
            ...item,
            priority_score: item.priority_score,
            finalScore: calculatePriorityScore(item),
            waitMinutes: 0 // Placeholder, calculated in matching
        }));
        return scored.sort((a, b) => b.finalScore - a.finalScore) as QueueCandidate[];
    };

    // --- COURT MANAGEMENT ---
    const handleAddCourt = () => {
        const nextChar = String.fromCharCode(65 + courts.length);
        setCourts([...courts, `Court ${nextChar}`]);
    };
    const handleRemoveCourt = (courtName: string) => {
        if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; }
        if (confirm(`🗑️ Remove ${courtName}?`)) setCourts(prev => prev.filter(c => c !== courtName));
    };

    // --- AUTO MATCHING ---
    const handleAutoMatch = async (courtName: string) => {
        if (loading) return;
        if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; }

        setLoading(true);
        try {
            const sortedList = await getSmartSortedQueue();
            const matchResult = generateV83Match(sortedList);

            if (!matchResult) {
                throw new Error("❌ Not enough players or no valid combination.");
            }

            const { matchType, playerIds } = matchResult;

            // V9.7.2: Strict RPC Model - create_match_draft
            const { data, error } = await supabase.rpc('create_match_draft', {
                p_player_ids: playerIds,
                p_match_type: matchType as 'MIXED' | 'MENS_DOUBLES' | 'WOMENS_DOUBLES' | 'SINGLES',
                p_court_name: courtName
            });
            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');
            fetchMatches();
        } catch (e: Error | unknown) { alert(e instanceof Error ? e.message : 'Unknown error'); }
        setLoading(false);
    };

    // --- MANUAL MATCHING (SINGLES + DOUBLES) ---
    const openManualModal = async (courtName: string) => {
        if (loading) return;
        if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; }
        setLoading(true);
        const sortedList = await getSmartSortedQueue();
        if (sortedList) {
            setQueueCandidates(sortedList);
            setManualTargetCourt(courtName);
            setSelectedManualPlayers([]);
            setSearchTerm('');
            setIsManualModalOpen(true);
        }
        setLoading(false);
    };

    const toggleManualSelection = (candidate: QueueCandidate) => {
        const isSelected = selectedManualPlayers.find(p => p.player_id === candidate.player_id);
        if (isSelected) {
            setSelectedManualPlayers(prev => prev.filter(p => p.player_id !== candidate.player_id));
        } else {
            if (selectedManualPlayers.length >= 4) return;
            setSelectedManualPlayers(prev => [...prev, candidate]);
        }
    };

    const confirmManualMatch = async () => {
        const count = selectedManualPlayers.length;
        if (!manualTargetCourt || (count !== 2 && count !== 4)) {
            alert("❌ Select 2 (Singles) or 4 (Doubles) players.");
            return;
        }
        if (loading) return;
        setLoading(true);
        try {
            const pIds = selectedManualPlayers.map(p => p.player_id);
            const isSingles = count === 2;

            // V9.7.2: Strict RPC Model - create_match_draft
            const { data, error } = await supabase.rpc('create_match_draft', {
                p_player_ids: pIds,
                p_match_type: isSingles ? 'SINGLES' : 'MIXED',
                p_court_name: manualTargetCourt
            });
            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');
            setIsManualModalOpen(false);
            setManualTargetCourt(null);
            setSelectedManualPlayers([]);
            fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Unknown error';
            alert("Error: " + msg);
        }
        setLoading(false);
    };

    // --- SWAP LOGIC ---
    const openSwapModal = async (matchId: string, col: string, oldName: string, oldId: string) => {
        if (loading) return;
        setLoading(true);
        const sortedList = await getSmartSortedQueue();
        if (sortedList) {
            setQueueCandidates(sortedList);
            setSwapTarget({ matchId, col, oldName, oldId });
            setSearchTerm('');
            setIsSwapModalOpen(true);
        }
        setLoading(false);
    };

    const handleExecuteSwap = async (candidate: QueueCandidate) => {
        if (!swapTarget) return;
        if (!confirm(`🔄 Swap with [${candidate.profiles?.name}]?`)) return;
        try {
            // Direct table update (swap_player RPC not defined in DB)
            const updateCol = swapTarget.col; // 'player_1', 'player_2', etc.
            const { error: updateError } = await supabase
                .from('matches')
                .update({ [updateCol]: candidate.player_id })
                .eq('id', swapTarget.matchId);
            if (updateError) throw updateError;

            // Return old player to queue (upsert with ignoreDuplicates)
            await supabase.from('queue').upsert({
                player_id: swapTarget.oldId,
                is_active: true,
                priority_score: 800 // Base re-queue priority
            }, { onConflict: 'player_id', ignoreDuplicates: true });

            // Remove new player from queue
            await supabase.from('queue').delete().eq('player_id', candidate.player_id);
            setIsSwapModalOpen(false);
            setSwapTarget(null);
            fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Swap failed';
            alert("Swap Error: " + msg);
        }
    };

    // --- GAME CONTROL ---
    const handleStartGame = async (matchId: string) => {
        try {
            // V9.7.2: Strict RPC Model
            const { data, error } = await supabase.rpc('start_match', { p_match_id: matchId });
            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');
            fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Start failed';
            alert("Start Error: " + msg);
        }
    };

    const handleEndGame = async (matchId: string) => {
        if (!confirm("Finish game?")) return;
        try {
            // V9.7.2: Strict RPC Model
            const { data, error } = await supabase.rpc('end_match', { p_match_id: matchId });
            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');
            fetchMatches();
        } catch (e: Error | unknown) { alert(e instanceof Error ? e.message : 'Unknown error'); }
    };

    const handleCancelMatch = async (matchId: string) => {
        if (!confirm("⚠️ Cancel match?")) return;
        setLoading(true);
        try {
            // V9.7.2: Strict RPC Model
            const { data, error } = await supabase.rpc('cancel_match', { p_match_id: matchId });
            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');
            fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Cancel failed';
            alert("Error: " + msg);
        }
        setLoading(false);
    };

    // --- SCORING & VERIFICATION (V3.5) ---
    const handleScoreChange = (matchId: string, team: 't1' | 't2', value: string) => {
        setScores(prev => ({ ...prev, [matchId]: { ...prev[matchId], [team]: value } }));
    };

    const handleSubmitScore = async (matchId: string) => {
        if (loading) return;
        const s = scores[matchId];
        if (!s || !s.t1 || !s.t2) { alert("점수를 입력해주세요"); return; }

        const s1 = parseInt(s.t1), s2 = parseInt(s.t2);
        const winner = s1 > s2 ? 'TEAM_1' : s2 > s1 ? 'TEAM_2' : 'DRAW';

        console.log('[CourtBoard] handleReportScore starting:', { matchId, s1, s2, winner });

        setLoading(true);
        try {
            // V9.7.2: Strict RPC Model - report_score with correct params
            const { data, error } = await supabase.rpc('report_score', {
                p_match_id: matchId,
                p_team1_score: s1,
                p_team2_score: s2,
                p_winner: winner
            });

            console.log('[CourtBoard] report_score RESPONSE:', { data, error });

            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');

            // V9.7.2: Strict RPC Model - report_score logic complete
            // Service call removed - RPC handles everything
            alert("✅ Reported! Waiting for confirmation.");
            fetchMatches();
        } catch (e: Error | unknown) {
            console.error('[CourtBoard] handleReportScore ERROR:', e);
            alert(e instanceof Error ? e.message : 'Unknown error');
        }
        setLoading(false);
    };

    const handleConfirmMatch = async (matchId: string) => {
        if (loading) return;
        if (!confirm("✅ Confirm result?")) return;
        if (!user) return alert("Login required");

        const match = activeMatches.find(m => m.id === matchId);
        if (!match) return;

        console.log('[CourtBoard] handleConfirmMatch starting:', {
            matchId,
            score_team1: match.score_team1,
            score_team2: match.score_team2,
            match_type: match.match_type,
            status: match.status
        });

        setLoading(true);
        try {
            const { data, error } = await supabase.rpc('finish_match_v2', {
                p_match_id: matchId,
                p_team1_score: match.score_team1 || 0,
                p_team2_score: match.score_team2 || 0,
                p_confirmation_type: 'NORMAL_CONFIRM'
            });

            console.log('[CourtBoard] finish_match_v2 FULL RESPONSE:', { data, error });

            if (error) {
                console.error('[CourtBoard] finish_match_v2 Supabase ERROR:', error);
                throw error;
            }

            // Check for logical error in JSON response
            type RpcResponse = { success?: boolean; error?: string; message?: string; bets_settled?: number; match_type?: string; sqlstate?: string };
            const rpcData = data as RpcResponse;

            console.log('[CourtBoard] finish_match_v2 parsed response:', {
                success: rpcData?.success,
                error: rpcData?.error,
                bets_settled: rpcData?.bets_settled,
                match_type: rpcData?.match_type,
                sqlstate: rpcData?.sqlstate,
                message: rpcData?.message
            });

            if (rpcData && !rpcData.success) {
                if (rpcData.error && rpcData.error !== 'ALREADY_FINISHED') {
                    throw new Error(rpcData.error + (rpcData.message ? ': ' + rpcData.message : ''));
                }
            }

            alert("🎉 Match Confirmed! ELO updated.");
            fetchMatches();
        } catch (e: unknown) {
            console.error('[CourtBoard] handleConfirmMatch CATCH:', e);
            const msg = e instanceof Error ? e.message : 'Confirm failed';
            alert(msg);
        }
        setLoading(false);
    };

    const handleRejectMatch = async (matchId: string) => {
        if (!confirm("⛔ Reject result?")) return;
        if (!user) return alert("Login required");
        setLoading(true);
        try {
            const { data, error } = await supabase.rpc('dispute_match', { p_match_id: matchId });
            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');

            alert("🛑 Rejected (Status: DISPUTED).");
            fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Reject failed';
            alert(msg);
        }
        setLoading(false);
    };

    // --- RENDER HELPERS ---
    const getMyTeam = (match: EnrichedMatch | undefined, uid: string) => {
        if (!match || !uid) return 0;
        if ([match.player_1, match.player_2].includes(uid)) return 1;
        if ([match.player_3, match.player_4].includes(uid)) return 2;
        return 0;
    };

    const filteredCandidates = queueCandidates.filter(c => c.profiles?.name?.toLowerCase().includes(searchTerm.toLowerCase()));

    return (
        <div className="grid grid-cols-1 gap-4">
            {/* 🔔 Notification Banner */}
            {isPendingOpponent && pendingReviewMatch && (
                <div
                    onClick={() => setMatchReviewTarget(pendingReviewMatch)}
                    className="bg-gradient-to-r from-amber-500 to-orange-500 p-4 rounded-2xl shadow-xl flex items-center justify-between cursor-pointer animate-pulse hover:scale-[1.02] transition-transform"
                >
                    <div className="flex items-center gap-3">
                        <span className="text-3xl bg-white/20 p-2 rounded-full">🔔</span>
                        <div>
                            <p className="font-black text-white text-lg leading-tight">Match Confirmation Required</p>
                            <p className="text-amber-100 text-xs font-bold">Court Released • Review Score & Vote MVP</p>
                        </div>
                    </div>
                    <button className="bg-white text-orange-600 font-black px-4 py-2 rounded-xl shadow-md text-sm">Review Now</button>
                </div>
            )}

            {courts.map((courtName) => {
                const match = activeMatches.find(m => m.court_name === courtName);
                const myTeam = user ? getMyTeam(match, user.id) : 0;
                const reporterTeam = match?.reported_by ? getMyTeam(match, match.reported_by) : 0;
                const isReporter = user && match?.reported_by === user.id;
                const isOpponent = myTeam !== 0 && myTeam !== reporterTeam && match?.status === 'PENDING';

                // STYLING: Restore V8.3 Aesthetics
                let containerClass = 'bg-white/5 border-white/10';
                if (match?.status === 'PLAYING') containerClass = 'bg-lime-900/20 border-lime-500/30';
                else if (match?.status === 'DRAFT') containerClass = 'bg-amber-900/20 border-amber-500/30';
                else if (match?.status === 'SCORING') containerClass = 'bg-cyan-900/20 border-cyan-500/30';

                return (
                    <div key={courtName} className={`relative p-6 backdrop-blur-md border rounded-2xl shadow-lg flex flex-col items-center justify-center min-h-[260px] transition-all ${containerClass}`}>
                        <div className="absolute top-4 left-4 bg-slate-700 px-3 py-1 rounded-md text-xs font-bold text-slate-300">{courtName}</div>
                        {courtName !== 'Court A' && courtName !== 'Court B' && (
                            <button onClick={() => handleRemoveCourt(courtName)} className="absolute top-4 right-4 text-slate-500 hover:text-rose-500 hover:bg-rose-500/10 p-1 rounded">✕</button>
                        )}

                        {!match ? (
                            <div className="text-center flex flex-col gap-3">
                                <p className="text-slate-500">Empty</p>
                                <div className="flex gap-2">
                                    <button onClick={() => handleAutoMatch(courtName)} disabled={loading} className="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white font-bold rounded-lg shadow-lg border border-slate-500 disabled:opacity-50 text-sm">🤖 Auto</button>
                                    <button onClick={() => openManualModal(courtName)} disabled={loading} className="px-4 py-2 bg-lime-700 hover:bg-lime-600 text-white font-bold rounded-lg shadow-lg border border-lime-500 disabled:opacity-50 text-sm">👆 Manual</button>
                                </div>
                            </div>
                        ) : match.status === 'PENDING' ? (
                            <div className="text-center w-full animate-pulse">
                                <p className="text-lg font-bold text-amber-400 mb-2">⏳ Confirmation Pending</p>
                                <div className="text-white text-2xl font-black mb-4 tracking-widest">{match.score_team1} : {match.score_team2}</div>
                                {isReporter ? (
                                    <div className="text-slate-400 text-sm bg-slate-800/50 p-2 rounded">Waiting for opponent...</div>
                                ) : isOpponent ? (
                                    <div className="flex gap-2 justify-center">
                                        <button onClick={() => handleConfirmMatch(match.id)} disabled={loading} className="px-6 py-2 bg-lime-600 text-white font-bold rounded-xl shadow-lg">✅ Confirm</button>
                                        <button onClick={() => handleRejectMatch(match.id)} disabled={loading} className="px-6 py-2 bg-rose-600 text-white font-bold rounded-xl shadow-lg">⛔ Reject</button>
                                    </div>
                                ) : (
                                    <div className="text-slate-500 text-xs">Verification in progress...</div>
                                )}
                            </div>
                        ) : match.status === 'SCORING' ? (
                            <div className="text-center w-full">
                                <p className="text-xl font-bold text-cyan-400 mb-4">✍️ 점수 입력</p>

                                {/* Team Labels + Score Inputs */}
                                <div className="flex items-stretch justify-center gap-4 mb-6">
                                    {/* Team 1 */}
                                    <div className="flex-1 bg-lime-900/20 border border-lime-500/30 rounded-xl p-3">
                                        <div className="text-lime-400 text-xs font-bold mb-2">🟢 Team 1</div>
                                        <div className="text-white text-xs mb-2 truncate">{match.p1_name}</div>
                                        <div className="text-white text-xs mb-3 truncate">{match.p2_name}</div>
                                        <input
                                            type="number"
                                            min="0"
                                            max="99"
                                            className="w-full h-12 bg-slate-800 border border-lime-500/50 rounded text-center text-2xl text-lime-400 font-bold focus:outline-none focus:border-lime-400"
                                            value={scores[match.id]?.t1 || ''}
                                            onChange={(e) => handleScoreChange(match.id, 't1', e.target.value)}
                                        />
                                    </div>

                                    <div className="flex items-center">
                                        <span className="text-slate-500 font-black text-2xl">:</span>
                                    </div>

                                    {/* Team 2 */}
                                    <div className="flex-1 bg-rose-900/20 border border-rose-500/30 rounded-xl p-3">
                                        <div className="text-rose-400 text-xs font-bold mb-2">🔴 Team 2</div>
                                        <div className="text-white text-xs mb-2 truncate">{match.p3_name}</div>
                                        <div className="text-white text-xs mb-3 truncate">{match.p4_name}</div>
                                        <input
                                            type="number"
                                            min="0"
                                            max="99"
                                            className="w-full h-12 bg-slate-800 border border-rose-500/50 rounded text-center text-2xl text-rose-400 font-bold focus:outline-none focus:border-rose-400"
                                            value={scores[match.id]?.t2 || ''}
                                            onChange={(e) => handleScoreChange(match.id, 't2', e.target.value)}
                                        />
                                    </div>
                                </div>

                                <button onClick={() => handleSubmitScore(match.id)} disabled={loading} className="px-6 py-2 bg-cyan-600 hover:bg-cyan-500 text-white font-bold rounded-lg shadow-lg">제출</button>
                            </div>
                        ) : (
                            <div className="text-center w-full">
                                <div className={`font-bold text-xl mb-4 ${match.status === 'PLAYING' ? 'text-lime-400 animate-pulse' : 'text-amber-400'}`}>
                                    {match.status === 'PLAYING' ? '🎾 경기 진행중' : '📋 매치 제안'}
                                </div>

                                {/* Team-based Layout */}
                                <div className="flex gap-3 w-full mb-6">
                                    {/* Team 1 */}
                                    <div className="flex-1 bg-lime-900/20 border border-lime-500/40 rounded-xl p-3">
                                        <div className="text-lime-400 text-xs font-bold mb-3">🟢 Team 1</div>
                                        {[{ id: 'player_1', n: match.p1_name, uid: match.player_1 }, { id: 'player_2', n: match.p2_name, uid: match.player_2 }].map((p, i) => (
                                            p.uid ? (
                                                <div key={i} className="bg-slate-800 p-2 rounded border border-lime-500/30 mb-2 flex items-center justify-between group relative">
                                                    <span className="text-sm text-white truncate">{p.n}</span>
                                                    <button onClick={() => openSwapModal(match.id, p.id, p.n, p.uid!)} className="text-[10px] bg-slate-600 hover:bg-lime-500 text-white px-1.5 py-0.5 rounded opacity-0 group-hover:opacity-100 transition-all">🔄</button>
                                                </div>
                                            ) : null
                                        ))}
                                    </div>

                                    <div className="flex items-center">
                                        <span className="text-slate-500 font-black text-lg">VS</span>
                                    </div>

                                    {/* Team 2 */}
                                    <div className="flex-1 bg-rose-900/20 border border-rose-500/40 rounded-xl p-3">
                                        <div className="text-rose-400 text-xs font-bold mb-3">🔴 Team 2</div>
                                        {[{ id: 'player_3', n: match.p3_name, uid: match.player_3 }, { id: 'player_4', n: match.p4_name, uid: match.player_4 }].map((p, i) => (
                                            p.uid ? (
                                                <div key={i} className="bg-slate-800 p-2 rounded border border-rose-500/30 mb-2 flex items-center justify-between group relative">
                                                    <span className="text-sm text-white truncate">{p.n}</span>
                                                    <button onClick={() => openSwapModal(match.id, p.id, p.n, p.uid!)} className="text-[10px] bg-slate-600 hover:bg-rose-500 text-white px-1.5 py-0.5 rounded opacity-0 group-hover:opacity-100 transition-all">🔄</button>
                                                </div>
                                            ) : null
                                        ))}
                                    </div>
                                </div>

                                {match.status === 'DRAFT' && (
                                    <div className="flex gap-3 w-full">
                                        <button onClick={() => handleStartGame(match.id)} className="flex-[2] py-3 bg-lime-600 hover:bg-lime-500 text-white font-bold rounded-xl shadow-lg">▶️ 게임 시작</button>
                                        <button onClick={() => handleCancelMatch(match.id)} className="flex-[1] py-3 bg-rose-700/80 hover:bg-rose-600 text-white font-bold rounded-xl shadow-lg border border-rose-500/30">🚫 취소</button>
                                    </div>
                                )}
                                {match.status === 'PLAYING' && <button onClick={() => handleEndGame(match.id)} className="px-4 py-2 bg-rose-500/20 text-rose-400 text-sm font-bold rounded-lg border border-rose-500/50 hover:bg-rose-500 hover:text-white transition-all">⏹ 게임 종료</button>}
                            </div>
                        )}
                    </div>
                );
            })}

            <button onClick={handleAddCourt} className="w-full h-14 border-2 border-dashed border-slate-700 hover:border-lime-500/50 rounded-2xl flex items-center justify-center text-slate-500 hover:text-lime-400 font-bold transition-all group">
                <span className="text-2xl mr-2 group-hover:scale-125 transition-transform">+</span> <span>Add Court</span>
            </button>

            {/* MANUAL MODAL */}
            {isManualModalOpen && (
                <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
                    <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-md max-h-[80vh] flex flex-col shadow-2xl">
                        <div className="p-4 border-b border-slate-700 flex justify-between items-center"><h3 className="text-white font-bold text-lg">👆 Manual ({selectedManualPlayers.length})</h3><button onClick={() => setIsManualModalOpen(false)} className="text-slate-400 hover:text-white">✕</button></div>
                        <div className="p-4 border-b border-slate-900/50"><input type="text" placeholder="Search..." value={searchTerm} onChange={(e) => setSearchTerm(e.target.value)} className="w-full bg-slate-800 border border-slate-600 text-white p-2 rounded-lg outline-none" autoFocus /></div>
                        <div className="overflow-y-auto flex-1 p-2 space-y-1">
                            {filteredCandidates.map((c) => {
                                const idx = selectedManualPlayers.findIndex(p => p.player_id === c.player_id); const isSel = idx !== -1;
                                return (<button key={c.player_id} onClick={() => toggleManualSelection(c)} className={`w-full flex justify-between p-3 rounded-xl border ${isSel ? 'bg-lime-500/20 border-lime-500/50' : 'hover:bg-slate-700 border-transparent'}`}><div className="flex gap-3"><span className={`w-6 h-6 rounded-full flex center text-xs font-bold ${isSel ? 'bg-lime-500 text-slate-900' : 'bg-slate-700 text-slate-300'}`}>{isSel ? idx + 1 : '-'}</span><p className="text-white font-bold text-sm">{c.profiles?.name} {c.profiles?.is_guest && '(G)'}</p></div></button>);
                            })}
                        </div>
                        <div className="p-4 border-t border-slate-700">
                            <div className="text-xs text-slate-400 mb-2 text-center">{selectedManualPlayers.length === 2 ? "Singles Match (1vs1)" : selectedManualPlayers.length === 4 ? "Doubles Match (2vs2)" : "Select 2 or 4 players"}</div>
                            <button onClick={confirmManualMatch} disabled={selectedManualPlayers.length !== 4 && selectedManualPlayers.length !== 2} className="w-full py-3 bg-lime-600 hover:bg-lime-500 text-white font-bold rounded-xl shadow-lg disabled:opacity-50">Create Match</button>
                        </div>
                    </div>
                </div>
            )}

            {/* SWAP MODAL */}
            {isSwapModalOpen && (
                <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
                    <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-md max-h-[80vh] flex flex-col shadow-2xl">
                        <div className="p-4 border-b border-slate-700 flex justify-between items-center"><h3 className="text-white font-bold text-lg">Swap Player</h3><button onClick={() => setIsSwapModalOpen(false)} className="text-slate-400 hover:text-white">✕</button></div>
                        <div className="p-4 border-b border-slate-900/50"><input type="text" placeholder="Search..." value={searchTerm} onChange={(e) => setSearchTerm(e.target.value)} className="w-full bg-slate-800 border border-slate-600 text-white p-2 rounded-lg outline-none" autoFocus /></div>
                        <div className="overflow-y-auto flex-1 p-2 space-y-1">
                            {filteredCandidates.map((c) => (
                                <button key={c.player_id} onClick={() => handleExecuteSwap(c)} className="w-full flex justify-between p-3 rounded-xl hover:bg-lime-500/20 border border-transparent"><div className="flex gap-3"><p className="text-white font-bold text-sm">{c.profiles?.name}</p></div><span className="text-xs bg-slate-700 text-slate-300 px-2 py-1 rounded">Select</span></button>
                            ))}
                        </div>
                    </div>
                </div>
            )}

            {/* MATCH REVIEW MODAL */}
            {matchReviewTarget && (
                <MatchReviewModal
                    match={matchReviewTarget}
                    user={user}
                    onClose={() => setMatchReviewTarget(null)}
                    onSuccess={() => { fetchMatches(); setMatchReviewTarget(null); }}
                />
            )}

            {/* 🚑 DEBUG: Visual Version Tag */}
            <div className="fixed bottom-2 right-2 bg-lime-600 text-white text-xs px-2 py-1 rounded-full z-[9999] font-bold shadow-lg">
                Ver 9.9.7 (COURT RELEASE)
            </div>
        </div>
    );
}
