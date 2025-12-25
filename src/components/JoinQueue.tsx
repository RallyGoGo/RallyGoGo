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

    // 이미 대기 중인지 확인
    useEffect(() => {
        checkMyQueue();
        // 실시간 감지 (내가 취소하거나 등록했을 때 UI 반영)
        const channel = supabase.channel('my_queue_check')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => checkMyQueue())
            .subscribe();
        return () => { supabase.removeChannel(channel); };
    }, [user]);

    const checkMyQueue = async () => {
        const { data } = await supabase.from('queue').select('id').eq('user_id', user.id).eq('is_active', true).maybeSingle();
        if (data) setMyQueueId(data.id);
        else setMyQueueId(null);
    };

    const handleJoin = async () => {
        if (!profile) return alert("프로필 정보를 먼저 설정해주세요.");
        if (!departureTime) return alert("출발 예정 시간을 입력해주세요!");

        setLoading(true);
        try {
            // ✨ game_type을 묻지 않고 '일반 매치(MATCH)'로 통일해서 저장
            const { error } = await supabase.from('queue').insert({
                user_id: user.id,
                departure_time: departureTime,
                game_type: 'MATCH',
                is_active: true
            });

            if (error) throw error;
            alert("대기열에 등록되었습니다! 🎾");
            setDepartureTime('');
        } catch (error: any) {
            alert("등록 실패: " + error.message);
        } finally {
            setLoading(false);
        }
    };

    const handleCancel = async () => {
        if (!myQueueId) return;
        if (!confirm("대기를 취소하시겠습니까?")) return;
        setLoading(true);
        await supabase.from('queue').delete().eq('id', myQueueId);
        setLoading(false);
    };

    // 현재 시간 + 10분, 30분 뒤 자동완성 버튼
    const setQuickTime = (minutes: number) => {
        const date = new window.Date(); // JS Date 객체
        date.setMinutes(date.getMinutes() + minutes);
        const timeString = date.toTimeString().slice(0, 5); // "14:30" 형식
        setDepartureTime(timeString);
    };

    return (
        <div className="bg-slate-800/50 border border-white/10 rounded-2xl p-6 h-full flex flex-col justify-center animate-fadeIn">
            <h3 className="text-xl font-bold text-white mb-6 flex items-center gap-2">
                <span>🏃</span> 매치 대기 등록
            </h3>

            {myQueueId ? (
                <div className="text-center py-10">
                    <div className="w-16 h-16 bg-lime-500 rounded-full flex items-center justify-center text-3xl mx-auto mb-4 animate-bounce shadow-lg shadow-lime-500/50">
                        🎾
                    </div>
                    <p className="text-white font-bold text-lg mb-1">매칭 대기 중입니다!</p>
                    <p className="text-slate-400 text-sm mb-6">다른 선수가 올 때까지 잠시만 기다려주세요.</p>
                    <button
                        onClick={handleCancel}
                        disabled={loading}
                        className="w-full py-3 rounded-xl font-bold bg-rose-500/20 text-rose-400 border border-rose-500/50 hover:bg-rose-500 hover:text-white transition-all"
                    >
                        대기 취소하기
                    </button>
                </div>
            ) : (
                <div className="space-y-6">
                    {/* 시간 입력 섹션 */}
                    <div>
                        <label className="block text-xs text-lime-400 font-bold mb-2 uppercase tracking-wider">
                            Departure Time (출발 예정)
                        </label>
                        <div className="flex gap-2 mb-2">
                            <button onClick={() => setQuickTime(10)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors">+10분</button>
                            <button onClick={() => setQuickTime(30)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors">+30분</button>
                            <button onClick={() => setQuickTime(60)} className="flex-1 bg-slate-700 text-slate-300 text-xs py-2 rounded-lg hover:bg-slate-600 transition-colors">+1시간</button>
                        </div>
                        <input
                            type="time"
                            value={departureTime}
                            onChange={(e) => setDepartureTime(e.target.value)}
                            className="w-full bg-slate-900 border border-slate-600 rounded-xl p-4 text-white text-center text-2xl font-mono focus:border-lime-400 outline-none shadow-inner"
                        />
                    </div>

                    <button
                        onClick={handleJoin}
                        disabled={loading}
                        className="w-full py-4 bg-gradient-to-r from-lime-500 to-emerald-500 hover:from-lime-400 hover:to-emerald-400 text-slate-900 font-black text-lg rounded-xl shadow-lg shadow-lime-500/20 transition-all transform hover:scale-[1.02] active:scale-95"
                    >
                        {loading ? '등록 중...' : '🚀 대기열 등록하기'}
                    </button>
                </div>
            )}
        </div>
    );
}