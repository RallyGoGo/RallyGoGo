import { useState } from 'react';
import { supabase } from '../lib/supabase';
import { initialEloFromNtrp, NTRP_OPTIONS } from '../utils/ratingPolicy'; // Display Only

interface GuestRegistrarProps {
    onRegister: (playerId: string) => void;
    onClose: () => void;
}

export default function GuestRegistrar({ onRegister, onClose }: GuestRegistrarProps) {
    const [name, setName] = useState('');
    const [ntrp, setNtrp] = useState<string>('3.0');
    const [gender, setGender] = useState<'Male' | 'Female'>('Male');
    const [departureTime, setDepartureTime] = useState<string>(
        new Date(Date.now() + 3 * 60 * 60 * 1000).toISOString().slice(11, 16)
    );
    const [loading, setLoading] = useState(false);

    const handleRegister = async () => {
        if (!name.trim()) return alert('이름을 입력해주세요.');
        setLoading(true);

        try {
            // Calculate Departure Time ISO
            const now = new Date();
            const [h, m] = departureTime.split(':').map(Number);
            const depDate = new Date();
            depDate.setHours(h, m, 0, 0);
            if (depDate < now) depDate.setDate(depDate.getDate() + 1);

            // RPC Call (Atomic Registration & Enqueue)
            // Policies for ELO and Priority are handled entirely in the DB
            const { data, error } = await supabase.rpc('register_guest_and_enqueue', {
                p_name: name,
                p_ntrp: parseFloat(ntrp),
                p_gender: gender,
                p_departure_time: depDate.toISOString()
            });

            if (error) throw error;

            type GuestRpcResponse = { player_id: string; reused: boolean; initial_elo: number };
            const { player_id, reused, initial_elo } = data as GuestRpcResponse;

            if (reused) {
                alert(`✅ 기존 게스트 프로필 사용: ${name} (G)`);
            } else {
                alert(`🎉 새 게스트 등록 완료: ${name} (G) (ELO ${initial_elo})`);
            }

            onRegister(player_id);
            onClose();

        } catch (err) {
            console.error(err);
            alert('등록 실패: 시스템 오류');
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4">
            <div className="absolute inset-0" onClick={onClose}></div>

            <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-sm p-6 shadow-2xl relative z-10">
                <button
                    onClick={onClose}
                    className="absolute top-4 right-4 text-slate-400 hover:text-white"
                >
                    ✕
                </button>

                <h3 className="text-xl font-bold text-white mb-1">⚡ 게스트 3초 등록</h3>
                <p className="text-xs text-slate-400 mb-6">
                    게스트는 밸런스를 위해 NTRP +0.25로 매칭됩니다.
                </p>

                <div className="space-y-4">
                    <div>
                        <label className="block text-xs text-slate-400 mb-1">이름</label>
                        <input
                            className="w-full bg-slate-900 border border-slate-700 rounded-xl p-3 text-white"
                            value={name}
                            onChange={(e) => setName(e.target.value)}
                            autoFocus
                            placeholder="예: 김테니"
                        />
                    </div>

                    <div className="flex gap-4">
                        <select
                            value={ntrp}
                            onChange={(e) => setNtrp(e.target.value)}
                            className="flex-1 bg-slate-900 border border-slate-700 rounded-xl p-3 text-white"
                        >
                            {NTRP_OPTIONS.map((v) => (
                                <option key={v} value={v.toString()}>
                                    {v.toFixed(1)}
                                </option>
                            ))}
                        </select>

                        <div className="flex bg-slate-900 rounded-xl p-1 border border-slate-700 h-[42px] flex-1">
                            <button
                                type="button"
                                onClick={() => setGender('Male')}
                                className={`flex-1 rounded-lg ${gender === 'Male' ? 'bg-blue-600 text-white' : 'text-slate-400'}`}
                            >
                                남
                            </button>
                            <button
                                type="button"
                                onClick={() => setGender('Female')}
                                className={`flex-1 rounded-lg ${gender === 'Female' ? 'bg-rose-600 text-white' : 'text-slate-400'}`}
                            >
                                여
                            </button>
                        </div>
                    </div>

                    <input
                        type="time"
                        value={departureTime}
                        onChange={(e) => setDepartureTime(e.target.value)}
                        className="w-full bg-slate-900 border border-slate-700 rounded-xl p-3 text-white"
                    />
                </div>

                <button
                    onClick={handleRegister}
                    disabled={loading}
                    className="w-full mt-6 py-4 bg-lime-500 hover:bg-lime-400 text-black font-black rounded-xl disabled:opacity-50"
                >
                    {loading ? '등록 중...' : '등록 완료'}
                </button>

                <p className="text-center text-[10px] text-slate-500 mt-3 font-mono">
                    초기 ELO {initialEloFromNtrp(parseFloat(ntrp))} / 매칭 보정 +0.25
                </p>
            </div>
        </div>
    );
}
