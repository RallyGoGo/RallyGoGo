import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';

interface JoinQueueProps {
    user: any;
    profile: any;
}

export default function JoinQueue({ user, profile }: JoinQueueProps) {
    const [loading, setLoading] = useState(false);
    const [departureTime, setDepartureTime] = useState('');
    const [myQueueId, setMyQueueId] = useState<string | null>(null);
    const [isEditing, setIsEditing] = useState(false);

    useEffect(() => {
        checkMyQueue();
        const channel = supabase.channel('my_queue_check')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => checkMyQueue())
            .subscribe();
        return () => { supabase.removeChannel(channel); };
    }, [user]);

    const checkMyQueue = async () => {
        const { data } = await supabase.from('queue').select('id, departure_time').eq('user_id', user.id).eq('is_active', true).maybeSingle();
        if (data) {
            setMyQueueId(data.id);
            if (!isEditing) setDepartureTime(data.departure_time);
        } else {
            setMyQueueId(null);
            setDepartureTime('');
        }
    };

    const handleJoinOrUpdate = async () => {
        if (!profile) return alert("프로필 정보를 먼저 설정해주세요.");
        if (!departureTime) return alert("시간을 입력해주세요!");

        setLoading(true);
        try {
            if (myQueueId) {
                // ✨ [수정] 대기열을 나가지 않고 시간만 바꿉니다 (순서 유지)
                const { error } = await supabase.from('queue').update({
                    departure_time: departureTime
                }).eq('id', myQueueId);
                if (error) throw error;
                alert("시간이 수정되었습니다! 🕒");
                setIsEditing(false);
            } else {
                // ✨ [등록] 게임 수는 profiles 테이블에 있으므로 삭제했다 다시 등록해도 유지됩니다.
                // 점수 공식: 기본점수 1000 - (오늘 게임 수 * 100) -> 게임 많이 할수록 점수 낮아짐
                const gamesPlayed = profile.games_played_today || 0;
                const initialScore = 1000 - (gamesPlayed * 100);

                const { error } = await supabase.from('queue').insert({
                    user_id: user.id,
                    departure_time: departureTime,
                    game_type: 'MATCH',
                    is_active: true,
                    priority_score: initialScore
                });
                if (error) throw error;
                alert("대기열에 등록되었습니다! 🚀");
            }
            checkMyQueue();
        } catch (error: any) {
            alert("오류 발생: " + error.message);
        } finally {
            setLoading(false);
        }
    };

    const handleCancel = async () => {
        if (!myQueueId) return;
        if (!confirm("정말 대기를 취소하시겠습니까?")) return;
        setLoading(true);
        // 대기열에서 삭제해도 profiles의 games_played_today는 남아있습니다!
        await supabase.from('queue').delete().eq('id', myQueueId);
        setMyQueueId(null);
        setDepartureTime('');
        setIsEditing(false);
        setLoading(false);
    };

    const setQuickTime = (minutes: number) => {
        const date = new window.Date();
        date.setMinutes(date.getMinutes() + minutes);
        setDepartureTime(date.toTimeString().slice(0, 5));
    };

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-6 h-full flex flex-col justify-center animate-fadeIn">
            <h3 className="text-xl font-bold text-white mb-6 flex items-center gap-2">
                <span>🏃</span> {myQueueId && !isEditing ? '내 대기 상태' : '매치 대기 등록'}
            </h3>

            {myQueueId && !isEditing ? (
                <div className="text-center py-6">
                    <div className="text-4xl mb-4">🎾</div>
                    <p className="text-white font-bold text-lg mb-1">현재 대기 중입니다</p>
                    <p className="text-lime-400 font-mono text-2xl font-black mb-6">{departureTime} 까지</p>

                    <div className="flex gap-2">
                        <button
                            onClick={handleCancel}
                            disabled={loading}
                            className="flex-1 py-3 rounded-xl font-bold bg-rose-500/20 text-rose-400 border border-rose-500/50 hover:bg-rose-500 hover:text-white transition-all"
                        >
                            대기 취소
                        </button>
                        <button
                            onClick={() => setIsEditing(true)}
                            disabled={loading}
                            className="flex-1 py-3 rounded-xl font-bold bg-blue-500/20 text-blue-400 border border-blue-500/50 hover:bg-blue-500 hover:text-white transition-all"
                        >
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
                            <button onClick={() => setQuickTime(60)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600">+1시간</button>
                            <button onClick={() => setQuickTime(120)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600">+2시간</button>
                            <button onClick={() => setQuickTime(180)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600">+3시간</button>
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
                            <button onClick={() => setIsEditing(false)} className="flex-1 bg-slate-700 text-white rounded-xl font-bold">취소</button>
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
        </div>
    );
}