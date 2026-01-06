import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';
import GuestRegistrar from './GuestRegistrar'; // 게스트 등록 컴포넌트 불러오기

interface JoinQueueProps {
    user: any;
    profile: any;
}

export default function JoinQueue({ user, profile }: JoinQueueProps) {
    const [loading, setLoading] = useState(false);
    const [departureTime, setDepartureTime] = useState('');
    const [myQueueId, setMyQueueId] = useState<string | null>(null);
    const [isEditing, setIsEditing] = useState(false);

    // [New] 게스트 등록 모달 상태
    const [showGuestReg, setShowGuestReg] = useState(false);

    useEffect(() => {
        checkMyQueue();
        const channel = supabase.channel('my_queue_check')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => checkMyQueue())
            .subscribe();
        return () => { supabase.removeChannel(channel); };
    }, [user]);

    const checkMyQueue = async () => {
        try {
            const { data } = await supabase
                .from('queue')
                .select('id, departure_time')
                .eq('player_id', user.id) // user_id 대신 player_id로 통일하는 것이 좋음 (DB 스키마 확인 필요)
                // 만약 queue 테이블에 user_id와 player_id가 둘 다 있다면, user_id 사용
                .eq('is_active', true)
                .maybeSingle();

            if (data) {
                setMyQueueId(data.id);
                if (!isEditing) {
                    setDepartureTime(data.departure_time);
                }
            } else {
                setMyQueueId(null);
                if (!isEditing) setDepartureTime('');
            }
        } catch (err) {
            console.error("Queue Check Error:", err);
        }
    };

    const handleJoinOrUpdate = async () => {
        if (!departureTime) return alert("시간을 입력해주세요!");

        setLoading(true);
        try {
            if (myQueueId) {
                // ✅ [수정 모드] : 시간만 업데이트
                const { error } = await supabase
                    .from('queue')
                    .update({ departure_time: departureTime })
                    .eq('id', myQueueId);

                if (error) throw error;
                alert("시간이 수정되었습니다! 🕒");
                setIsEditing(false);

            } else {
                // ✅ [신규 등록] : 스마트 우선순위 점수 적용
                const { data: freshProfile } = await supabase
                    .from('profiles')
                    .select('games_played_today')
                    .eq('id', user.id)
                    .maybeSingle();

                const gamesPlayed = freshProfile?.games_played_today || 0;
                let calculatedScore = 1000 - (gamesPlayed * 100);

                // [뉴비 버프]
                if (gamesPlayed === 0) calculatedScore += 50;

                // [막차 버프]
                const now = new Date();
                const [targetH, targetM] = departureTime.split(':').map(Number);
                const targetDate = new Date();
                targetDate.setHours(targetH, targetM, 0, 0);

                if (targetDate < now) targetDate.setDate(targetDate.getDate() + 1);

                const diffMins = (targetDate.getTime() - now.getTime()) / (1000 * 60);
                if (diffMins > 0 && diffMins <= 40) calculatedScore += 70;

                // 5. 최종 등록
                // player_id가 queue 테이블의 FK라면 user.id를 player_id에 넣어야 함.
                // 만약 user_id 컬럼을 따로 쓴다면 user_id: user.id 사용. 
                // 여기서는 가장 일반적인 player_id 사용으로 가정.
                const { error } = await supabase.from('queue').insert({
                    player_id: user.id, // 본인 등록
                    joined_at: new Date().toISOString(), // 필수
                    departure_time: departureTime,
                    is_active: true,
                    priority_score: calculatedScore
                });

                if (error) throw error;
                alert("대기열에 등록되었습니다! 🚀");
            }
            await checkMyQueue();
        } catch (error: any) {
            console.error(error);
            alert("오류 발생: " + error.message);
        } finally {
            setLoading(false);
        }
    };

    const handleCancel = async () => {
        if (!myQueueId) return;
        if (!confirm("정말 대기를 취소하시겠습니까?")) return;

        setLoading(true);
        try {
            await supabase.from('queue').delete().eq('id', myQueueId);
            setMyQueueId(null);
            setDepartureTime('');
            setIsEditing(false);
        } catch (error) {
            console.error("Cancel Error:", error);
        } finally {
            setLoading(false);
        }
    };

    const setQuickTime = (minutes: number) => {
        const date = new window.Date();
        date.setMinutes(date.getMinutes() + minutes);
        setDepartureTime(date.toTimeString().slice(0, 5));
    };

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-6 h-full flex flex-col justify-center animate-fadeIn relative">

            {/* [New] 게스트 등록 버튼 (누구나 볼 수 있음) */}
            <div className="absolute top-4 right-4">
                <button
                    onClick={() => setShowGuestReg(true)}
                    className="text-xs bg-indigo-900/50 text-indigo-300 px-2 py-1 rounded border border-indigo-500/30 hover:bg-indigo-800 transition-colors"
                >
                    ⚡ 동반 게스트 등록
                </button>
            </div>

            <h3 className="text-xl font-bold text-white mb-6 flex items-center gap-2">
                <span>🏃</span> {myQueueId && !isEditing ? '내 대기 상태' : '매치 대기 등록'}
            </h3>

            {myQueueId && !isEditing ? (
                <div className="text-center py-6">
                    <div className="text-4xl mb-4">🎾</div>
                    <p className="text-white font-bold text-lg mb-1">현재 대기 중입니다</p>
                    <p className="text-lime-400 font-mono text-2xl font-black mb-6">{departureTime} 까지</p>

                    <div className="flex gap-2">
                        <button onClick={handleCancel} disabled={loading} className="flex-1 py-3 rounded-xl font-bold bg-rose-500/20 text-rose-400 border border-rose-500/50 hover:bg-rose-500 hover:text-white transition-all">
                            대기 취소
                        </button>
                        <button onClick={() => setIsEditing(true)} disabled={loading} className="flex-1 py-3 rounded-xl font-bold bg-blue-500/20 text-blue-400 border border-blue-500/50 hover:bg-blue-500 hover:text-white transition-all">
                            시간 수정
                        </button>
                    </div>
                </div>
            ) : (
                <div className="space-y-6">
                    <div>
                        <label className="block text-xs text-lime-400 font-bold mb-2 uppercase tracking-wider">
                            Departure Time (갈 시간)
                        </label>
                        <div className="flex gap-2 mb-2">
                            <button onClick={() => setQuickTime(60)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors">+1시간</button>
                            <button onClick={() => setQuickTime(120)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors">+2시간</button>
                            <button onClick={() => setQuickTime(180)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors">+3시간</button>
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
                            <button onClick={() => { setIsEditing(false); checkMyQueue(); }} className="flex-1 bg-slate-700 text-white rounded-xl font-bold">취소</button>
                        )}
                        <button
                            onClick={handleJoinOrUpdate}
                            disabled={loading}
                            className="flex-[2] py-4 bg-gradient-to-r from-lime-500 to-emerald-500 hover:from-lime-400 hover:to-emerald-400 text-slate-900 font-black text-lg rounded-xl shadow-lg transition-all"
                        >
                            {loading ? '처리 중...' : isEditing ? '시간 수정 완료' : '대기열 등록하기'}
                        </button>
                    </div>
                </div>
            )}

            {/* 게스트 등록 모달 */}
            {showGuestReg && (
                <GuestRegistrar
                    onClose={() => setShowGuestReg(false)}
                    onSuccess={() => {
                        // 게스트 등록이 성공하면, 굳이 내 큐를 다시 체크할 필요는 없지만
                        // 전체 대기열(QueueBoard)이 갱신되어야 함.
                        // 이 컴포넌트는 '나의 상태'만 보여주므로 별도 로직 불필요.
                        // 다만, 알림을 주거나 로그를 찍을 수 있음.
                        console.log("Guest Added!");
                    }}
                />
            )}
        </div>
    );
}