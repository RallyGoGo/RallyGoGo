import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';

interface QueueItem {
    id: number;
    user_id: string;
    created_at: string;
    is_active: boolean;
    game_type: string;
    profiles: {
        name: string;
        ntrp: number;
        gender: string;
        emoji?: string;
    } | null; // ✨ 프로필이 없을 수도 있음을 명시
}

export default function QueueBoard({ user }: { user: any }) {
    const [queue, setQueue] = useState<QueueItem[]>([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        fetchQueue();

        // 실시간 대기열 변화 감지
        const channel = supabase
            .channel('public:queue')
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
            // 대기열 데이터 가져오기 (프로필 정보 조인)
            const { data, error } = await supabase
                .from('queue')
                .select(`
          id, user_id, created_at, is_active, game_type,
          profiles (name, ntrp, gender, emoji)
        `)
                .eq('is_active', true)
                .order('created_at', { ascending: true });

            if (error) throw error;
            setQueue(data || []);
        } catch (error) {
            console.error('Error fetching queue:', error);
        } finally {
            setLoading(false);
        }
    };

    // 대기 시간 계산 함수
    const getTimeDiff = (dateString: string) => {
        const diff = new Date().getTime() - new Date(dateString).getTime();
        const minutes = Math.floor(diff / 60000);
        return minutes < 1 ? '방금' : `${minutes}분 전`;
    };

    // 삭제 함수 (내 대기열 취소)
    const handleLeave = async (id: number) => {
        if (!window.confirm("대기열을 취소하시겠습니까?")) return;
        await supabase.from('queue').delete().eq('id', id);
        fetchQueue();
    };

    if (loading) return <div className="text-center p-4 text-slate-500">대기열 로딩 중...</div>;

    return (
        <div className="bg-slate-800 rounded-2xl p-6 border border-slate-700 shadow-xl h-full flex flex-col">
            <h3 className="text-xl font-black text-white mb-4 flex items-center justify-between">
                <span className="flex items-center gap-2">⏳ 대기 현황 <span className="text-lime-400 text-sm">({queue.length}명)</span></span>
            </h3>

            <div className="flex-1 overflow-y-auto space-y-3 custom-scrollbar">
                {queue.length === 0 ? (
                    <div className="text-center py-10 text-slate-500">
                        <p className="text-4xl mb-2">🍃</p>
                        <p>현재 대기자가 없습니다.</p>
                    </div>
                ) : (
                    queue.map((item) => {
                        // ✨ 에러 방지 핵심: 프로필이 없으면 'Unknown'으로 처리 (toLowerCase 에러 방지)
                        const profile = item.profiles || { name: 'Unknown', ntrp: 0, gender: 'Unknown' };
                        const isMe = item.user_id === user.id;

                        return (
                            <div
                                key={item.id}
                                className={`flex items-center justify-between p-3 rounded-xl border ${isMe ? 'bg-lime-900/20 border-lime-500/50' : 'bg-slate-700/30 border-slate-700'
                                    }`}
                            >
                                <div className="flex items-center gap-3">
                                    <div className={`w-10 h-10 rounded-full flex items-center justify-center text-lg font-bold ${isMe ? 'bg-lime-500 text-slate-900' : 'bg-slate-600 text-slate-300'
                                        }`}>
                                        {profile.emoji || (profile.gender === 'Male' ? '👨' : '👩')}
                                    </div>
                                    <div>
                                        <div className="font-bold text-white flex items-center gap-2">
                                            {profile.name}
                                            {isMe && <span className="text-[10px] bg-lime-500 text-slate-900 px-1 rounded font-black">ME</span>}
                                        </div>
                                        <div className="text-xs text-slate-400 font-mono flex gap-2">
                                            <span className="text-lime-400">NTRP {profile.ntrp?.toFixed(1) || '?.?'}</span>
                                            <span>• {item.game_type || '단식'}</span>
                                            <span>• {getTimeDiff(item.created_at)}</span>
                                        </div>
                                    </div>
                                </div>

                                {isMe && (
                                    <button
                                        onClick={() => handleLeave(item.id)}
                                        className="text-rose-400 hover:text-rose-300 text-xs border border-rose-500/30 px-2 py-1 rounded hover:bg-rose-500/10 transition-colors"
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