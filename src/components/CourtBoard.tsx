import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
// Services
import { calculatePriorityScore, generateV83Match } from '../services/matchingSystem';
import { reportMatchResult, confirmMatchResult, rejectMatchResult } from '../services/matchVerification';
// Types
import { Database } from '../types/supabase';

type Match = Database['public']['Tables']['matches']['Row'];
type Profile = Database['public']['Tables']['profiles']['Row'];

// Queue Type (Custom combination for UI)
type QueueCandidate = {
    player_id: string;
    priority_score: number;
    joined_at: string;
    departure_time: string;
    profiles: Profile | null; // Safe Fetch
    finalScore: number;
};

// Extends Match with Player Names for UI
interface EnrichedMatch extends Match {
    p1_name: string;
    p2_name: string;
    p3_name: string;
    p4_name: string;
}

import MatchReviewModal from './MatchReviewModal';

export default function CourtBoard({ user }: { user: any }) {
    const [courts, setCourts] = useState<string[]>(['Court A', 'Court B']);
    const [activeMatches, setActiveMatches] = useState<EnrichedMatch[]>([]);
    const [loading, setLoading] = useState(false);

    // Score & Tournament State
    const [scores, setScores] = useState<{ [matchId: string]: { t1: string, t2: string } }>({});
    const [isTournament, setIsTournament] = useState<{ [matchId: string]: boolean }>({});
    const [tournamentCode, setTournamentCode] = useState<{ [matchId: string]: string }>({});

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

    // [New] Notification Banner Logic
    // Find pending matches involving user that are NOT on any court (Instant Released)
    const pendingReviewMatch = user ? activeMatches.find(m =>
        m.status === 'PENDING' &&
        m.court_name === null &&
        ([m.player_1, m.player_2, m.player_3, m.player_4].includes(user.id) || matchReviewTarget?.id === m.id)
    ) : null;

    // Check if I am the opponent (needs to confirm) or reporter (waiting)
    const isPendingOpponent = pendingReviewMatch && pendingReviewMatch.reported_by !== user.id;

    useEffect(() => {
        fetchMatches();
        const channel = supabase.channel('public:matches')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => { fetchMatches(); })
            .subscribe();
        return () => { supabase.removeChannel(channel); };
    }, []);

    // --- DATA FETCHING (SAFE 406 PREVENTION) ---
    const fetchMatches = async () => {
        // Explicitly cast or allow inference if supabase client is typed (which we will verify next)
        const { data } = await supabase
            .from('matches')
            .select('*')
            .neq('status', 'FINISHED');

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

        const queueData = data as any[]; // Complex join type, casting to any[] for mapping convenience

        if (!queueData) return [];

        const scored = queueData.map((item) => ({
            ...item,
            priority_score: item.priority_score,
            finalScore: calculatePriorityScore(item)
        }));
        return scored.sort((a: any, b: any) => b.finalScore - a.finalScore) as QueueCandidate[];
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

            const { matchType, team1, team2, playerIds } = matchResult;

            const { error } = await supabase.from('matches').insert({
                court_name: courtName,
                status: 'DRAFT',
                match_category: matchType,
                player_1: team1[0].player_id, player_2: team1[1].player_id,
                player_3: team2[0].player_id, player_4: team2[1].player_id
            });
            if (error) throw error;
            await supabase.from('queue').delete().in('player_id', playerIds);
            fetchMatches();
        } catch (e: any) { alert(e.message); }
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

            const { error } = await supabase.from('matches').insert({
                court_name: manualTargetCourt,
                status: 'DRAFT',
                match_category: isSingles ? 'SINGLES' : 'MIXED', // Default to MIXED for manual doubles unless refining further
                player_1: pIds[0],
                player_2: isSingles ? null : pIds[1],
                // For singles, pIds[1] becomes player_3 (opponent)
                player_3: isSingles ? pIds[1] : pIds[2],
                player_4: isSingles ? null : pIds[3]
            });

            if (error) throw error;
            await supabase.from('queue').delete().in('player_id', pIds);
            setIsManualModalOpen(false);
            setManualTargetCourt(null);
            setSelectedManualPlayers([]);
            fetchMatches();
        } catch (e: any) { alert("Error: " + e.message); }
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
            await supabase.from('matches').update({ [swapTarget.col]: candidate.player_id }).eq('id', swapTarget.matchId);
            await supabase.from('queue').delete().eq('player_id', candidate.player_id);
            if (swapTarget.oldId) {
                await supabase.from('queue').insert({
                    player_id: swapTarget.oldId,
                    priority_score: 1000,
                    joined_at: new Date().toISOString(),
                    is_active: true
                });
            }
            setIsSwapModalOpen(false);
            setSwapTarget(null);
            fetchMatches();
        } catch (e: any) { alert("Swap Error: " + e.message); }
    };

    // --- GAME CONTROL ---
    const handleStartGame = async (matchId: string) => {
        const startTime = new Date();
        const bettingClosesAt = new Date(startTime.getTime() + 5 * 60 * 1000);
        await supabase.from('matches').update({
            status: 'PLAYING',
            start_time: startTime.toISOString(),
            betting_closes_at: bettingClosesAt.toISOString()
        }).eq('id', matchId);
        fetchMatches();
    };

    const handleEndGame = async (matchId: string) => {
        if (confirm("Finish game?")) {
            await supabase.from('matches').update({ status: 'SCORING' }).eq('id', matchId);
            fetchMatches();
        }
    };

    const handleCancelMatch = async (matchId: string) => {
        if (!confirm("⚠️ Cancel match?")) return;
        setLoading(true);
        try {
            const match = activeMatches.find(m => m.id === matchId);
            if (match) {
                const pIds = [match.player_1, match.player_2, match.player_3, match.player_4].filter(Boolean) as string[];
                const { error } = await supabase.from('matches').delete().eq('id', matchId);
                if (error) throw error;
                if (pIds.length > 0) {
                    await supabase.from('queue').upsert(pIds.map(pid => ({
                        player_id: pid,
                        joined_at: new Date().toISOString(),
                        priority_score: 1000,
                        is_active: true
                    })), { onConflict: 'player_id' });
                }
                fetchMatches();
            }
        } catch (e: any) { alert("Error: " + e.message); }
        setLoading(false);
    };

    // --- SCORING & VERIFICATION (V3.5) ---
    const handleScoreChange = (matchId: string, team: 't1' | 't2', value: string) => {
        setScores(prev => ({ ...prev, [matchId]: { ...prev[matchId], [team]: value } }));
    };

    const handleSubmitScore = async (matchId: string) => {
        if (loading) return;
        const s = scores[matchId];
        if (!s || !s.t1 || !s.t2) { alert("Scores required"); return; }

        // Tournament Code Logic
        if ((isTournament[matchId]) && tournamentCode[matchId] !== '7777') {
            alert("⛔ Wrong Code!"); return;
        }

        const s1 = parseInt(s.t1), s2 = parseInt(s.t2);
        const winner = s1 > s2 ? 'TEAM_1' : s2 > s1 ? 'TEAM_2' : 'DRAW';

        setLoading(true);
        try {
            // Update Metadata First
            await supabase.from('matches').update({
                winner_team: winner,
                match_type: isTournament[matchId] ? 'TOURNAMENT' : 'REGULAR',
                // category is usually set at creation, but could refine here if needed
            }).eq('id', matchId);

            // Report via Service
            await reportMatchResult(matchId, s1, s2, user.id);
            alert("✅ Reported! Waiting for confirmation.");
            fetchMatches();
        } catch (e: any) { alert(e.message); }
        setLoading(false);
    };

    const handleConfirmMatch = async (matchId: string) => {
        if (loading) return;
        if (!confirm("✅ Confirm result?")) return;
        if (!user) return alert("Login required");

        setLoading(true);
        try {
            await confirmMatchResult(matchId, user.id);
            alert("🎉 Match Confirmed! ELO updated.");
            fetchMatches();
        } catch (e: any) { alert(e.message); }
        setLoading(false);
    };

    const handleRejectMatch = async (matchId: string) => {
        if (!confirm("⛔ Reject result?")) return;
        if (!user) return alert("Login required");
        setLoading(true);
        try {
            await rejectMatchResult(matchId, user.id);
            alert("🛑 Rejected.");
            fetchMatches();
        } catch (e: any) { alert(e.message); }
        setLoading(false);
    };

    // --- RENDER HELPERS ---
    const getMyTeam = (match: any, uid: string) => {
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
                                <p className="text-xl font-bold text-cyan-400 mb-4">✍️ Enter Score</p>
                                <div className="flex flex-col items-center justify-center mb-4 gap-2">
                                    <label className="flex items-center gap-2 cursor-pointer bg-slate-800 px-3 py-1.5 rounded-lg border border-slate-600 hover:border-amber-500 transition-colors">
                                        <input type="checkbox" checked={isTournament[match.id] || false} onChange={() => setIsTournament({ ...isTournament, [match.id]: !isTournament[match.id] })} className="w-4 h-4 accent-amber-500" />
                                        <span className={`text-sm font-bold ${isTournament[match.id] ? 'text-amber-400' : 'text-slate-400'}`}>🏆 Tournament</span>
                                    </label>
                                    {isTournament[match.id] && (<input type="password" maxLength={4} placeholder="PIN" value={tournamentCode[match.id] || ''} onChange={(e) => setTournamentCode({ ...tournamentCode, [match.id]: e.target.value })} className="w-24 bg-slate-900 border border-amber-500/50 text-center text-white rounded p-1 text-sm focus:outline-none" />)}
                                </div>
                                <div className="flex items-center justify-center gap-4 mb-6">
                                    <input type="number" className="w-16 h-12 bg-slate-800 border border-slate-600 rounded text-center text-xl text-white font-bold" value={scores[match.id]?.t1 || ''} onChange={(e) => handleScoreChange(match.id, 't1', e.target.value)} />
                                    <span className="text-slate-500 font-bold">:</span>
                                    <input type="number" className="w-16 h-12 bg-slate-800 border border-slate-600 rounded text-center text-xl text-white font-bold" value={scores[match.id]?.t2 || ''} onChange={(e) => handleScoreChange(match.id, 't2', e.target.value)} />
                                </div>
                                <button onClick={() => handleSubmitScore(match.id)} disabled={loading} className="px-6 py-2 bg-cyan-600 hover:bg-cyan-500 text-white font-bold rounded-lg shadow-lg">Submit</button>
                            </div>
                        ) : (
                            <div className="text-center w-full">
                                <div className={`font-bold text-xl mb-4 ${match.status === 'PLAYING' ? 'text-lime-400 animate-pulse' : 'text-amber-400'}`}>{match.status === 'PLAYING' ? '🎾 In Progress' : '📋 Match Proposed'}</div>
                                <div className="grid grid-cols-2 gap-3 w-full mb-6">
                                    {[{ id: 'player_1', n: match.p1_name, uid: match.player_1 }, { id: 'player_2', n: match.p2_name, uid: match.player_2 }, { id: 'player_3', n: match.p3_name, uid: match.player_3 }, { id: 'player_4', n: match.p4_name, uid: match.player_4 }].map((p, i) => (
                                        p.uid ? ( // Only render if uid exists (handle Singles gaps)
                                            <div key={i} className="bg-slate-800 p-2 rounded border border-slate-600 flex items-center justify-between group relative">
                                                <span className="text-xs text-white truncate max-w-[80px]">{p.n}</span>
                                                <button onClick={() => openSwapModal(match.id, p.id, p.n, p.uid!)} className="text-[10px] bg-slate-600 hover:bg-amber-500 text-white px-1.5 py-0.5 rounded opacity-0 group-hover:opacity-100 transition-all absolute right-1">🔄</button>
                                            </div>
                                        ) : <div key={i} className="bg-transparent" />
                                    ))}
                                </div>
                                {match.status === 'DRAFT' && (
                                    <div className="flex gap-3 w-full">
                                        <button onClick={() => handleStartGame(match.id)} className="flex-[2] py-3 bg-lime-600 hover:bg-lime-500 text-white font-bold rounded-xl shadow-lg">▶️ Start Game</button>
                                        <button onClick={() => handleCancelMatch(match.id)} className="flex-[1] py-3 bg-rose-700/80 hover:bg-rose-600 text-white font-bold rounded-xl shadow-lg border border-rose-500/30">🚫 Cancel</button>
                                    </div>
                                )}
                                {match.status === 'PLAYING' && <button onClick={() => handleEndGame(match.id)} className="px-4 py-1 bg-rose-500/20 text-rose-400 text-xs rounded border border-rose-500/50 hover:bg-rose-500">⏹ End Game</button>}
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
        </div>
    );
}