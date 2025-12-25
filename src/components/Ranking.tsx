import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';
import PlayerProfileModal from './PlayerProfileModal';

// ... (타입 정의는 동일) ...
type Profile = { id: string; name: string | null; ntrp: number; is_guest: boolean; gender: string; elo_men_doubles: number | null; elo_women_doubles: number | null; elo_mixed_doubles: number | null; elo_singles: number | null; avatar_url?: string; emoji?: string; };
type MatchRecord = { id: string; end_time: string; score_team1: number; score_team2: number; match_type: string; match_category: string; player_1: string; player_2: string; player_3: string; player_4: string; p1_name: string; p2_name: string; p3_name: string; p4_name: string; winner_team: string; my_vote?: string; };
type RankCategory = 'MEN_D' | 'WOMEN_D' | 'MIXED' | 'SINGLES';

export default function Ranking({ user }: { user: User }) {
    // ... (기존 state 로직 동일) ...
    const [activeTab, setActiveTab] = useState<'RANKING' | 'HISTORY'>('RANKING');
    const [rankCategory, setRankCategory] = useState<RankCategory>('MEN_D');
    const [rankings, setRankings] = useState<Profile[]>([]);
    const [history, setHistory] = useState<MatchRecord[]>([]);
    const [loading, setLoading] = useState(false);
    const [selectedDate, setSelectedDate] = useState(new Date().toISOString().split('T')[0]);
    const [searchPlayer, setSearchPlayer] = useState('');
    const [isVoteModalOpen, setIsVoteModalOpen] = useState(false);
    const [voteTargetMatch, setVoteTargetMatch] = useState<MatchRecord | null>(null);
    const [voteCandidate, setVoteCandidate] = useState<string | null>(null);
    const [voteTag, setVoteTag] = useState<string>("");
    const [selectedProfileId, setSelectedProfileId] = useState<string | null>(null);

    useEffect(() => {
        setRankings([]); fetchData();
        const sub = supabase.channel('ranking_updates').on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => fetchData()).subscribe();
        return () => { supabase.removeChannel(sub); };
    }, [rankCategory, selectedDate, activeTab]);

    const fetchData = async () => {
        setLoading(true);
        try {
            if (activeTab === 'RANKING') {
                let sortField = 'elo_men_doubles';
                if (rankCategory === 'WOMEN_D') sortField = 'elo_women_doubles';
                else if (rankCategory === 'MIXED') sortField = 'elo_mixed_doubles';
                else if (rankCategory === 'SINGLES') sortField = 'elo_singles';

                const { data: profiles } = await supabase.from('profiles').select('*').order(sortField, { ascending: false }).limit(50);
                const cleanProfiles = (profiles || []).filter(p => {
                    let rawScore = rankCategory === 'MEN_D' ? p.elo_men_doubles : rankCategory === 'WOMEN_D' ? p.elo_women_doubles : rankCategory === 'MIXED' ? p.elo_mixed_doubles : p.elo_singles;
                    if (!rawScore || rawScore <= 0) return false;
                    const gender = (p.gender || '').toLowerCase();
                    if (rankCategory === 'MEN_D' && gender !== 'male') return false;
                    if (rankCategory === 'WOMEN_D' && gender !== 'female') return false;
                    return (p.name || 'Unknown').toLowerCase().includes(searchPlayer.toLowerCase());
                });
                setRankings(cleanProfiles);
            } else {
                const startOfDay = `${selectedDate}T00:00:00`;
                const endOfDay = `${selectedDate}T23:59:59`;
                const { data: matches } = await supabase.from('matches').select('*').eq('status', 'FINISHED').gte('end_time', startOfDay).lte('end_time', endOfDay).order('end_time', { ascending: false });
                if (matches && matches.length > 0) {
                    const pIds = new Set<string>();
                    matches.forEach((m: any) => { if (m.player_1) pIds.add(m.player_1); if (m.player_2) pIds.add(m.player_2); if (m.player_3) pIds.add(m.player_3); if (m.player_4) pIds.add(m.player_4); });
                    const { data: pNames } = await supabase.from('profiles').select('id, name').in('id', Array.from(pIds));
                    const { data: myVotes } = await supabase.from('mvp_votes').select('match_id, target_id').eq('voter_id', user.id).in('match_id', matches.map(m => m.id));
                    setHistory(matches.map((m: any) => ({ ...m, p1_name: pNames?.find(p => p.id === m.player_1)?.name || '?', p2_name: pNames?.find(p => p.id === m.player_2)?.name || '?', p3_name: pNames?.find(p => p.id === m.player_3)?.name || '?', p4_name: pNames?.find(p => p.id === m.player_4)?.name || '?', my_vote: myVotes?.find(v => v.match_id === m.id)?.target_id })));
                } else setHistory([]);
            }
        } catch (e) { console.error(e); } finally { setLoading(false); }
    };

    const getScore = (p: Profile) => { if (rankCategory === 'MEN_D') return p.elo_men_doubles; if (rankCategory === 'WOMEN_D') return p.elo_women_doubles; if (rankCategory === 'SINGLES') return p.elo_singles; return p.elo_mixed_doubles; };
    const openVoteModal = (match: MatchRecord) => { setVoteTargetMatch(match); setVoteCandidate(null); setVoteTag(""); setIsVoteModalOpen(true); };
    const submitVote = async () => { if (!voteTargetMatch || !voteCandidate || !voteTag) return; await supabase.from('mvp_votes').insert({ match_id: voteTargetMatch.id, voter_id: user.id, target_id: voteCandidate, tag: voteTag }); setIsVoteModalOpen(false); fetchData(); };
    const getVoteCandidates = () => { if (!voteTargetMatch) return []; return (voteTargetMatch.winner_team === 'TEAM_1' ? [{ id: voteTargetMatch.player_1, name: voteTargetMatch.p1_name }, { id: voteTargetMatch.player_2, name: voteTargetMatch.p2_name }] : [{ id: voteTargetMatch.player_3, name: voteTargetMatch.p3_name }, { id: voteTargetMatch.player_4, name: voteTargetMatch.p4_name }]).filter(p => p.id !== user.id); };

    // ✨ Top 3 & 나머지 7명 (총 10명)
    const top3 = rankings.slice(0, 3);
    const restOfRankings = rankings.slice(3, 10);

    const renderPodiumCard = (player: Profile | undefined, rank: number, styles: any) => {
        if (!player) return <div className="flex-1"></div>;
        return (
            <div onClick={() => setSelectedProfileId(player.id)} className={`flex-1 flex flex-col items-center relative transition-all duration-500 cursor-pointer hover:-translate-y-2 ${styles.mt} ${styles.scale}`}>
                <div className={`w-10 h-10 rounded-full flex items-center justify-center font-black text-lg mb-2 border-4 ${styles.badge} z-30`}>{rank}</div>
                <div className={`w-full p-3 rounded-2xl border bg-gradient-to-b from-slate-800 to-slate-900 flex flex-col items-center relative ${styles.cardBorder} ${styles.cardShadow}`}>
                    <p className="text-white font-bold truncate max-w-[90%] text-sm relative z-10">{player.name || '?'}</p>
                    <p className="text-2xl font-black mt-2 text-white tracking-tighter relative z-10">{getScore(player)}</p>
                    <p className="text-[9px] text-slate-400 font-bold uppercase mt-1 relative z-10">ELO</p>
                </div>
            </div>
        );
    }

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-4 h-full flex flex-col relative animate-fadeIn">
            <div className="flex flex-col gap-3 mb-4 border-b border-white/10 pb-2 shrink-0">
                <div className="flex gap-4">
                    <button onClick={() => setActiveTab('RANKING')} className={`text-lg font-bold pb-2 ${activeTab === 'RANKING' ? 'text-lime-400 border-b-2 border-lime-400' : 'text-slate-400'}`}>🏆 랭킹</button>
                    <button onClick={() => setActiveTab('HISTORY')} className={`text-lg font-bold pb-2 ${activeTab === 'HISTORY' ? 'text-cyan-400 border-b-2 border-cyan-400' : 'text-slate-400'}`}>📜 경기 기록</button>
                </div>
                {activeTab === 'RANKING' && <input value={searchPlayer} onChange={e => setSearchPlayer(e.target.value)} placeholder="🔍 선수 검색..." className="w-full bg-slate-900 border border-slate-600 rounded px-3 py-2 text-white" />}
                {activeTab === 'HISTORY' && <input type="date" value={selectedDate} onChange={e => setSelectedDate(e.target.value)} className="bg-slate-900 text-white border border-slate-600 rounded px-2 py-1 self-end" />}
            </div>
            <div className="flex-1 overflow-y-auto pr-1 custom-scrollbar">
                {loading ? <div className="text-center py-10">로딩 중...</div> : activeTab === 'RANKING' ? (
                    <>
                        <div className="flex gap-1 mb-4 bg-slate-900/50 p-1 rounded inline-flex self-center">
                            {['MEN_D', 'WOMEN_D', 'MIXED', 'SINGLES'].map(cat => <button key={cat} onClick={() => setRankCategory(cat as any)} className={`px-2 py-1 text-[10px] rounded font-bold ${rankCategory === cat ? 'bg-slate-600 text-white' : 'text-slate-400'}`}>{cat === 'MEN_D' ? '남복' : cat === 'WOMEN_D' ? '여복' : cat === 'MIXED' ? '혼복' : '단식'}</button>)}
                        </div>
                        {top3.length > 0 ? (
                            <div className="flex items-end justify-center gap-2 mb-6 px-2 min-h-[160px]">
                                {renderPodiumCard(top3[1], 2, { mt: '', scale: 'z-10', badge: 'bg-slate-400 text-slate-900', cardBorder: 'border-slate-500', cardShadow: 'shadow-lg' })}
                                {/* ✨ 1등 단상을 mb-16으로 확실히 올림 */}
                                {renderPodiumCard(top3[0], 1, { mt: 'mb-16', scale: 'scale-110 z-20', badge: 'bg-yellow-400 text-yellow-900', cardBorder: 'border-yellow-500', cardShadow: 'shadow-xl' })}
                                {renderPodiumCard(top3[2], 3, { mt: '', scale: 'z-10', badge: 'bg-amber-700 text-amber-100', cardBorder: 'border-amber-600', cardShadow: 'shadow-lg' })}
                            </div>
                        ) : <div className="text-center py-10">데이터 없음</div>}
                        <div className="space-y-2">
                            {restOfRankings.map((p, i) => <div key={p.id} onClick={() => setSelectedProfileId(p.id)} className="flex justify-between p-3 rounded border border-slate-700 bg-slate-800/50 cursor-pointer"><div className="flex gap-3"><span className="font-bold text-slate-300 w-6">{i + 4}</span><span className="font-bold text-white">{p.name}</span></div><span className="font-mono text-white">{getScore(p)}</span></div>)}
                        </div>
                    </>
                ) : (<div className="space-y-3">{history.map(m => <div key={m.id} className="bg-slate-900/50 p-4 rounded border border-white/5"><div className="flex justify-between mb-2"><span className="text-xs bg-slate-700 px-2 rounded">{m.match_category}</span><span className="text-xs text-slate-500">{m.end_time.slice(11, 16)}</span></div><div className="flex justify-between items-center"><div className={`text-center w-1/3 ${m.winner_team === 'TEAM_1' ? 'text-lime-400' : 'text-slate-500'}`}><p className="text-xl font-black">{m.score_team1}</p><p className="text-xs">{m.p1_name}/{m.p2_name}</p></div><div className="text-slate-600">VS</div><div className={`text-center w-1/3 ${m.winner_team === 'TEAM_2' ? 'text-lime-400' : 'text-slate-500'}`}><p className="text-xl font-black">{m.score_team2}</p><p className="text-xs">{m.p3_name}/{m.p4_name}</p></div></div>{!m.my_vote && <button onClick={() => openVoteModal(m)} className="w-full mt-2 py-1 bg-indigo-600 text-xs rounded">MVP 투표</button>}</div>)}</div>)}
            </div>
            {isVoteModalOpen && voteTargetMatch && <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/80"><div className="bg-slate-800 p-6 rounded-2xl w-full max-w-sm"><h3 className="text-white font-bold mb-4">👑 MVP 투표</h3><div className="grid grid-cols-2 gap-2 mb-4">{getVoteCandidates().map(p => <button key={p.id} onClick={() => setVoteCandidate(p.id)} className={`p-3 rounded border ${voteCandidate === p.id ? 'bg-indigo-600 border-indigo-400' : 'bg-slate-700 border-transparent'}`}>{p.name}</button>)}</div>{voteCandidate && <div className="grid grid-cols-1 gap-2 max-h-40 overflow-y-auto">{MVP_TAGS.map(t => <button key={t.label} onClick={() => setVoteTag(t.label)} className={`text-left p-2 rounded border text-xs ${voteTag === t.label ? 'bg-amber-500/20 border-amber-500' : 'bg-slate-900 border-slate-700'}`}>{t.icon} {t.label}</button>)}</div>}<div className="flex gap-2 mt-4"><button onClick={() => setIsVoteModalOpen(false)} className="flex-1 bg-slate-600 py-2 rounded">취소</button><button onClick={submitVote} className="flex-1 bg-indigo-600 py-2 rounded font-bold">투표</button></div></div></div>}
            {selectedProfileId && <PlayerProfileModal playerId={selectedProfileId} onClose={() => setSelectedProfileId(null)} />}
        </div>
    );
}