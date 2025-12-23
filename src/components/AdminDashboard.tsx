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

export default function AdminDashboard({ onClose }: Props) {
    const [activeTab, setActiveTab] = useState<'MEMBERS' | 'NOTICES' | 'MATCHES'>('MEMBERS');
    const [profiles, setProfiles] = useState<Profile[]>([]);
    const [notices, setNotices] = useState<Notice[]>([]);
    const [matches, setMatches] = useState<Match[]>([]);
    const [loading, setLoading] = useState(false);
    const [searchTerm, setSearchTerm] = useState('');

    // Member Edit State
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
                p1_name: pNames?.find(p => p.id === m.player_1)?.name || '?', p2_name: pNames?.find(p => p.id === m.player_2)?.name || '?',
                p3_name: pNames?.find(p => p.id === m.player_3)?.name || '?', p4_name: pNames?.find(p => p.id === m.player_4)?.name || '?',
            }));
            setMatches(enriched);
        }
        setLoading(false);
    };

    // Actions
    const startEdit = (p: Profile) => { setEditingId(p.id); setEditForm({ name: p.name, gender: p.gender || 'Male', ntrp: p.ntrp }); };
    const saveEdit = async () => { if (!editingId) return; const { error } = await supabase.from('profiles').update(editForm).eq('id', editingId); if (error) alert(error.message); else { setEditingId(null); fetchProfiles(); } };
    const clearQueue = async () => { if (!confirm("⚠️ KICK ALL form Queue?")) return; await supabase.from('queue').delete().neq('player_id', '0000'); alert("Queue Cleared!"); };
    const resetGuests = async () => { if (!confirm("⚠️ Delete ALL Guests?")) return; const { error } = await supabase.from('profiles').delete().eq('is_guest', true); if (error) alert("Matches exist. Cannot delete."); else { alert("Guests Cleared!"); fetchProfiles(); } };
    const addNotice = async () => { if (!newNotice.trim()) return; await supabase.from('notices').insert({ content: newNotice, is_active: true }); setNewNotice(''); fetchNotices(); };
    const toggleNotice = async (id: string, currentStatus: boolean) => { await supabase.from('notices').update({ is_active: !currentStatus }).eq('id', id); fetchNotices(); };
    const deleteNotice = async (id: string) => { if (!confirm("Delete this notice?")) return; await supabase.from('notices').delete().eq('id', id); fetchNotices(); };

    const rollbackMatch = async (m: Match) => {
        if (!confirm(`⚠️ WARNING: This will DELETE the match and REVERT ELO points.\n\nAre you sure you want to delete this match?\n(${m.score_team1}:${m.score_team2})`)) return;
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
                        const revertAmount = isWinner ? -delta : delta;
                        const currentScore = (p as any)[eloField];
                        await supabase.from('profiles').update({ [eloField]: currentScore + revertAmount }).eq('id', p.id);
                        await supabase.from('elo_history').insert({ player_id: p.id, match_category: m.match_category, elo_score: currentScore + revertAmount });
                    }
                }
            }
            const { error } = await supabase.from('matches').delete().eq('id', m.id);
            if (error) throw error;
            alert("✅ Match deleted & ELO reverted."); fetchMatches();
        } catch (e: any) { alert("Error: " + e.message); }
        setLoading(false);
    };

    const filteredProfiles = profiles.filter(p => p.name?.toLowerCase().includes(searchTerm.toLowerCase()));

    return (
        <div className="fixed inset-0 z-[90] bg-slate-900 flex flex-col animate-fadeIn">
            <div className="p-4 border-b border-slate-700 bg-slate-800 flex justify-between items-center shadow-md">
                <h2 className="text-xl font-black text-rose-500 flex items-center gap-2">🛡️ Admin Dashboard</h2>
                <button onClick={onClose} className="bg-slate-700 hover:bg-slate-600 px-4 py-2 rounded-lg font-bold text-white transition-all">Exit Admin</button>
            </div>
            <div className="flex-1 flex overflow-hidden">
                <div className="w-64 bg-slate-800/50 border-r border-slate-700 p-4 flex flex-col gap-2 hidden md:flex">
                    <button onClick={() => setActiveTab('MEMBERS')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'MEMBERS' ? 'bg-indigo-600 text-white' : 'text-slate-400 hover:bg-slate-800'}`}>👥 Members</button>
                    <button onClick={() => setActiveTab('NOTICES')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'NOTICES' ? 'bg-indigo-600 text-white' : 'text-slate-400 hover:bg-slate-800'}`}>📢 Notices</button>
                    <button onClick={() => setActiveTab('MATCHES')} className={`w-full text-left p-3 rounded-lg font-bold transition-all ${activeTab === 'MATCHES' ? 'bg-indigo-600 text-white' : 'text-slate-400 hover:bg-slate-800'}`}>🎾 Matches</button>
                    <div className="mt-auto pt-4 border-t border-slate-700"><h3 className="text-rose-400 font-bold mb-2 text-xs uppercase">Danger Zone</h3><button onClick={clearQueue} className="w-full py-2 bg-rose-900/50 hover:bg-rose-600 border border-rose-500/30 text-rose-200 font-bold rounded mb-2 text-xs">Clear Queue</button><button onClick={resetGuests} className="w-full py-2 bg-slate-700 hover:bg-slate-600 text-slate-300 font-bold rounded text-xs">Delete Guests</button></div>
                </div>
                <div className="flex-1 p-6 overflow-y-auto custom-scrollbar">
                    {activeTab === 'MEMBERS' ? (
                        <div className="bg-slate-800 rounded-xl border border-slate-700 overflow-hidden">
                            <table className="w-full text-left border-collapse"><thead className="bg-slate-700 text-slate-300 text-xs uppercase"><tr><th className="p-4">Name</th><th className="p-4">Gender</th><th className="p-4">NTRP</th><th className="p-4">Type</th><th className="p-4 text-right">Actions</th></tr></thead>
                                <tbody className="divide-y divide-slate-700">{loading ? <tr><td colSpan={5} className="p-8 text-center text-slate-500">Loading...</td></tr> : filteredProfiles.map(p => (
                                    <tr key={p.id} className="hover:bg-slate-700/50 transition-colors"><td className="p-4">{editingId === p.id ? <input className="bg-slate-900 border border-slate-500 rounded px-2 py-1 text-white w-full" value={editForm.name} onChange={e => setEditForm({ ...editForm, name: e.target.value })} /> : <div className="flex flex-col"><span className="font-bold text-white">{p.name}</span><span className="text-xs text-slate-500">{p.email}</span></div>}</td><td className="p-4">{editingId === p.id ? <select className="bg-slate-900 border border-slate-500 rounded px-2 py-1 text-white" value={editForm.gender} onChange={e => setEditForm({ ...editForm, gender: e.target.value })}><option value="Male">Male</option><option value="Female">Female</option></select> : <span className={`px-2 py-1 rounded text-xs font-bold ${p.gender === 'Male' ? 'bg-blue-900 text-blue-300' : p.gender === 'Female' ? 'bg-rose-900 text-rose-300' : 'bg-slate-700 text-slate-400'}`}>{p.gender || 'Not Set'}</span>}</td><td className="p-4">{editingId === p.id ? <input type="number" step="0.5" className="bg-slate-900 border border-slate-500 rounded px-2 py-1 text-white w-16" value={editForm.ntrp} onChange={e => setEditForm({ ...editForm, ntrp: parseFloat(e.target.value) })} /> : <span className="font-mono text-lime-400 font-bold">{p.ntrp.toFixed(1)}</span>}</td><td className="p-4">{p.is_guest ? <span className="text-xs bg-indigo-500 text-white px-1.5 py-0.5 rounded">Guest</span> : <span className="text-xs text-slate-500">Member</span>}</td><td className="p-4 text-right">{editingId === p.id ? <div className="flex gap-2 justify-end"><button onClick={saveEdit} className="px-3 py-1 bg-lime-600 hover:bg-lime-500 text-white rounded text-xs font-bold">Save</button><button onClick={() => setEditingId(null)} className="px-3 py-1 bg-slate-600 hover:bg-slate-500 text-white rounded text-xs">Cancel</button></div> : <button onClick={() => startEdit(p)} className="px-3 py-1 border border-slate-500 hover:bg-slate-700 text-slate-300 rounded text-xs transition-colors">Edit</button>}</td></tr>))}</tbody></table>
                        </div>
                    ) : activeTab === 'NOTICES' ? (
                        <div className="max-w-3xl mx-auto"><h3 className="text-2xl font-bold text-white mb-6">📢 Manage Notices</h3><div className="flex gap-2 mb-8"><input type="text" placeholder="Enter new announcement..." value={newNotice} onChange={(e) => setNewNotice(e.target.value)} className="flex-1 bg-slate-800 border border-slate-600 rounded-xl px-4 py-3 text-white focus:border-indigo-500 outline-none" /><button onClick={addNotice} className="px-6 bg-indigo-600 hover:bg-indigo-500 text-white font-bold rounded-xl shadow-lg">Add</button></div><div className="space-y-4">{notices.map(n => (<div key={n.id} className={`p-4 rounded-xl border flex justify-between items-center ${n.is_active ? 'bg-indigo-900/20 border-indigo-500/50' : 'bg-slate-800 border-slate-700 opacity-60'}`}><div><p className="text-white font-bold text-lg mb-1">{n.content}</p><p className="text-xs text-slate-500">{new Date(n.created_at).toLocaleString()}</p></div><div className="flex gap-3"><button onClick={() => toggleNotice(n.id, n.is_active)} className={`px-3 py-1 rounded text-xs font-bold ${n.is_active ? 'bg-lime-500 text-slate-900' : 'bg-slate-600 text-slate-300'}`}>{n.is_active ? 'Active' : 'Hidden'}</button><button onClick={() => deleteNotice(n.id)} className="px-3 py-1 bg-rose-600/20 hover:bg-rose-600 text-rose-400 hover:text-white border border-rose-500/30 rounded text-xs">Delete</button></div></div>))}</div></div>
                    ) : (
                        <div className="max-w-4xl mx-auto"><h3 className="text-2xl font-bold text-white mb-6">🎾 Recent Matches (Rollback)</h3><div className="space-y-4">{matches.map(m => (<div key={m.id} className="bg-slate-800 border border-slate-700 p-4 rounded-xl flex justify-between items-center group hover:border-slate-500 transition-colors"><div className="flex flex-col gap-1"><div className="flex items-center gap-2"><span className={`px-2 py-0.5 rounded text-[10px] font-bold ${m.match_category === 'MEN_D' ? 'bg-blue-900 text-blue-300' : m.match_category === 'WOMEN_D' ? 'bg-rose-900 text-rose-300' : 'bg-purple-900 text-purple-300'}`}>{m.match_category}</span><span className="text-xs text-slate-500">{new Date(m.end_time).toLocaleString()}</span></div><div className="flex items-center gap-4 mt-2"><div className={`text-center ${m.winner_team === 'TEAM_1' ? 'text-lime-400' : 'text-slate-400'}`}><p className="text-xl font-black">{m.score_team1}</p><p className="text-xs text-slate-400">{m.p1_name}, {m.p2_name}</p></div><span className="text-slate-600 font-bold">vs</span><div className={`text-center ${m.winner_team === 'TEAM_2' ? 'text-lime-400' : 'text-slate-400'}`}><p className="text-xl font-black">{m.score_team2}</p><p className="text-xs text-slate-400">{m.p3_name}, {m.p4_name}</p></div></div></div><div className="text-right flex flex-col items-end gap-2"><span className="text-xs text-slate-400">Impact: <span className="text-white font-bold">{m.elo_delta || 0}</span> pts</span><button onClick={() => rollbackMatch(m)} className="px-4 py-2 bg-rose-600/20 hover:bg-rose-600 text-rose-400 hover:text-white border border-rose-500/30 rounded-lg text-xs font-bold transition-all">🗑️ Delete & Revert</button></div></div>))}</div></div>
                    )}
                </div>
            </div>
        </div>
    );
}