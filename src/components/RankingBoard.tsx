import { useEffect, useState } from 'react'; // 👈 이 부분이 빠져있었습니다!
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';
import PlayerProfileModal from './PlayerProfileModal';

// Types
type Profile = {
    id: string; name: string; ntrp: number; is_guest: boolean;
    elo_men_doubles: number; elo_women_doubles: number; elo_mixed_doubles: number; elo_singles: number;
};

type MatchRecord = {
    id: string; end_time: string; score_team1: number; score_team2: number;
    match_type: string; match_category: string;
    player_1: string; player_2: string; player_3: string; player_4: string;
    p1_name: string; p2_name: string; p3_name: string; p4_name: string;
    winner_team: string; my_vote?: string;
};

type RankCategory = 'MEN_D' | 'WOMEN_D' | 'MIXED' | 'SINGLES';

// 🏷️ MVP Tags
const MVP_TAGS = [
    { label: "🚀 강력한 불꽃 서브", icon: "🚀" }, { label: "💪 미친 포핸드", icon: "💪" },
    { label: "🛡️ 통곡의 벽 (수비)", icon: "🛡️" }, { label: "🧠 테니스 지능캐", icon: "🧠" },
    { label: "🎩 젠틀맨 (매너)", icon: "🎩" }, { label: "🔥 꺾이지 않는 마음", icon: "🔥" },
    { label: "🩰 우아한 발놀림", icon: "🩰" },
];

export default function RankingBoard({ user }: { user: User }) {
    const [activeTab, setActiveTab] = useState<'RANKING' | 'HISTORY'>('RANKING');
    const [rankCategory, setRankCategory] = useState<RankCategory>('MEN_D');

    // Data State
    const [rankings, setRankings] = useState<Profile[]>([]);
    const [history, setHistory] = useState<MatchRecord[]>([]);
    const [loading, setLoading] = useState(false);
    const [selectedDate, setSelectedDate] = useState(new Date().toISOString().split('T')[0]);

    // ✨ Search State
    const [searchPlayer, setSearchPlayer] = useState('');

    // Modals
    const [isVoteModalOpen, setIsVoteModalOpen] = useState(false);
    const [voteTargetMatch, setVoteTargetMatch] = useState<MatchRecord | null>(null);
    const [voteCandidate, setVoteCandidate] = useState<string | null>(null);
    const [voteTag, setVoteTag] = useState<string>("");

    // Player Profile Modal State
    const [selectedProfileId, setSelectedProfileId] = useState<string | null>(null);

    useEffect(() => {
        fetchData();
        const sub = supabase.channel('ranking_updates').on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => fetchData()).subscribe();
        return () => { supabase.removeChannel(sub); };
    }, [rankCategory, selectedDate, activeTab]);

    const fetchData = async () => {
        setLoading(true);
        try {
            if (activeTab === 'RANKING') {
                let sortField = 'elo_men_doubles';
                if (rankCategory === 'WOMEN_D') sortField = 'elo_women_doubles';
                if (rankCategory === 'MIXED') sortField = 'elo_mixed_doubles';
                if (rankCategory === 'SINGLES') sortField = 'elo_singles';

                const { data: profiles } = await supabase.from('profiles').select('*').order(sortField, { ascending: false }).limit(50);
                if (profiles) setRankings(profiles as Profile[]);
            } else {
                const startOfDay = `${selectedDate}T00:00:00`;
                const endOfDay = `${selectedDate}T23:59:59`;
                const { data: matches } = await supabase.from('matches').select('*').eq('status', 'FINISHED').gte('end_time', startOfDay).lte('end_time', endOfDay).order('end_time', { ascending: false });
                if (matches && matches.length > 0) {
                    const pIds = new Set<string>();
                    matches.forEach((m: any) => { if (m.player_1) pIds.add(m.player_1); if (m.player_2) pIds.add(m.player_2); if (m.player_3) pIds.add(m.player_3); if (m.player_4) pIds.add(m.player_4); });
                    const { data: pNames } = await supabase.from('profiles').select('id, name').in('id', Array.from(pIds));
                    const { data: myVotes } = await supabase.from('mvp_votes').select('match_id, target_id').eq('voter_id', user.id).in('match_id', matches.map(m => m.id));

                    const formattedHistory = matches.map((m: any) => ({
                        ...m,
                        p1_name: pNames?.find(p => p.id === m.player_1)?.name || '?', p2_name: pNames?.find(p => p.id === m.player_2)?.name || '?',
                        p3_name: pNames?.find(p => p.id === m.player_3)?.name || '?', p4_name: pNames?.find(p => p.id === m.player_4)?.name || '?',
                        my_vote: myVotes?.find(v => v.match_id === m.id)?.target_id
                    }));
                    setHistory(formattedHistory);
                } else { setHistory([]); }
            }
        } catch (e) { console.error(e); }
        setLoading(false);
    };

    const getScore = (p: Profile) => {
        if (rankCategory === 'MEN_D') return p.elo_men_doubles;
        if (rankCategory === 'WOMEN_D') return p.elo_women_doubles;
        if (rankCategory === 'SINGLES') return p.elo_singles;
        return p.elo_mixed_doubles;
    };

    // Vote Logic
    const openVoteModal = (match: MatchRecord) => { setVoteTargetMatch(match); setVoteCandidate(null); setVoteTag(""); setIsVoteModalOpen(true); };
    const submitVote = async () => {
        if (!voteTargetMatch || !voteCandidate || !voteTag) return alert("Select Player & Tag!");
        try {
            const { error } = await supabase.from('mvp_votes').insert({ match_id: voteTargetMatch.id, voter_id: user.id, target_id: voteCandidate, tag: voteTag });
            if (error) throw error; alert("👑 MVP Voted!"); setIsVoteModalOpen(false); fetchData();
        } catch (e: any) { alert("Already voted or error."); }
    };
    const getVoteCandidates = () => {
        if (!voteTargetMatch) return [];
        const isTeam1Win = voteTargetMatch.winner_team === 'TEAM_1';
        const winners = isTeam1Win ? [{ id: voteTargetMatch.player_1, name: voteTargetMatch.p1_name }, { id: voteTargetMatch.player_2, name: voteTargetMatch.p2_name }] : [{ id: voteTargetMatch.player_3, name: voteTargetMatch.p3_name }, { id: voteTargetMatch.player_4, name: voteTargetMatch.p4_name }];
        return winners.filter(p => p.id && p.id !== user.id);
    };

    // Filter Logic for Autocomplete
    const filteredRankings = rankings.filter(p =>
        p.name.toLowerCase().includes(searchPlayer.toLowerCase())
    );

    // Render Helpers
    const top3 = rankings.slice(0, 3);
    const restOfRankings = rankings.slice(3);

    const renderPodiumCard = (player: Profile | undefined, rank: number, colorBg: string, badgeTextColor: string, isCenter: boolean = false) => {
        if (!player) return <div className="flex-1"></div>;
        let styles = { mt: 'mt-14', scale: 'z-10', badge: 'bg-slate-700 text-slate-300 border-slate-600', cardBorder: 'border-slate-600', cardShadow: '', glow: '' };
        if (rank === 1) { styles = { mt: 'mt-4', scale: 'scale-110 z-20', badge: 'bg-gradient-to-br from-yellow-300 to-yellow-500 text-yellow-900 border-yellow-200 shadow-md', cardBorder: 'border-yellow-400', cardShadow: 'shadow-[0_0_25px_rgba(234,179,8,0.6)]', glow: 'before:absolute before:inset-0 before:bg-gradient-to-t before:from-yellow-500/30 before:via-yellow-500/5 before:to-transparent before:rounded-2xl before:pointer-events-none' }; }
        else if (rank === 2) { styles = { mt: 'mt-14', scale: 'z-10', badge: 'bg-gradient-to-br from-slate-200 to-slate-400 text-slate-900 border-slate-100 shadow-md', cardBorder: 'border-slate-300', cardShadow: 'shadow-[0_0_20px_rgba(203,213,225,0.4)]', glow: 'before:absolute before:inset-0 before:bg-gradient-to-t before:from-slate-400/20 before:via-slate-400/5 before:to-transparent before:rounded-2xl before:pointer-events-none' }; }
        else if (rank === 3) { styles = { mt: 'mt-14', scale: 'z-10', badge: 'bg-gradient-to-br from-amber-600 to-amber-800 text-amber-100 border-amber-500 shadow-md', cardBorder: 'border-amber-600', cardShadow: 'shadow-[0_0_20px_rgba(180,83,9,0.4)]', glow: 'before:absolute before:inset-0 before:bg-gradient-to-t before:from-amber-700/20 before:via-amber-700/5 before:to-transparent before:rounded-2xl before:pointer-events-none' }; }

        return (
            <div
                onClick={() => setSelectedProfileId(player.id)}
                className={`flex-1 flex flex-col items-center relative transition-all duration-500 cursor-pointer hover:-translate-y-2 ${styles.mt} ${styles.scale}`}
            >
                <div className={`w-12 h-12 rounded-full flex items-center justify-center font-black text-xl mb-3 border-4 ${styles.badge} z-30`}>{rank}</div>
                <div className={`w-full p-4 rounded-2xl border bg-gradient-to-b from-slate-800 to-slate-900 flex flex-col items-center relative ${styles.cardBorder} ${styles.cardShadow} ${styles.glow}`}>
                    <p className="text-white font-bold truncate max-w-[90%] text-sm md:text-base relative z-10">{player.name}</p>
                    {player.is_guest && <span className="text-[9px] bg-indigo-500 text-white px-1.5 py-0.5 rounded mt-1 font-bold relative z-10">GUEST</span>}
                    <p className="text-3xl font-black mt-3 text-white tracking-tighter drop-shadow-md relative z-10">{getScore(player)}</p>
                    <p className="text-[10px] text-slate-400 font-bold tracking-widest uppercase mt-1 relative z-10">ELO Point</p>
                </div>
            </div>
        );
    }

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-6 h-full flex flex-col relative">
            {/* Header */}
            <div className="flex flex-col gap-4 mb-4 border-b border-white/10 pb-2 shrink-0">
                <div className="flex justify-between items-center">
                    <div className="flex gap-4">
                        <button onClick={() => setActiveTab('RANKING')} className={`text-lg font-bold pb-2 transition-all ${activeTab === 'RANKING' ? 'text-lime-400 border-b-2 border-lime-400' : 'text-slate-400 hover:text-white'}`}>🏆 Leaderboard</button>
                        <button onClick={() => setActiveTab('HISTORY')} className={`text-lg font-bold pb-2 transition-all ${activeTab === 'HISTORY' ? 'text-cyan-400 border-b-2 border-cyan-400' : 'text-slate-400 hover:text-white'}`}>📜 History</button>
                    </div>
                </div>

                {/* 🔍 Search Bar (Visible only in Ranking Tab) */}
                {activeTab === 'RANKING' && (
                    <div className="relative">
                        <input
                            type="text"
                            placeholder="🔍 Search Player..."
                            value={searchPlayer}
                            onChange={(e) => setSearchPlayer(e.target.value)}
                            className="w-full bg-slate-900/80 border border-slate-600 rounded-lg px-3 py-2 text-white text-sm outline-none focus:border-lime-400 transition-all"
                        />
                        {/* Autocomplete Dropdown */}
                        {searchPlayer && (
                            <div className="absolute top-full left-0 w-full bg-slate-800 border border-slate-600 rounded-lg mt-1 shadow-xl z-50 max-h-48 overflow-y-auto">
                                {filteredRankings.length === 0 ? (
                                    <div className="p-3 text-slate-500 text-xs text-center">No player found</div>
                                ) : (
                                    filteredRankings.map(p => (
                                        <button
                                            key={p.id}
                                            onClick={() => { setSelectedProfileId(p.id); setSearchPlayer(''); }}
                                            className="w-full text-left px-3 py-2 hover:bg-slate-700 text-sm flex justify-between items-center"
                                        >
                                            <span className="text-white font-bold">{p.name}</span>
                                            <span className="text-xs text-slate-400">ELO: {getScore(p)}</span>
                                        </button>
                                    ))
                                )}
                            </div>
                        )}
                    </div>
                )}

                {/* 📅 Date Picker (Only for History) */}
                {activeTab === 'HISTORY' && (
                    <div className="flex justify-end">
                        <input type="date" value={selectedDate} onChange={(e) => setSelectedDate(e.target.value)} className="bg-slate-900 text-white border border-slate-600 rounded-lg px-2 py-1 text-sm outline-none focus:border-cyan-400" />
                    </div>
                )}
            </div>

            <div className="flex-1 overflow-y-auto pr-2 custom-scrollbar relative">
                {loading ? (<div className="text-center text-slate-500 py-10">Loading...</div>) : activeTab === 'RANKING' ? (
                    <>
                        <div className="flex gap-2 mb-4 bg-slate-900/50 p-1 rounded-lg inline-flex self-center shrink-0">
                            <button onClick={() => setRankCategory('MEN_D')} className={`px-3 py-1 text-xs rounded-md font-bold transition-all ${rankCategory === 'MEN_D' ? 'bg-blue-600 text-white shadow' : 'text-slate-400 hover:text-white'}`}>Men's</button>
                            <button onClick={() => setRankCategory('WOMEN_D')} className={`px-3 py-1 text-xs rounded-md font-bold transition-all ${rankCategory === 'WOMEN_D' ? 'bg-rose-600 text-white shadow' : 'text-slate-400 hover:text-white'}`}>Women's</button>
                            <button onClick={() => setRankCategory('MIXED')} className={`px-3 py-1 text-xs rounded-md font-bold transition-all ${rankCategory === 'MIXED' ? 'bg-purple-600 text-white shadow' : 'text-slate-400 hover:text-white'}`}>Mixed</button>
                            <button onClick={() => setRankCategory('SINGLES')} className={`px-3 py-1 text-xs rounded-md font-bold transition-all ${rankCategory === 'SINGLES' ? 'bg-emerald-600 text-white shadow' : 'text-slate-400 hover:text-white'}`}>Singles</button>
                        </div>
                        {rankings.length > 0 && (
                            <div className="flex items-start justify-center gap-2 md:gap-4 mb-8 pt-4 px-2 min-h-[180px]">
                                {renderPodiumCard(top3[1], 2, 'bg-slate-300', 'text-slate-900')}
                                {renderPodiumCard(top3[0], 1, 'bg-yellow-400', 'text-yellow-900', true)}
                                {renderPodiumCard(top3[2], 3, 'bg-amber-700', 'text-amber-100')}
                            </div>
                        )}
                        <div className="space-y-2 bg-slate-900/30 p-4 rounded-xl border border-white/5">
                            {restOfRankings.map((player, idx) => (
                                <div
                                    key={player.id}
                                    onClick={() => setSelectedProfileId(player.id)}
                                    className={`flex items-center justify-between p-3 rounded-xl border cursor-pointer hover:bg-slate-700/50 transition-colors ${player.is_guest ? 'bg-indigo-900/20 border-indigo-500/30' : 'bg-slate-800/50 border-slate-700'}`}
                                >
                                    <div className="flex items-center gap-3"><div className="w-8 h-8 rounded-full flex items-center justify-center font-bold text-sm bg-slate-700 text-slate-300 border border-slate-600">{idx + 4}</div><div><p className="text-white font-bold text-sm">{player.name}{player.is_guest && <span className="ml-2 text-[9px] bg-indigo-500 px-1 rounded text-white">GUEST</span>}</p></div></div>
                                    <p className="text-white font-mono font-bold text-md">{getScore(player)}</p>
                                </div>
                            ))}
                        </div>
                    </>
                ) : (
                    <div className="space-y-3 pb-20">
                        {history.length === 0 ? (<div className="text-center py-10 opacity-50"><p className="text-4xl mb-2">📅</p><p>No matches on {selectedDate}</p></div>) : history.map((match) => (
                            <div key={match.id} className="bg-slate-900/50 p-4 rounded-xl border border-white/5 relative group">
                                <div className="flex justify-between items-center mb-3">
                                    <div className="flex gap-2">
                                        {match.match_type === 'TOURNAMENT' && <span className="text-[10px] px-2 py-0.5 rounded font-bold bg-amber-500/20 text-amber-400 border border-amber-500/50">🏆 TOURNAMENT</span>}
                                        <span className="text-[10px] px-2 py-0.5 rounded font-bold bg-slate-700 text-slate-300">{match.match_category}</span>
                                    </div>
                                    <span className="text-[10px] text-slate-500">{new Date(match.end_time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
                                </div>
                                <div className="flex justify-between items-center mb-3">
                                    <div className={`flex-1 text-center ${match.winner_team === 'TEAM_1' ? 'opacity-100' : 'opacity-40 grayscale'}`}><p className={`text-2xl font-black mb-1 ${match.winner_team === 'TEAM_1' ? 'text-lime-400' : 'text-slate-500'}`}>{match.score_team1}</p><div className="text-xs text-slate-300 flex flex-col items-center gap-0.5"><span>{match.p1_name}</span><span>{match.p2_name}</span></div></div>
                                    <div className="px-2 text-slate-600 font-bold italic">VS</div>
                                    <div className={`flex-1 text-center ${match.winner_team === 'TEAM_2' ? 'opacity-100' : 'opacity-40 grayscale'}`}><p className={`text-2xl font-black mb-1 ${match.winner_team === 'TEAM_2' ? 'text-lime-400' : 'text-slate-500'}`}>{match.score_team2}</p><div className="text-xs text-slate-300 flex flex-col items-center gap-0.5"><span>{match.p3_name}</span><span>{match.p4_name}</span></div></div>
                                </div>
                                {match.winner_team !== 'DRAW' && !match.my_vote && (<button onClick={() => openVoteModal(match)} className="w-full py-2 bg-gradient-to-r from-violet-600 to-indigo-600 text-white font-bold text-xs rounded-lg hover:from-violet-500 hover:to-indigo-500 shadow-lg transition-all">👑 Vote MVP</button>)}
                                {match.my_vote && (<div className="text-center text-[10px] text-indigo-400 font-bold bg-indigo-900/20 py-1 rounded">✅ You voted for MVP</div>)}
                            </div>
                        ))}
                    </div>
                )}
            </div>

            {/* 🗳️ VOTE MODAL */}
            {isVoteModalOpen && voteTargetMatch && (
                <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4">
                    <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-sm p-6 shadow-2xl relative">
                        <button onClick={() => setIsVoteModalOpen(false)} className="absolute top-4 right-4 text-slate-400 hover:text-white">✕</button>
                        <h3 className="text-xl font-bold text-white mb-1">👑 Select Match MVP</h3>
                        <p className="text-xs text-slate-400 mb-6">Vote for the best player of the winning team!</p>
                        <div className="space-y-4">
                            <div><label className="block text-xs text-slate-400 mb-2 font-bold">Who was the best?</label><div className="grid grid-cols-2 gap-2">{getVoteCandidates().map(p => (<button key={p.id} onClick={() => setVoteCandidate(p.id)} className={`p-3 rounded-xl border transition-all font-bold text-sm ${voteCandidate === p.id ? 'bg-indigo-600 border-indigo-400 text-white' : 'bg-slate-700 border-transparent text-slate-300 hover:bg-slate-600'}`}>{p.name}</button>))}</div></div>
                            {voteCandidate && (<div><label className="block text-xs text-slate-400 mb-2 font-bold mt-4">Give them a title!</label><div className="grid grid-cols-1 gap-2 max-h-[160px] overflow-y-auto pr-1 custom-scrollbar">{MVP_TAGS.map((tag) => (<button key={tag.label} onClick={() => setVoteTag(tag.label)} className={`text-left px-3 py-2 rounded-lg text-xs font-bold border transition-all flex items-center gap-2 ${voteTag === tag.label ? 'bg-amber-500/20 border-amber-500 text-amber-300' : 'bg-slate-900 border-slate-700 text-slate-400 hover:border-slate-500'}`}><span className="text-lg">{tag.icon}</span> {tag.label}</button>))}</div></div>)}
                            <button onClick={submitVote} disabled={!voteCandidate || !voteTag} className="w-full py-3 bg-gradient-to-r from-indigo-500 to-purple-600 hover:from-indigo-400 hover:to-purple-500 text-white font-bold rounded-xl mt-2 shadow-lg disabled:opacity-50 disabled:cursor-not-allowed">Submit Vote</button>
                        </div>
                    </div>
                </div>
            )}

            {/* ✨ PLAYER PROFILE MODAL */}
            {selectedProfileId && (
                <PlayerProfileModal
                    playerId={selectedProfileId}
                    onClose={() => setSelectedProfileId(null)}
                />
            )}
        </div>
    );
}