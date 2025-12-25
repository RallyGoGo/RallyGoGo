import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';

// App.tsx에서 전달받는 profile 타입 정의
interface Profile {
    name: string;
    ntrp: number;
    gender: string;
    emoji?: string;
}

type Props = {
    user: User | null;
    profile: Profile | null; // ✨ 프로필 정보 추가
};

export default function JoinQueue({ user, profile }: Props) {
    const [isSearching, setIsSearching] = useState(false);
    const [departureTime, setDepartureTime] = useState('');
    const [gameType, setGameType] = useState('Singles'); // 기본값 단식

    useEffect(() => {
        if (!user) return;

        const checkStatus = async () => {
            // ⚠️ 중요: player_id -> user_id 로 변경 (DB 컬럼명 통일)
            const { data } = await supabase
                .from('queue')
                .select('departure_time, game_type')
                .eq('user_id', user.id)
                .eq('is_active', true)
                .maybeSingle();

            if (data) {
                setIsSearching(true);
                if (data.departure_time) setDepartureTime(data.departure_time);
                if (data.game_type) setGameType(data.game_type);
            } else {
                setIsSearching(false);
            }
        };

        checkStatus();

        // 내 대기 상태 변화 실시간 감지
        const channel = supabase.channel('my_queue_status')
            .on(
                'postgres_changes',
                { event: '*', schema: 'public', table: 'queue', filter: `user_id=eq.${user.id}` },
                () => checkStatus()
            )
            .subscribe();

        return () => { supabase.removeChannel(channel); };
    }, [user]);

    const handleQueueAction = async () => {
        if (!user) return;

        try {
            if (isSearching) {
                // [대기 취소]
                const { error } = await supabase
                    .from('queue')
                    .delete()
                    .eq('user_id', user.id);

                if (error) throw error;
                setIsSearching(false);
                setDepartureTime('');
            } else {
                // [대기열 등록]
                if (!departureTime) {
                    alert("⏰ 언제 떠나시는지 시간을 입력해주세요!");
                    return;
                }

                // 프로필에서 NTRP 가져오기 (없으면 기본값 2.5)
                const userNtrp = profile?.ntrp || 2.5;

                const { error } = await supabase.from('queue').insert({
                    user_id: user.id,          // 컬럼명 통일
                    is_active: true,           // 활성 상태 명시
                    game_type: gameType,       // 게임 타입 (단식/복식)
                    priority_score: userNtrp,  // 우선순위 점수
                    departure_time: departureTime,
                    created_at: new Date().toISOString() // 등록 시간
                });

                if (error) throw error;
                setIsSearching(true);
            }
        } catch (error: any) {
            console.error("Queue Error:", error);
            alert("오류가 발생했습니다: " + error.message);
        }
    };

    const handleUpdateTime = async () => {
        if (!user || !isSearching) return;
        await supabase.from('queue').update({ departure_time: departureTime }).eq('user_id', user.id);
        alert("✅ 시간이 수정되었습니다!");
    };

    return (
        <div className="w-full bg-slate-800 border border-slate-700 rounded-2xl shadow-xl p-6 text-center animate-slideDown">
            <h2 className="text-xl font-black text-white mb-4 flex items-center justify-center gap-2">
                🎾 매치 찾기
            </h2>

            {/* 게임 타입 선택 (단식/복식) */}
            <div className="flex bg-slate-900 rounded-lg p-1 mb-4 border border-slate-700">
                {['Singles', 'Doubles'].map((type) => (
                    <button
                        key={type}
                        onClick={() => !isSearching && setGameType(type)} // 대기 중엔 변경 불가
                        disabled={isSearching}
                        className={`flex-1 py-2 rounded-md text-sm font-bold transition-all ${gameType === type
                                ? 'bg-lime-500 text-slate-900 shadow-md'
                                : 'text-slate-400 hover:text-white'
                            } ${isSearching ? 'opacity-50 cursor-not-allowed' : ''}`}
                    >
                        {type === 'Singles' ? '👤 단식' : '👥 복식'}
                    </button>
                ))}
            </div>

            {/* 시간 입력 */}
            <div className="flex items-center space-x-2 mb-4">
                <div className="relative w-full">
                    <label className="absolute -top-2 left-3 bg-slate-800 px-1 text-[10px] text-lime-400 font-bold">
                        Departure Time (떠나는 시간)
                    </label>
                    <input
                        type="time"
                        value={departureTime}
                        onChange={(e) => setDepartureTime(e.target.value)}
                        className="w-full bg-slate-900 border border-slate-600 text-white p-3 rounded-xl text-center text-xl font-mono focus:border-lime-500 focus:ring-1 focus:ring-lime-500 outline-none transition-all"
                    />
                </div>
                {isSearching && (
                    <button
                        onClick={handleUpdateTime}
                        className="bg-slate-700 hover:bg-slate-600 text-white p-3 rounded-xl border border-slate-600 transition-colors h-full flex items-center justify-center"
                    >
                        🔄
                    </button>
                )}
            </div>

            {/* 액션 버튼 */}
            <button
                onClick={handleQueueAction}
                className={`w-full py-4 font-black rounded-xl text-lg transition-all shadow-lg flex items-center justify-center gap-2 ${isSearching
                        ? 'bg-rose-500 hover:bg-rose-600 text-white shadow-rose-500/20'
                        : 'bg-gradient-to-r from-lime-400 to-lime-500 hover:from-lime-300 hover:to-lime-400 text-slate-900 shadow-lime-500/20'
                    }`}
            >
                {isSearching ? (
                    <><span>🚫</span> 대기 취소하기</>
                ) : (
                    <><span>🚀</span> 대기열 등록하기</>
                )}
            </button>
        </div>
    );
}