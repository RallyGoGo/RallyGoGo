import { useEffect, useState, useRef } from 'react';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';

type Props = {
    user: User;
    onClose: () => void;
    onUpdate: () => void;
};

// 🌟 Expanded Emoji List
const EMOJI_LIST = [
    "🎾", "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🐦", "🐤", "🦅", "🦉", "🦄",
    "🐝", "🐛", "🦋", "🐌", "🐞", "🐜", "🕷️", "🐢", "🐍", "🦎", "🦖", "🦕", "🐙", "🦑", "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳", "🦈", "🐊",
    "🐅", "🐆", "🦓", "🦍", "🦧", "🐘", "🦛", "🦏", "🐪", "🐫", "🦒", "🦘", "🐃", "🐂", "🐄", "🐎", "🐖", "RAM", "🐑", "🦙", "🐐", "🦌", "🐕", "🐩",
    "🔥", "💧", "⚡", "❄️", "🌈", "☀️", "🌙", "⭐", "💎", "👑", "🚀", "🛸", "⚓", "⚽", "🏀", "🏈", "⚾", "🏐", "🏉", "🎱", "🏓", "🏸", "🥊", "🥋"
];

// Simple SVG Line Chart Component
const SimpleLineChart = ({ data }: { data: number[] }) => {
    if (!data || data.length < 2) return <div className="text-center text-xs text-slate-500 py-10">Not enough data for graph</div>;

    const width = 300;
    const height = 100;
    const padding = 10;
    const min = Math.min(...data);
    const max = Math.max(...data);
    const range = max - min || 1;

    // Normalize points
    const points = data.map((val, idx) => {
        const x = (idx / (data.length - 1)) * (width - padding * 2) + padding;
        const y = height - ((val - min) / range) * (height - padding * 2) - padding;
        return `${x},${y}`;
    }).join(" ");

    return (
        <div className="w-full bg-slate-900/50 rounded-xl p-4 border border-slate-700 relative overflow-hidden">
            <p className="text-[10px] text-slate-400 font-bold mb-2 uppercase tracking-widest">ELO Trend (Recent {data.length} Games)</p>
            <svg width="100%" height={height} viewBox={`0 0 ${width} ${height}`} className="overflow-visible">
                {/* Gradient Definition */}
                <defs>
                    <linearGradient id="gradient" x1="0" x2="0" y1="0" y2="1">
                        <stop offset="0%" stopColor="#84cc16" stopOpacity="0.5" />
                        <stop offset="100%" stopColor="#84cc16" stopOpacity="0" />
                    </linearGradient>
                </defs>
                {/* Area Fill */}
                <path d={`M ${points.split(" ")[0].split(",")[0]},${height} L ${points.replace(/,/g, " ")} L ${width - padding},${height} Z`} fill="url(#gradient)" stroke="none" />
                {/* Line */}
                <polyline points={points} fill="none" stroke="#84cc16" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
                {/* Dots */}
                {data.map((val, idx) => {
                    const x = (idx / (data.length - 1)) * (width - padding * 2) + padding;
                    const y = height - ((val - min) / range) * (height - padding * 2) - padding;
                    return <circle key={idx} cx={x} cy={y} r="3" fill="#ecfccb" />;
                })}
            </svg>
            <div className="flex justify-between text-[10px] text-slate-500 mt-2 font-mono">
                <span>Start: {data[0]}</span>
                <span>Current: {data[data.length - 1]}</span>
            </div>
        </div>
    );
};

export default function MyStatsModal({ user, onClose, onUpdate }: Props) {
    const [name, setName] = useState('');
    const [selectedEmoji, setSelectedEmoji] = useState('🎾');
    const [avatarUrl, setAvatarUrl] = useState<string | null>(null);
    const [loading, setLoading] = useState(true);
    const [saving, setSaving] = useState(false);

    // Image Upload State
    const fileInputRef = useRef<HTMLInputElement>(null);
    const [uploading, setUploading] = useState(false);

    // Stats
    const [myProfile, setMyProfile] = useState<any>(null);
    const [bestPartner, setBestPartner] = useState<{ name: string, wins: number } | null>(null);
    const [worstRival, setWorstRival] = useState<{ name: string, losses: number } | null>(null);
    const [totalStats, setTotalStats] = useState({ wins: 0, losses: 0, winRate: 0 });

    // [New] Graph & Badges
    const [eloHistory, setEloHistory] = useState<number[]>([]);
    const [mvpBadges, setMvpBadges] = useState<{ tag: string, count: number }[]>([]);

    useEffect(() => {
        fetchMyData();
    }, [user]);

    const fetchMyData = async () => {
        setLoading(true);
        // 1. Load Profile
        const { data: profile } = await supabase.from('profiles').select('name, emoji, avatar_url, gender, elo_men_doubles, elo_women_doubles, elo_mixed_doubles, elo_singles').eq('id', user.id).single();
        if (profile) {
            setName(profile.name);
            setSelectedEmoji(profile.emoji || '🎾');
            setAvatarUrl(profile.avatar_url);
            setMyProfile(profile);
        }

        // 2. Analyze Matches
        const { data: matches } = await supabase.from('matches')
            .select('*').eq('status', 'FINISHED')
            .or(`player_1.eq.${user.id},player_2.eq.${user.id},player_3.eq.${user.id},player_4.eq.${user.id}`);

        if (matches) {
            const partnerStats: { [key: string]: number } = {};
            const rivalStats: { [key: string]: number } = {};
            let w = 0, l = 0;

            matches.forEach((m: any) => {
                let myTeam = 0; let partnerId = ''; let enemies: string[] = [];
                if (m.player_1 === user.id) { myTeam = 1; partnerId = m.player_2; enemies = [m.player_3, m.player_4]; }
                else if (m.player_2 === user.id) { myTeam = 1; partnerId = m.player_1; enemies = [m.player_3, m.player_4]; }
                else if (m.player_3 === user.id) { myTeam = 2; partnerId = m.player_4; enemies = [m.player_1, m.player_2]; }
                else if (m.player_4 === user.id) { myTeam = 2; partnerId = m.player_3; enemies = [m.player_1, m.player_2]; }

                if (m.winner_team === 'DRAW') return;
                const iWon = (myTeam === 1 && m.winner_team === 'TEAM_1') || (myTeam === 2 && m.winner_team === 'TEAM_2');

                if (iWon) { w++; if (partnerId) partnerStats[partnerId] = (partnerStats[partnerId] || 0) + 1; }
                else { l++; enemies.forEach(e => { if (e) rivalStats[e] = (rivalStats[e] || 0) + 1; }); }
            });

            setTotalStats({ wins: w, losses: l, winRate: (w + l) > 0 ? Math.round((w / (w + l)) * 100) : 0 });

            let bestPid = Object.keys(partnerStats).reduce((a, b) => partnerStats[a] > partnerStats[b] ? a : b, '');
            if (bestPid) { const { data } = await supabase.from('profiles').select('name').eq('id', bestPid).single(); if (data) setBestPartner({ name: data.name, wins: partnerStats[bestPid] }); }

            let worstPid = Object.keys(rivalStats).reduce((a, b) => rivalStats[a] > rivalStats[b] ? a : b, '');
            if (worstPid) { const { data } = await supabase.from('profiles').select('name').eq('id', worstPid).single(); if (data) setWorstRival({ name: data.name, losses: rivalStats[worstPid] }); }
        }

        // 3. [New] Load ELO History (Graph)
        const { data: history } = await supabase.from('elo_history')
            .select('elo_score')
            .eq('player_id', user.id)
            .order('created_at', { ascending: true }) // Oldest first
            .limit(20); // Last 20 changes

        if (history) {
            setEloHistory(history.map((h: any) => h.elo_score));
        }

        // 4. [New] Load MVP Badges
        const { data: votes } = await supabase.from('mvp_votes')
            .select('tag')
            .eq('target_id', user.id);

        if (votes) {
            const badgeCounts: { [key: string]: number } = {};
            votes.forEach((v: any) => { badgeCounts[v.tag] = (badgeCounts[v.tag] || 0) + 1; });
            const sortedBadges = Object.entries(badgeCounts)
                .map(([tag, count]) => ({ tag, count }))
                .sort((a, b) => b.count - a.count);
            setMvpBadges(sortedBadges);
        }

        setLoading(false);
    };

    // 📸 Image Compression & Upload Logic (Same as before)
    const handleImageUpload = async (event: React.ChangeEvent<HTMLInputElement>) => {
        if (!event.target.files || event.target.files.length === 0) return;
        setUploading(true);
        const file = event.target.files[0];
        try {
            const compressedFile = await new Promise<Blob>((resolve, reject) => {
                const img = new Image(); img.src = URL.createObjectURL(file);
                img.onload = () => {
                    const canvas = document.createElement('canvas'); const ctx = canvas.getContext('2d');
                    if (!ctx) { reject('Canvas error'); return; }
                    const MAX_SIZE = 300; let width = img.width; let height = img.height;
                    if (width > height) { if (width > MAX_SIZE) { height *= MAX_SIZE / width; width = MAX_SIZE; } }
                    else { if (height > MAX_SIZE) { width *= MAX_SIZE / height; height = MAX_SIZE; } }
                    canvas.width = width; canvas.height = height; ctx.drawImage(img, 0, 0, width, height);
                    canvas.toBlob((blob) => { if (blob) resolve(blob); else reject('Compression failed'); }, 'image/jpeg', 0.7);
                }; img.onerror = (e) => reject(e);
            });
            const fileExt = 'jpg'; const fileName = `${user.id}-${Date.now()}.${fileExt}`;
            const { error: uploadError } = await supabase.storage.from('avatars').upload(fileName, compressedFile);
            if (uploadError) throw uploadError;
            const { data: { publicUrl } } = supabase.storage.from('avatars').getPublicUrl(fileName);
            setAvatarUrl(publicUrl);
        } catch (error: any) { alert('Upload Error: ' + error.message); } finally { setUploading(false); }
    };

    const handleSave = async () => {
        setSaving(true);
        const { error } = await supabase.from('profiles').update({ emoji: selectedEmoji, avatar_url: avatarUrl }).eq('id', user.id);
        if (error) alert(error.message); else { alert("✅ Profile Updated!"); onUpdate(); onClose(); }
        setSaving(false);
    };

    return (
        <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-fadeIn">
            <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-md shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
                <div className="bg-slate-900 p-4 border-b border-slate-700 flex justify-between items-center">
                    <h2 className="text-xl font-bold text-white flex items-center gap-2">⚙️ My Stats</h2>
                    <button onClick={onClose} className="text-slate-400 hover:text-white">✕</button>
                </div>

                <div className="p-6 overflow-y-auto custom-scrollbar">
                    {loading ? <div className="text-center py-10">Loading...</div> : (
                        <>
                            {/* 1. Profile Header (Same) */}
                            <div className="mb-6 flex flex-col items-center">
                                <div className="relative group mb-4">
                                    <div onClick={() => fileInputRef.current?.click()} className="w-24 h-24 rounded-full bg-slate-700 border-4 border-slate-500 flex items-center justify-center text-5xl cursor-pointer hover:border-lime-400 overflow-hidden transition-all shadow-xl">
                                        {uploading ? <div className="text-xs text-white animate-pulse">Uploading...</div> : avatarUrl ? <img src={avatarUrl} alt="Avatar" className="w-full h-full object-cover" /> : <span>{selectedEmoji}</span>}
                                        <div className="absolute inset-0 bg-black/50 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity"><span className="text-xs text-white font-bold">📷 Change</span></div>
                                    </div>
                                    <input type="file" ref={fileInputRef} onChange={handleImageUpload} accept="image/*" className="hidden" />
                                    {!avatarUrl && <div className="absolute top-0 -right-10 flex flex-col gap-1 h-24 overflow-y-auto custom-scrollbar bg-slate-800 p-1 rounded border border-slate-600">{EMOJI_LIST.slice(0, 10).map(e => <button key={e} onClick={() => setSelectedEmoji(e)} className="text-lg hover:bg-slate-600 rounded">{e}</button>)}<button onClick={() => setSelectedEmoji('🎾')} className="text-[10px] text-slate-400">More..</button></div>}
                                </div>
                                <h3 className="text-2xl font-black text-white">{name}</h3>
                                <p className="text-xs text-lime-400 font-bold mb-4">{myProfile?.gender} · {myProfile?.role || 'Member'}</p>

                                {/* ELO Grid */}
                                <div className="w-full bg-slate-700/30 rounded-xl p-3 border border-slate-600 grid grid-cols-4 gap-2 text-center text-xs">
                                    <div className="bg-slate-800 rounded p-1"><p className="text-slate-400">Men</p><p className="font-bold text-white">{myProfile.elo_men_doubles || '-'}</p></div>
                                    <div className="bg-slate-800 rounded p-1"><p className="text-slate-400">Women</p><p className="font-bold text-white">{myProfile.elo_women_doubles || '-'}</p></div>
                                    <div className="bg-slate-800 rounded p-1"><p className="text-slate-400">Mixed</p><p className="font-bold text-white">{myProfile.elo_mixed_doubles || '-'}</p></div>
                                    <div className="bg-slate-800 rounded p-1"><p className="text-slate-400">Single</p><p className="font-bold text-white">{myProfile.elo_singles || '-'}</p></div>
                                </div>
                            </div>

                            {/* 2. [New] ELO Graph */}
                            <div className="mb-6">
                                <SimpleLineChart data={eloHistory} />
                            </div>

                            {/* 3. Win Rate & Rival */}
                            <div className="grid grid-cols-2 gap-3 mb-6">
                                <div className="bg-slate-900/50 border border-slate-700 rounded-xl p-3 text-center">
                                    <p className="text-xs text-slate-500 mb-1">Win Rate</p>
                                    <p className="text-xl font-black text-lime-400">{totalStats.winRate}%</p>
                                    <p className="text-[10px] text-slate-400">{totalStats.wins}W - {totalStats.losses}L</p>
                                </div>
                                <div className="bg-slate-900/50 border border-slate-700 rounded-xl p-3 text-center flex flex-col justify-center">
                                    {bestPartner ? <div><p className="text-xs text-indigo-400 font-bold">Best Partner</p><p className="text-sm font-bold text-white">{bestPartner.name}</p></div> : <p className="text-xs text-slate-500">Play more games!</p>}
                                </div>
                            </div>

                            {/* 4. [New] MVP Badges */}
                            <div className="bg-slate-900/50 rounded-xl p-4 border border-slate-700">
                                <p className="text-[10px] text-slate-400 font-bold mb-2 uppercase">My MVP Badges</p>
                                <div className="flex flex-wrap gap-2">
                                    {mvpBadges.length > 0 ? mvpBadges.map((badge, idx) => (
                                        <div key={idx} className="bg-slate-800 border border-slate-600 px-3 py-1 rounded-full text-xs font-bold text-white flex items-center gap-1 shadow-sm">
                                            <span>{badge.tag}</span>
                                            <span className="bg-yellow-500 text-slate-900 w-4 h-4 rounded-full flex items-center justify-center text-[9px]">{badge.count}</span>
                                        </div>
                                    )) : <p className="text-xs text-slate-500 italic">No MVP votes yet. Show them your skills!</p>}
                                </div>
                            </div>
                        </>
                    )}
                </div>

                <div className="p-4 border-t border-slate-700 bg-slate-900">
                    <button onClick={handleSave} disabled={saving} className="w-full py-3 bg-lime-500 hover:bg-lime-400 text-slate-900 font-bold rounded-xl shadow-lg disabled:opacity-50">
                        {saving ? 'Saving...' : 'Save Changes'}
                    </button>
                </div>
            </div>
        </div>
    );
}