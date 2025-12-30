import { useState } from 'react';
import { supabase } from '../lib/supabase';

interface Props {
    onClose: () => void;
    onSuccess: () => void;
}

export default function GuestRegistrar({ onClose, onSuccess }: Props) {
    const [name, setName] = useState('');
    const [ntrp, setNtrp] = useState('3.0'); // Default
    const [gender, setGender] = useState('Male');
    const [loading, setLoading] = useState(false);

    const handleRegister = async () => {
        if (!name) return alert("이름을 입력해주세요.");
        setLoading(true);

        try {
            // 1. UUID 생성 (브라우저 호환성 체크)
            const guestId = crypto.randomUUID ? crypto.randomUUID() : 'guest-' + Date.now();

            // 2. 게스트 밸런스 패치 (실력 + 0.25)
            // 게스트는 보통 실력을 낮게 말하는 경향이 있으므로, 조금 더 강한 상대로 매칭
            const realScore = parseFloat(ntrp);
            const boostedScore = realScore + 0.25;

            // ELO 점수 변환 (NTRP 3.0 -> ELO 1200 기준, 0.5당 100점 차이 등 가정)
            // 여기서는 단순하게 기본 1200점으로 시작하되, 큐 우선순위 점수(priority_score)를 높입니다.

            // 3. 프로필 생성 (Profiles Insert)
            const { error: profileError } = await supabase.from('profiles').insert({
                id: guestId,
                email: `guest_${Date.now()}@temp.com`, // 더미 이메일
                name: `${name} (G)`, // (G) 태그로 게스트 구분
                ntrp: boostedScore,
                gender: gender,
                is_guest: true,
                role: 'member',
                // DB 필수 컬럼 채우기
                elo_men_doubles: 1200,
                elo_women_doubles: 1200,
                elo_mixed_doubles: 1200,
                elo_singles: 1200,
                games_played_today: 0
            });

            if (profileError) throw profileError;

            // 4. 대기열 즉시 등록 (Queue Insert)
            const { error: queueError } = await supabase.from('queue').insert({
                player_id: guestId,
                joined_at: new Date().toISOString(),
                is_active: true,
                // 우선순위 점수에 NTRP 반영 (매칭 시스템이 이 점수를 참고한다면)
                priority_score: 5000 + (boostedScore * 100), // 신규 버프(5000) + 실력 가산점
                departure_time: '23:00' // 막차 시간 기본값
            });

            if (queueError) throw queueError;

            alert(`✅ 게스트 [${name}] 등록 완료!`);
            onSuccess();
            onClose();

        } catch (e: any) {
            console.error(e);
            alert("등록 실패: " + e.message);
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-fadeIn">
            <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-sm p-6 shadow-2xl relative">
                <button onClick={onClose} className="absolute top-4 right-4 text-slate-400 hover:text-white">✕</button>

                <h3 className="text-xl font-bold text-white mb-1">⚡ 게스트 3초 등록</h3>
                <p className="text-xs text-slate-400 mb-6">게스트는 밸런스를 위해 NTRP +0.25로 적용됩니다.</p>

                <div className="space-y-4">
                    <div>
                        <label className="block text-xs text-slate-400 mb-1">이름 (Name)</label>
                        <input
                            type="text"
                            className="w-full bg-slate-900 border border-slate-700 rounded-xl p-3 text-white focus:border-lime-500 outline-none font-bold"
                            placeholder="예: 김테니"
                            value={name}
                            onChange={(e) => setName(e.target.value)}
                            autoFocus
                        />
                    </div>

                    <div className="flex gap-4">
                        <div className="flex-1">
                            <label className="block text-xs text-slate-400 mb-1">실력 (NTRP)</label>
                            <select value={ntrp} onChange={(e) => setNtrp(e.target.value)} className="w-full bg-slate-900 border border-slate-700 rounded-xl p-3 text-white text-xs font-bold">
                                <option value="1.0">1.0 (입문)</option>
                                <option value="2.0">2.0 (초보)</option>
                                <option value="2.5">2.5 (초중급)</option>
                                <option value="3.0">3.0 (중급 - 평균)</option>
                                <option value="3.5">3.5 (중상급)</option>
                                <option value="4.0">4.0 (상급)</option>
                                <option value="4.5">4.5 (선출)</option>
                            </select>
                        </div>
                        <div className="flex-1">
                            <label className="block text-xs text-slate-400 mb-1">성별</label>
                            <div className="flex bg-slate-900 rounded-xl p-1 border border-slate-700">
                                <button onClick={() => setGender('Male')} className={`flex-1 py-2 rounded-lg text-xs font-bold transition-all ${gender === 'Male' ? 'bg-blue-600 text-white' : 'text-slate-400'}`}>남</button>
                                <button onClick={() => setGender('Female')} className={`flex-1 py-2 rounded-lg text-xs font-bold transition-all ${gender === 'Female' ? 'bg-rose-600 text-white' : 'text-slate-400'}`}>여</button>
                            </div>
                        </div>
                    </div>

                    <button
                        onClick={handleRegister}
                        disabled={loading}
                        className="w-full py-4 bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-500 hover:to-purple-500 text-white font-bold rounded-xl mt-4 shadow-lg disabled:opacity-50"
                    >
                        {loading ? "등록 중..." : "🚀 대기열 즉시 투입"}
                    </button>
                </div>
            </div>
        </div>
    );
}