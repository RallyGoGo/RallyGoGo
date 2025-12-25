import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';

interface PlayerProfile {
    id: string;
    name: string | null; // 이름이 없을 수도 있음
    ntrp: number | null; // 점수가 없을 수도 있음
    gender: string | null;
    elo_singles: number | null;
    emoji?: string;
}

export default function Ranking() {
    const [players, setPlayers] = useState<PlayerProfile[]>([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        fetchRankings();

        // 실시간 랭킹 변화 감지 (누가 가입하거나 점수 바뀌면 바로 반영)
        const channel = supabase
            .channel('public:profiles')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'profiles' }, () => {
                fetchRankings();
            })
            .subscribe();

        return () => { supabase.removeChannel(channel); };
    }, []);

    const fetchRankings = async () => {
        try {
            setLoading(true);
            const { data, error } = await supabase
                .from('profiles')
                .select('id, name, ntrp, gender, elo_singles, emoji')
                .order('elo_singles', { ascending: false }) // 점수 높은 순
                .limit(50);

            if (error) throw error;
            setPlayers(data || []);
        } catch (error) {
            console.error('Error fetching rankings:', error);
        } finally {
            setLoading(false);
        }
    };

    if (loading) {
        return (
            <div className="flex flex-col justify-center items-center h-64 text-slate-500">
                <div className="animate-spin text-4xl mb-2">🎾</div>
                <p>랭킹 불러오는 중...</p>
            </div>
        );
    }

    return (
        <div className="w-full max-w-md mx-auto p-4 animate-fadeIn">
            <div className="flex items-center justify-between mb-6">
                <h2 className="text-2xl font-black text-white flex items-center gap-2">
                    🏆 Top Players
                </h2>
                <span className="text-xs font-bold text-lime-400 bg-lime-400/10 px-3 py-1 rounded-full border border-lime-400/20">
                    Singles (단식)
                </span>
            </div>

            <div className="space-y-3 pb-20">
                {players.length === 0 ? (
                    <div className="bg-slate-800 rounded-xl p-10 text-center border border-slate-700">
                        <p className="text-5xl mb-4 grayscale opacity-50">🏆</p>
                        <p className="text-lg font-bold text-slate-300">랭킹 데이터가 없습니다</p>
                        <p className="text-sm text-slate-500 mt-2">
                            회원가입을 하면<br />자동으로 랭킹에 등록됩니다.
                        </p>
                    </div>
                ) : (
                    players.map((player, index) => {
                        // ✨ 안전장치: 데이터가 null이면 기본값 사용
                        const displayName = player.name || '이름 없음';
                        const displayNtrp = player.ntrp ? player.ntrp.toFixed(1) : '?.?';
                        const displayElo = player.elo_singles || 1000;
                        const isMale = (player.gender || 'Male') === 'Male';

                        return (
                            <div
                                key={player.id}
                                className={`relative flex items-center justify-between p-4 rounded-xl border transition-all hover:scale-[1.02] ${index === 0 ? 'bg-gradient-to-r from-yellow-900/40 to-slate-800 border-yellow-500/50 shadow-yellow-900/20' :
                                        index === 1 ? 'bg-gradient-to-r from-slate-700/40 to-slate-800 border-slate-400/50' :
                                            index === 2 ? 'bg-gradient-to-r from-orange-900/40 to-slate-800 border-orange-500/50' :
                                                'bg-slate-800 border-slate-700'
                                    }`}
                            >
                                <div className="flex items-center gap-4">
                                    {/* 등수 뱃지 */}
                                    <div className={`w-8 h-8 flex items-center justify-center rounded-lg font-black text-sm shadow-lg ${index === 0 ? 'bg-yellow-400 text-black shadow-yellow-400/50' :
                                            index === 1 ? 'bg-slate-300 text-black shadow-slate-300/50' :
                                                index === 2 ? 'bg-orange-400 text-black shadow-orange-400/50' :
                                                    'bg-slate-700 text-slate-400'
                                        }`}>
                                        {index + 1}
                                    </div>

                                    {/* 프로필 정보 */}
                                    <div>
                                        <div className="font-bold text-white flex items-center gap-2 text-lg">
                                            {displayName}
                                            <span className="text-xs opacity-50 bg-slate-900 px-1 rounded">
                                                {player.emoji || (isMale ? '👨' : '👩')}
                                            </span>
                                        </div>
                                        <div className="text-xs text-slate-400 font-mono flex items-center gap-2">
                                            <span className="bg-slate-900 px-1.5 py-0.5 rounded text-lime-400">
                                                NTRP {displayNtrp}
                                            </span>
                                        </div>
                                    </div>
                                </div>

                                {/* ELO 점수 */}
                                <div className="text-right">
                                    <div className="font-black text-white text-xl tracking-tighter">
                                        {displayElo}
                                    </div>
                                    <div className="text-[9px] text-slate-500 font-bold uppercase tracking-widest">
                                        Points
                                    </div>
                                </div>
                            </div>
                        );
                    })
                )}
            </div>
        </div>
    );
}