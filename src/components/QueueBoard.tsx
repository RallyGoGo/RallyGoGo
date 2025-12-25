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
        games_played_today: number; // ✨ 사라지지 않는 게임 수
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
        // ✨ DB에서 games_played_today 정보를 같이 가져옵니다.
        const { data, error } = await supabase
            .from('queue')
            .select(`
                *,
                profiles (name, ntrp, gender, games_played_today)
            `)
            .eq('is_active', true)
            .order('priority_score', { ascending: false }) // 점수 높은 순
            .order('created_at', { ascending: true }); // 점수 같으면 먼저 온 순

        if (!error) setQueue(data as any || []);
        setLoading(false);
    };

    const formatTime = (isoString: string) => {
        const date = new Date(isoString);
        return date.toTimeString().slice(0, 5);
    };

    if (loading) return <div className="text-center py-10 text-slate-500">로딩 중...</div>;

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-4 h-full flex flex-col">
            <h3 className="text-lg font-bold text-white mb-4 flex items-center gap-2">
                <span>📋</span> 대기 현황 <span className="text-lime-400 text-sm">({queue.length}명)</span>
            </h3>

            {/* 헤더 */}
            <div className="grid grid-cols-12 gap-2 text-[10px] text-slate-400 font-bold uppercase mb-2 px-2 text-center">
                <div className="col-span-1">#</div>
                <div className="col-span-3 text-left">이름</div>
                <div className="col-span-2">온시간</div>
                <div className="col-span-2">갈시간</div>
                <div className="col-span-2 text-lime-400">게임수</div>
                <div className="col-span-2 text-yellow-400">점수</div>
            </div>

            <div className="flex-1 overflow-y-auto pr-1 custom-scrollbar space-y-1">
                {queue.length === 0 ? (
                    <div className="text-center py-10 text-slate-500 border border-dashed border-slate-700 rounded-xl">
                        대기자가 없습니다.
                    </div>
                ) : (
                    queue.map((item, index) => {
                        const profile = item.profiles || { name: '?', ntrp: 0, gender: '-', games_played_today: 0 };
                        const isMe = item.user_id === user.id;

                        return (
                            <div key={item.id} className={`grid grid-cols-12 gap-2 items-center p-2 rounded-lg border text-center text-xs ${isMe ? 'bg-indigo-900/30 border-indigo-500/50' : 'bg-slate-900/50 border-white/5'}`}>
                                <div className="col-span-1 font-bold text-slate-500">{index + 1}</div>
                                <div className="col-span-3 text-left truncate font-bold text-white pl-1">
                                    {profile.name}
                                </div>
                                <div className="col-span-2 text-slate-400">{formatTime(item.created_at)}</div>
                                <div className="col-span-2 text-slate-400">{item.departure_time}</div>
                                <div className="col-span-2">
                                    <span className="bg-slate-700 text-white px-1.5 py-0.5 rounded font-bold">{profile.games_played_today}</span>
                                </div>
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