import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

// [Update] role 필드 추가
type Profile = {
    id: string;
    email: string;
    name: string;
    gender: string;
    ntrp: number;
    is_guest: boolean;
    role?: string; // 'member', 'coach', 'admin'
};

type Notice = { id: string; content: string; is_active: boolean; created_at: string; };
type Match = {
    id: string; end_time: string; score_team1: number; score_team2: number; winner_team: string;
    player_1: string; player_2: string; player_3: string; player_4: string;
    elo_delta: number; match_category: string;
    status: string; // [Update] status 필드 필수
    p1_name?: string; p2_name?: string; p3_name?: string; p4_name?: string;
};

type Props = { onClose: () => void; };

export default function AdminBoard({ onClose }: Props) {
    const [activeTab, setActiveTab] = useState<'MEMBERS' | 'NOTICES' | 'MATCHES' | 'EVENTS'>('MEMBERS');
    const [profiles, setProfiles] = useState<Profile[]>([]);
    const [notices, setNotices] = useState<Notice[]>([]);
    const [matches, setMatches] = useState<Match[]>([]);
    const [loading, setLoading] = useState(false);
    const [searchTerm, setSearchTerm] = useState('');

    // [New] State for Team Balancer
    const [selectedEventMembers, setSelectedEventMembers] = useState<Set<string>>(new Set());
    const [blueCaptain, setBlueCaptain] = useState<string>('');
    const [whiteCaptain, setWhiteCaptain] = useState<string>('');
    const [generatedTeams, setGeneratedTeams] = useState<{ blue: Profile[], white: Profile[], blueAvg: number, whiteAvg: number } | null>(null);

    // [New] State for Partner Recommendation
    const [recPartner, setRecPartner] = useState<{ name: string, winRate: number, count: number } | null>(null);

    const [editingId, setEditingId] = useState<string | null>(null);
    const [editForm, setEditForm] = useState<Partial<Profile>>({});
    const [newNotice, setNewNotice] = useState('');

    useEffect(() => {
        if (activeTab === 'MEMBERS') fetchProfiles();
        else if (activeTab === 'NOTICES') fetchNotices();
        else fetchMatches();
    }, [activeTab]);

    const fetchProfiles = async () => {
        setLoading(true);
        const { data } = await supabase.from('profiles').select('*').order('name', { ascending: true });
        if (data) setProfiles(data);
        setLoading(false);
    };
    const fetchNotices = async () => {
        setLoading(true);
        const { data } = await supabase.from('notices').select('*').order('created_at', { ascending: false });
        if (data) setNotices(data);
        setLoading(false);
    };

    // ✅ [핵심 수정] PENDING 상태인 경기도 가져오도록 수정
    const fetchMatches = async () => {
        setLoading(true);
        const { data: matches } = await supabase
            .from('matches')
            .select('*')
            // 'pending' (소문자 주의), 'FINISHED', 'DISPUTED' 상태 모두 가져옴
            .in('status', ['FINISHED', 'pending', 'DISPUTED'])
            .order('end_time', { ascending: false })
            .limit(50);

        if (matches) {
            const pIds = new Set<string>();
            matches.forEach((m: any) => { if (m.player_1) pIds.add(m.player_1); if (m.player_2) pIds.add(m.player_2); if (m.player_3) pIds.add(m.player_3); if (m.player_4) pIds.add(m.player_4); });
            const { data: pNames } = await supabase.from('profiles').select('id, name').in('id', Array.from(pIds));
            const enriched = matches.map((m: any) => ({
                ...m,
                p1_name: pNames?.find((p: any) => p.id === m.player_1)?.name || '?', p2_name: pNames?.find((p: any) => p.id === m.player_2)?.name || '?',
                p3_name: pNames?.find((p: any) => p.id === m.player_3)?.name || '?', p4_name: pNames?.find((p: any) => p.id === m.player_4)?.name || '?',
            }));
            setMatches(enriched);
        }
        setLoading(false);
    };

    const startEdit = (p: Profile) => {
        setEditingId(p.id);
        setEditForm({ name: p.name, gender: p.gender || 'Male', ntrp: p.ntrp, role: p.role || 'member' });
    };

    const saveEdit = async () => {
        if (!editingId) return;
        const { error } = await supabase.from('profiles').update(editForm).eq('id', editingId);
        if (error) alert(error.message);
        else { setEditingId(null); fetchProfiles(); }
    };

    const clearQueue = async () => { if (!confirm("⚠️ 대기열을 초기화하시겠습니까? (모든 대기자 삭제)")) return; await supabase.from('queue').delete().neq('user_id', '00000000-0000-0000-0000-000000000000'); alert("Queue Cleared!"); };

    const addNotice = async () => { if (!newNotice.trim()) return; await supabase.from('notices').insert({ content: newNotice, is_active: true }); setNewNotice(''); fetchNotices(); };
    const deleteNotice = async (id: string) => { if (!confirm("Delete this notice?")) return; await supabase.from('notices').delete().eq('id', id); fetchNotices(); };

    // ✅ [기능 추가] 관리자 강제 승인 기능
    const adminConfirmMatch = async (matchId: string) => {
        if (!confirm("관리자 권한으로 이 결과를 승인하시겠습니까? (ELO 점수가 반영됩니다)")) return;
        setLoading(true);
        try {
            // 1. 상태를 FINISHED로 변경
            const { error } = await supabase.from('matches').update({ status: 'FINISHED' }).eq('id', matchId);
            if (error) throw error;

            // (참고: ELO 계산 로직이 DB 트리거에 있다면 자동 실행됨. 없다면 별도 계산 필요하지만, 일단 승인 처리만 수행)

            alert("✅ 관리자 승인 완료!");
            fetchMatches(); // 목록 새로고침
        } catch (e: any) { alert("Error: " + e.message); }
        setLoading(false);
    };

    const rollbackMatch = async (m: Match) => {
        // PENDING 상태일 때 '거절' 누르면 롤백이 아니라 그냥 삭제/취소임
        const isPending = m.status.toLowerCase() === 'pending';
        const msg = isPending
            ? "이 경기 결과를 거절하고 무효화하시겠습니까?"
            : `⚠️ WARNING: 이 경기 기록을 삭제하고 점수를 롤백하시겠습니까?`;

        if (!confirm(msg)) return;

        setLoading(true);
        try {
            // 이미 끝난 경기라면 점수 원복 로직 실행
            if (!isPending) {
                const delta = m.elo_delta || 0;
                let eloField = 'elo_mixed_doubles';
                if (m.match_category === 'MEN_D') eloField = 'elo_men_doubles';
                else if (m.match_category === 'WOMEN_D') eloField = 'elo_women_doubles';
                else if (m.match_category === 'SINGLES') eloField = 'elo_singles';

                if (delta !== 0 && m.winner_team !== 'DRAW') {
                    const winners = m.winner_team === 'TEAM_1' ? [m.player_1, m.player_2] : [m.player_3, m.player_4];
                    const losers = m.winner_team === 'TEAM_1' ? [m.player_3, m.player_4] : [m.player_1, m.player_2];
                    const { data: players } = await supabase.from('profiles').select(`id, ${eloField}`).in('id', [...winners, ...losers].filter(Boolean));

                    if (players) {
                        for (const p of players) {
                            const isWinner = winners.includes(p.id);
                            const revertAmount = isWinner ? -delta : delta;
                            const currentScore = (p as any)[eloField] || 1200;
                            const newScore = currentScore + revertAmount;

                            await supabase.from('profiles').update({ [eloField]: newScore }).eq('id', p.id);
                            await supabase.from('elo_history').insert({
                                player_id: p.id,
                                match_type: m.match_category,
                                elo_score: newScore,
                                delta: revertAmount,
                                created_at: new Date().toISOString()
                            });
                        }
                    }
                }
            }

            // 경기 기록 삭제 (거절/롤백 공통)
            const { error } = await supabase.from('matches').delete().eq('id', m.id);
            if (error) throw error;

            alert(isPending ? "🚫 승인 거절됨 (기록 삭제)" : "✅ 롤백 완료");
            fetchMatches();
        } catch (e: any) { alert("Error: " + e.message); }
        setLoading(false);
    };

    // ------------------------------------------------------------------
    // 1. 📅 Season Soft Reset (Compression Logic)
    // ------------------------------------------------------------------
    const softResetSeason = async () => {
        if (!confirm("⚠️ [SEASON RESET] 정말 시즌을 초기화하시겠습니까?\n\n모든 유저의 점수가 1200점 기준으로 압축됩니다.\n(예: 1600 -> 1400, 1000 -> 1100)")) return;

        const userInput = prompt("초기화를 진행하려면 'RESET'을 입력하세요.");
        if (userInput !== 'RESET') return alert("취소되었습니다.");

        setLoading(true);
        try {
            // Fetch all profiles
            const { data: allProfiles } = await supabase.from('profiles').select('id, elo_men_doubles, elo_women_doubles, elo_mixed_doubles, elo_singles');
            if (!allProfiles) throw new Error("No profiles found");

            for (const p of allProfiles) {
                // Apply Formula: New = 1200 + (Old - 1200) / 2
                const compress = (old: number) => Math.round(1200 + ((old || 1200) - 1200) / 2);

                await supabase.from('profiles').update({
                    elo_men_doubles: compress(p.elo_men_doubles),
                    elo_women_doubles: compress(p.elo_women_doubles),
                    elo_mixed_doubles: compress(p.elo_mixed_doubles),
                    elo_singles: compress(p.elo_singles),
                }).eq('id', p.id);
            }
            alert("✅ 시즌 소프트 리셋 완료! 점수가 압축되었습니다.");
            fetchProfiles();
        } catch (e: any) { alert("Error: " + e.message); }
        setLoading(false);
    };

    // ------------------------------------------------------------------
    // 2. ⚔️ Cheong-Baek-Jeon Team Balancer
    // ------------------------------------------------------------------
    const toggleEventMember = (id: string) => {
        const newSet = new Set(selectedEventMembers);
        if (newSet.has(id)) newSet.delete(id); else newSet.add(id);
        setSelectedEventMembers(newSet);
    };

    const generateBalancedTeams = () => {
        if (!blueCaptain || !whiteCaptain) return alert("청팀/백팀 주장을 먼저 선택해주세요.");

        // Filter valid pool (excluding captains)
        const pool = profiles.filter(p => selectedEventMembers.has(p.id) && p.id !== blueCaptain && p.id !== whiteCaptain);

        // Sort by mixed ELO (default) descending
        pool.sort((a, b) => (b.ntrp || 0) - (a.ntrp || 0)); // Use NTRP or ELO as proxy

        // Snake Draft
        const blueTeam: Profile[] = [];
        const whiteTeam: Profile[] = [];

        // Add captains first
        const bCap = profiles.find(p => p.id === blueCaptain);
        const wCap = profiles.find(p => p.id === whiteCaptain);
        if (bCap) blueTeam.push(bCap);
        if (wCap) whiteTeam.push(wCap);

        pool.forEach((p, idx) => {
            // Snake: 0->Blue, 1->White, 2->White, 3->Blue ...
            // Simple Alternating for now roughly works if sorted, but let's do simple A/B/B/A
            if (idx % 4 === 0 || idx % 4 === 3) blueTeam.push(p);
            else whiteTeam.push(p);
        });

        // Calculate Stats
        const getAvg = (team: Profile[]) => {
            if (team.length === 0) return 0;
            const sum = team.reduce((acc, p) => acc + (p.ntrp || 0), 0);
            return (sum / team.length).toFixed(2);
        };

        setGeneratedTeams({
            blue: blueTeam,
            white: whiteTeam,
            blueAvg: Number(getAvg(blueTeam)),
            whiteAvg: Number(getAvg(whiteTeam))
        });
    };

    // ------------------------------------------------------------------
    // 3. 🤝 Smart Partner Recommendation
    // ------------------------------------------------------------------
    const fetchBestPartner = async (targetId: string) => {
        setRecPartner(null);
        // Find finished matches where this user played
        const { data: history } = await supabase.from('matches')
            .select('*')
            .eq('status', 'FINISHED')
            .or(`player_1.eq.${targetId},player_2.eq.${targetId},player_3.eq.${targetId},player_4.eq.${targetId}`)
            .order('end_time', { ascending: false })
            .limit(100);

        if (!history || history.length === 0) return;

        const partnerStats: Record<string, { wins: number, total: number, name: string }> = {};

        // Helper to get partner ID
        const getPartner = (m: Match, myId: string) => {
            if (m.player_1 === myId) return { id: m.player_2, name: m.p2_name };
            if (m.player_2 === myId) return { id: m.player_1, name: m.p1_name };
            if (m.player_3 === myId) return { id: m.player_4, name: m.p4_name };
            if (m.player_4 === myId) return { id: m.player_3, name: m.p3_name };
            return null;
        };

        // Helper to check win
        const didWin = (m: Match, myId: string) => {
            const myTeam = (m.player_1 === myId || m.player_2 === myId) ? 'TEAM_1' : 'TEAM_2';
            return m.winner_team === myTeam;
        };

        // Iterate
        // Note: p1_name etc might be missing in raw fetch if we don't join, 
        // but 'matches' from state has names if we use that. 
        // Here we are fetching fresh. Ideally we use 'profiles' map.

        for (const m of history) {
            const partnerInfo = getPartner(m as any, targetId); // simplified
            if (!partnerInfo || !partnerInfo.id) continue;

            // Resolve name from 'profiles' state if possible
            const pProfile = profiles.find(p => p.id === partnerInfo.id);
            const pName = pProfile?.name || 'Unknown';

            if (!partnerStats[partnerInfo.id]) partnerStats[partnerInfo.id] = { wins: 0, total: 0, name: pName };

            partnerStats[partnerInfo.id].total += 1;
            if (didWin(m as any, targetId)) partnerStats[partnerInfo.id].wins += 1;
        }

        // Find Best
        let bestPid = '';
        let bestWr = -1;
        let bestCount = 0;

        Object.entries(partnerStats).forEach(([pid, stat]) => {
            if (stat.total < 2) return; // Min 2 games
            const wr = stat.wins / stat.total;
            if (wr > bestWr) {
                bestWr = wr;
                bestPid = pid;
                bestCount = stat.total;
            }
        });

        if (bestPid) {
            setRecPartner({
                name: partnerStats[bestPid].name,
                winRate: Math.round(bestWr * 100),
                count: bestCount
            });
        }
    };

    // When clicking 'Edit' (or expanding), we define a wrapper
    const handleStartEdit = (p: Profile) => {
        startEdit(p);
        fetchBestPartner(p.id);
    };

    const filteredProfiles = profiles.filter(p => p.name?.toLowerCase().includes(searchTerm.toLowerCase()));

    return (
        <div className="fixed inset-0 z-[90] bg-slate-900 flex flex-col animate-fadeIn">
            {/* Header */}
            <div className="p-4 border-b border-slate-700 bg-slate-800 flex justify-between items-center shadow-md">
                <h2 className="text-xl font-black text-rose-500 flex items-center gap-2">🛡️ 관리자 대시보드</h2>
                <button onClick={onClose} className="bg-slate-700 hover:bg-slate-600 px-4 py-2 rounded-lg font-bold text-white transition-colors">닫기 (Exit)</button>
            </div>

            {/* Mobile Tabs */}
            <div className="flex md:hidden border-b border-slate-700 bg-slate-800">
                <button onClick={() => setActiveTab('MEMBERS')} className={`flex-1 p-3 text-sm font-bold ${activeTab === 'MEMBERS' ? 'text-lime-400 border-b-2 border-lime-400' : 'text-slate-400'}`}>👥 회원</button>
                <button onClick={() => setActiveTab('NOTICES')} className={`flex-1 p-3 text-sm font-bold ${activeTab === 'NOTICES' ? 'text-yellow-400 border-b-2 border-yellow-400' : 'text-slate-400'}`}>📢 공지</button>
                <button onClick={() => setActiveTab('MATCHES')} className={`flex-1 p-3 text-sm font-bold ${activeTab === 'MATCHES' ? 'text-rose-400 border-b-2 border-rose-400' : 'text-slate-400'}`}>🎾 경기</button>
                <button onClick={() => setActiveTab('EVENTS')} className={`flex-1 p-3 text-sm font-bold ${activeTab === 'EVENTS' ? 'text-purple-400 border-b-2 border-purple-400' : 'text-slate-400'}`}>🎉 이벤트</button>
            </div>

            <div className="flex-1 flex overflow-hidden">
                {/* Desktop Sidebar */}
                <div className="w-64 bg-slate-800/50 border-r border-slate-700 p-4 flex flex-col gap-2 hidden md:flex">
                    <button onClick={() => setActiveTab('MEMBERS')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'MEMBERS' ? 'bg-slate-700 text-lime-400' : 'text-slate-400 hover:bg-slate-800'}`}>👥 회원 관리</button>
                    <button onClick={() => setActiveTab('NOTICES')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'NOTICES' ? 'bg-slate-700 text-yellow-400' : 'text-slate-400 hover:bg-slate-800'}`}>📢 공지사항</button>
                    <button onClick={() => setActiveTab('MATCHES')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'MATCHES' ? 'bg-slate-700 text-rose-400' : 'text-slate-400 hover:bg-slate-800'}`}>🎾 경기 승인/롤백</button>
                    <button onClick={() => setActiveTab('EVENTS')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'EVENTS' ? 'bg-slate-700 text-purple-400' : 'text-slate-400 hover:bg-slate-800'}`}>🎉 이벤트 (팀짜기)</button>

                    <div className="mt-auto pt-4 border-t border-slate-700">
                        <button onClick={clearQueue} className="w-full text-left p-3 rounded-lg font-bold text-rose-500 hover:bg-rose-900/20 text-xs">⚠️ 대기열 강제 초기화</button>
                    </div>
                </div>

                {/* Main Content */}
                <div className="flex-1 p-4 md:p-6 overflow-y-auto custom-scrollbar bg-slate-900">
                    {activeTab === 'MEMBERS' && (
                        <div className="space-y-4">
                            <input
                                type="text"
                                placeholder="🔍 이름 검색..."
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                                className="w-full bg-slate-800 border border-slate-700 rounded-lg p-3 text-white outline-none focus:border-lime-500"
                            />
                            <div className="bg-slate-800 rounded-xl border border-slate-700 overflow-hidden shadow-lg">
                                <div className="overflow-x-auto">
                                    <table className="w-full text-left border-collapse">
                                        <thead className="bg-slate-700 text-slate-300 text-xs uppercase">
                                            <tr><th className="p-4 min-w-[100px]">이름</th><th className="p-4">성별</th><th className="p-4">NTRP</th><th className="p-4">등급(Role)</th><th className="p-4 text-right">관리</th></tr>
                                        </thead>
                                        <tbody className="divide-y divide-slate-700">
                                            {loading ? <tr><td colSpan={5} className="p-8 text-center text-slate-500">로딩 중...</td></tr> : filteredProfiles.map(p => (
                                                <tr key={p.id} className="hover:bg-slate-700/50">
                                                    <td className="p-4">
                                                        {editingId === p.id ? <input className="bg-slate-900 border border-slate-600 rounded px-2 py-1 text-white w-full" value={editForm.name} onChange={e => setEditForm({ ...editForm, name: e.target.value })} /> : <span className="font-bold text-white">{p.name}</span>}
                                                    </td>
                                                    <td className="p-4">
                                                        {editingId === p.id ? (
                                                            <select className="bg-slate-900 border border-slate-600 rounded px-2 py-1 text-white" value={editForm.gender} onChange={e => setEditForm({ ...editForm, gender: e.target.value })}>
                                                                <option value="Male">남</option><option value="Female">여</option>
                                                            </select>
                                                        ) : <span className={`text-xs px-2 py-1 rounded ${p.gender === 'Male' ? 'bg-blue-900/50 text-blue-300' : 'bg-rose-900/50 text-rose-300'}`}>{p.gender}</span>}
                                                    </td>
                                                    <td className="p-4">
                                                        {editingId === p.id ? (
                                                            <input type="number" step="0.5" className="bg-slate-900 border border-slate-600 rounded px-2 py-1 text-white w-16" value={editForm.ntrp} onChange={e => setEditForm({ ...editForm, ntrp: parseFloat(e.target.value) })} />
                                                        ) : <span className="font-mono text-slate-400">{p.ntrp}</span>}
                                                    </td>
                                                    <td className="p-4">
                                                        {editingId === p.id ? (
                                                            <select
                                                                className="bg-slate-900 border border-slate-600 rounded px-2 py-1 text-white text-xs"
                                                                value={editForm.role}
                                                                onChange={e => setEditForm({ ...editForm, role: e.target.value })}
                                                            >
                                                                <option value="member">Member</option>
                                                                <option value="coach">Coach</option>
                                                                <option value="admin">Admin</option>
                                                            </select>
                                                        ) : (
                                                            <span className={`text-xs px-2 py-1 rounded font-bold ${p.role === 'coach' ? 'bg-purple-900 text-purple-300' : p.role === 'admin' ? 'bg-rose-900 text-rose-300' : 'bg-slate-700 text-slate-400'}`}>
                                                                {p.role || 'member'}
                                                            </span>
                                                        )}
                                                    </td>
                                                    <td className="p-4 text-right">
                                                        {editingId === p.id ?
                                                            <div className="flex gap-2 justify-end items-center">
                                                                {recPartner && (
                                                                    <span className="text-[10px] bg-indigo-900 text-indigo-200 px-2 py-1 rounded border border-indigo-500/50 animate-pulse">
                                                                        🔥 Best: {recPartner.name} ({recPartner.winRate}%)
                                                                    </span>
                                                                )}
                                                                <button onClick={saveEdit} className="bg-lime-600 hover:bg-lime-500 text-white px-3 py-1 rounded text-xs font-bold">저장</button>
                                                                <button onClick={() => setEditingId(null)} className="bg-slate-600 hover:bg-slate-500 text-white px-3 py-1 rounded text-xs">취소</button>
                                                            </div>
                                                            :
                                                            <button onClick={() => handleStartEdit(p)} className="text-blue-400 hover:text-blue-300 text-sm font-bold">수정</button>
                                                        }
                                                    </td>
                                                </tr>
                                            ))}
                                        </tbody>
                                    </table>
                                </div>
                            </div>
                        </div>
                    )}

                    {activeTab === 'NOTICES' && (
                        <div className="space-y-6">
                            <div className="bg-slate-800 p-4 rounded-xl border border-slate-700">
                                <h3 className="text-white font-bold mb-3">새 공지 등록</h3>
                                <div className="flex gap-2">
                                    <input value={newNotice} onChange={e => setNewNotice(e.target.value)} placeholder="공지 내용을 입력하세요..." className="flex-1 bg-slate-900 border border-slate-600 rounded-lg p-3 text-white outline-none focus:border-yellow-400" />
                                    <button onClick={addNotice} className="bg-blue-600 hover:bg-blue-500 text-white px-6 py-2 rounded-lg font-bold">등록</button>
                                </div>
                            </div>
                            <div className="space-y-3">
                                {notices.map(n => (
                                    <div key={n.id} className="bg-slate-800 p-4 rounded-xl border border-slate-700 flex justify-between items-center group hover:border-slate-500 transition-all">
                                        <div>
                                            <p className="text-white font-medium">{n.content}</p>
                                            <p className="text-xs text-slate-500 mt-1">{new Date(n.created_at).toLocaleDateString()}</p>
                                        </div>
                                        <button onClick={() => deleteNotice(n.id)} className="text-slate-500 hover:text-rose-500 p-2 opacity-50 group-hover:opacity-100 transition-all">🗑️</button>
                                    </div>
                                ))}
                                {notices.length === 0 && <p className="text-center text-slate-500 py-10">등록된 공지가 없습니다.</p>}
                            </div>
                        </div>
                    )}

                    {/* ✅ [수정된 부분] 경기 목록 탭 - 승인 대기 상태 표시 및 액션 버튼 추가 */}
                    {activeTab === 'MATCHES' && (
                        <div className="space-y-3">
                            {matches.map(m => (
                                <div key={m.id} className={`bg-slate-800 p-4 rounded-xl border flex flex-col md:flex-row justify-between items-center gap-4 transition-all ${m.status === 'pending' ? 'border-amber-500/50 bg-amber-900/10' : 'border-slate-700'}`}>
                                    <div className="flex items-center gap-4 w-full md:w-auto justify-between md:justify-start">

                                        {/* 상태 뱃지 */}
                                        {m.status.toLowerCase() === 'pending' && <span className="bg-amber-500 text-slate-900 text-[10px] px-2 py-0.5 rounded font-black animate-pulse whitespace-nowrap">⏳ 승인 대기</span>}
                                        {m.status === 'DISPUTED' && <span className="bg-rose-500 text-white text-[10px] px-2 py-0.5 rounded font-black animate-pulse whitespace-nowrap">🚨 분쟁 중</span>}

                                        <div className="text-right">
                                            <p className={`font-bold ${m.winner_team === 'TEAM_1' ? 'text-lime-400' : 'text-slate-400'}`}>{m.p1_name}, {m.p2_name}</p>
                                            <p className="text-2xl font-black text-white">{m.score_team1}</p>
                                        </div>
                                        <div className="text-slate-600 font-bold px-2">VS</div>
                                        <div className="text-left">
                                            <p className={`font-bold ${m.winner_team === 'TEAM_2' ? 'text-lime-400' : 'text-slate-400'}`}>{m.p3_name}, {m.p4_name}</p>
                                            <p className="text-2xl font-black text-white">{m.score_team2}</p>
                                        </div>
                                    </div>

                                    {/* 액션 버튼 그룹 */}
                                    <div className="flex items-center gap-2 w-full md:w-auto justify-end">
                                        <div className="text-right hidden md:block mr-2">
                                            <p className="text-xs font-bold text-slate-500 uppercase">{m.match_category}</p>
                                            <p className="text-xs text-slate-600">{new Date(m.end_time).toLocaleDateString()}</p>
                                        </div>

                                        {m.status.toLowerCase() === 'pending' || m.status === 'DISPUTED' ? (
                                            <>
                                                <button onClick={() => adminConfirmMatch(m.id)} className="bg-lime-600 hover:bg-lime-500 text-white px-3 py-2 rounded-lg text-xs font-bold shadow-lg border border-lime-400 transition-all whitespace-nowrap">
                                                    ⚡ 강제 승인
                                                </button>
                                                <button onClick={() => rollbackMatch(m)} className="bg-slate-700 hover:bg-slate-600 text-white px-3 py-2 rounded-lg text-xs font-bold border border-slate-500 transition-all whitespace-nowrap">
                                                    거절
                                                </button>
                                            </>
                                        ) : (
                                            <button onClick={() => rollbackMatch(m)} className="bg-rose-900/30 text-rose-500 hover:bg-rose-600 hover:text-white px-3 py-2 rounded-lg text-xs font-bold border border-rose-900 transition-all whitespace-nowrap">
                                                ⚠️ 롤백
                                            </button>
                                        )}
                                    </div>
                                </div>
                            ))}
                            {matches.length === 0 && <p className="text-center text-slate-500 py-10">경기 기록이 없습니다.</p>}
                        </div>
                    )}

                    {/* ✅ [New Tab] EVENTS (Team Balancer & Soft Reset) */}
                    {activeTab === 'EVENTS' && (
                        <div className="space-y-8 pb-20">
                            {/* 1. Season Reset */}
                            <div className="bg-slate-800 p-6 rounded-xl border border-rose-500/30">
                                <h3 className="text-lg font-bold text-white mb-2">🔥 Danger Zone</h3>
                                <div className="flex justify-between items-center">
                                    <div>
                                        <p className="text-sm text-slate-400">새로운 시즌을 위해 모든 점수를 압축합니다.</p>
                                        <p className="text-xs text-slate-500 font-mono mt-1">Formula: 1200 + (Old - 1200) / 2</p>
                                    </div>
                                    <button onClick={softResetSeason} className="bg-rose-900/50 hover:bg-rose-600 text-rose-200 hover:text-white px-4 py-2 rounded-xl font-bold border border-rose-800 transition-all">
                                        ⚠️ Season Soft Reset
                                    </button>
                                </div>
                            </div>

                            {/* 2. Team Balancer */}
                            <div className="bg-slate-800 p-6 rounded-xl border border-purple-500/30">
                                <h3 className="text-lg font-bold text-white mb-4">⚖️ Cheong-Baek-Jeon Balancer</h3>

                                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                                    {/* Left: Setup */}
                                    <div className="space-y-4">
                                        <div className="grid grid-cols-2 gap-2">
                                            <div>
                                                <label className="text-xs text-blue-400 font-bold">🔵 Blue Captain</label>
                                                <select className="w-full bg-slate-900 border border-slate-700 rounded p-2 text-white text-xs mt-1" value={blueCaptain} onChange={e => setBlueCaptain(e.target.value)}>
                                                    <option value="">Select Captain</option>
                                                    {profiles.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
                                                </select>
                                            </div>
                                            <div>
                                                <label className="text-xs text-white font-bold">⚪ White Captain</label>
                                                <select className="w-full bg-slate-900 border border-slate-700 rounded p-2 text-white text-xs mt-1" value={whiteCaptain} onChange={e => setWhiteCaptain(e.target.value)}>
                                                    <option value="">Select Captain</option>
                                                    {profiles.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
                                                </select>
                                            </div>
                                        </div>

                                        <div className="bg-slate-900/50 p-3 rounded-lg border border-slate-700 max-h-[300px] overflow-y-auto custom-scrollbar">
                                            <p className="text-xs text-slate-400 mb-2 font-bold sticky top-0 bg-slate-900 z-10 p-1">참가자 선택 ({selectedEventMembers.size}명)</p>
                                            <div className="grid grid-cols-2 gap-1">
                                                {profiles.map(p => (
                                                    <label key={p.id} className={`flex items-center gap-2 p-1 rounded cursor-pointer ${selectedEventMembers.has(p.id) ? 'bg-purple-900/30' : 'hover:bg-slate-800'}`}>
                                                        <input type="checkbox" checked={selectedEventMembers.has(p.id)} onChange={() => toggleEventMember(p.id)} className="accent-purple-500" />
                                                        <span className="text-xs text-slate-300 truncate">{p.name} <span className="text-[9px] text-slate-500">({p.ntrp})</span></span>
                                                    </label>
                                                ))}
                                            </div>
                                        </div>

                                        <button onClick={generateBalancedTeams} className="w-full py-3 bg-purple-600 hover:bg-purple-500 text-white font-bold rounded-xl shadow-lg transition-all">
                                            ⚔️ Generate Balanced Teams
                                        </button>
                                    </div>

                                    {/* Right: Result */}
                                    <div className="bg-slate-900 p-4 rounded-xl min-h-[300px]">
                                        {generatedTeams ? (
                                            <div className="h-full flex flex-col">
                                                <div className="grid grid-cols-2 gap-4 h-full">
                                                    {/* Blue Team */}
                                                    <div className="bg-blue-900/20 border border-blue-500/30 rounded-lg p-3">
                                                        <h4 className="text-blue-400 font-black text-center mb-2">BLUE TEAM</h4>
                                                        <p className="text-center text-xs text-blue-200 mb-4 bg-blue-900/50 rounded py-1">Avg: {generatedTeams.blueAvg}</p>
                                                        <ul className="space-y-1 text-xs text-slate-300">
                                                            {generatedTeams.blue.map(p => (
                                                                <li key={p.id} className="flex justify-between border-b border-blue-500/10 pb-1">
                                                                    <span>{p.name} {p.id === blueCaptain && '👑'}</span>
                                                                    <span className="font-mono text-slate-500">{p.ntrp}</span>
                                                                </li>
                                                            ))}
                                                        </ul>
                                                    </div>
                                                    {/* White Team */}
                                                    <div className="bg-white/5 border border-white/20 rounded-lg p-3">
                                                        <h4 className="text-white font-black text-center mb-2">WHITE TEAM</h4>
                                                        <p className="text-center text-xs text-slate-300 mb-4 bg-white/10 rounded py-1">Avg: {generatedTeams.whiteAvg}</p>
                                                        <ul className="space-y-1 text-xs text-slate-300">
                                                            {generatedTeams.white.map(p => (
                                                                <li key={p.id} className="flex justify-between border-b border-white/10 pb-1">
                                                                    <span>{p.name} {p.id === whiteCaptain && '👑'}</span>
                                                                    <span className="font-mono text-slate-500">{p.ntrp}</span>
                                                                </li>
                                                            ))}
                                                        </ul>
                                                    </div>
                                                </div>
                                            </div>
                                        ) : (
                                            <div className="h-full flex items-center justify-center text-slate-600 text-sm">
                                                팀 생성 결과가 여기에 표시됩니다.
                                            </div>
                                        )}
                                    </div>
                                </div>
                            </div>
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}