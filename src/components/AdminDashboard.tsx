import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

type Profile = { id: string; email: string; name: string; gender: string; ntrp: number; is_guest: boolean; };
type Notice = { id: string; content: string; is_active: boolean; created_at: string; };
type Match = {
    id: string; end_time: string; score_team1: number; score_team2: number; winner_team: string;
    player_1: string; player_2: string; player_3: string; player_4: string;
    elo_delta: number; match_category: string;
    p1_name?: string; p2_name?: string; p3_name?: string; p4_name?: string;
};

type Props = { onClose: () => void; };

export default function AdminBoard({ onClose }: Props) {
    const [activeTab, setActiveTab] = useState<'MEMBERS' | 'NOTICES' | 'MATCHES'>('MEMBERS');
    const [profiles, setProfiles] = useState<Profile[]>([]);
    const [notices, setNotices] = useState<Notice[]>([]);
    const [matches, setMatches] = useState<Match[]>([]);
    const [loading, setLoading] = useState(false);
    const [searchTerm, setSearchTerm] = useState('');

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
    const fetchMatches = async () => {
        setLoading(true);
        const { data: matches } = await supabase.from('matches').select('*').eq('status', 'FINISHED').order('end_time', { ascending: false }).limit(50);
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

    const startEdit = (p: Profile) => { setEditingId(p.id); setEditForm({ name: p.name, gender: p.gender || 'Male', ntrp: p.ntrp }); };
    const saveEdit = async () => { if (!editingId) return; const { error } = await supabase.from('profiles').update(editForm).eq('id', editingId); if (error) alert(error.message); else { setEditingId(null); fetchProfiles(); } };

    // 위험한 기능들 (조심!)
    const clearQueue = async () => { if (!confirm("⚠️ 대기열을 초기화하시겠습니까? (모든 대기자 삭제)")) return; await supabase.from('queue').delete().neq('user_id', '00000000-0000-0000-0000-000000000000'); alert("Queue Cleared!"); };

    const addNotice = async () => { if (!newNotice.trim()) return; await supabase.from('notices').insert({ content: newNotice, is_active: true }); setNewNotice(''); fetchNotices(); };
    const deleteNotice = async (id: string) => { if (!confirm("Delete this notice?")) return; await supabase.from('notices').delete().eq('id', id); fetchNotices(); };

    const rollbackMatch = async (m: Match) => {
        if (!confirm(`⚠️ WARNING: 이 경기 기록을 정말 삭제하시겠습니까?\n(${m.score_team1}:${m.score_team2}, ${m.match_category})\n\n점수 변동(ELO)도 원래대로 되돌려집니다.`)) return;
        setLoading(true);
        try {
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
                        // 이겼던 사람은 점수 뺏고(-), 졌던 사람은 점수 돌려줌(+)
                        const revertAmount = isWinner ? -delta : delta;
                        const currentScore = (p as any)[eloField];
                        // 1. 프로필 점수 원복
                        await supabase.from('profiles').update({ [eloField]: currentScore + revertAmount }).eq('id', p.id);
                        // 2. 히스토리에 원복 기록 남김 (선택사항)
                        // await supabase.from('elo_history').insert({ player_id: p.id, match_category: m.match_category, elo_score: currentScore + revertAmount });
                    }
                }
            }
            // 경기 기록 삭제
            const { error } = await supabase.from('matches').delete().eq('id', m.id);
            if (error) throw error;
            alert("✅ 경기가 취소되고 점수가 롤백되었습니다."); fetchMatches();
        } catch (e: any) { alert("Error: " + e.message); }
        setLoading(false);
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
            </div>

            <div className="flex-1 flex overflow-hidden">
                {/* Desktop Sidebar */}
                <div className="w-64 bg-slate-800/50 border-r border-slate-700 p-4 flex flex-col gap-2 hidden md:flex">
                    <button onClick={() => setActiveTab('MEMBERS')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'MEMBERS' ? 'bg-slate-700 text-lime-400' : 'text-slate-400 hover:bg-slate-800'}`}>👥 회원 관리</button>
                    <button onClick={() => setActiveTab('NOTICES')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'NOTICES' ? 'bg-slate-700 text-yellow-400' : 'text-slate-400 hover:bg-slate-800'}`}>📢 공지사항</button>
                    <button onClick={() => setActiveTab('MATCHES')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'MATCHES' ? 'bg-slate-700 text-rose-400' : 'text-slate-400 hover:bg-slate-800'}`}>🎾 경기 기록 (롤백)</button>

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
                                            <tr><th className="p-4 min-w-[100px]">이름</th><th className="p-4">성별</th><th className="p-4">NTRP</th><th className="p-4 text-right">관리</th></tr>
                                        </thead>
                                        <tbody className="divide-y divide-slate-700">
                                            {loading ? <tr><td colSpan={4} className="p-8 text-center text-slate-500">로딩 중...</td></tr> : filteredProfiles.map(p => (
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
                                                    <td className="p-4 text-right">
                                                        {editingId === p.id ?
                                                            <div className="flex gap-2 justify-end">
                                                                <button onClick={saveEdit} className="bg-lime-600 hover:bg-lime-500 text-white px-3 py-1 rounded text-xs font-bold">저장</button>
                                                                <button onClick={() => setEditingId(null)} className="bg-slate-600 hover:bg-slate-500 text-white px-3 py-1 rounded text-xs">취소</button>
                                                            </div>
                                                            :
                                                            <button onClick={() => startEdit(p)} className="text-blue-400 hover:text-blue-300 text-sm font-bold">수정</button>
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

                    {activeTab === 'MATCHES' && (
                        <div className="space-y-3">
                            {matches.map(m => (
                                <div key={m.id} className="bg-slate-800 p-4 rounded-xl border border-slate-700 flex flex-col md:flex-row justify-between items-center gap-4">
                                    <div className="flex items-center gap-4 w-full md:w-auto justify-between md:justify-start">
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
                                    <div className="flex items-center gap-4 w-full md:w-auto justify-end">
                                        <div className="text-right hidden md:block">
                                            <p className="text-xs font-bold text-slate-500 uppercase">{m.match_category}</p>
                                            <p className="text-xs text-slate-600">{new Date(m.end_time).toLocaleDateString()}</p>
                                        </div>
                                        <button onClick={() => rollbackMatch(m)} className="bg-rose-900/30 text-rose-500 hover:bg-rose-600 hover:text-white px-3 py-2 rounded-lg text-xs font-bold border border-rose-900 transition-all">
                                            ⚠️ 기록 삭제 (Rollback)
                                        </button>
                                    </div>
                                </div>
                            ))}
                            {matches.length === 0 && <p className="text-center text-slate-500 py-10">경기 기록이 없습니다.</p>}
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}