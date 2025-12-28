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

        // 2. Analyze Matches (Same logic as before)
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
        setLoading(false);
    };

    // 📸 Image Compression & Upload Logic
    const handleImageUpload = async (event: React.ChangeEvent<HTMLInputElement>) => {
        if (!event.target.files || event.target.files.length === 0) return;
        setUploading(true);

        const file = event.target.files[0];

        try {
            // 1. Compress Image (Client-side Canvas)
            const compressedFile = await new Promise<Blob>((resolve, reject) => {
                const img = new Image();
                img.src = URL.createObjectURL(file);
                img.onload = () => {
                    const canvas = document.createElement('canvas');
                    const ctx = canvas.getContext('2d');
                    if (!ctx) { reject('Canvas error'); return; }

                    // Resize logic (Max 300px width/height)
                    const MAX_SIZE = 300;
                    let width = img.width;
                    let height = img.height;

                    if (width > height) {
                        if (width > MAX_SIZE) { height *= MAX_SIZE / width; width = MAX_SIZE; }
                    } else {
                        if (height > MAX_SIZE) { width *= MAX_SIZE / height; height = MAX_SIZE; }
                    }

                    canvas.width = width;
                    canvas.height = height;
                    ctx.drawImage(img, 0, 0, width, height);

                    // Convert to Blob (JPEG 70% quality)
                    canvas.toBlob((blob) => {
                        if (blob) resolve(blob); else reject('Compression failed');
                    }, 'image/jpeg', 0.7);
                };
                img.onerror = (e) => reject(e);
            });

            // 2. Upload to Supabase Storage ('avatars' bucket)
            const fileExt = 'jpg';
            const fileName = `${user.id}-${Date.now()}.${fileExt}`;
            const { error: uploadError } = await supabase.storage.from('avatars').upload(fileName, compressedFile);

            if (uploadError) throw uploadError;

            // 3. Get Public URL
            const { data: { publicUrl } } = supabase.storage.from('avatars').getPublicUrl(fileName);
            setAvatarUrl(publicUrl); // Preview immediately

        } catch (error: any) {
            alert('Upload Error: ' + error.message);
        } finally {
            setUploading(false);
        }
    };

    const handleSave = async () => {
        setSaving(true);
        // Name is READ-ONLY, so we don't update it. Only Emoji & Avatar.
        const { error } = await supabase.from('profiles').update({ emoji: selectedEmoji, avatar_url: avatarUrl }).eq('id', user.id);
        if (error) alert(error.message);
        else {
            alert("✅ Profile Updated!");
            onUpdate();
            onClose();
        }
        setSaving(false);
    };

    return (
        <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-fadeIn">
            <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-md shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
                <div className="bg-slate-900 p-4 border-b border-slate-700 flex justify-between items-center">
                    <h2 className="text-xl font-bold text-white flex items-center gap-2">⚙️ My Settings & Stats</h2>
                    <button onClick={onClose} className="text-slate-400 hover:text-white">✕</button>
                </div>

                <div className="p-6 overflow-y-auto custom-scrollbar">
                    {loading ? <div className="text-center py-10">Loading...</div> : (
                        <>
                            {/* 1. Edit Profile */}
                            <div className="mb-8 flex flex-col items-center">
                                {/* Photo / Emoji Selector */}
                                <div className="relative group mb-4">
                                    <div
                                        onClick={() => fileInputRef.current?.click()}
                                        className="w-24 h-24 rounded-full bg-slate-700 border-4 border-slate-500 flex items-center justify-center text-5xl cursor-pointer hover:border-lime-400 overflow-hidden transition-all shadow-xl"
                                    >
                                        {uploading ? (
                                            <div className="text-xs text-white animate-pulse">Uploading...</div>
                                        ) : avatarUrl ? (
                                            <img src={avatarUrl} alt="Avatar" className="w-full h-full object-cover" />
                                        ) : (
                                            <span>{selectedEmoji}</span>
                                        )}

                                        {/* Hover Overlay */}
                                        <div className="absolute inset-0 bg-black/50 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity">
                                            <span className="text-xs text-white font-bold">📷 Change</span>
                                        </div>
                                    </div>
                                    <input
                                        type="file"
                                        ref={fileInputRef}
                                        onChange={handleImageUpload}
                                        accept="image/*"
                                        className="hidden"
                                    />

                                    {/* Emoji Quick Picker (If no photo) */}
                                    {!avatarUrl && (
                                        <div className="absolute top-0 -right-10 flex flex-col gap-1 h-24 overflow-y-auto custom-scrollbar bg-slate-800 p-1 rounded border border-slate-600">
                                            {EMOJI_LIST.slice(0, 10).map(e => <button key={e} onClick={() => setSelectedEmoji(e)} className="text-lg hover:bg-slate-600 rounded">{e}</button>)}
                                            <button onClick={() => setSelectedEmoji('🎾')} className="text-[10px] text-slate-400">More..</button>
                                        </div>
                                    )}
                                </div>

                                {/* Emoji List (Full) - Toggle logic omitted for simplicity, showing list below */}
                                <div className="w-full mb-4">
                                    <p className="text-xs text-slate-400 mb-2 text-center">Or pick an Emoji:</p>
                                    <div className="flex flex-wrap justify-center gap-1 max-h-24 overflow-y-auto bg-slate-900/50 p-2 rounded-lg border border-slate-700">
                                        {EMOJI_LIST.map(e => (
                                            <button key={e} onClick={() => { setSelectedEmoji(e); setAvatarUrl(null); }} className={`p-1.5 rounded text-xl transition-all ${selectedEmoji === e ? 'bg-lime-500/20 scale-110' : 'hover:bg-slate-700'}`}>
                                                {e}
                                            </button>
                                        ))}
                                    </div>
                                </div>

                                {/* Name Field (Read-Only) */}
                                <div className="w-full">
                                    <label className="block text-xs text-slate-400 font-bold mb-1 ml-1">Name (Fixed)</label>
                                    <input
                                        type="text"
                                        value={name}
                                        readOnly // 🔒 수정 불가
                                        className="w-full bg-slate-900 border border-slate-700 rounded-xl px-4 py-3 text-slate-400 cursor-not-allowed font-bold text-center"
                                    />

                                    {/* Detailed Stats (Gender / ELO) */}
                                    {myProfile && (
                                        <div className="w-full mt-4 bg-slate-700/30 rounded-xl p-3 border border-slate-600 grid grid-cols-2 gap-2 text-xs">
                                            <div className="col-span-2 flex justify-center mb-1">
                                                <span className={`px-2 py-0.5 rounded text-[10px] font-bold ${(myProfile.gender || '').toLowerCase() === 'male' ? 'bg-blue-900 text-blue-300' : (myProfile.gender || '').toLowerCase() === 'female' ? 'bg-rose-900 text-rose-300' : 'bg-slate-700 text-slate-400'}`}>
                                                    {myProfile.gender || 'No Gender'}
                                                </span>
                                            </div>
                                            <div className="flex justify-between px-2 py-1 bg-slate-800 rounded">
                                                <span className="text-blue-300">Men</span>
                                                <span className="font-mono font-bold text-white">{myProfile.elo_men_doubles || '-'}</span>
                                            </div>
                                            <div className="flex justify-between px-2 py-1 bg-slate-800 rounded">
                                                <span className="text-rose-300">Women</span>
                                                <span className="font-mono font-bold text-white">{myProfile.elo_women_doubles || '-'}</span>
                                            </div>
                                            <div className="flex justify-between px-2 py-1 bg-slate-800 rounded">
                                                <span className="text-purple-300">Mixed</span>
                                                <span className="font-mono font-bold text-white">{myProfile.elo_mixed_doubles || '-'}</span>
                                            </div>
                                            <div className="flex justify-between px-2 py-1 bg-slate-800 rounded">
                                                <span className="text-emerald-300">Singles</span>
                                                <span className="font-mono font-bold text-white">{myProfile.elo_singles || '-'}</span>
                                            </div>
                                        </div>
                                    )}
                                </div>
                            </div>

                            {/* 2. Stats (Partner/Rival) */}
                            <div className="grid grid-cols-2 gap-4 mb-6">
                                <div className="bg-gradient-to-br from-indigo-900/50 to-slate-800 border border-indigo-500/30 rounded-xl p-4 flex flex-col items-center text-center relative overflow-hidden">
                                    <div className="absolute top-0 right-0 p-1 opacity-20 text-4xl">🤝</div>
                                    <p className="text-[10px] text-indigo-300 font-bold uppercase mb-1">Soulmate</p>
                                    {bestPartner ? (
                                        <>
                                            <p className="text-lg font-black text-white">{bestPartner.name}</p>
                                            <p className="text-xs text-slate-400">Won <span className="text-lime-400 font-bold">{bestPartner.wins}</span> games together</p>
                                        </>
                                    ) : <p className="text-xs text-slate-500 italic mt-2">No data yet</p>}
                                </div>
                                <div className="bg-gradient-to-br from-rose-900/50 to-slate-800 border border-rose-500/30 rounded-xl p-4 flex flex-col items-center text-center relative overflow-hidden">
                                    <div className="absolute top-0 right-0 p-1 opacity-20 text-4xl">😈</div>
                                    <p className="text-[10px] text-rose-300 font-bold uppercase mb-1">Rival</p>
                                    {worstRival ? (
                                        <>
                                            <p className="text-lg font-black text-white">{worstRival.name}</p>
                                            <p className="text-xs text-slate-400">Lost <span className="text-rose-400 font-bold">{worstRival.losses}</span> times</p>
                                        </>
                                    ) : <p className="text-xs text-slate-500 italic mt-2">Undefeated!</p>}
                                </div>
                            </div>

                            {/* 3. Summary */}
                            <div className="bg-slate-900/50 rounded-xl p-4 border border-slate-700 flex justify-around text-center">
                                <div><p className="text-xs text-slate-500">Wins</p><p className="text-xl font-black text-lime-400">{totalStats.wins}</p></div>
                                <div><p className="text-xs text-slate-500">Win Rate</p><p className="text-xl font-black text-white">{totalStats.winRate}%</p></div>
                                <div><p className="text-xs text-slate-500">Losses</p><p className="text-xl font-black text-rose-400">{totalStats.losses}</p></div>
                            </div>
                        </>
                    )}
                </div>

                <div className="p-4 border-t border-slate-700 bg-slate-900">
                    <button
                        onClick={handleSave}
                        disabled={saving}
                        className="w-full py-3 bg-lime-500 hover:bg-lime-400 text-slate-900 font-bold rounded-xl shadow-lg disabled:opacity-50"
                    >
                        {saving ? 'Saving...' : 'Save Changes'}
                    </button>
                </div>
            </div>
        </div>
    );
}