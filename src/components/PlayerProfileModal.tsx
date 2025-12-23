import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

type Props = {
    playerId: string;
    onClose: () => void;
};

// 📈 Simple SVG Chart (Same as before)
const EloChart = ({ history }: { history: any[] }) => {
    if (!history || history.length < 2) return <div className="h-32 flex items-center justify-center text-slate-500 text-xs">Not enough matches for graph</div>;
    const width = 300; const height = 100;
    const categories = {
        'MEN_D': { color: '#3b82f6', data: [] as number[] }, 'WOMEN_D': { color: '#f43f5e', data: [] as number[] },
        'MIXED': { color: '#9333ea', data: [] as number[] }, 'SINGLES': { color: '#10b981', data: [] as number[] }
    };
    history.forEach(h => { if (categories[h.match_category as keyof typeof categories]) categories[h.match_category as keyof typeof categories].data.push(h.elo_score); });
    const allScores = history.map(h => h.elo_score);
    const minScore = Math.min(...allScores) - 50; const maxScore = Math.max(...allScores) + 50; const range = maxScore - minScore;

    return (
        <div className="w-full h-40 bg-slate-900/50 rounded-xl border border-slate-700 p-2 relative">
            <svg viewBox={`0 0 ${width} ${height}`} className="w-full h-full overflow-visible">
                <line x1="0" y1="0" x2={width} y2="0" stroke="#334155" strokeWidth="0.5" strokeDasharray="4" />
                <line x1="0" y1={height / 2} x2={width} y2={height / 2} stroke="#334155" strokeWidth="0.5" strokeDasharray="4" />
                <line x1="0" y1={height} x2={width} y2={height} stroke="#334155" strokeWidth="0.5" strokeDasharray="4" />
                {Object.entries(categories).map(([cat, info]) => {
                    if (info.data.length < 1) return null;
                    const points = info.data.map((score, index) => { const x = (index / (info.data.length - 1 || 1)) * width; const y = height - ((score - minScore) / range) * height; return `${x},${y}`; }).join(' ');
                    return (<g key={cat}><polyline fill="none" stroke={info.color} strokeWidth="2" points={points} strokeLinecap="round" strokeLinejoin="round" />{info.data.map((score, index) => { const x = (index / (info.data.length - 1 || 1)) * width; const y = height - ((score - minScore) / range) * height; return <circle key={index} cx={x} cy={y} r="2" fill={info.color} />; })}</g>);
                })}
            </svg>
            <div className="flex justify-center gap-3 mt-2">
                <div className="flex items-center gap-1"><span className="w-2 h-2 rounded-full bg-blue-500"></span><span className="text-[10px] text-slate-400">Men</span></div>
                <div className="flex items-center gap-1"><span className="w-2 h-2 rounded-full bg-rose-500"></span><span className="text-[10px] text-slate-400">Women</span></div>
                <div className="flex items-center gap-1"><span className="w-2 h-2 rounded-full bg-purple-500"></span><span className="text-[10px] text-slate-400">Mixed</span></div>
                <div className="flex items-center gap-1"><span className="w-2 h-2 rounded-full bg-emerald-500"></span><span className="text-[10px] text-slate-400">Singles</span></div>
            </div>
        </div>
    );
};

export default function PlayerProfileModal({ playerId, onClose }: Props) {
    const [profile, setProfile] = useState<any>(null);
    const [stats, setStats] = useState({ wins: 0, losses: 0, winRate: 0, total: 0 });
    const [mvpTags, setMvpTags] = useState<{ tag: string; count: number }[]>([]);
    const [eloHistory, setEloHistory] = useState<any[]>([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        const fetchDetail = async () => {
            setLoading(true);
            const { data: p } = await supabase.from('profiles').select('*').eq('id', playerId).single();
            setProfile(p);

            const { data: matches } = await supabase.from('matches').select('winner_team, player_1, player_2, player_3, player_4').eq('status', 'FINISHED').or(`player_1.eq.${playerId},player_2.eq.${playerId},player_3.eq.${playerId},player_4.eq.${playerId}`);
            if (matches) {
                let w = 0, l = 0;
                matches.forEach(m => {
                    const isTeam1 = (m.player_1 === playerId || m.player_2 === playerId);
                    if (m.winner_team === 'DRAW') return;
                    if ((isTeam1 && m.winner_team === 'TEAM_1') || (!isTeam1 && m.winner_team === 'TEAM_2')) w++; else l++;
                });
                setStats({ wins: w, losses: l, total: w + l, winRate: (w + l) > 0 ? Math.round((w / (w + l)) * 100) : 0 });
            }

            const { data: votes } = await supabase.from('mvp_votes').select('tag').eq('target_id', playerId);
            if (votes) {
                const counts: { [key: string]: number } = {};
                votes.forEach(v => { counts[v.tag] = (counts[v.tag] || 0) + 1; });
                setMvpTags(Object.entries(counts).map(([tag, count]) => ({ tag, count })).sort((a, b) => b.count - a.count));
            }

            const { data: history } = await supabase.from('elo_history').select('*').eq('player_id', playerId).order('recorded_at', { ascending: true });
            if (history) setEloHistory(history);

            setLoading(false);
        };
        fetchDetail();
    }, [playerId]);

    if (!playerId) return null;

    // 🔥 GENDER FILTER HELPER
    const getDisplayScore = (score: number, type: 'MEN' | 'WOMEN') => {
        if (!profile?.gender) return score; // Gender not set, show all
        if (profile.gender === 'Male' && type === 'WOMEN') return '---';
        if (profile.gender === 'Female' && type === 'MEN') return '---';
        return score;
    };

    return (
        <div className="fixed inset-0 z-[70] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-fadeIn">
            <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-md shadow-2xl relative overflow-hidden flex flex-col max-h-[90vh]">
                <div className="h-24 bg-gradient-to-r from-indigo-600 to-purple-600 w-full absolute top-0 left-0"></div>
                <button onClick={onClose} className="absolute top-4 right-4 text-white/70 hover:text-white z-10 bg-black/20 rounded-full p-1">✕</button>

                <div className="pt-12 px-6 pb-6 relative flex flex-col items-center flex-1 overflow-y-auto custom-scrollbar">

                    {/* Avatar Logic: Image > Emoji > Default */}
                    <div className="w-24 h-24 rounded-full border-4 border-slate-800 bg-slate-700 flex items-center justify-center text-4xl shadow-xl z-10 mb-3 overflow-hidden">
                        {loading ? '...' : profile?.avatar_url ? (
                            <img src={profile.avatar_url} alt="Profile" className="w-full h-full object-cover" />
                        ) : (
                            profile?.emoji || '🎾'
                        )}
                    </div>

                    {loading ? <p className="text-slate-400">Loading Profile...</p> : (
                        <>
                            <h2 className="text-2xl font-black text-white">{profile.name}</h2>
                            <p className="text-sm text-slate-400 font-bold mb-6 flex items-center gap-2">
                                {profile.is_guest ? 'GUEST PLAYER' : 'OFFICIAL MEMBER'}
                                {profile.gender && <span className={`text-[10px] px-1.5 rounded ${profile.gender === 'Male' ? 'bg-blue-500/20 text-blue-400' : 'bg-rose-500/20 text-rose-400'}`}>{profile.gender}</span>}
                            </p>

                            <div className="w-full mb-6">
                                <h3 className="text-xs font-bold text-slate-400 uppercase mb-2 ml-1">ELO Growth Chart</h3>
                                <EloChart history={eloHistory} />
                            </div>

                            <div className="w-full grid grid-cols-3 gap-2 mb-6">
                                <div className="bg-slate-900/50 p-2 rounded-lg text-center border border-slate-700"><p className="text-[10px] text-slate-500">Matches</p><p className="font-bold text-white">{stats.total}</p></div>
                                <div className="bg-slate-900/50 p-2 rounded-lg text-center border border-slate-700"><p className="text-[10px] text-slate-500">Win Rate</p><p className={`font-bold ${stats.winRate >= 50 ? 'text-lime-400' : 'text-rose-400'}`}>{stats.winRate}%</p></div>
                                <div className="bg-slate-900/50 p-2 rounded-lg text-center border border-slate-700"><p className="text-[10px] text-slate-500">W / L</p><p className="font-bold text-white"><span className="text-lime-400">{stats.wins}</span>/<span className="text-rose-400">{stats.losses}</span></p></div>
                            </div>

                            {/* ELO Current (Filtered by Gender) */}
                            <div className="w-full bg-slate-700/30 rounded-xl p-3 mb-6 border border-slate-600 grid grid-cols-2 gap-2">
                                <div className={`flex justify-between px-2 py-1 bg-slate-800 rounded ${profile.gender === 'Female' ? 'opacity-30' : ''}`}>
                                    <span className="text-[10px] text-blue-300">Men</span>
                                    <span className="font-mono text-sm font-bold">{getDisplayScore(profile.elo_men_doubles, 'MEN')}</span>
                                </div>
                                <div className={`flex justify-between px-2 py-1 bg-slate-800 rounded ${profile.gender === 'Male' ? 'opacity-30' : ''}`}>
                                    <span className="text-[10px] text-rose-300">Women</span>
                                    <span className="font-mono text-sm font-bold">{getDisplayScore(profile.elo_women_doubles, 'WOMEN')}</span>
                                </div>
                                <div className="flex justify-between px-2 py-1 bg-slate-800 rounded"><span className="text-[10px] text-purple-300">Mixed</span><span className="font-mono text-sm font-bold">{profile.elo_mixed_doubles}</span></div>
                                <div className="flex justify-between px-2 py-1 bg-slate-800 rounded"><span className="text-[10px] text-emerald-300">Singles</span><span className="font-mono text-sm font-bold">{profile.elo_singles}</span></div>
                            </div>

                            <div className="w-full">
                                <h3 className="text-xs font-bold text-yellow-400 uppercase mb-2">MVP Collection</h3>
                                <div className="flex flex-wrap gap-2">
                                    {mvpTags.map((item, idx) => (
                                        <div key={idx} className="flex items-center gap-1.5 bg-slate-700 border border-slate-600 px-2 py-1 rounded shadow-sm">
                                            <span className="text-sm">{item.tag.split(' ')[0]}</span>
                                            <span className="text-[10px] font-bold text-slate-200">{item.tag.split(' ').slice(1).join(' ')}</span>
                                            <span className="bg-yellow-500 text-slate-900 text-[9px] font-black px-1 rounded-full">{item.count}</span>
                                        </div>
                                    ))}
                                    {mvpTags.length === 0 && <span className="text-[10px] text-slate-500 italic">No MVP votes yet.</span>}
                                </div>
                            </div>
                        </>
                    )}
                </div>
            </div>
        </div>
    );
}