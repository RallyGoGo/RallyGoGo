import { useEffect, useState, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';
import PlayerProfileModal from './PlayerProfileModal';
import { Database } from '../types/database.types';

// 프로필 타입 정의 (V3 Schema - Using Database Types)
type Profile = Database['public']['Tables']['profiles']['Row'];
type MatchRecord = Database['public']['Tables']['matches']['Row'] & {
    p1_name: string; p2_name: string; p3_name: string; p4_name: string;
    my_vote?: string;
    match_category: string;
};

type RankCategory = 'MENS_DOUBLES' | 'WOMENS_DOUBLES' | 'MIXED' | 'SINGLES';

// MVP 투표 태그 리스트
const MVP_TAGS = [
    { label: "🚀 강력한 불꽃 서브", icon: "🚀" }, { label: "💪 미친 포핸드", icon: "💪" },
    { label: "🛡️ 통곡의 벽 (수비)", icon: "🛡️" }, { label: "🧠 테니스 지능캐", icon: "🧠" },
    { label: "🎩 젠틀맨 (매너)", icon: "🎩" }, { label: "🔥 꺾이지 않는 마음", icon: "🔥" },
    { label: "🩰 우아한 발놀림", icon: "🩰" },
];

export default function Ranking({ user }: { user: User }) {
    // 상태 관리
    const [activeTab, setActiveTab] = useState<'RANKING' | 'HISTORY'>('RANKING');
    const [rankCategory, setRankCategory] = useState<RankCategory>('MENS_DOUBLES');

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

    // 데이터 불러오기 함수 (useCallback으로 메모이제이션)
    const fetchData = useCallback(async () => {
        setLoading(true);
        try {
            if (activeTab === 'RANKING') {
                // V3: Column names with 's' (elo_mens_doubles, elo_womens_doubles)
                let sortField: keyof Profile = 'elo_mens_doubles';
                if (rankCategory === 'WOMENS_DOUBLES') sortField = 'elo_womens_doubles';
                if (rankCategory === 'MIXED') sortField = 'elo_mixed_doubles';
                if (rankCategory === 'SINGLES') sortField = 'elo_singles';

                // Server-side filtering (Performance optimized)
                let query = supabase
                    .from('profiles')
                    .select('*')
                    .gt(sortField, 0) // Filter 0 points
                    .order(sortField, { ascending: false })
                    .limit(50); // Hard limit for safety

                // Gender filter (Server-side)
                if (rankCategory === 'MENS_DOUBLES') query = query.eq('gender', 'MALE');
                if (rankCategory === 'WOMENS_DOUBLES') query = query.eq('gender', 'FEMALE');

                // Search filter (Server-side)
                if (searchPlayer) query = query.ilike('name', `%${searchPlayer}%`);

                const { data: profiles, error } = await query;
                if (error) throw error;
                setRankings(profiles as Profile[]);
            } else {
                // 경기 기록 가져오기
                const startOfDay = `${selectedDate}T00:00:00`;
                const endOfDay = `${selectedDate}T23:59:59`;

                const { data: matches, error: matchError } = await supabase
                    .from('matches')
                    .select('*')
                    .eq('status', 'FINISHED')
                    .gte('end_time', startOfDay)
                    .lte('end_time', endOfDay)
                    .order('end_time', { ascending: false });

                if (matchError) throw matchError;

                if (matches && matches.length > 0) {
                    const pIds = new Set<string>();
                    matches.forEach((m) => {
                        if (m.player_1) pIds.add(m.player_1); if (m.player_2) pIds.add(m.player_2);
                        if (m.player_3) pIds.add(m.player_3); if (m.player_4) pIds.add(m.player_4);
                    });

                    // V9.7.2: Parallel fetch & Type Safety
                    const [{ data: pNames }, { data: myVotes }] = await Promise.all([
                        supabase.from('profiles').select('id, name').in('id', Array.from(pIds)),
                        supabase.from('mvp_votes').select('match_id, target_id').eq('voter_id', user.id).in('match_id', matches.map((m) => m.id))
                    ]);

                    const nameMap = new Map((pNames || []).map((p) => [p.id, p.name]));
                    const voteMap = new Map((myVotes || []).map((v) => [v.match_id, v.target_id]));

                    const formattedHistory = matches.map((m) => ({
                        ...m,
                        p1_name: nameMap.get(m.player_1 || '') || 'Unknown',
                        p2_name: nameMap.get(m.player_2 || '') || 'Unknown',
                        p3_name: nameMap.get(m.player_3 || '') || 'Unknown',
                        p4_name: nameMap.get(m.player_4 || '') || 'Unknown',
                        my_vote: voteMap.get(m.id),
                        match_category: m.match_type === 'MENS_DOUBLES' ? '남복' : m.match_type === 'WOMENS_DOUBLES' ? '여복' : m.match_type === 'SINGLES' ? '단식' : '혼복'
                    }));
                    setHistory(formattedHistory as MatchRecord[]);
                } else { setHistory([]); }
            }
        } catch (e) { console.error(e); } finally { setLoading(false); }
    }, [activeTab, rankCategory, searchPlayer, selectedDate, user.id]);

    // 데이터 실시간 감지 및 불러오기
    useEffect(() => {
        setRankings([]); // Clear on tab switch
        fetchData();
        const sub = supabase.channel('ranking_updates')
            .on('postgres_changes', { event: '*', schema: 'public' }, () => fetchData()) // Listen to all changes (matches, mvp_votes, etc)
            .subscribe();
        return () => { supabase.removeChannel(sub); };
    }, [activeTab, rankCategory, selectedDate, fetchData]);

    // 현재 카테고리에 맞는 점수 반환
    const getScore = (p: Profile) => {
        if (rankCategory === 'MENS_DOUBLES') return p.elo_mens_doubles || 0;
        if (rankCategory === 'WOMENS_DOUBLES') return p.elo_womens_doubles || 0;
        if (rankCategory === 'SINGLES') return p.elo_singles || 0;
        return p.elo_mixed_doubles || 0;
    };

    // MVP 투표 관련 함수들
    const openVoteModal = (match: MatchRecord) => { setVoteTargetMatch(match); setVoteCandidate(null); setVoteTag(""); setIsVoteModalOpen(true); };

    // Server-side voting is better, but keeping simple insert for now as specification allows simple interaction
    const submitVote = async () => {
        if (!voteTargetMatch || !voteCandidate || !voteTag) return alert("Select Player & Tag!");
        try {
            /* V9.7.2: Use RPC if possible, but mvp_votes table is simple insert. Assuming RLS allows insert for auth user. */
            const { error } = await supabase.from('mvp_votes').insert({
                match_id: voteTargetMatch.id,
                voter_id: user.id,
                target_id: voteCandidate,
                tag: voteTag
            });
            if (error) throw error;
            alert("👑 투표 완료!");
            setIsVoteModalOpen(false);
            fetchData();
        } catch { alert("Error!"); }
    };

    const getVoteCandidates = () => {
        if (!voteTargetMatch) return [];
        const isTeam1Win = voteTargetMatch.winner_team === 'TEAM_1';
        const winners = isTeam1Win
            ? [{ id: voteTargetMatch.player_1, name: voteTargetMatch.p1_name }, { id: voteTargetMatch.player_2, name: voteTargetMatch.p2_name }]
            : [{ id: voteTargetMatch.player_3, name: voteTargetMatch.p3_name }, { id: voteTargetMatch.player_4, name: voteTargetMatch.p4_name }];
        return winners.filter(p => p.id && p.id !== user.id);
    };

    // ✨ 데이터 슬라이싱 (1~3등 / 4~10등)
    const top3 = rankings.slice(0, 3);
    const restOfRankings = rankings.slice(3, 10);

    // Podium card style type for type safety
    type PodiumStyles = { mt: string; scale: string; badge: string; cardBorder: string; cardShadow: string };

    // 단상 카드 렌더링 함수
    const renderPodiumCard = (player: Profile | undefined, rank: number, styles: PodiumStyles) => {
        if (!player) return <div className="flex-1"></div>;
        return (
            <div onClick={() => setSelectedProfileId(player.id)} className={`flex-1 flex flex-col items-center relative transition-all duration-500 cursor-pointer hover:-translate-y-2 ${styles.mt} ${styles.scale}`}>
                <div className={`w-10 h-10 rounded-full flex items-center justify-center font-black text-lg mb-2 border-4 ${styles.badge} z-30`}>{rank}</div>
                <div className={`w-full p-3 rounded-2xl border bg-gradient-to-b from-slate-800 to-slate-900 flex flex-col items-center relative ${styles.cardBorder} ${styles.cardShadow}`}>
                    <p className="text-white font-bold truncate max-w-[90%] text-sm relative z-10">{player.name || 'Unknown'}</p>
                    <p className="text-2xl font-black mt-2 text-white tracking-tighter relative z-10">{getScore(player)}</p>
                    <p className="text-[9px] text-slate-400 font-bold uppercase mt-1 relative z-10">ELO</p>
                </div>
            </div>
        );
    }

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-4 h-full flex flex-col relative animate-fadeIn">
            {/* 상단 탭 및 검색 */}
            <div className="flex flex-col gap-3 mb-4 border-b border-white/10 pb-2 shrink-0">
                <div className="flex gap-4">
                    <button onClick={() => setActiveTab('RANKING')} className={`text-lg font-bold pb-2 transition-all ${activeTab === 'RANKING' ? 'text-lime-400 border-b-2 border-lime-400' : 'text-slate-400 hover:text-white'}`}>🏆 랭킹</button>
                    <button onClick={() => setActiveTab('HISTORY')} className={`text-lg font-bold pb-2 transition-all ${activeTab === 'HISTORY' ? 'text-cyan-400 border-b-2 border-cyan-400' : 'text-slate-400 hover:text-white'}`}>📜 경기 기록</button>
                </div>
                {activeTab === 'RANKING' && <input type="text" placeholder="🔍 선수 검색..." value={searchPlayer} onChange={(e) => setSearchPlayer(e.target.value)} className="w-full bg-slate-900/80 border border-slate-600 rounded-lg px-3 py-2 text-white text-sm outline-none focus:border-lime-400" />}
                {activeTab === 'HISTORY' && <input type="date" value={selectedDate} onChange={(e) => setSelectedDate(e.target.value)} className="bg-slate-900 text-white border border-slate-600 rounded-lg px-2 py-1 text-sm outline-none focus:border-cyan-400 self-end" />}
            </div>

            <div className="flex-1 overflow-y-auto pr-1 custom-scrollbar">
                {loading ? <div className="text-center text-slate-500 py-10">로딩 중...</div> : activeTab === 'RANKING' ? (
                    <>
                        {/* 카테고리 선택 버튼 */}
                        <div className="flex gap-1 mb-4 bg-slate-900/50 p-1 rounded-lg inline-flex self-center">
                            {['MENS_DOUBLES', 'WOMENS_DOUBLES', 'MIXED', 'SINGLES'].map(cat => (
                                <button key={cat} onClick={() => setRankCategory(cat as RankCategory)} className={`px-2 py-1 text-[10px] rounded font-bold transition-all ${rankCategory === cat ? 'bg-slate-600 text-white shadow' : 'text-slate-400'}`}>
                                    {cat === 'MENS_DOUBLES' ? '남복' : cat === 'WOMENS_DOUBLES' ? '여복' : cat === 'MIXED' ? '혼복' : '단식'}
                                </button>
                            ))}
                        </div>

                        {/* 단상 (TOP 3) */}
                        {top3.length > 0 ? (
                            <div className="flex items-end justify-center gap-2 mb-6 px-2 min-h-[160px]">
                                {/* 2등 */}
                                {renderPodiumCard(top3[1], 2, { mt: '', scale: 'z-10', badge: 'bg-slate-400 text-slate-900', cardBorder: 'border-slate-500', cardShadow: 'shadow-lg' })}

                                {/* 1등: mb-12로 적절하게 올림 */}
                                {renderPodiumCard(top3[0], 1, { mt: 'mb-12', scale: 'scale-110 z-20', badge: 'bg-yellow-400 text-yellow-900', cardBorder: 'border-yellow-500', cardShadow: 'shadow-xl shadow-yellow-500/20' })}

                                {/* 3등 */}
                                {renderPodiumCard(top3[2], 3, { mt: '', scale: 'z-10', badge: 'bg-amber-700 text-amber-100', cardBorder: 'border-amber-600', cardShadow: 'shadow-lg' })}
                            </div>
                        ) : (
                            <div className="text-center py-10 text-slate-500">
                                <p className="text-2xl mb-2">🍃</p>
                                <p>{rankCategory === 'WOMENS_DOUBLES' ? '여성 랭킹 데이터가 없습니다.' : '랭킹 데이터가 없습니다.'}</p>
                            </div>
                        )}

                        {/* 랭킹 리스트 (4위 ~ 10위) */}
                        <div className="space-y-2">
                            {restOfRankings.map((player, idx) => (
                                <div key={player.id} onClick={() => setSelectedProfileId(player.id)} className="flex items-center justify-between p-3 rounded-xl border border-slate-700 bg-slate-800/50 cursor-pointer hover:bg-slate-700/50">
                                    <div className="flex items-center gap-3">
                                        <div className="w-8 h-8 rounded-full flex items-center justify-center font-bold text-sm bg-slate-700 text-slate-300">{idx + 4}</div>
                                        <div><p className="text-white font-bold text-sm">{player.name || 'Unknown'}</p></div>
                                    </div>
                                    <p className="text-white font-mono font-bold">{getScore(player)}</p>
                                </div>
                            ))}
                        </div>
                        {/* 10위 제한 안내 메시지 */}
                        {rankings.length > 10 && (
                            <div className="text-center py-4 text-xs text-slate-500">
                                ... 상위 10명만 표시됩니다 ...
                            </div>
                        )}
                    </>
                ) : (
                    // 경기 기록 탭
                    <div className="space-y-3 pb-20">
                        {history.length === 0 ? <div className="text-center py-10 opacity-50">기록이 없습니다.</div> : history.map((match) => (
                            <div key={match.id} className="bg-slate-900/50 p-4 rounded-xl border border-white/5">
                                <div className="flex justify-between items-center mb-2">
                                    <span className="text-[10px] px-2 py-0.5 rounded font-bold bg-slate-700 text-slate-300">{match.match_category}</span>
                                    <span className="text-[10px] text-slate-500">{(match.end_time || '').substring(11, 16)}</span>
                                </div>
                                <div className="flex justify-between items-center">
                                    <div className={`text-center w-1/3 ${match.winner_team === 'TEAM_1' ? 'text-lime-400' : 'text-slate-500'}`}><p className="text-xl font-black">{match.score_team1}</p><p className="text-xs truncate">{match.p1_name}/{match.p2_name}</p></div>
                                    <div className="font-bold text-slate-600">VS</div>
                                    <div className={`text-center w-1/3 ${match.winner_team === 'TEAM_2' ? 'text-lime-400' : 'text-slate-500'}`}><p className="text-xl font-black">{match.score_team2}</p><p className="text-xs truncate">{match.p3_name}/{match.p4_name}</p></div>
                                </div>
                                {match.winner_team !== 'DRAW' && !match.my_vote && <button onClick={() => openVoteModal(match)} className="w-full mt-3 py-2 bg-indigo-600 text-white text-xs font-bold rounded hover:bg-indigo-500">👑 MVP 투표</button>}
                            </div>
                        ))}
                    </div>
                )}
            </div>

            {/* 투표 모달 */}
            {isVoteModalOpen && voteTargetMatch && (
                <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4">
                    <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-sm p-6 shadow-2xl relative">
                        <button onClick={() => setIsVoteModalOpen(false)} className="absolute top-4 right-4 text-slate-400 hover:text-white">✕</button>
                        <h3 className="text-xl font-bold text-white mb-1">👑 MVP 투표</h3>
                        <div className="space-y-4 pt-4">
                            <div><label className="block text-xs text-slate-400 mb-2 font-bold">누가 제일 잘했나요?</label><div className="grid grid-cols-2 gap-2">{getVoteCandidates().map(p => (<button key={p.id} onClick={() => setVoteCandidate(p.id)} className={`p-3 rounded-xl border transition-all font-bold text-sm ${voteCandidate === p.id ? 'bg-indigo-600 border-indigo-400 text-white' : 'bg-slate-700 border-transparent text-slate-300 hover:bg-slate-600'}`}>{p.name}</button>))}</div></div>
                            {voteCandidate && (<div><label className="block text-xs text-slate-400 mb-2 font-bold mt-4">어떤 점이 좋았나요?</label><div className="grid grid-cols-1 gap-2 max-h-[160px] overflow-y-auto pr-1 custom-scrollbar">{MVP_TAGS.map((tag) => (<button key={tag.label} onClick={() => setVoteTag(tag.label)} className={`text-left px-3 py-2 rounded-lg text-xs font-bold border transition-all flex items-center gap-2 ${voteTag === tag.label ? 'bg-amber-500/20 border-amber-500 text-amber-300' : 'bg-slate-900 border-slate-700 text-slate-400 hover:border-slate-500'}`}><span className="text-lg">{tag.icon}</span> {tag.label}</button>))}</div></div>)}
                            <button onClick={submitVote} disabled={!voteCandidate || !voteTag} className="w-full py-3 bg-gradient-to-r from-indigo-500 to-purple-600 hover:from-indigo-400 hover:to-purple-500 text-white font-bold rounded-xl mt-2 shadow-lg disabled:opacity-50 disabled:cursor-not-allowed">투표하기</button>
                        </div>
                    </div>
                </div>
            )}

            {/* 프로필 모달 */}
            {selectedProfileId && <PlayerProfileModal playerId={selectedProfileId} onClose={() => setSelectedProfileId(null)} />}
        </div>
    );
}