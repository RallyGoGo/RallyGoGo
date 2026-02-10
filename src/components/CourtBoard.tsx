import { useState, useMemo } from 'react';
import { supabase, Match } from '../lib/supabase';
// Services
import { calculatePriorityScore, generateV83Match } from '../services/matchingSystem';
import { logger } from '../utils/logger';
import type { AppQueueItem, AppMatch } from '../types/app';

// V3 Helper: Extract error from RPC JSON response
type RpcResponse = { success?: boolean; error?: string; message?: string } | null;
const getRpcError = (data: unknown): string | null => {
    if (data && typeof data === 'object' && 'error' in data) {
        return (data as RpcResponse)?.error || null;
    }
    return null;
};

// Extends Match with Player Names for UI -> moved to types/app.ts
// interface EnrichedMatch extends Match ... removed

import MatchReviewModal from './MatchReviewModal';

// User type for props - only need id for checking participation
type UserProp = { id: string };

// Props interface
interface CourtBoardProps {
    user: UserProp | null;
    matches: Match[]; // Using the raw Match type from supabase, but we know it's enriched if coming from useRallyData
    queue: AppQueueItem[]; // Using refined type
}

export default function CourtBoard({ user, matches, queue }: CourtBoardProps) {
    // V3: Matches and Queue are now passed as props from useRallyData (Centralized)
    const { activeMatches, pendingMatches, queueCandidates } = useMemo(() => {
        // Filter matches for Courts (DRAFT, PLAYING, SCORING) - EXCLUDE PENDING so court is free
        const courtMatches = matches.filter(m =>
            ['DRAFT', 'PLAYING', 'SCORING'].includes(m.status || '')
        ) as AppMatch[];

        // Filter PENDING matches separately (for Banner / Notification)
        const pendingList = matches.filter(m =>
            m.status === 'PENDING'
        ) as AppMatch[];

        // Process Queue Data for UI
        const scoredQueue = queue.map((item) => {
            const joinedAt = item.joined_at || new Date().toISOString();
            const input = { ...item, joined_at: joinedAt };
            return {
                ...item,
                joined_at: joinedAt,
                // Ensure we use a consistent ID field. matchingSystem uses player_id or user_id. 
                // Our DB uses player_id.
                player_id: item.player_id,
                finalScore: calculatePriorityScore(input),
                waitMinutes: 0
            };
        });

        const sortedQueue = scoredQueue.sort((a, b) => (b.finalScore || 0) - (a.finalScore || 0)) as AppQueueItem[];

        return { activeMatches: courtMatches, pendingMatches: pendingList, queueCandidates: sortedQueue };
    }, [matches, queue]);

    // Local state for UI only
    const [loading, setLoading] = useState(false);
    const [searchTerm, setSearchTerm] = useState('');
    const [courts, setCourts] = useState<string[]>(['Court A', 'Court B']);

    // Score State
    const [scores, setScores] = useState<{ [matchId: string]: { t1: string, t2: string } }>({});

    // Modals
    const [isSwapModalOpen, setIsSwapModalOpen] = useState(false);
    const [swapTarget, setSwapTarget] = useState<{ matchId: string; col: string; oldName: string; oldId: string } | null>(null);
    const [isManualModalOpen, setIsManualModalOpen] = useState(false);
    const [manualTargetCourt, setManualTargetCourt] = useState<string | null>(null);
    const [selectedManualPlayers, setSelectedManualPlayers] = useState<AppQueueItem[]>([]);
    const [matchReviewTarget, setMatchReviewTarget] = useState<AppMatch | null>(null);

    // Derived State for Auto-Match
    const getSmartSortedQueue = async () => {
        return queueCandidates;
    };

    // [New] PENDING matches for notification (derived from props)
    const pendingReviewMatch = useMemo(() => user ? pendingMatches.find(m =>
        ([m.player_1, m.player_2, m.player_3, m.player_4].includes(user.id))
    ) : null, [user, pendingMatches]);

    // Check if I am the opponent (needs to confirm) or reporter (waiting)
    const isPendingOpponent = pendingReviewMatch && user && pendingReviewMatch.reported_by !== user.id;


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
            const matchResult = generateV83Match(sortedList as any); // Cast as any to satisfy strict QueueItem requirements including joined_at string

            if (!matchResult) {
                throw new Error("❌ Not enough players or no valid combination.");
            }

            const { matchType, playerIds } = matchResult;

            // V9.7.2: Strict RPC Model - create_match_draft
            const { data, error } = await supabase.rpc('create_match_draft', {
                p_player_ids: playerIds.filter((id): id is string => !!id),
                p_match_type: matchType as 'MIXED' | 'MENS_DOUBLES' | 'WOMENS_DOUBLES' | 'SINGLES',
                p_court_name: courtName
            });
            const rpcErr = getRpcError(data);
            if (error || rpcErr) {
                logger.error('match.auto_create_fail', error || rpcErr);
                throw new Error(error?.message || rpcErr || 'Unknown error');
            }
            logger.info('match.auto_created', { court: courtName, matchType });
            // // fetchMatches(); // Handled by Realtime in parent
        } catch (e: Error | unknown) {
            logger.error('match.auto_fail', e);
            alert(e instanceof Error ? e.message : 'Unknown error');
        }
        setLoading(false);
    };

    // --- MANUAL MATCHING (SINGLES + DOUBLES) ---
    const openManualModal = async (courtName: string) => {
        if (loading) return;
        if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; }
        setLoading(true);
        // Queue candidates are already updated via props
        setManualTargetCourt(courtName);
        setSelectedManualPlayers([]);
        setSearchTerm('');
        setIsManualModalOpen(true);
        setLoading(false);
    };

    const toggleManualSelection = (candidate: AppQueueItem) => {
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
            if (error || rpcErr) {
                logger.error('match.manual_create_fail', error || rpcErr);
                throw new Error(error?.message || rpcErr || 'Unknown error');
            }
            logger.info('match.manual_created', { court: manualTargetCourt, isSingles });
            setIsManualModalOpen(false);
            setManualTargetCourt(null);
            setSelectedManualPlayers([]);
            // // fetchMatches(); // Handled by Realtime in parent
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Unknown error';
            logger.error('match.manual_fail', e);
            alert("Error: " + msg);
        }
        setLoading(false);
    };

    // --- SWAP LOGIC ---
    const openSwapModal = async (matchId: string, col: string, oldName: string, oldId: string) => {
        if (loading) return;
        setLoading(true);
        // Queue candidates are already updated via props
        setSwapTarget({ matchId, col, oldName, oldId });
        setSearchTerm('');
        setIsSwapModalOpen(true);
        setLoading(false);
    };

    const handleExecuteSwap = async (candidate: AppQueueItem) => {
        if (!swapTarget) return;
        if (!confirm(`🔄 Swap with [${candidate.profiles?.name}]?`)) return;
        try {
            // ✅ P1 Fix: Use swap_player RPC (atomic operation)
            const { data, error } = await supabase.rpc('swap_player', {
                p_match_id: swapTarget.matchId,
                p_old_player_id: swapTarget.oldId,
                p_new_player_id: candidate.player_id
            });
            if (error) throw error;
            if (data && typeof data === 'object' && 'error' in data) throw new Error(String((data as Record<string, unknown>).error));

            logger.info('match.player_swapped', { matchId: swapTarget.matchId, old: swapTarget.oldName, new: candidate.profiles?.name });
            setIsSwapModalOpen(false);
            setSwapTarget(null);
            // fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Swap failed';
            logger.error('match.swap_fail', e);
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

            logger.info('match.started', { matchId });
            // fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Start failed';
            logger.error('match.start_fail', e);
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

            logger.info('match.ended', { matchId });
            // fetchMatches();
        } catch (e: Error | unknown) {
            logger.error('match.end_fail', e);
            alert(e instanceof Error ? e.message : 'Unknown error');
        }
    };

    const handleCancelMatch = async (matchId: string) => {
        if (!confirm("⚠️ Cancel match?")) return;
        setLoading(true);
        try {
            // V9.7.2: Strict RPC Model
            const { data, error } = await supabase.rpc('cancel_match', { p_match_id: matchId });
            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');

            logger.info('match.cancelled', { matchId });
            // fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Cancel failed';
            logger.error('match.cancel_fail', e);
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

        logger.info('match.score_submit_start', { matchId, s1, s2, winner });

        setLoading(true);
        try {
            // V9.7.2: Strict RPC Model - report_score with correct params
            const { data, error } = await supabase.rpc('report_score', {
                p_match_id: matchId,
                p_team1_score: s1,
                p_team2_score: s2,
                p_winner: winner
            });

            const rpcErr = getRpcError(data);
            if (error || rpcErr) throw new Error(error?.message || rpcErr || 'Unknown error');

            logger.info('match.score_reported', { matchId });
            // V9.7.2: Strict RPC Model - report_score logic complete
            // Service call removed - RPC handles everything
            alert("✅ Reported! Waiting for confirmation.");
            // fetchMatches();
        } catch (e: Error | unknown) {
            logger.error('match.score_report_fail', e);
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

        logger.info('match.confirm_start', { matchId });

        setLoading(true);
        try {
            const { data, error } = await supabase.rpc('finish_match_v2', {
                p_match_id: matchId,
                p_team1_score: match.score_team1 || 0,
                p_team2_score: match.score_team2 || 0,
                p_confirmation_type: 'NORMAL_CONFIRM'
            });

            if (error) {
                logger.error('match.finish_v2_fail', error);
                throw error;
            }

            // Check for logical error in JSON response
            type RpcResponse = { success?: boolean; error?: string; message?: string; bets_settled?: number; match_type?: string; sqlstate?: string };
            const rpcData = data as RpcResponse;

            if (rpcData && !rpcData.success) {
                if (rpcData.error && rpcData.error !== 'ALREADY_FINISHED') {
                    throw new Error(rpcData.error + (rpcData.message ? ': ' + rpcData.message : ''));
                }
            }

            logger.info('match.confirmed', { matchId, betsSettled: rpcData?.bets_settled });
            alert("🎉 Match Confirmed! ELO updated.");
            // fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Confirm failed';
            logger.error('match.confirm_fail', e);
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

            logger.info('match.disputed', { matchId });
            alert("🛑 Rejected (Status: DISPUTED).");
            // fetchMatches();
        } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : 'Reject failed';
            logger.error('match.dispute_fail', e);
            alert(msg);
        }
        setLoading(false);
    };

    // --- RENDER HELPERS ---
    const getMyTeam = (match: AppMatch | undefined, uid: string) => {
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
                    user={user!}
                    onClose={() => setMatchReviewTarget(null)}
                    onSuccess={() => { setMatchReviewTarget(null); }}
                />
            )}


        </div>
    );
}
