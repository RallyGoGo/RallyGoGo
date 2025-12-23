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

    const startEdit = (p: Profile) => { setEditingId(p.id); setEditForm({ name: p.name, gender: p.gender || 'Male', ntrp: p.ntrp }); };
    const saveEdit = async () => { if (!editingId) return; const { error } = await supabase.from('profiles').update(editForm).eq('id', editingId); if (error) alert(error.message); else { setEditingId(null); fetchProfiles(); } };
    const clearQueue = async () => { if (!confirm("⚠️ KICK ALL form Queue?")) return; await supabase.from('queue').delete().neq('player_id', '0000'); alert("Queue Cleared!"); };
    const resetGuests = async () => { if (!confirm("⚠️ Delete ALL Guests?")) return; const { error } = await supabase.from('profiles').delete().eq('is_guest', true); if (error) alert("Matches exist. Cannot delete."); else { alert("Guests Cleared!"); fetchProfiles(); } };
    const addNotice = async () => { if (!newNotice.trim()) return; await supabase.from('notices').insert({ content: newNotice, is_active: true }); setNewNotice(''); fetchNotices(); };
    const toggleNotice = async (id: string, currentStatus: boolean) => { await supabase.from('notices').update({ is_active: !currentStatus }).eq('id', id); fetchNotices(); };
    const deleteNotice = async (id: string) => { if (!confirm("Delete this notice?")) return; await supabase.from('notices').delete().eq('id', id); fetchNotices(); };

    const rollbackMatch = async (m: Match) => {
        if (!confirm(`⚠️ WARNING: Delete match (${m.score_team1}:${m.score_team2})?`)) return;
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
            alert("✅ Reverted."); fetchMatches();
        } catch (e: any) { alert("Error: " + e.message); }
        setLoading(false);
    };

    const filteredProfiles = profiles.filter(p => p.name?.toLowerCase().includes(searchTerm.toLowerCase()));

    return (
        <div className="fixed inset-0 z-[90] bg-slate-900 flex flex-col animate-fadeIn">
            <div className="p-4 border-b border-slate-700 bg-slate-800 flex justify-between items-center shadow-md">
                <h2 className="text-xl font-black text-rose-500 flex items-center gap-2">🛡️ Admin Dashboard</h2>
                <button onClick={onClose} className="bg-slate-700 hover:bg-slate-600 px-4 py-2 rounded-lg font-bold text-white">Exit</button>
            </div>
            <div className="flex-1 flex overflow-hidden">
                <div className="w-64 bg-slate-800/50 border-r border-slate-700 p-4 flex flex-col gap-2 hidden md:flex">
                    <button onClick={() => setActiveTab('MEMBERS')} className="w-full text-left p-3 rounded-lg font-bold text-slate-400 hover:bg-slate-800">👥 Members</button>
                    <button onClick={() => setActiveTab('NOTICES')} className="w-full text-left p-3 rounded-lg font-bold text-slate-400 hover:bg-slate-800">📢 Notices</button>
                    <button onClick={() => setActiveTab('MATCHES')} className="w-full text-left p-3 rounded-lg font-bold text-slate-400 hover:bg-slate-800">🎾 Matches</button>
                </div>
                <div className="flex-1 p-6 overflow-y-auto custom-scrollbar">
                    {activeTab === 'MEMBERS' && (
                        <div className="bg-slate-800 rounded-xl border border-slate-700 overflow-hidden">
                            <table className="w-full text-left border-collapse"><thead className="bg-slate-700 text-slate-300 text-xs uppercase"><tr><th className="p-4">Name</th><th className="p-4">Gender</th><th className="p-4">NTRP</th><th className="p-4">Type</th><th className="p-4 text-right">Actions</th></tr></thead><tbody className="divide-y divide-slate-700">{loading ? <tr><td colSpan={5} className="p-8 text-center text-slate-500">Loading...</td></tr> : filteredProfiles.map(p => (<tr key={p.id}><td className="p-4">{editingId === p.id ? <input className="bg-slate-900 text-white" value={editForm.name} onChange={e => setEditForm({ ...editForm, name: e.target.value })} /> : p.name}</td><td className="p-4">{p.gender || 'Not Set'}</td><td className="p-4">{p.ntrp}</td><td className="p-4">{p.is_guest ? 'G' : 'M'}</td><td className="p-4 text-right">{editingId === p.id ? <button onClick={saveEdit} className="text-lime-400">Save</button> : <button onClick={() => startEdit(p)} className="text-blue-400">Edit</button>}</td></tr>))}</tbody></table>
                        </div>
                    )}
                    {activeTab === 'NOTICES' && (
                        <div><input value={newNotice} onChange={e => setNewNotice(e.target.value)} placeholder="Notice..." className="bg-slate-800 text-white p-2" /><button onClick={addNotice} className="bg-blue-600 text-white p-2 ml-2">Add</button><div className="mt-4">{notices.map(n => <div key={n.id} className="text-white border-b p-2">{n.content} <button onClick={() => deleteNotice(n.id)} className="text-red-500 ml-4">Del</button></div>)}</div></div>
                    )}
                    {activeTab === 'MATCHES' && (
                        <div className="space-y-2">{matches.map(m => <div key={m.id} className="bg-slate-800 p-4 rounded text-white flex justify-between"><span>{m.score_team1}:{m.score_team2} ({m.match_category})</span><button onClick={() => rollbackMatch(m)} className="text-red-400">Rollback</button></div>)}</div>
                    )}
                </div>
            </div>
        </div>
    );
}