import { useState, useEffect, useCallback } from 'react';
import { User } from '@supabase/supabase-js';
import { supabase, Profile } from '../lib/supabase';
import { logger } from '../utils/logger';
import GuestRegistrar from './GuestRegistrar';

// ============================================================================
// TYPES
// ============================================================================
interface JoinQueueProps {
    user: User;
    profile: Profile | null;
}

interface QueueEntry {
    id: string;
    departure_time: string | null;
    priority_score: number | null;
    joined_at: string | null;
}

// ============================================================================
// COMPONENT
// ============================================================================
export default function JoinQueue({ user, profile }: JoinQueueProps) {
    const [loading, setLoading] = useState(false);
    const [departureTime, setDepartureTime] = useState('');
    const [myQueue, setMyQueue] = useState<QueueEntry | null>(null);
    const [isEditing, setIsEditing] = useState(false);
    const [showGuestReg, setShowGuestReg] = useState(false);
    const [showGuestRemove, setShowGuestRemove] = useState(false);
    const [guestsInQueue, setGuestsInQueue] = useState<{ player_id: string; name: string; departure_time: string | null }[]>([]);
    const [guestLoading, setGuestLoading] = useState(false);

    // ============================================================================
    // CHECK MY QUEUE STATUS
    // ============================================================================
    const checkMyQueue = useCallback(async () => {
        try {
            const { data, error } = await supabase
                .from('queue')
                .select('id, departure_time, priority_score, joined_at')
                .eq('player_id', user.id)
                .eq('is_active', true)
                .maybeSingle();

            if (error) {
                logger.error('joinQueue.check_error', error);
                return;
            }

            if (data) {
                setMyQueue(data);
                if (!isEditing) {
                    setDepartureTime(data.departure_time || '');
                }
            } else {
                setMyQueue(null);
                if (!isEditing) setDepartureTime('');
            }
        } catch (err) {
            logger.error('joinQueue.check_exception', err);
        }
    }, [user.id, isEditing]);

    // ============================================================================
    // FETCH GUESTS IN QUEUE
    // ============================================================================
    const fetchGuestsInQueue = useCallback(async () => {
        try {
            const { data, error } = await supabase
                .from('queue')
                .select(`
                    player_id,
                    departure_time,
                    profiles!inner (name, is_guest)
                `)
                .eq('is_active', true)
                .eq('profiles.is_guest', true);

            if (error) {
                logger.error('joinQueue.fetch_guests_error', error);
                return;
            }

            if (data) {
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const guests = data.map((q: any) => ({
                    player_id: q.player_id,
                    name: q.profiles?.name || 'Unknown',
                    departure_time: q.departure_time
                }));
                setGuestsInQueue(guests);
            }
        } catch (err) {
            logger.error('joinQueue.fetch_guests_exception', err);
        }
    }, []);

    // ============================================================================
    // REMOVE GUEST FROM QUEUE (RPC)
    // ============================================================================
    const handleRemoveGuest = async (guestId: string, guestName: string) => {
        if (!confirm(`${guestName}님을 대기열에서 삭제하시겠습니까?`)) return;

        setGuestLoading(true);
        try {
            const { data, error } = await supabase.rpc('remove_guest_from_queue', {
                p_guest_id: guestId
            });

            if (error) {
                logger.error('joinQueue.remove_guest_error', error);
                throw error;
            }

            type RemoveResult = { success: boolean; error?: string; message?: string };
            const response = data as RemoveResult;

            if (response?.success) {
                alert(response.message || '삭제되었습니다.');
                await fetchGuestsInQueue();
            } else {
                throw new Error(response?.message || response?.error || '삭제 실패');
            }
        } catch (err: unknown) {
            logger.error('joinQueue.remove_guest_exception', err);
            const message = err instanceof Error ? err.message : 'Unknown error';
            alert('오류: ' + message);
        } finally {
            setGuestLoading(false);
        }
    };

    // ============================================================================
    // INITIAL LOAD & REALTIME SUBSCRIPTION
    // Note: App.tsx handles centralized realtime, but we keep local check for 
    // immediate feedback after actions
    // ============================================================================
    useEffect(() => {
        checkMyQueue();

        // Subscribe to queue changes for this user
        const channel = supabase
            .channel(`queue_${user.id}`)
            .on(
                'postgres_changes',
                {
                    event: '*',
                    schema: 'public',
                    table: 'queue',
                    filter: `player_id=eq.${user.id}`
                },
                () => checkMyQueue()
            )
            .subscribe();

        return () => {
            supabase.removeChannel(channel);
        };
    }, [user.id, checkMyQueue]);

    // ============================================================================
    // JOIN QUEUE (RPC) - V3 Enhanced with diagnostic logging
    // ============================================================================
    const handleJoinQueue = async () => {
        if (!departureTime) {
            alert('⏰ 갈 시간을 입력해주세요!');
            return;
        }

        setLoading(true);
        try {
            // Calculate priority score based on games played
            const gamesPlayed = profile?.games_played_today || 0;
            let calculatedScore = 1000 - (gamesPlayed * 100);

            // Newbie buff
            if (gamesPlayed === 0) calculatedScore += 50;

            // "Last train" buff - if leaving within 40 minutes
            const now = new Date();
            const [targetH, targetM] = departureTime.split(':').map(Number);
            const targetDate = new Date();
            targetDate.setHours(targetH, targetM, 0, 0);

            if (targetDate < now) targetDate.setDate(targetDate.getDate() + 1);

            const diffMins = (targetDate.getTime() - now.getTime()) / (1000 * 60);
            if (diffMins > 0 && diffMins <= 40) calculatedScore += 70;

            // Convert HH:mm to ISO 8601 timestamp (TIMESTAMPTZ)
            const departureTimestamp = targetDate.toISOString();

            // Call RPC with 15s Timeout
            const rpcPromise = supabase.rpc('join_queue', {
                p_priority_score: calculatedScore,
                p_departure_time: departureTimestamp
            });

            const timeoutPromise = new Promise((_, reject) =>
                setTimeout(() => reject(new Error('REQUEST_TIMEOUT')), 15000)
            );

            // Race RPC against timeout
            const result = await Promise.race([rpcPromise, timeoutPromise]) as { data: unknown; error: unknown };
            const { data, error } = result;

            if (error) {
                logger.error('joinQueue.join_supabase_error', error);
                throw error;
            }

            // Type-safe response handling
            type JoinQueueResult = {
                success: boolean;
                error?: string;
                message?: string;
                queue_id?: string;
                was_duplicate?: boolean;
            };
            const response = data as JoinQueueResult | null;

            if (!response) {
                throw new Error('서버 응답 없음');
            }

            if (response.success === true) {
                if (response.was_duplicate) {
                    alert('이미 대기열에 등록되어 있습니다! 🔄');
                } else {
                    alert('대기열에 등록되었습니다! 🚀');
                }
                await checkMyQueue();
            } else {
                // Extract error with multiple fallbacks
                const errorMsg = response.error || response.message || JSON.stringify(response);
                logger.error('joinQueue.join_rpc_error', errorMsg);

                // Provide user-friendly messages for known errors
                const friendlyMessages: Record<string, string> = {
                    'AUTHENTICATION_REQUIRED': '로그인이 필요합니다. 다시 로그인해주세요.',
                    'PROFILE_NOT_FOUND': '프로필이 없습니다. 관리자에게 문의하세요.',
                    'ALREADY_IN_QUEUE': '이미 대기열에 등록되어 있습니다.',
                    'ALREADY_IN_MATCH': '진행 중인 경기가 있습니다.'
                };
                throw new Error(friendlyMessages[errorMsg] || errorMsg);
            }
        } catch (error: unknown) {
            logger.error('joinQueue.join_exception', error);
            const message = error instanceof Error ? error.message : 'Unknown error';
            alert('오류 발생: ' + message);
        } finally {
            setLoading(false);
        }
    };

    // ============================================================================
    // UPDATE DEPARTURE TIME (Strict RPC) - V3 Enhanced
    // ============================================================================
    const handleUpdateTime = async () => {
        if (!myQueue || !departureTime) return;

        setLoading(true);
        try {
            // Convert HH:mm to ISO 8601 timestamp
            const now = new Date();
            const [targetH, targetM] = departureTime.split(':').map(Number);
            const targetDate = new Date();
            targetDate.setHours(targetH, targetM, 0, 0);
            if (targetDate < now) targetDate.setDate(targetDate.getDate() + 1);

            logger.info('joinQueue.update_time_attempt', { queueId: myQueue.id, newTime: targetDate.toISOString() });

            // Call RPC
            const { data, error } = await supabase.rpc('update_queue_departure_time', {
                p_queue_id: myQueue.id,
                p_departure_time: targetDate.toISOString()
            });

            if (error) {
                logger.error('joinQueue.update_supabase_error', error);
                throw error;
            }

            type RpcResponse = { success: boolean; error?: string };
            const response = data as RpcResponse;

            if (!response.success) {
                logger.error('joinQueue.update_rpc_fail', response.error);
                throw new Error(response.error);
            }

            logger.info('joinQueue.update_success', { queueId: myQueue.id });
            alert('시간이 수정되었습니다! 🕒');
            setIsEditing(false);
            await checkMyQueue();
        } catch (error: unknown) {
            logger.error('joinQueue.update_exception', error);
            const message = error instanceof Error ? error.message : 'Unknown error';
            alert('오류 발생: ' + message);
        } finally {
            setLoading(false);
        }
    };

    // ============================================================================
    // LEAVE QUEUE (RPC) - V3 Enhanced with diagnostic logging
    // ============================================================================
    const handleLeaveQueue = async () => {
        if (!myQueue) return;
        if (!confirm('정말 대기를 취소하시겠습니까?')) return;

        setLoading(true);
        try {
            const { data, error } = await supabase.rpc('leave_queue');

            if (error) {
                logger.error('joinQueue.leave_supabase_error', error);
                throw error;
            }

            // Type-safe response handling
            type LeaveQueueResult = {
                success: boolean;
                error?: string;
                message?: string;
                deleted_count?: number;
            };
            const response = data as LeaveQueueResult | null;

            if (response?.success === true) {
                setMyQueue(null);
                setDepartureTime('');
                setIsEditing(false);
                alert('대기가 취소되었습니다.');
            } else if (response?.error === 'NOT_IN_QUEUE') {
                // If not in queue, just clear local state
                setMyQueue(null);
                setDepartureTime('');
            } else {
                const errorMsg = response?.error || response?.message || 'Unknown error';
                logger.error('joinQueue.leave_rpc_error', errorMsg);
                throw new Error(errorMsg);
            }
        } catch (error: unknown) {
            logger.error('joinQueue.leave_exception', error);
            const message = error instanceof Error ? error.message : 'Unknown error';
            alert('오류 발생: ' + message);
        } finally {
            setLoading(false);
        }
    };

    // ============================================================================
    // QUICK TIME BUTTONS
    // ============================================================================
    const setQuickTime = (minutes: number) => {
        const date = new Date();
        date.setMinutes(date.getMinutes() + minutes);
        setDepartureTime(date.toTimeString().slice(0, 5));
    };

    // ============================================================================
    // RENDER
    // ============================================================================
    const isInQueue = !!myQueue;

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-6 h-full flex flex-col justify-center animate-fadeIn relative">

            {/* Guest Registration & Remove Buttons */}
            <div className="absolute top-4 right-4 flex gap-1">
                <button
                    onClick={() => {
                        setShowGuestRemove(!showGuestRemove);
                        if (!showGuestRemove) fetchGuestsInQueue();
                    }}
                    className="text-xs bg-rose-900/50 text-rose-300 px-2 py-1 rounded border border-rose-500/30 hover:bg-rose-800 transition-colors"
                >
                    🗑 게스트 삭제
                </button>
                <button
                    onClick={() => setShowGuestReg(true)}
                    className="text-xs bg-indigo-900/50 text-indigo-300 px-2 py-1 rounded border border-indigo-500/30 hover:bg-indigo-800 transition-colors"
                >
                    ⚡ 게스트 등록
                </button>
            </div>

            <h3 className="text-xl font-bold text-white mb-6 flex items-center gap-2">
                <span>🏃</span> {isInQueue && !isEditing ? '내 대기 상태' : '매치 대기 등록'}
            </h3>

            {isInQueue && !isEditing ? (
                /* ========== In Queue View ========== */
                <div className="text-center py-6">
                    <div className="text-4xl mb-4">🎾</div>
                    <p className="text-white font-bold text-lg mb-1">현재 대기 중입니다</p>
                    <p className="text-lime-400 font-mono text-2xl font-black mb-2">
                        {myQueue.departure_time
                            ? new Date(myQueue.departure_time).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })
                            : '--:--'} 까지
                    </p>
                    {myQueue.priority_score && (
                        <p className="text-sm text-yellow-400 mb-4">
                            우선순위 점수: <span className="font-mono font-bold">{Math.round(myQueue.priority_score)}</span>
                        </p>
                    )}

                    <div className="flex gap-2">
                        <button
                            onClick={handleLeaveQueue}
                            disabled={loading}
                            className="flex-1 py-3 rounded-xl font-bold bg-rose-500/20 text-rose-400 border border-rose-500/50 hover:bg-rose-500 hover:text-white transition-all disabled:opacity-50"
                        >
                            {loading ? '처리 중...' : '대기 취소'}
                        </button>
                        <button
                            onClick={() => setIsEditing(true)}
                            disabled={loading}
                            className="flex-1 py-3 rounded-xl font-bold bg-blue-500/20 text-blue-400 border border-blue-500/50 hover:bg-blue-500 hover:text-white transition-all disabled:opacity-50"
                        >
                            시간 수정
                        </button>
                    </div>
                </div>
            ) : (
                /* ========== Join/Edit Queue View ========== */
                <div className="space-y-6">
                    <div>
                        <label className="block text-xs text-lime-400 font-bold mb-2 uppercase tracking-wider">
                            Departure Time (갈 시간)
                        </label>
                        <div className="flex gap-2 mb-2">
                            <button
                                onClick={() => setQuickTime(60)}
                                className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors"
                            >
                                +1시간
                            </button>
                            <button
                                onClick={() => setQuickTime(120)}
                                className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors"
                            >
                                +2시간
                            </button>
                            <button
                                onClick={() => setQuickTime(180)}
                                className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors"
                            >
                                +3시간
                            </button>
                        </div>
                        <input
                            type="time"
                            value={departureTime}
                            onChange={(e) => setDepartureTime(e.target.value)}
                            className="w-full bg-slate-900 border border-slate-600 rounded-xl p-4 text-white text-center text-2xl font-mono focus:border-lime-400 outline-none"
                        />
                    </div>

                    <div className="flex gap-2">
                        {isEditing && (
                            <button
                                onClick={() => {
                                    setIsEditing(false);
                                    checkMyQueue();
                                }}
                                className="flex-1 py-4 bg-slate-700 text-white rounded-xl font-bold hover:bg-slate-600 transition-colors"
                            >
                                취소
                            </button>
                        )}
                        <button
                            onClick={isEditing ? handleUpdateTime : handleJoinQueue}
                            disabled={loading || !departureTime}
                            className="flex-[2] py-4 bg-gradient-to-r from-lime-500 to-emerald-500 hover:from-lime-400 hover:to-emerald-400 text-slate-900 font-black text-lg rounded-xl shadow-lg transition-all disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            {loading ? '처리 중...' : isEditing ? '시간 수정 완료' : '대기열 등록하기'}
                        </button>
                    </div>
                </div>
            )}

            {/* Guest Remove Panel */}
            {showGuestRemove && (
                <div className="mt-4 bg-slate-900/80 border border-rose-500/30 rounded-xl p-4 animate-fadeIn">
                    <div className="flex items-center justify-between mb-3">
                        <h4 className="text-sm font-bold text-rose-400">🗑 대기 중 게스트 삭제</h4>
                        <button
                            onClick={() => setShowGuestRemove(false)}
                            className="text-xs text-slate-500 hover:text-white"
                        >
                            닫기 ✕
                        </button>
                    </div>
                    {guestsInQueue.length === 0 ? (
                        <p className="text-xs text-slate-500 text-center py-2">대기 중인 게스트가 없습니다.</p>
                    ) : (
                        <div className="space-y-2 max-h-40 overflow-y-auto">
                            {guestsInQueue.map((g) => (
                                <div key={g.player_id} className="flex items-center justify-between bg-slate-800 rounded-lg px-3 py-2">
                                    <div>
                                        <span className="text-sm text-white font-bold">{g.name}</span>
                                        <span className="text-xs text-slate-400 ml-2">
                                            {g.departure_time
                                                ? new Date(g.departure_time).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })
                                                : '시간 미설정'}
                                        </span>
                                    </div>
                                    <button
                                        onClick={() => handleRemoveGuest(g.player_id, g.name)}
                                        disabled={guestLoading}
                                        className="text-xs bg-rose-600/50 text-rose-200 px-2 py-1 rounded hover:bg-rose-500 transition-colors disabled:opacity-50"
                                    >
                                        {guestLoading ? '...' : '삭제'}
                                    </button>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            )}

            {/* Guest Registration Modal */}
            {showGuestReg && (
                <GuestRegistrar
                    onClose={() => setShowGuestReg(false)}
                    onRegister={() => {
                        setShowGuestReg(false);
                    }}
                />
            )}
        </div>
    );
}