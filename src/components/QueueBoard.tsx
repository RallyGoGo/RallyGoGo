import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';

type QueueItem = {
    id: string;
    user_id: string;
    departure_time: string;
    created_at: string;
    priority_score: number;
    profiles: {
        name: string;
        ntrp: number;
        gender: string;
        games_played_today: number;
        elo_men_doubles: number | null;
        elo_women_doubles: number | null;
    } | null;
};

export default function QueueBoard({ user }: { user: User }) {
    const [queue, setQueue] = useState<QueueItem[]>([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        fetchQueue();
        const channel = supabase
            .channel('queue_realtime')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => fetchQueue())
            .subscribe();
        return () => { supabase.removeChannel(channel); };
    }, []);

    const fetchQueue = async () => {
        const { data, error } = await supabase
            .from('queue')
            .select(`
                *,
                profiles (name, ntrp, gender, games_played_today, elo_men_doubles, elo_women_doubles)
            `)
            .eq('is_active', true)
            .order('priority_score', { ascending: false })
            .order('created_at', { ascending: true });

        if (!error) setQueue(data as any || []);
        setLoading(false);
    };

    const formatTime = (isoString: string) => {
        const date = new Date(isoString);
        return date.toTimeString().slice(0, 5);
    };

    // 점수 계산 (없으면 1250)
    const getDoublesElo = (profile: any) => {
        if (!profile) return 1250;
        const score = profile.gender === 'Male' ? profile.elo_men_doubles : profile.elo_women_doubles;
        return score || 1250;
    };

    if (loading) return <div className="text-center py-10 text-slate-500">로딩 중...</div>;

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-4 h-full flex flex-col">
            <h3 className="text-lg font-bold text-white mb-4 flex items-center gap-2">
                <span>📋</span> 대기 현황 <span className="text-lime-400 text-sm">({queue.length}명)</span>
            </h3>

            {/* 헤더 */}
            <div className="grid grid-cols-12 gap-1 text-[10px] text-slate-400 font-bold uppercase mb-2 px-2 text-center">
                <div className="col-span-1">#</div>
                <div className="col-span-5 text-left pl-1">선수 정보</div> {/* 공간 더 확보 */}
                <div className="col-span-2">온시간</div>
                <div className="col-span-2">갈시간</div>
                <div className="col-span-2 text-yellow-400">점수</div>
            </div>

            <div className="flex-1 overflow-y-auto pr-1 custom-scrollbar space-y-1">
                {queue.length === 0 ? (
                    <div className="text-center py-10 text-slate-500 border border-dashed border-slate-700 rounded-xl">
                        대기자가 없습니다.
                    </div>
                ) : (
                    queue.map((item, index) => {
                        const profile = item.profiles || { name: '?', ntrp: 0, gender: 'Male', games_played_today: 0, elo_men_doubles: 1250, elo_women_doubles: 1250 };
                        const isMe = item.user_id === user.id;

                        const isMale = profile.gender === 'Male';
                        // 성별/점수 표시용 변수
                        const genderBadge = isMale ? 'M' : 'F';
                        const genderColor = isMale ? 'text-blue-300 bg-blue-900/60' : 'text-rose-300 bg-rose-900/60';
                        const elo = getDoublesElo(profile);

                        return (
                            <div key={item.id} className={`grid grid-cols-12 gap-1 items-center p-2 rounded-lg border text-center text-xs transition-all ${isMe ? 'bg-indigo-900/30 border-indigo-500/50' : 'bg-slate-900/50 border-white/5'}`}>
                                <div className="col-span-1 font-bold text-slate-500">{index + 1}</div>

                                {/* ✨ 이름 & 성별 & 점수 (한 줄 또는 두 줄로 자연스럽게 표시) */}
                                <div className="col-span-5 text-left flex flex-col pl-1 justify-center">
                                    <span className={`font-bold truncate text-sm ${isMe ? 'text-white' : 'text-slate-200'}`}>
                                        {profile.name}
                                    </span>
                                    {/* 뱃지 영역 */}
                                    <div className="flex items-center gap-1 mt-0.5">
                                        <span className={`px-1 rounded text-[9px] font-black ${genderColor}`}>
                                            {genderBadge} {elo}
                                        </span>
                                        {/* 게임 수 뱃지 (작게 표시) */}
                                        <span className="px-1 rounded text-[9px] bg-slate-700 text-slate-300">
                                            {profile.games_played_today}겜
                                        </span>
                                    </div>
                                </div>

                                <div className="col-span-2 text-slate-500">{formatTime(item.created_at)}</div>
                                <div className="col-span-2 text-white font-bold">{item.departure_time}</div>
                                <div className="col-span-2 font-mono text-yellow-400 font-bold">
                                    {item.priority_score?.toFixed(0) || 0}
                                </div>
                            </div>
                        );
                    })
                )}
            </div>
        </div>
    );
}