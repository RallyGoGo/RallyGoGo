import { useState, useEffect, useCallback } from 'react';
import { User } from '@supabase/supabase-js';
import { supabase, Profile } from '../lib/supabase';
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
                console.error('[JoinQueue] Check error:', error);
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
            console.error('[JoinQueue] Queue Check Error:', err);
        }
    }, [user.id, isEditing]);

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

            // 🔍 DIAGNOSTIC: Check Supabase client status
            console.log('[JoinQueue] 🔍 Supabase client URL:', import.meta.env.VITE_SUPABASE_URL?.substring(0, 30) + '...');
            console.log('[JoinQueue] 🔍 About to construct RPC promise...');

            // Call RPC with 15s Timeout
            console.log('[JoinQueue] Calling join_queue RPC with timestamp:', departureTimestamp);

            const rpcPromise = supabase.rpc('join_queue', {
                p_priority_score: calculatedScore,
                p_departure_time: departureTimestamp
            });

            console.log('[JoinQueue] 🔍 RPC promise constructed, starting race...');

            const timeoutPromise = new Promise((_, reject) =>
                setTimeout(() => reject(new Error('REQUEST_TIMEOUT')), 15000)
            );

            // Race RPC against timeout
            console.log('[JoinQueue] 🔍 Awaiting Promise.race...');
            const result = await Promise.race([rpcPromise, timeoutPromise]) as { data: unknown; error: unknown };
            console.log('[JoinQueue] 🔍 Promise.race resolved!');
            const { data, error } = result;

            // 🔍 DIAGNOSTIC: Log full response
            console.log('[JoinQueue] RPC Response:', { data, error });

            if (error) {
                console.error('[JoinQueue] Supabase client error:', error);
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

            console.log('[JoinQueue] Parsed response:', response);

            if (!response) {
                throw new Error('서버 응답 없음');
            }

            console.log('[JoinQueue] Parsed response:', response);

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
                console.error('[JoinQueue] RPC Error:', errorMsg);

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
            console.error('[JoinQueue] Join error:', error);
            const message = error instanceof Error ? error.message : 'Unknown error';
            alert('오류 발생: ' + message);
        } finally {
            setLoading(false);
        }
    };

    // ============================================================================
    // UPDATE DEPARTURE TIME (Direct update - no RPC needed for simple time change)
    // ============================================================================
    const handleUpdateTime = async () => {
        if (!myQueue || !departureTime) return;

        setLoading(true);
        try {
            // Convert HH:mm to ISO 8601 timestamp for direct update
            const now = new Date();
            const [targetH, targetM] = departureTime.split(':').map(Number);
            const targetDate = new Date();
            targetDate.setHours(targetH, targetM, 0, 0);
            if (targetDate < now) targetDate.setDate(targetDate.getDate() + 1);

            const { error } = await supabase
                .from('queue')
                .update({ departure_time: targetDate.toISOString() })
                .eq('id', myQueue.id);

            if (error) throw error;

            alert('시간이 수정되었습니다! 🕒');
            setIsEditing(false);
            await checkMyQueue();
        } catch (error: unknown) {
            console.error('[JoinQueue] Update error:', error);
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
            console.log('[JoinQueue] Calling leave_queue RPC...');
            const { data, error } = await supabase.rpc('leave_queue');

            // 🔍 DIAGNOSTIC: Log full response
            console.log('[JoinQueue] leave_queue Response:', { data, error });

            if (error) {
                console.error('[JoinQueue] Supabase client error:', error);
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
                console.error('[JoinQueue] leave_queue Error:', errorMsg);
                throw new Error(errorMsg);
            }
        } catch (error: unknown) {
            console.error('[JoinQueue] Leave error:', error);
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

            {/* Guest Registration Button */}
            <div className="absolute top-4 right-4">
                <button
                    onClick={() => setShowGuestReg(true)}
                    className="text-xs bg-indigo-900/50 text-indigo-300 px-2 py-1 rounded border border-indigo-500/30 hover:bg-indigo-800 transition-colors"
                >
                    ⚡ 동반 게스트 등록
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
                        {departureTime || '--:--'} 까지
                    </p>
                    {myQueue.priority_score && (
                        <p className="text-sm text-yellow-400 mb-4">
                            우선순위 점수: <span className="font-mono font-bold">{myQueue.priority_score}</span>
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

            {/* Guest Registration Modal */}
            {showGuestReg && (
                <GuestRegistrar
                    onClose={() => setShowGuestReg(false)}
                    onRegister={(playerId: string) => {
                        console.log('[JoinQueue] Guest registered with ID:', playerId);
                        setShowGuestReg(false);
                    }}
                />
            )}
        </div>
    );
}