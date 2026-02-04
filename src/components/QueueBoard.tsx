import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { calculatePriorityScore } from '../services/matchingSystem';
import type { User } from '@supabase/supabase-js';

type QueueItem = {
    id: string;
    player_id: string;  // V3: Changed from user_id
    departure_time: string | null;
    joined_at: string;  // V3: Changed from created_at
    priority_score: number | null;
    profiles: {
        name: string;
        ntrp: number | null;
        gender: string | null;
        games_played_today: number | null;
        elo_mens_doubles: number | null;   // V3: men → mens
        elo_womens_doubles: number | null; // V3: women → womens
        elo_mixed_doubles: number | null;
        is_guest: boolean | null;
    } | null;
};

// [New] Type for players currently in a match
type InGamePlayer = {
    id: string;
    name: string;
    court_name: string;
    status: string;
};

export default function QueueBoard({ user }: { user: User }) {
    const [queue, setQueue] = useState<QueueItem[]>([]);
    const [inGamePlayers, setInGamePlayers] = useState<InGamePlayer[]>([]);
    const [loading, setLoading] = useState(true);

    const fetchQueue = async () => {
        // V3 Schema: Use correct column names
        const { data, error } = await supabase
            .from('queue')
            .select(`
                *,
                profiles (name, ntrp, gender, games_played_today, elo_mens_doubles, elo_womens_doubles, is_guest, elo_mixed_doubles, elo_singles)
            `)
            .eq('is_active', true);

        if (!error) setQueue(data as QueueItem[] || []);

        // 2. [New] Fetch In-Game Players
        const { data: matchData } = await supabase
            .from('matches')
            .select('id, player_1, player_2, player_3, player_4, court_name, status')
            // V3: match_status_t = DRAFT, PLAYING, SCORING, FINISHED, CANCELLED, DISPUTED (no PENDING)
            .in('status', ['DRAFT', 'PLAYING', 'SCORING']);

        if (matchData && matchData.length > 0) {
            // Type for match data from DB
            type MatchDataRow = { player_1: string | null; player_2: string | null; player_3: string | null; player_4: string | null; court_name: string; status: string };
            type ProfileRow = { id: string; name: string };

            const allPlayerIds = new Set<string>();
            matchData.forEach((m: MatchDataRow) => {
                [m.player_1, m.player_2, m.player_3, m.player_4].filter(Boolean).forEach(id => allPlayerIds.add(id as string));
            });

            if (allPlayerIds.size > 0) {
                const { data: profiles } = await supabase.from('profiles').select('id, name').in('id', Array.from(allPlayerIds));
                const profileMap = new Map(profiles?.map((p: ProfileRow) => [p.id, p.name]));

                const playingList: InGamePlayer[] = [];
                matchData.forEach((m: MatchDataRow) => {
                    [m.player_1, m.player_2, m.player_3, m.player_4].filter(Boolean).forEach(pid => {
                        playingList.push({
                            id: pid as string,
                            name: (profileMap.get(pid as string) as string) || 'Unknown',
                            court_name: m.court_name,
                            status: m.status
                        });
                    });
                });
                setInGamePlayers(playingList);
            }
        } else {
            setInGamePlayers([]);
        }

        setLoading(false);
    };

    // ✨ [핵심] 자동 퇴장 로직 (시간 지난 사람 삭제)
    const checkAutoExit = async (currentQueue: QueueItem[]) => {
        const currentTime = new Date();
        const exitCandidates = currentQueue.filter(item => {
            if (!item.departure_time) return false;

            let targetDate: Date;

            // Handle both ISO timestamp (from DB) and HH:MM format (from UI)
            if (item.departure_time.includes('T') || item.departure_time.includes('-')) {
                // ISO format: "2026-02-04T21:30:00+00:00" or "2026-02-04 21:30:00+00"
                targetDate = new Date(item.departure_time);
            } else if (item.departure_time.includes(':')) {
                // HH:MM format: "21:30"
                const [targetH, targetM] = item.departure_time.split(':').map(Number);
                targetDate = new Date();
                targetDate.setHours(targetH, targetM, 0, 0);

                // 날짜 경계 처리 로직 (새벽반 고려)
                if (targetH < currentTime.getHours() && (currentTime.getHours() - targetH) > 12) {
                    targetDate.setDate(targetDate.getDate() + 1);
                } else if (targetH > currentTime.getHours() && (targetH - currentTime.getHours()) > 12) {
                    targetDate.setDate(targetDate.getDate() - 1);
                }
            } else {
                // Unknown format, skip
                return false;
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
        // Data fetching on mount
        void fetchQueue();

        // 1. 실시간 DB 변경 감지
        const channel = supabase
            .channel('queue_realtime')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => fetchQueue())
            .subscribe();

        // 2. 1분마다 화면 갱신 및 자동 퇴장 체크
        const timer = setInterval(() => {
            // 현재 큐 상태를 기반으로 퇴장 체크 수행
            // setQueue의 콜백을 활용하여 최신 상태값 접근
            setQueue(currentQueue => {
                void checkAutoExit(currentQueue);
                return currentQueue;
            });

        }, 60000); // 1분마다 체크

        return () => {
            supabase.removeChannel(channel);
            clearInterval(timer);
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    const getDoublesElo = (profile: QueueItem['profiles']) => {
        if (!profile) return 1250;
        const gender = (profile.gender || '').toUpperCase();  // V3: MALE/FEMALE
        const score = gender === 'MALE' ? profile.elo_mens_doubles : profile.elo_womens_doubles;
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
            // V3: Use joined_at instead of created_at
            return new Date(a.joined_at).getTime() - new Date(b.joined_at).getTime();
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
                        const profile = item.profiles || { name: '?', ntrp: 0, gender: 'MALE', games_played_today: 0, elo_mens_doubles: 1250, elo_womens_doubles: 1250, elo_mixed_doubles: 1250, is_guest: false };
                        const isMe = item.player_id === user.id;  // V3: user_id → player_id

                        const isMale = (profile.gender || '').toUpperCase() === 'MALE';  // V3: MALE/FEMALE
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

                                <div className="col-span-2 text-slate-500">{item.joined_at ? new Date(item.joined_at).toTimeString().slice(0, 5) : '-'}</div>
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

            {/* [New] In-Game Players Section */}
            {inGamePlayers.length > 0 && (
                <div className="mt-4 pt-4 border-t border-slate-700">
                    <h4 className="text-sm font-bold text-lime-400 mb-2 flex items-center gap-2">
                        <span>🎾</span> 경기 중 <span className="text-slate-400 text-xs">({inGamePlayers.length}명)</span>
                    </h4>
                    <div className="flex flex-wrap gap-2">
                        {inGamePlayers.map((p, idx) => (
                            <div key={p.id + idx} className="bg-lime-900/30 border border-lime-500/30 px-3 py-1.5 rounded-lg flex items-center gap-2 text-xs">
                                <span className="text-white font-bold">{p.name}</span>
                                <span className="text-lime-400 text-[10px]">{p.court_name}</span>
                            </div>
                        ))}
                    </div>
                </div>
            )}
        </div>
    );
}