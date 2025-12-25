import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';

type QueueItem = {
    id: string;
    user_id: string;
    departure_time: string;
    game_type: string;
    created_at: string;
    priority_score: number;
    // profiles 테이블과 조인된 데이터
    profiles: {
        name: string;
        ntrp: number;
        gender: string;
        emoji: string;
    } | null;
};

export default function QueueBoard({ user }: { user: User }) {
    const [queue, setQueue] = useState<QueueItem[]>([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        fetchQueue();

        // ✨ 실시간 구독 (DB가 변하면 즉시 화면 갱신)
        const channel = supabase
            .channel('queue_realtime')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => {
                fetchQueue();
            })
            .subscribe();

        return () => {
            supabase.removeChannel(channel);
        };
    }, []);

    const fetchQueue = async () => {
        try {
            setLoading(true);
            const { data, error } = await supabase
                .from('queue')
                .select(`
          *,
          profiles (name, ntrp, gender, emoji)
        `)
                .eq('is_active', true)
                .order('created_at', { ascending: true });

            if (error) throw error;
            setQueue(data as any || []);
        } catch (error) {
            console.error('Error fetching queue:', error);
        } finally {
            setLoading(false);
        }
    };

    const handleCancel = async (queueId: string) => {
        if (!confirm("대기를 취소하시겠습니까?")) return;
        const { error } = await supabase.from('queue').delete().eq('id', queueId);
        if (error) alert("취소 실패");
        // 성공 시 실시간 구독이 알아서 fetchQueue를 실행하므로, 여기서 굳이 호출 안 해도 되지만 안전하게 둠
    };

    if (loading) return <div className="text-center py-10 text-slate-500">로딩 중...</div>;

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-4 h-full flex flex-col">
            <h3 className="text-lg font-bold text-white mb-4 flex items-center gap-2">
                <span>📋</span> 현재 대기 현황 <span className="text-lime-400 text-sm">({queue.length}명)</span>
            </h3>

            <div className="flex-1 overflow-y-auto space-y-2 pr-1 custom-scrollbar">
                {queue.length === 0 ? (
                    <div className="text-center py-10 text-slate-500 bg-slate-900/50 rounded-xl border border-dashed border-slate-700">
                        <p className="text-2xl mb-2">🎾</p>
                        <p>현재 대기자가 없습니다.</p>
                        <p className="text-xs mt-1">1등으로 등록해보세요!</p>
                    </div>
                ) : (
                    queue.map((item, index) => {
                        const profile = item.profiles || { name: 'Unknown', ntrp: 0, gender: '-', emoji: '👤' };
                        const isMe = item.user_id === user.id;

                        return (
                            <div key={item.id} className={`p-3 rounded-xl border flex justify-between items-center transition-all ${isMe ? 'bg-indigo-900/30 border-indigo-500/50 shadow-lg shadow-indigo-500/10' : 'bg-slate-900/50 border-white/5'}`}>
                                <div className="flex items-center gap-3">
                                    <div className={`w-8 h-8 rounded-full flex items-center justify-center text-sm border ${isMe ? 'bg-indigo-600 border-indigo-400' : 'bg-slate-700 border-slate-600'}`}>
                                        {index + 1}
                                    </div>
                                    <div>
                                        <div className="flex items-center gap-2">
                                            <p className={`font-bold text-sm ${isMe ? 'text-white' : 'text-slate-200'}`}>
                                                {profile.name}
                                            </p>
                                            <span className="text-[10px] px-1.5 py-0.5 bg-slate-800 rounded text-slate-400 border border-slate-700">
                                                {profile.ntrp?.toFixed(1)}
                                            </span>
                                        </div>
                                        <div className="flex gap-2 text-[10px] text-slate-400 mt-0.5">
                                            <span className="flex items-center gap-1">⏰ {item.departure_time || '시간미정'}</span>
                                            {/* 👇 여기가 수정된 부분입니다: 복잡한 조건문 제거하고 심플하게 변경 */}
                                            <span className="flex items-center gap-1">🎾 매치 대기</span>
                                        </div>
                                    </div>
                                </div>

                                {isMe && (
                                    <button
                                        onClick={() => handleCancel(item.id)}
                                        className="px-3 py-1.5 bg-rose-500/20 text-rose-400 text-xs font-bold rounded-lg hover:bg-rose-500 hover:text-white transition-colors border border-rose-500/30"
                                    >
                                        취소
                                    </button>
                                )}
                            </div>
                        );
                    })
                )}
            </div>
        </div>
    );
}