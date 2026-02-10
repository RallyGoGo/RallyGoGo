import { useState, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import { logger } from '../utils/logger';
// import { initialEloFromNtrp } from '../utils/ratingPolicy'; // Unused in new UI

interface GuestRegistrarProps {
    onRegister: (playerId: string) => void;
    onClose: () => void;
}

// Reuse NTRP Options from Auth structure for consistency
const NTRP_OPTIONS = [
    { val: "1.0", label: "1.0 (완전 입문 - 테린이)" },
    { val: "1.5", label: "1.5 (초보 - 랠리가 어려움)" },
    { val: "2.0", label: "2.0 (초급 - 기본기 연습 중)" },
    { val: "2.5", label: "2.5 (초중급 - 느린 랠리 가능)" },
    { val: "3.0", label: "3.0 (중급 - 동호인 평균 수준)" },
    { val: "3.5", label: "3.5 (중상급 - 발리/스매시 가능)" },
    { val: "4.0", label: "4.0 (상급 - 강한 스트로크/전략)" },
    { val: "4.5", label: "4.5 (최상급 - 선수 출신/코치)" },
    { val: "5.0", label: "5.0+ (프로 선수급)" },
];

export default function GuestRegistrar({ onRegister, onClose }: GuestRegistrarProps) {
    const [name, setName] = useState('');
    const [ntrp, setNtrp] = useState<string>('3.0');
    const [gender, setGender] = useState<'Male' | 'Female'>('Male');

    // Initialize departure time (default +3h, capped at 22:00? No, let user choose, but default reasonable)
    // User requested +1h, +2h, +3h buttons.
    const [departureTime, setDepartureTime] = useState<string>(() => {
        const now = new Date();
        now.setHours(now.getHours() + 2); // Default +2h
        return now.toTimeString().slice(0, 5);
    });

    const [loading, setLoading] = useState(false);

    // Helper: Set Time (+1h, +2h, +3h)
    const handleSetTime = useCallback((addHours: number) => {
        const now = new Date();
        now.setHours(now.getHours() + addHours);

        // 22:00 Limit Check
        // If "Now + X" is past 22:00 today, cap it at 22:00.
        // If it's already past 22:00, what to do? User said "10시 이후로는 설정이 안되게".
        // Let's assume matches happen within the day.

        const limit = new Date();
        limit.setHours(22, 0, 0, 0);

        if (now > limit) {
            // If already past 22:00, maybe it's too late for guests? 
            // Or maybe next day? Assuming same day logic for simplicity as per "Daily Reset".
            // We'll set it to 22:00 as max.
            now.setHours(22, 0, 0, 0);
        }

        const timeStr = now.toTimeString().slice(0, 5);
        setDepartureTime(timeStr);
    }, []);

    // Validate Time Change
    const handleTimeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const val = e.target.value; // HH:mm
        const [h, m] = val.split(':').map(Number);

        if (h > 22 || (h === 22 && m > 0)) {
            alert("⏰ 오후 10시 이후로는 설정할 수 없습니다.");
            setDepartureTime("22:00");
            return;
        }
        setDepartureTime(val);
    };

    const handleRegister = async () => {
        if (!name.trim()) return alert('이름을 입력해주세요.');
        setLoading(true);

        try {
            // Calculate Departure Time ISO
            const now = new Date();
            const [h, m] = departureTime.split(':').map(Number);

            // Hard Limit Validation again just in case
            if (h > 22 || (h === 22 && m > 0)) {
                alert("⏰ 오후 10시 이후로는 설정할 수 없습니다.");
                setLoading(false);
                return;
            }

            const depDate = new Date();
            depDate.setHours(h, m, 0, 0);

            // Handle next day roll-over if time is earlier than now?
            // "Current time based +1/2/3h" implies same day moving forward. 
            // If user manually sets 01:00 (AM) meaning next day?
            // "10시 이후 설정 불가" implies 22:00 is the hard stop for the day.
            // If user sets 09:00 (AM) when it is 16:00 (PM), it's past.
            if (depDate < now) {
                // If past, maybe they mean tomorrow? But we have daily reset.
                // Assuming user sets future time today.
                // Warn? Or just allow? Let's just create ISO.
            }

            logger.info('guest.register_attempt', { name, ntrp, gender, departure: depDate.toISOString() });

            // RPC Call
            const rpcPromise = supabase.rpc('register_guest_and_enqueue', {
                p_name: name,
                p_ntrp: parseFloat(ntrp),
                p_gender: gender,
                p_departure_time: depDate.toISOString()
            });

            const timeoutPromise = new Promise((_, reject) =>
                setTimeout(() => reject(new Error('REQUEST_TIMEOUT')), 15000)
            );

            const result = await Promise.race([rpcPromise, timeoutPromise]) as { data: unknown; error: any };
            const { data, error } = result;

            if (error) throw error;

            type GuestRpcResponse = { player_id: string; reused: boolean; initial_elo: number; };
            const { player_id, reused, initial_elo } = data as GuestRpcResponse;

            if (reused) {
                alert(`✅ 기존 게스트 프로필 사용: ${name} (G)\n(ELO 갱신됨: ${initial_elo})`);
            } else {
                alert(`🎉 새 게스트 등록 완료: ${name} (G) (ELO ${initial_elo})`);
            }

            onRegister(player_id);
            onClose();

        } catch (err: unknown) {
            logger.error('guest.register_fail', err);
            const msg = err instanceof Error ? err.message : (err as { message?: string })?.message || 'Unknown Error';

            if (msg === 'REQUEST_TIMEOUT') {
                alert('⏳ 요청 시간 초과. 잠시 후 다시 시도해주세요.');
            } else if (msg.includes('DUPLICATE_QUEUE')) {
                alert('🚫 이미 대기열에 등록된 이름입니다.');
            } else {
                alert(`등록 실패: ${msg}`);
            }
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4">
            <div className="absolute inset-0" onClick={onClose}></div>

            <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-sm p-6 shadow-2xl relative z-10 flex flex-col max-h-[90vh]">
                <button
                    onClick={onClose}
                    className="absolute top-4 right-4 text-slate-400 hover:text-white"
                >
                    ✕
                </button>

                <h3 className="text-xl font-bold text-white mb-1">⚡ 게스트 3초 등록</h3>
                <p className="text-xs text-slate-400 mb-6">
                    {/* Removed balance text per request */}
                </p>

                <div className="space-y-4 overflow-y-auto custom-scrollbar flex-1 pr-1">
                    <div>
                        <label className="block text-xs text-slate-400 mb-1">이름</label>
                        <input
                            className="w-full bg-slate-900 border border-slate-700 rounded-xl p-3 text-white focus:border-lime-500 outline-none"
                            value={name}
                            onChange={(e) => setName(e.target.value)}
                            autoFocus
                            placeholder="예: 김테니"
                        />
                    </div>

                    <div>
                        <label className="block text-xs text-slate-400 mb-1">성별</label>
                        <div className="flex bg-slate-900 rounded-xl p-1 border border-slate-700 h-[42px] w-full">
                            <button
                                type="button"
                                onClick={() => setGender('Male')}
                                className={`flex-1 rounded-lg transition-colors ${gender === 'Male' ? 'bg-blue-600 text-white font-bold' : 'text-slate-400 hover:text-white'}`}
                            >
                                남
                            </button>
                            <button
                                type="button"
                                onClick={() => setGender('Female')}
                                className={`flex-1 rounded-lg transition-colors ${gender === 'Female' ? 'bg-rose-600 text-white font-bold' : 'text-slate-400 hover:text-white'}`}
                            >
                                여
                            </button>
                        </div>
                    </div>

                    <div>
                        <label className="block text-xs text-slate-400 mb-1">NTRP (실력)</label>
                        <div className="border border-slate-600 rounded-lg overflow-hidden bg-slate-900">
                            <div className="max-h-40 overflow-y-auto custom-scrollbar p-1 space-y-1">
                                {NTRP_OPTIONS.map((opt) => (
                                    <button
                                        key={opt.val}
                                        type="button"
                                        onClick={() => setNtrp(opt.val)}
                                        className={`w-full text-left px-3 py-2 rounded text-sm transition-colors flex items-center justify-between ${ntrp === opt.val ? 'bg-lime-500 text-slate-900 font-bold' : 'text-slate-300 hover:bg-slate-800'}`}
                                    >
                                        <span>{opt.label}</span>
                                        {ntrp === opt.val && <span>✓</span>}
                                    </button>
                                ))}
                            </div>
                        </div>
                    </div>

                    <div>
                        <label className="block text-xs text-slate-400 mb-1">출발 예정 시간 (Max 22:00)</label>
                        <div className="flex flex-col gap-2">
                            <input
                                type="time"
                                value={departureTime}
                                onChange={handleTimeChange}
                                className="w-full bg-slate-900 border border-slate-700 rounded-xl p-3 text-white text-center font-bold text-lg"
                            />
                            <div className="flex gap-2">
                                <button onClick={() => handleSetTime(1)} className="flex-1 bg-slate-700 hover:bg-slate-600 text-white text-xs py-2 rounded-lg transition-colors">+1시간</button>
                                <button onClick={() => handleSetTime(2)} className="flex-1 bg-slate-700 hover:bg-slate-600 text-white text-xs py-2 rounded-lg transition-colors">+2시간</button>
                                <button onClick={() => handleSetTime(3)} className="flex-1 bg-slate-700 hover:bg-slate-600 text-white text-xs py-2 rounded-lg transition-colors">+3시간</button>
                            </div>
                        </div>
                    </div>
                </div>

                <button
                    onClick={handleRegister}
                    disabled={loading}
                    className="w-full mt-4 py-4 bg-lime-500 hover:bg-lime-400 text-black font-black rounded-xl disabled:opacity-50 shadow-lg shadow-lime-500/20 transition-all"
                >
                    {loading ? '등록 중...' : '등록 완료'}
                </button>

                {/* Removed bottom explanation text as requested */}
            </div>
        </div>
    );
}
