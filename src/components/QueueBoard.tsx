import { useMemo, useState } from 'react';
import type { User } from '@supabase/supabase-js';
import { calculatePriorityScore } from '../services/matchingSystem';
import type { AppQueueItem } from '../types/app';
import { supabase } from '../lib/supabase';

// [New] Type for players currently in a match
// type InGamePlayer = {
//     id: string;
//     name: string;
//     court_name: string;
//     status: string;
// };

interface QueueBoardProps {
    user: User;
    queue: AppQueueItem[];
    isAdmin?: boolean;
}

// Helper to calculate score - reused from existing code or imported
// reusing calculatePriorityScore from services

export default function QueueBoard({ user, queue, isAdmin = false }: QueueBoardProps) {
    // V4: No internal state for queue, uses prop
    // Internal state for inGamePlayers could be derived if matches were passed, 
    // but for now let's focus on the queue list. 
    // If inGamePlayers is critical, we should pass matches prop too.

    // For now, I will Comment out inGamePlayers logic as it requires matches prop which I didn't add to App.tsx yet.
    // Or better, I can update App.tsx to pass matches to QueueBoard as well.
    // Let's stick to Queue first.

    const sortedQueue = useMemo(() => {
        const processed = queue.map(item => {
            // Ensure types match QueueItemInput
            const input = { ...item, joined_at: item.joined_at || new Date().toISOString() };
            return {
                ...item,
                joined_at: item.joined_at || new Date().toISOString(), // Normalize for UI
                finalScore: calculatePriorityScore(input)
            };
        });

        return processed.sort((a, b) => {
            if (b.finalScore !== a.finalScore) {
                return b.finalScore - a.finalScore;
            }
            return new Date(a.joined_at).getTime() - new Date(b.joined_at).getTime();
        });
    }, [queue]);

    const [processingQueueId, setProcessingQueueId] = useState<string | null>(null);
    const showCleanupColumn = true;

    // Helpers
    const getDoublesElo = (profile: any) => {
        if (!profile) return 1250;
        const gender = (profile.gender || '').toUpperCase();
        const score = gender === 'MALE' ? profile.elo_mens_doubles : profile.elo_womens_doubles;
        return score || 1250;
    };

    const formatTimeCell = (time: string | null | undefined, emptyLabel = '-') => {
        if (!time) return emptyLabel;
        const parsed = new Date(time);
        if (Number.isNaN(parsed.getTime())) return emptyLabel;
        return parsed.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false });
    };

    const handleQueueCleanup = async (item: AppQueueItem) => {
        const playerName = item.profiles?.name || '해당 사용자';
        if (item.player_id === user.id) {
            alert('본인 대기열은 "대기 취소" 버튼을 사용해주세요.');
            return;
        }

        if (!confirm(`${playerName}님 대기열 정리를 진행할까요?`)) return;

        setProcessingQueueId(item.id);
        try {
            const { data, error } = isAdmin
                ? await supabase.rpc('admin_remove_queue_entry', {
                    p_queue_id: item.id,
                    p_reason: 'LEFT_EARLY_MANUAL'
                })
                : await supabase.rpc('confirm_queue_entry_removal', {
                    p_queue_id: item.id,
                    p_reason: 'LEFT_EARLY_CONFIRM'
                });

            if (error) throw error;

            const response = data as {
                success?: boolean;
                error?: string;
                message?: string;
                removed?: boolean;
                confirmations?: number;
                required_confirmations?: number;
            };
            if (!response?.success) {
                throw new Error(response?.error || response?.message || '대기열 제외 실패');
            }

            if (isAdmin || response.removed) {
                if (response.message) alert(response.message);
                return;
            }

            const current = Number(response.confirmations || 0);
            const required = Number(response.required_confirmations || 2);
            const needed = Math.max(0, required - current);
            alert(`확인 ${current}/${required} 완료. ${needed}명 추가 확인 시 자동 제거됩니다.`);
        } catch (err) {
            const message = err instanceof Error ? err.message : 'Unknown error';
            alert(`제외 처리 실패: ${message}`);
        } finally {
            setProcessingQueueId(null);
        }
    };

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-4 h-full flex flex-col">
            <h3 className="text-lg font-bold text-white mb-4 flex items-center gap-2">
                <span>📋</span> 대기 현황 <span className="text-lime-400 text-sm">({queue.length}명)</span>
            </h3>

            <div className="grid grid-cols-12 gap-1 text-[10px] text-slate-400 font-bold uppercase mb-2 px-2 text-center">
                <div className="col-span-1">#</div>
                <div className={`${showCleanupColumn ? 'col-span-4' : 'col-span-5'} text-left pl-1`}>선수 정보</div>
                <div className="col-span-2">온시간</div>
                <div className="col-span-2">갈시간</div>
                <div className="col-span-2 text-yellow-400">점수</div>
                {showCleanupColumn && <div className="col-span-1">정리</div>}
            </div>

            <div className="flex-1 overflow-y-auto pr-1 custom-scrollbar space-y-1">
                {sortedQueue.length === 0 ? (
                    <div className="text-center py-10 text-slate-500 border border-dashed border-slate-700 rounded-xl">
                        대기자가 없습니다.
                    </div>
                ) : (
                    sortedQueue.map((item, index) => {
                        const profile = item.profiles || { name: '?', ntrp: 0, gender: 'MALE', games_played_today: 0, elo_mens_doubles: 1250, elo_womens_doubles: 1250, elo_mixed_doubles: 1250, elo_singles: 1250, is_guest: false };
                        const isMe = item.player_id === user.id;

                        const isMale = (profile.gender || '').toUpperCase() === 'MALE';
                        const genderBadge = isMale ? 'M' : 'F';
                        const genderColor = isMale ? 'text-blue-300 bg-blue-900/60' : 'text-rose-300 bg-rose-900/60';
                        const elo = getDoublesElo(profile);

                        const hasUrgentBuff = item.finalScore > (item.priority_score ?? 0);

                        return (
                            <div key={item.id} className={`grid grid-cols-12 gap-1 items-center p-2 rounded-lg border text-center text-xs transition-all ${isMe ? 'bg-indigo-900/30 border-indigo-500/50' : 'bg-slate-900/50 border-white/5'}`}>
                                <div className="col-span-1 font-bold text-slate-500">{index + 1}</div>

                                <div className={`${showCleanupColumn ? 'col-span-4' : 'col-span-5'} text-left flex flex-col justify-center pl-1`}>
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

                                <div className="col-span-2 font-bold text-slate-500">
                                    {formatTimeCell(item.joined_at, '-')}
                                </div>
                                <div className={`col-span-2 font-bold ${hasUrgentBuff ? 'text-rose-400 animate-pulse' : 'text-white'}`}>
                                    {formatTimeCell(item.departure_time, '미입력')}
                                </div>
                                <div className="col-span-2 font-mono text-yellow-400 font-bold flex items-center justify-center gap-1">
                                    {item.finalScore.toFixed(0)}
                                    {hasUrgentBuff && <span className="text-[8px]">🔥</span>}
                                </div>
                                {showCleanupColumn && (
                                    <div className="col-span-1 flex justify-center">
                                        <button
                                            onClick={() => void handleQueueCleanup(item)}
                                            disabled={processingQueueId === item.id || isMe}
                                            className="text-[10px] px-1.5 py-0.5 rounded border border-rose-500/40 text-rose-300 hover:bg-rose-500/20 disabled:opacity-50"
                                            title={isAdmin ? '대기열 즉시 제외' : '2인 확인으로 대기열 정리'}
                                        >
                                            {processingQueueId === item.id ? '...' : isAdmin ? 'X' : '2인'}
                                        </button>
                                    </div>
                                )}
                            </div>
                        );
                    })
                )}
            </div>

            {/* Removed internal inGamePlayers logic for now as it duplicates matching fetching */}
        </div>
    );
}
