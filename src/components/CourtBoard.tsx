import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
// V8.3 매칭 엔진 적용
import { calculatePriorityScore, generateV83Match } from '../services/matchingSystem';
// 검증 시스템 적용
import { reportMatchResult, confirmMatchResult, rejectMatchResult } from '../services/matchVerification';

// [Fix 3] 타입 정의를 실제 데이터 구조와 일치시킴
type QueueCandidate = {
    player_id: string;
    priority_score: number;
    joined_at: string;
    departure_time: string;
    profiles: {
        name: string;
        gender: string;
        is_guest?: boolean;
        elo_men_doubles?: number;
        elo_women_doubles?: number;
        elo_mixed_doubles?: number;
    } | null; // profiles가 없을 수도 있음 (null safe)
    finalScore: number;
};

export default function CourtBoard({ user }: { user: any }) {
    const [courts, setCourts] = useState<string[]>(['Court A', 'Court B']);
    const [activeMatches, setActiveMatches] = useState<any[]>([]);
    const [loading, setLoading] = useState(false);

    // 점수 입력 상태 관리
    const [scores, setScores] = useState<{ [matchId: string]: { t1: string, t2: string } }>({});
    const [isTournament, setIsTournament] = useState<{ [matchId: string]: boolean }>({});
    const [tournamentCode, setTournamentCode] = useState<{ [matchId: string]: string }>({});

    // 모달 상태 관리
    const [isSwapModalOpen, setIsSwapModalOpen] = useState(false);
    const [swapTarget, setSwapTarget] = useState<{ matchId: string; col: string; oldName: string; oldId: string } | null>(null);
    const [isManualModalOpen, setIsManualModalOpen] = useState(false);
    const [manualTargetCourt, setManualTargetCourt] = useState<string | null>(null);
    const [selectedManualPlayers, setSelectedManualPlayers] = useState<QueueCandidate[]>([]);
    const [queueCandidates, setQueueCandidates] = useState<QueueCandidate[]>([]);
    const [searchTerm, setSearchTerm] = useState('');

    useEffect(() => {
        checkDailyReset(); // Check for 22:00 auto-reset
        fetchMatches();
        const channel = supabase.channel('public:matches').on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => { fetchMatches(); }).subscribe();
        return () => { supabase.removeChannel(channel); };
    }, []);

    // [New Feature] 22:00 Reset Logic
    const checkDailyReset = async () => {
        const now = new Date();
        // Check if it's past 22:00 (10 PM)
        if (now.getHours() >= 22) {
            // Check if queue is not empty to avoid redundant calls
            const { count } = await supabase.from('queue').select('*', { count: 'exact', head: true });
            if (count && count > 0) {
                console.log("🕒 22:00 Passed. Clearing Queue...");
                await supabase.from('queue').delete().neq('player_id', 'placeholder_id'); // Delete All
                fetchMatches();
            }
        }
    };

    // [Fix 1] fetchMatches: 프로필 이름 매핑 로직 강화 (Data Loss 방지) & 완료된 매치 숨기기
    const fetchMatches = async () => {
        const { data: matchData } = await supabase
            .from('matches')
            .select('*')
            .from('matches')
            .select('*')
            .neq('status', 'FINISHED'); // [Refactor] remove legacy 'completed' check

        if (!matchData) return;

        const allPlayerIds = new Set<string>();
        matchData.forEach((m: any) => {
            if (m.player_1) allPlayerIds.add(m.player_1);
            if (m.player_2) allPlayerIds.add(m.player_2);
            if (m.player_3) allPlayerIds.add(m.player_3);
            if (m.player_4) allPlayerIds.add(m.player_4);
        });

        if (allPlayerIds.size > 0) {
            const { data: profiles } = await supabase
                .from('profiles')
                .select('id, name')
                .in('id', Array.from(allPlayerIds));

            // Map을 사용하여 O(1) 조회 속도 확보
            const profileMap = new Map(profiles?.map((p: any) => [p.id, p.name]));

            const enriched = matchData.map((m: any) => ({
                ...m,
                p1_name: profileMap.get(m.player_1) || 'Unknown',
                p2_name: profileMap.get(m.player_2) || 'Unknown',
                p3_name: profileMap.get(m.player_3) || 'Unknown',
                p4_name: profileMap.get(m.player_4) || 'Unknown',
            }));
            setActiveMatches(enriched);
        } else {
            setActiveMatches(matchData);
        }
    };

    const handleAddCourt = () => { const nextChar = String.fromCharCode(65 + courts.length); setCourts([...courts, `Court ${nextChar}`]); };
    const handleRemoveCourt = (courtName: string) => { if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; } if (confirm(`🗑️ Remove ${courtName}?`)) setCourts(prev => prev.filter(c => c !== courtName)); };

    // ✨ [V8.2] 스마트 정렬 로직 (Service 위임)
    const getSmartSortedQueue = async () => {
        const { data: queueData } = await supabase
            .from('queue')
            .select(`
                *,
                profiles (name, gender, is_guest, elo_men_doubles, elo_women_doubles, elo_mixed_doubles, games_played_today, ntrp)
            `)
            .eq('is_active', true);

        if (!queueData || queueData.length === 0) return [];

        // V8.2 점수 계산
        const scoredQueue = queueData.map((item: any) => ({
            ...item,
            finalScore: calculatePriorityScore(item)
        }));

        return scoredQueue.sort((a: any, b: any) => b.finalScore - a.finalScore);
    };

    // ✨ [V8.3] 자동 매칭 엔진 (Service 위임)
    const handleAutoMatch = async (courtName: string) => {
        if (loading) return;
        if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; }

        setLoading(true);
        try {
            const sortedList = await getSmartSortedQueue();

            // V8.3 매칭 엔진 호출
            const matchResult = generateV83Match(sortedList);

            if (!matchResult) {
                alert("❌ 매칭 실패: 인원이 부족하거나 조건에 맞는 조합이 없습니다.");
                setLoading(false);
                return;
            }

            const { matchType, team1, team2, playerIds } = matchResult;

            console.log(`[V8.3] Match Generated: ${matchType}`, { team1, team2 });

            // 5. 매치 생성
            const { error } = await supabase.from('matches').insert({
                court_name: courtName,
                status: 'DRAFT',
                match_category: matchType,
                player_1: team1[0].player_id, player_2: team1[1].player_id,
                player_3: team2[0].player_id, player_4: team2[1].player_id
            });

            if (error) throw error;

            // 대기열에서 삭제
            await supabase.from('queue').delete().in('player_id', playerIds);

            fetchMatches();
        } catch (e: any) { alert(e.message); }
        setLoading(false);
    };

    // [Manual Modal] 관련
    const openManualModal = async (courtName: string) => {
        if (loading) return; if (activeMatches.find(m => m.court_name === courtName)) { alert("❌ Court busy!"); return; } setLoading(true);
        const sortedList = await getSmartSortedQueue();
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

    // [Match Management] 관련
    const handleCancelMatch = async (matchId: string) => {
        if (!confirm("⚠️ Cancel match?")) return; setLoading(true);
        try {
            const match = activeMatches.find(m => m.id === matchId);
            if (match) {
                const pIds = [match.player_1, match.player_2, match.player_3, match.player_4].filter(Boolean);
                const { error } = await supabase.from('matches').delete().eq('id', matchId); if (error) throw error;
                if (pIds.length > 0) {
                    await supabase.from('queue').insert(pIds.map(pid => ({
                        player_id: pid,
                        joined_at: new Date().toISOString(),
                        priority_score: 1000,
                        is_active: true
                    })));
                }
                alert("✅ Canceled."); fetchMatches();
            }
        } catch (e: any) { alert("Error: " + e.message); } setLoading(false);
    };

    // [Swap] 관련
    const openSwapModal = async (matchId: string, col: string, oldName: string, oldId: string) => {
        if (loading) return; setLoading(true); const sortedList = await getSmartSortedQueue();
        if (sortedList) { setQueueCandidates(sortedList as any); setSwapTarget({ matchId, col, oldName, oldId }); setSearchTerm(''); setIsSwapModalOpen(true); } setLoading(false);
    };
    const handleExecuteSwap = async (candidate: QueueCandidate) => {
        if (!swapTarget) return; if (!confirm(`🔄 Swap with [${candidate.profiles?.name}]?`)) return;
        try {
            await supabase.from('matches').update({ [swapTarget.col]: candidate.player_id }).eq('id', swapTarget.matchId); await supabase.from('queue').delete().eq('player_id', candidate.player_id);
            if (swapTarget.oldId) { await supabase.from('queue').insert({ player_id: swapTarget.oldId, priority_score: 1000, joined_at: new Date().toISOString(), is_active: true }); }
            setIsSwapModalOpen(false); setSwapTarget(null); fetchMatches();
        } catch (e: any) { alert("Swap Error: " + e.message); }
    };

    // [Game Control]
    const handleStartGame = async (matchId: string) => { await supabase.from('matches').update({ status: 'PLAYING', start_time: new Date().toISOString() }).eq('id', matchId); fetchMatches(); };
    const handleEndGame = async (matchId: string) => { if (confirm("Finish game?")) { await supabase.from('matches').update({ status: 'SCORING' }).eq('id', matchId); fetchMatches(); } };

    // [Score & Tournament]
    const handleScoreChange = (matchId: string, team: 't1' | 't2', value: string) => setScores(prev => ({ ...prev, [matchId]: { ...prev[matchId], [team]: value } }));
    const handleCodeChange = (matchId: string, value: string) => setTournamentCode(prev => ({ ...prev, [matchId]: value }));
    const toggleTournament = (matchId: string) => setIsTournament(prev => ({ ...prev, [matchId]: !prev[matchId] }));

    const handleSubmitScore = async (matchId: string) => {
        const s = scores[matchId];
        if (!s || !s.t1 || !s.t2) { alert("Scores required"); return; }

        const isTourney = isTournament[matchId] || false;
        if (isTourney && tournamentCode[matchId] !== '7777') { alert("⛔ Wrong Code!"); return; }

        const s1 = parseInt(s.t1), s2 = parseInt(s.t2);
        const winner = s1 > s2 ? 'TEAM_1' : s2 > s1 ? 'TEAM_2' : 'DRAW';

        setLoading(true);
        try {
            const match = activeMatches.find(m => m.id === matchId);
            const pIds = [match.player_1, match.player_2, match.player_3, match.player_4].filter(Boolean);
            const { data: players } = await supabase.from('profiles').select('id, gender').in('id', pIds);

            if (players && players.length === 4) {
                const males = players.filter((p: any) => (p.gender || '').toLowerCase() === 'male').length;
                let category = 'MIXED'; let label = 'Mixed Doubles';
                if (males === 4) { category = 'MEN_D'; label = "Men's Doubles"; }
                else if (males === 0) { category = 'WOMEN_D'; label = "Women's Doubles"; }

                if (!confirm(`Confirm: ${s1}:${s2}? \n[${label}]`)) { setLoading(false); return; }

                // 1. Update Match Metadata
                await supabase.from('matches').update({
                    winner_team: winner,
                    match_type: isTourney ? 'TOURNAMENT' : 'REGULAR',
                    match_category: category
                }).eq('id', matchId);

                // 2. Report Scores via Service
                await reportMatchResult(matchId, s1, s2, user.id);

                alert("✅ Result Reported! Waiting for opponent confirmation.");
            }
            fetchMatches();
        } catch (e: any) { alert(e.message); } setLoading(false);
    };

    const handleConfirmMatch = async (matchId: string) => {
        if (!confirm("✅ Confirm this result?")) return;
        if (!user) { alert("User not logged in."); return; }
        setLoading(true);
        try {
            await confirmMatchResult(matchId, user.id);
            alert("🎉 Match Confirmed! ELO updated.");
            fetchMatches();
        } catch (e: any) { alert(e.message); }
        setLoading(false);
    };

    const handleRejectMatch = async (matchId: string) => {
        if (!confirm("⛔ Reject this result?")) return;
        if (!user) { alert("User not logged in."); return; }
        setLoading(true);
        try {
            await rejectMatchResult(matchId, user.id);
            alert("🛑 Match Rejected. Status set to Disputed.");
            fetchMatches();
        } catch (e: any) { alert(e.message); }
        setLoading(false);
    };

    const getMyTeam = (match: any, uid: string) => {
        if (!match || !uid) return 0;
        if ([match.player_1, match.player_2].includes(uid)) return 1;
        if ([match.player_3, match.player_4].includes(uid)) return 2;
        return 0;
    };

    const filteredCandidates = queueCandidates.filter(c => c.profiles?.name?.toLowerCase().includes(searchTerm.toLowerCase()));

    return (
        <div className="grid grid-cols-1 gap-4">
            {courts.map((courtName) => {
                const match = activeMatches.find(m => m.court_name === courtName);

                const myTeam = user ? getMyTeam(match, user.id) : 0;
                const reporterTeam = match?.reported_by ? getMyTeam(match, match.reported_by) : 0;
                const isReporter = user && match?.reported_by === user.id;

                // [Fix 2] 제3자에게 버튼 안 보이게 하기
                // 내가 참가자이고(myTeam !== 0), 리포터와 다른 팀이어야 승인 권한(isOpponent) 가짐
                const isOpponent = myTeam !== 0 && myTeam !== reporterTeam && match?.status === 'PENDING';

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
                        ) : match.status === 'PENDING' ? (
                            <div className="text-center w-full animate-pulse">
                                <p className="text-lg font-bold text-amber-400 mb-2">⏳ Confirmation Pending</p>
                                <div className="text-white text-2xl font-black mb-4 tracking-widest">{match.score_team1} : {match.score_team2}</div>

                                {isReporter ? (
                                    <div className="text-slate-400 text-sm bg-slate-800/50 p-2 rounded">
                                        Waiting for opponent to confirm...
                                    </div>
                                ) : isOpponent ? (
                                    <div className="flex gap-2 justify-center">
                                        <button onClick={() => handleConfirmMatch(match.id)} disabled={loading} className="px-6 py-2 bg-lime-600 hover:bg-lime-500 text-white font-bold rounded-xl shadow-lg border-b-4 border-lime-800 active:border-b-0 active:translate-y-1 transition-all">✅ Confirm</button>
                                        <button onClick={() => handleRejectMatch(match.id)} disabled={loading} className="px-6 py-2 bg-rose-600 hover:bg-rose-500 text-white font-bold rounded-xl shadow-lg border-b-4 border-rose-800 active:border-b-0 active:translate-y-1 transition-all">⛔ Reject</button>
                                    </div>
                                ) : (
                                    <div className="text-slate-500 text-xs">
                                        Verification in progress...
                                    </div>
                                )}
                            </div>
                        ) : match.status === 'SCORING' ? (
                            <div className="text-center w-full">
                                <p className="text-xl font-bold text-cyan-400 mb-4">✍️ Enter Score</p>
                                {/* 점수 입력 UI 생략 (기존 유지) */}
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

            <button onClick={handleAddCourt} className="w-full h-14 border-2 border-dashed border-slate-700 hover:border-lime-500/50 rounded-2xl flex items-center justify-center text-slate-500 hover:text-lime-400 font-bold transition-all group">
                <span className="text-2xl mr-2 group-hover:scale-125 transition-transform">+</span> <span>Add Court</span>
            </button>

            {/* 모달 렌더링 (Manual & Swap) - 기존 코드 유지 */}
            {isManualModalOpen && (
                <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
                    <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-md max-h-[80vh] flex flex-col shadow-2xl">
                        <div className="p-4 border-b border-slate-700 flex justify-between items-center"><h3 className="text-white font-bold text-lg">👆 Manual ({selectedManualPlayers.length}/4)</h3><button onClick={() => setIsManualModalOpen(false)} className="text-slate-400 hover:text-white">✕</button></div>
                        <div className="p-4 border-b border-slate-900/50"><input type="text" placeholder="Search..." value={searchTerm} onChange={(e) => setSearchTerm(e.target.value)} className="w-full bg-slate-800 border border-slate-600 text-white p-2 rounded-lg outline-none" autoFocus /></div>
                        <div className="overflow-y-auto flex-1 p-2 space-y-1">
                            {filteredCandidates.map((c) => {
                                const idx = selectedManualPlayers.findIndex(p => p.player_id === c.player_id); const isSel = idx !== -1;
                                return (<button key={c.player_id} onClick={() => toggleManualSelection(c)} className={`w-full flex justify-between p-3 rounded-xl border ${isSel ? 'bg-lime-500/20 border-lime-500/50' : 'hover:bg-slate-700 border-transparent'}`}><div className="flex gap-3"><span className={`w-6 h-6 rounded-full flex center text-xs font-bold ${isSel ? 'bg-lime-500 text-slate-900' : 'bg-slate-700 text-slate-300'}`}>{isSel ? idx + 1 : '-'}</span><p className="text-white font-bold text-sm">{c.profiles?.name} {c.profiles?.is_guest && '(G)'}</p></div></button>);
                            })}
                        </div>
                        <div className="p-4 border-t border-slate-700"><button onClick={confirmManualMatch} disabled={selectedManualPlayers.length !== 4} className="w-full py-3 bg-lime-600 hover:bg-lime-500 text-white font-bold rounded-xl shadow-lg disabled:opacity-50">Create Match</button></div>
                    </div>
                </div>
            )}
            {isSwapModalOpen && (
                <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
                    <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-md max-h-[80vh] flex flex-col shadow-2xl">
                        <div className="p-4 border-b border-slate-700 flex justify-between items-center"><h3 className="text-white font-bold text-lg">Swap Player</h3><button onClick={() => setIsSwapModalOpen(false)} className="text-slate-400 hover:text-white">✕</button></div>
                        <div className="p-4 border-b border-slate-900/50"><input type="text" placeholder="Search..." value={searchTerm} onChange={(e) => setSearchTerm(e.target.value)} className="w-full bg-slate-800 border border-slate-600 text-white p-2 rounded-lg outline-none" autoFocus /></div>
                        <div className="overflow-y-auto flex-1 p-2 space-y-1">
                            {filteredCandidates.map((c, idx) => (
                                <button key={c.player_id} onClick={() => handleExecuteSwap(c)} className="w-full flex justify-between p-3 rounded-xl hover:bg-lime-500/20 border border-transparent"><div className="flex gap-3"><span className="w-6 h-6 bg-slate-700 rounded-full flex center text-xs font-bold text-slate-300">{idx + 1}</span><p className="text-white font-bold text-sm">{c.profiles?.name} {c.profiles?.is_guest && '(G)'}</p></div><span className="text-xs bg-slate-700 text-slate-300 px-2 py-1 rounded">Select</span></button>
                            ))}
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
}