import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

type QueueCandidate = {
    player_id: string;
    priority_score: number;
    joined_at: string;
    profiles: { name: string; email: string; is_guest?: boolean };
    finalScore: number;
};

export default function CourtBoard() {
    const [courts, setCourts] = useState<string[]>(['Court A', 'Court B']);
    const [activeMatches, setActiveMatches] = useState<any[]>([]);
    const [loading, setLoading] = useState(false);

    const [scores, setScores] = useState<{ [matchId: string]: { t1: string, t2: string } }>({});
    const [isTournament, setIsTournament] = useState<{ [matchId: string]: boolean }>({});
    const [tournamentCode, setTournamentCode] = useState<{ [matchId: string]: string }>({});

    const [isSwapModalOpen, setIsSwapModalOpen] = useState(false);
    const [swapTarget, setSwapTarget] = useState<{ matchId: string; col: string; oldName: string; oldId: string } | null>(null);
    const [isManualModalOpen, setIsManualModalOpen] = useState(false);
    const [manualTargetCourt, setManualTargetCourt] = useState<string | null>(null);
    const [selectedManualPlayers, setSelectedManualPlayers] = useState<QueueCandidate[]>([]);
    const [queueCandidates, setQueueCandidates] = useState<QueueCandidate[]>([]);
    const [searchTerm, setSearchTerm] = useState('');

    useEffect(() => {
        fetchMatches();
        const channel = supabase.channel('public:matches').on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => { fetchMatches(); }).subscribe();
        return () => { supabase.removeChannel(channel); };
    }, []);

    const fetchMatches = async () => {
        const { data: matchData } = await supabase.from('matches').select('*').neq('status', 'FINISHED');
        if (!matchData) return;

        const allPlayerIds = new Set<string>();
        matchData.forEach((m: any) => {
            if (m.player_1) allPlayerIds.add(m.player_1); if (m.player_2) allPlayerIds.add(m.player_2);
            if (m.player_3) allPlayerIds.add(m.player_3); if (m.player_4) allPlayerIds.add(m.player_4);
        });

        if (allPlayerIds.size > 0) {
            const { data: profiles } = await supabase.from('profiles').select('id, name').in('id', Array.from(allPlayerIds));
            const enriched = matchData.map((m: any) => ({
                ...m,
                p1_name: profiles?.find(p => p.id === m.player_1)?.name || 'Unknown', p2_name: profiles?.find(p => p.id === m.player_2)?.name || 'Unknown',
                p3_name: profiles?.find(p => p.id === m.player_3)?.name || 'Unknown', p4_name: profiles?.find(p => p.id === m.player_4)?.name || 'Unknown',
            }));
            setActiveMatches(enriched);
        } else { setActiveMatches(matchData); }
    };

    const handleAddCourt = () => { const nextChar = String.fromCharCode(65 + courts.length); setCourts([...courts, `Court ${nextChar}`]); };
    const handleRemoveCourt = (courtName: string) => { if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Cannot remove active court!"); return; } if (confirm(`🗑️ Remove ${courtName}?`)) setCourts(prev => prev.filter(c => c !== courtName)); };

    const getSortedQueue = async () => {
        const { data: queueData } = await supabase.from('queue').select('*');
        if (!queueData || queueData.length === 0) return [];
        const playerIds = queueData.map(q => q.player_id);
        const { data: profiles } = await supabase.from('profiles').select('id, name, email, is_guest').in('id', playerIds);
        const { data: matches } = await supabase.from('matches').select('player_1, player_2, player_3, player_4').eq('status', 'FINISHED');
        const gameCounts: { [key: string]: number } = {};
        if (matches) { matches.forEach(m => { [m.player_1, m.player_2, m.player_3, m.player_4].forEach(pid => { if (pid) gameCounts[pid] = (gameCounts[pid] || 0) + 1; }); }); }
        const scoredQueue = queueData.map((item) => {
            const profile = profiles?.find(p => p.id === item.player_id);
            const gamesPlayed = gameCounts[item.player_id] || 0;
            let score = item.priority_score || 2.5;
            if (gamesPlayed === 0) score += 2000; score -= (gamesPlayed * 500);
            const waitMins = (Date.now() - new Date(item.joined_at).getTime()) / 60000; score += (waitMins * 10);
            if (profile?.is_guest) score += 300;
            return { ...item, profiles: profile, finalScore: score };
        });
        return scoredQueue.sort((a, b) => b.finalScore - a.finalScore);
    };

    const handleAutoMatch = async (courtName: string) => {
        if (loading) return; if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; } setLoading(true);
        try {
            const sortedList = await getSortedQueue();
            if (sortedList.length < 4) { alert("❌ Need 4 players!"); setLoading(false); return; }
            const pIds = sortedList.slice(0, 4).map(p => p.player_id);
            const { error } = await supabase.from('matches').insert({ court_name: courtName, status: 'DRAFT', player_1: pIds[0], player_2: pIds[1], player_3: pIds[2], player_4: pIds[3] });
            if (error) throw error; await supabase.from('queue').delete().in('player_id', pIds); fetchMatches();
        } catch (e: any) { alert(e.message); } setLoading(false);
    };
    const openManualModal = async (courtName: string) => {
        if (loading) return; if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; } setLoading(true);
        const sortedList = await getSortedQueue();
        if (sortedList) { setQueueCandidates(sortedList as any); setManualTargetCourt(courtName); setSelectedManualPlayers([]); setSearchTerm(''); setIsManualModalOpen(true); } setLoading(false);
    };
    const toggleManualSelection = (candidate: QueueCandidate) => {
        const isSelected = selectedManualPlayers.find(p => p.player_id === candidate.player_id);
        if (isSelected) setSelectedManualPlayers(prev => prev.filter(p => p.player_id !== candidate.player_id)); else { if (selectedManualPlayers.length >= 4) return; setSelectedManualPlayers(prev => [...prev, candidate]); }
    };
    const confirmManualMatch = async () => {
        if (!manualTargetCourt || selectedManualPlayers.length !== 4) return; if (loading) return; setLoading(true);
        try {
            const pIds = selectedManualPlayers.map(p => p.player_id);
            const { error } = await supabase.from('matches').insert({ court_name: manualTargetCourt, status: 'DRAFT', player_1: pIds[0], player_2: pIds[1], player_3: pIds[2], player_4: pIds[3] });
            if (error) throw error; await supabase.from('queue').delete().in('player_id', pIds); setIsManualModalOpen(false); setManualTargetCourt(null); setSelectedManualPlayers([]); fetchMatches();
        } catch (e: any) { alert("Error: " + e.message); } setLoading(false);
    };
    const handleCancelMatch = async (matchId: string) => {
        if (!confirm("⚠️ Cancel match?")) return; setLoading(true);
        try {
            const match = activeMatches.find(m => m.id === matchId);
            if (match) {
                const pIds = [match.player_1, match.player_2, match.player_3, match.player_4].filter(Boolean);
                const { error } = await supabase.from('matches').delete().eq('id', matchId); if (error) throw error;
                if (pIds.length > 0) { await supabase.from('queue').insert(pIds.map(pid => ({ player_id: pid, joined_at: new Date().toISOString(), arrived_at: new Date().toISOString(), departure_time: '23:00', priority_score: 2.5 }))); }
                alert("✅ Canceled."); fetchMatches();
            }
        } catch (e: any) { alert("Error: " + e.message); } setLoading(false);
    };
    const openSwapModal = async (matchId: string, col: string, oldName: string, oldId: string) => {
        if (loading) return; setLoading(true); const sortedList = await getSortedQueue();
        if (sortedList) { setQueueCandidates(sortedList as any); setSwapTarget({ matchId, col, oldName, oldId }); setSearchTerm(''); setIsSwapModalOpen(true); } setLoading(false);
    };
    const handleExecuteSwap = async (candidate: QueueCandidate) => {
        if (!swapTarget) return; if (!confirm(`🔄 Swap with [${candidate.profiles?.name}]?`)) return;
        try {
            await supabase.from('matches').update({ [swapTarget.col]: candidate.player_id }).eq('id', swapTarget.matchId); await supabase.from('queue').delete().eq('player_id', candidate.player_id);
            if (swapTarget.oldId) { await supabase.from('queue').insert({ player_id: swapTarget.oldId, priority_score: 2.5, joined_at: new Date().toISOString(), arrived_at: new Date().toISOString(), departure_time: '23:00' }); }
            setIsSwapModalOpen(false); setSwapTarget(null); fetchMatches();
        } catch (e: any) { alert("Swap Error: " + e.message); }
    };
    const handleStartGame = async (matchId: string) => { await supabase.from('matches').update({ status: 'PLAYING', start_time: new Date().toISOString() }).eq('id', matchId); fetchMatches(); };
    const handleEndGame = async (matchId: string) => { if (confirm("Finish game?")) { await supabase.from('matches').update({ status: 'SCORING' }).eq('id', matchId); fetchMatches(); } };
    const handleScoreChange = (matchId: string, team: 't1' | 't2', value: string) => setScores(prev => ({ ...prev, [matchId]: { ...prev[matchId], [team]: value } }));
    const handleCodeChange = (matchId: string, value: string) => setTournamentCode(prev => ({ ...prev, [matchId]: value }));
    const toggleTournament = (matchId: string) => setIsTournament(prev => ({ ...prev, [matchId]: !prev[matchId] }));

    // 🔥 UPDATED: Submit Score and Save Delta
    const handleSubmitScore = async (matchId: string) => {
        const s = scores[matchId];
        if (!s || !s.t1 || !s.t2) { alert("Scores required"); return; }

        const isTourney = isTournament[matchId] || false;
        if (isTourney && tournamentCode[matchId] !== '7777') { alert("⛔ Wrong Code!"); return; }

        const s1 = parseInt(s.t1), s2 = parseInt(s.t2);
        const winner = s1 > s2 ? 'TEAM_1' : s2 > s1 ? 'TEAM_2' : 'DRAW';
        const K = isTourney ? 64 : 32;

        setLoading(true);
        try {
            const match = activeMatches.find(m => m.id === matchId);
            const pIds = [match.player_1, match.player_2, match.player_3, match.player_4].filter(Boolean);

            const { data: players } = await supabase.from('profiles').select('id, gender, elo_men_doubles, elo_women_doubles, elo_mixed_doubles, elo_singles').in('id', pIds);

            if (players && players.length === 4) {
                const males = players.filter(p => p.gender === 'Male').length;
                let category = 'MIXED'; let eloField = 'elo_mixed_doubles'; let label = 'Mixed Doubles';

                if (males === 4) { category = 'MEN_D'; eloField = 'elo_men_doubles'; label = "Men's Doubles"; }
                else if (males === 0) { category = 'WOMEN_D'; eloField = 'elo_women_doubles'; label = "Women's Doubles"; }

                if (!confirm(`Confirm: ${s1}:${s2}? \n[${label}]`)) { setLoading(false); return; }

                const p1 = players.find(p => p.id === match.player_1); const p2 = players.find(p => p.id === match.player_2);
                const p3 = players.find(p => p.id === match.player_3); const p4 = players.find(p => p.id === match.player_4);

                const t1Avg = ((p1 as any)[eloField] + (p2 as any)[eloField]) / 2;
                const t2Avg = ((p3 as any)[eloField] + (p4 as any)[eloField]) / 2;
                const actualT1 = s1 > s2 ? 1.0 : 0.0;
                const expectedT1 = 1 / (1 + Math.pow(10, (t2Avg - t1Avg) / 400));
                const delta = Math.round(K * (actualT1 - expectedT1));

                // 1. Update Profile Scores
                const updates = [{ p: p1, d: delta }, { p: p2, d: delta }, { p: p3, d: -delta }, { p: p4, d: -delta }];

                for (const u of updates) {
                    if (u.p) {
                        const newScore = (u.p as any)[eloField] + u.d;
                        await supabase.from('profiles').update({ [eloField]: newScore }).eq('id', u.p.id);
                        await supabase.from('elo_history').insert({ player_id: u.p.id, match_category: category === 'MEN_D' ? 'MEN_D' : category === 'WOMEN_D' ? 'WOMEN_D' : 'MIXED', elo_score: newScore });
                    }
                }

                // 2. Save Match Record with DELTA ✨
                await supabase.from('matches').update({
                    score_team1: s1, score_team2: s2, winner_team: winner,
                    status: 'FINISHED', end_time: new Date().toISOString(),
                    match_type: isTourney ? 'TOURNAMENT' : 'REGULAR',
                    match_category: category,
                    elo_delta: delta // ✨ Save Delta!
                }).eq('id', matchId);
            }

            if (pIds.length > 0) { await supabase.from('queue').insert(pIds.map(pid => ({ player_id: pid, joined_at: new Date().toISOString(), arrived_at: new Date().toISOString(), departure_time: '23:00', priority_score: 2.5 }))); }
            fetchMatches();
        } catch (e: any) { alert(e.message); } setLoading(false);
    };

    const filteredCandidates = queueCandidates.filter(c => c.profiles?.name?.toLowerCase().includes(searchTerm.toLowerCase()));

    return (
        <div className="grid grid-cols-1 gap-4">
            {courts.map((courtName) => {
                const match = activeMatches.find(m => m.court_name === courtName);
                return (
                    <div key={courtName} className={`relative p-6 backdrop-blur-md border rounded-2xl shadow-lg flex flex-col items-center justify-center min-h-[260px] transition-all ${match?.status === 'PLAYING' ? 'bg-lime-900/20 border-lime-500/30' : match?.status === 'DRAFT' ? 'bg-amber-900/20 border-amber-500/30' : match?.status === 'SCORING' ? 'bg-cyan-900/20 border-cyan-500/30' : 'bg-white/5 border-white/10'}`}>
                        <div className="absolute top-4 left-4 bg-slate-700 px-3 py-1 rounded-md text-xs font-bold text-slate-300">{courtName}</div>
                        {courtName !== 'Court A' && courtName !== 'Court B' && (<button onClick={() => handleRemoveCourt(courtName)} className="absolute top-4 right-4 text-slate-500 hover:text-rose-500 hover:bg-rose-500/10 p-1 rounded">✕</button>)}

                        {!match ? (
                            <div className="text-center flex flex-col gap-3">
                                <p className="text-slate-500">Empty</p>
                                <div className="flex gap-2">
                                    <button onClick={() => handleAutoMatch(courtName)} disabled={loading} className="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white font-bold rounded-lg shadow-lg border border-slate-500 disabled:opacity-50 text-sm">🤖 Auto</button>
                                    <button onClick={() => openManualModal(courtName)} disabled={loading} className="px-4 py-2 bg-lime-700 hover:bg-lime-600 text-white font-bold rounded-lg shadow-lg border border-lime-500 disabled:opacity-50 text-sm">👆 Manual</button>
                                </div>
                            </div>
                        ) : match.status === 'SCORING' ? (
                            <div className="text-center w-full">
                                <p className="text-xl font-bold text-cyan-400 mb-4">✍️ Enter Score</p>
                                <div className="flex flex-col items-center justify-center mb-4 gap-2">
                                    <label className="flex items-center gap-2 cursor-pointer bg-slate-800 px-3 py-1.5 rounded-lg border border-slate-600 hover:border-amber-500 transition-colors">
                                        <input type="checkbox" checked={isTournament[match.id] || false} onChange={() => toggleTournament(match.id)} className="w-4 h-4 accent-amber-500" />
                                        <span className={`text-sm font-bold ${isTournament[match.id] ? 'text-amber-400' : 'text-slate-400'}`}>🏆 Tournament</span>
                                    </label>
                                    {isTournament[match.id] && (<input type="password" maxLength={4} placeholder="PIN" value={tournamentCode[match.id] || ''} onChange={(e) => handleCodeChange(match.id, e.target.value)} className="w-24 bg-slate-900 border border-amber-500/50 text-center text-white rounded p-1 text-sm focus:outline-none" />)}
                                </div>
                                <div className="flex items-center justify-center gap-4 mb-6">
                                    <div className="flex flex-col items-center"><span className="text-xs text-slate-400 mb-1">Team 1</span><input type="number" className="w-16 h-12 bg-slate-800 border border-slate-600 rounded text-center text-xl text-white font-bold focus:border-cyan-400 outline-none" value={scores[match.id]?.t1 || ''} onChange={(e) => handleScoreChange(match.id, 't1', e.target.value)} /></div>
                                    <span className="text-slate-500 font-bold">:</span>
                                    <div className="flex flex-col items-center"><span className="text-xs text-slate-400 mb-1">Team 2</span><input type="number" className="w-16 h-12 bg-slate-800 border border-slate-600 rounded text-center text-xl text-white font-bold focus:border-cyan-400 outline-none" value={scores[match.id]?.t2 || ''} onChange={(e) => handleScoreChange(match.id, 't2', e.target.value)} /></div>
                                </div>
                                <button onClick={() => handleSubmitScore(match.id)} disabled={loading} className={`px-6 py-2 font-bold rounded-lg shadow-lg disabled:opacity-50 text-white ${isTournament[match.id] ? 'bg-amber-600 hover:bg-amber-500' : 'bg-cyan-600 hover:bg-cyan-500'}`}>{isTournament[match.id] ? '🏆 Submit' : '✅ Submit'}</button>
                            </div>
                        ) : (
                            <div className="text-center w-full">
                                <div className={`font-bold text-xl mb-4 ${match.status === 'PLAYING' ? 'text-lime-400 animate-pulse' : 'text-amber-400'}`}>{match.status === 'PLAYING' ? '🎾 In Progress' : '📋 Match Proposed'}</div>
                                <div className="grid grid-cols-2 gap-3 w-full mb-6">
                                    {[{ id: 'player_1', n: match.p1_name, uid: match.player_1 }, { id: 'player_2', n: match.p2_name, uid: match.player_2 }, { id: 'player_3', n: match.p3_name, uid: match.player_3 }, { id: 'player_4', n: match.p4_name, uid: match.player_4 }].map((p, i) => (
                                        <div key={i} className="bg-slate-800 p-2 rounded border border-slate-600 flex items-center justify-between group relative">
                                            <span className="text-xs text-white truncate max-w-[80px]">{p.n}</span>
                                            <button onClick={() => openSwapModal(match.id, p.id, p.n, p.uid)} className="text-[10px] bg-slate-600 hover:bg-amber-500 text-white px-1.5 py-0.5 rounded opacity-0 group-hover:opacity-100 transition-all absolute right-1">🔄</button>
                                        </div>
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

            {/* Small Add Court Button */}
            <button onClick={handleAddCourt} className="w-full h-14 border-2 border-dashed border-slate-700 hover:border-lime-500/50 rounded-2xl flex items-center justify-center text-slate-500 hover:text-lime-400 font-bold transition-all group">
                <span className="text-2xl mr-2 group-hover:scale-125 transition-transform">+</span> <span>Add Court</span>
            </button>

            {/* Modals are omitted for brevity... */}
            {/* ... (Previous Modals Code) ... */}
        </div>
    );
}