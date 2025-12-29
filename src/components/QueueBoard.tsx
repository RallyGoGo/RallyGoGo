import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { calculatePriorityScore } from '../services/matchingSystem';
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
    const [now, setNow] = useState(new Date());

    const fetchQueue = async () => {
        const { data, error } = await supabase
            .from('queue')
            .select(`
                *,
                profiles (name, ntrp, gender, games_played_today, elo_men_doubles, elo_women_doubles, is_guest, elo_mixed_doubles, elo_singles)
            `)
            .eq('is_active', true);

        if (!error) setQueue(data as any || []);
        setLoading(false);
    };

    // ✨ [핵심] 자동 퇴장 로직 (시간 지난 사람 삭제)
    const checkAutoExit = async (currentQueue: QueueItem[]) => {
        const currentTime = new Date();
        const exitCandidates = currentQueue.filter(item => {
            if (!item.departure_time) return false;

            const [targetH, targetM] = item.departure_time.split(':').map(Number);
            const targetDate = new Date();
            targetDate.setHours(targetH, targetM, 0, 0);

            // 날짜 경계 처리 로직 (새벽반 고려)
            // 예: 현재 23시, 갈시간 01시 -> 내일 01시 (아직 안 지남)
            // 예: 현재 01시, 갈시간 23시 -> 어제 23시 (이미 지남)

            if (targetH < currentTime.getHours() && (currentTime.getHours() - targetH) > 12) {
                targetDate.setDate(targetDate.getDate() + 1);
            } else if (targetH > currentTime.getHours() && (targetH - currentTime.getHours()) > 12) {
                targetDate.setDate(targetDate.getDate() - 1);
            }

            // 현재 시간이 타겟 시간보다 크면(지났으면) 퇴장 대상
            return currentTime > targetDate;
        });

        if (exitCandidates.length > 0) {
            const idsToDelete = exitCandidates.map(i => i.id);
            console.log("👋 Auto Exiting (Time over):", idsToDelete);

            // DB에서 삭제
            await supabase.from('queue').delete().in('id', idsToDelete);

            // 삭제 후 목록 즉시 갱신
            fetchQueue();
        }
    };

    useEffect(() => {
        fetchQueue();

        // 1. 실시간 DB 변경 감지
        const channel = supabase
            .channel('queue_realtime')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => fetchQueue())
            .subscribe();

        // 2. 1분마다 화면 갱신 및 자동 퇴장 체크
        const timer = setInterval(() => {
            setNow(new Date());

            // 현재 큐 상태를 기반으로 퇴장 체크 수행
            // setQueue의 콜백을 활용하여 최신 상태값 접근
            setQueue(currentQueue => {
                checkAutoExit(currentQueue);
                return currentQueue;
            });

        }, 60000); // 1분마다 체크

        return () => {
            supabase.removeChannel(channel);
            clearInterval(timer);
        };
    }, []);

    const formatTime = (isoString: string) => {
        const date = new Date(isoString);
        return date.toTimeString().slice(0, 5);
    };

    const getDoublesElo = (profile: any) => {
        if (!profile) return 1250;
        const gender = (profile.gender || '').toLowerCase();
        const score = gender === 'male' ? profile.elo_men_doubles : profile.elo_women_doubles;
        return score || 1250;
    };

    // ✨ [V8.2] 실시간 우선순위 점수 계산 (Service 위임)
    const getProcessedQueue = () => {
        const processed = queue.map(item => ({
            ...item,
            finalScore: calculatePriorityScore(item)
        }));

        return processed.sort((a, b) => {
            if (b.finalScore !== a.finalScore) {
                return b.finalScore - a.finalScore;
            }
            return new Date(a.created_at).getTime() - new Date(b.created_at).getTime();
        });
    };

    const sortedQueue = getProcessedQueue();

    if (loading) return <div className="text-center py-10 text-slate-500">로딩 중...</div>;

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-4 h-full flex flex-col">
            <h3 className="text-lg font-bold text-white mb-4 flex items-center gap-2">
                <span>📋</span> 대기 현황 <span className="text-lime-400 text-sm">({queue.length}명)</span>
            </h3>

            <div className="grid grid-cols-12 gap-1 text-[10px] text-slate-400 font-bold uppercase mb-2 px-2 text-center">
                <div className="col-span-1">#</div>
                <div className="col-span-5 text-left pl-1">선수 정보</div>
                <div className="col-span-2">온시간</div>
                <div className="col-span-2">갈시간</div>
                <div className="col-span-2 text-yellow-400">점수</div>
            </div>

            <div className="flex-1 overflow-y-auto pr-1 custom-scrollbar space-y-1">
                {sortedQueue.length === 0 ? (
                    <div className="text-center py-10 text-slate-500 border border-dashed border-slate-700 rounded-xl">
                        대기자가 없습니다.
                    </div>
                ) : (
                    sortedQueue.map((item, index) => {
                        const profile = item.profiles || { name: '?', ntrp: 0, gender: 'Male', games_played_today: 0, elo_men_doubles: 1250, elo_women_doubles: 1250 };
                        const isMe = item.user_id === user.id;

                        const isMale = (profile.gender || '').toLowerCase() === 'male';
                        const genderBadge = isMale ? 'M' : 'F';
                        const genderColor = isMale ? 'text-blue-300 bg-blue-900/60' : 'text-rose-300 bg-rose-900/60';
                        const elo = getDoublesElo(profile);

                        const hasUrgentBuff = item.finalScore > item.priority_score;

                        return (
                            <div key={item.id} className={`grid grid-cols-12 gap-1 items-center p-2 rounded-lg border text-center text-xs transition-all ${isMe ? 'bg-indigo-900/30 border-indigo-500/50' : 'bg-slate-900/50 border-white/5'}`}>
                                <div className="col-span-1 font-bold text-slate-500">{index + 1}</div>

                                <div className="col-span-5 text-left flex flex-col justify-center pl-1">
                                    <span className={`font-bold truncate text-sm mb-0.5 ${isMe ? 'text-white' : 'text-slate-200'}`}>
                                        {profile.name}
                                    </span>
                                    <div className="flex items-center gap-1">
                                        <span className={`px-1.5 py-0.5 rounded text-[9px] font-black ${genderColor}`}>
                                            {genderBadge} {elo}
                                        </span>
                                        <span className="px-1.5 py-0.5 rounded text-[9px] bg-slate-700 text-slate-300">
                                            {profile.games_played_today}겜
                                        </span>
                                    </div>
                                </div>

                                <div className="col-span-2 text-slate-500">{formatTime(item.created_at)}</div>
                                <div className={`col-span-2 font-bold ${hasUrgentBuff ? 'text-rose-400 animate-pulse' : 'text-white'}`}>
                                    {item.departure_time}
                                </div>
                                <div className="col-span-2 font-mono text-yellow-400 font-bold flex items-center justify-center gap-1">
                                    {item.finalScore.toFixed(0)}
                                    {hasUrgentBuff && <span className="text-[8px]">🔥</span>}
                                </div>
                            </div>
                        );
                    })
                )}
            </div>
        </div>
    );
}