import { useState } from 'react';
import { supabase } from '../lib/supabase';

export default function Auth() {
    const [loading, setLoading] = useState(false);
    const [isSignUp, setIsSignUp] = useState(false);
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');

    const [name, setName] = useState('');
    const [ntrp, setNtrp] = useState('2.5');
    const [gender, setGender] = useState('Male');

    // ✨ 화면에 보여질 설명 텍스트 (확인용으로 내용을 조금 더 길게 씀)
    const ntrpOptions = [
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

    const getInitialElo = (ntrpValue: string) => {
        const n = parseFloat(ntrpValue);
        if (n <= 2.0) return 1000;
        if (n === 2.5) return 1100;
        if (n === 3.0) return 1250;
        if (n === 3.5) return 1400;
        if (n === 4.0) return 1500;
        if (n >= 4.5) return 1600;
        return 1250;
    };

    const handleAuth = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);

        try {
            if (isSignUp) {
                const { data, error } = await supabase.auth.signUp({ email, password });
                if (error) throw error;

                if (data.user) {
                    const initialScore = getInitialElo(ntrp);
                    const { error: profileError } = await supabase.from('profiles').insert({
                        id: data.user.id,
                        email: email,
                        name: name,
                        ntrp: parseFloat(ntrp),
                        gender: gender,
                        elo_men_doubles: initialScore,
                        elo_women_doubles: initialScore,
                        elo_mixed_doubles: initialScore,
                        elo_singles: initialScore,
                        is_guest: false
                    });

                    if (profileError) {
                        alert('저장 실패: ' + profileError.message);
                    } else {
                        alert(`가입 성공! 시작 점수: ${initialScore}점`);
                        setIsSignUp(false);
                    }
                }
            } else {
                const { error } = await supabase.auth.signInWithPassword({ email, password });
                if (error) throw error;
            }
        } catch (error: any) {
            alert(error.error_description || error.message);
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="flex justify-center items-center min-h-screen bg-slate-900 p-4">
            <div className="w-full max-w-md bg-slate-800 p-8 rounded-2xl shadow-2xl border border-slate-700">
                {/* 👇 여기가 바뀌었는지 꼭 확인하세요! (Ver 2) */}
                <h2 className="text-3xl font-black text-white mb-6 text-center">
                    {isSignUp ? '✨ 회원가입 (Ver 2)' : '🎾 RallyGoGo'}
                </h2>

                <form onSubmit={handleAuth} className="space-y-4">
                    <div>
                        <label className="block text-xs text-slate-400 mb-1">Email</label>
                        <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white focus:border-lime-400 outline-none" />
                    </div>
                    <div>
                        <label className="block text-xs text-slate-400 mb-1">Password</label>
                        <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white focus:border-lime-400 outline-none" />
                    </div>

                    {isSignUp && (
                        <div className="space-y-4 animate-fadeIn">
                            <div>
                                <label className="block text-xs text-slate-400 mb-1">Name</label>
                                <input type="text" value={name} onChange={(e) => setName(e.target.value)} required className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white focus:border-lime-400 outline-none" placeholder="홍길동" />
                            </div>

                            <div className="grid grid-cols-1 gap-4">
                                <div>
                                    <label className="block text-xs text-slate-400 mb-1">Gender</label>
                                    <select value={gender} onChange={(e) => setGender(e.target.value)} className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white outline-none">
                                        <option value="Male" className="bg-slate-900 text-white">남성 (Male)</option>
                                        <option value="Female" className="bg-slate-900 text-white">여성 (Female)</option>
                                    </select>
                                </div>
                                <div>
                                    <label className="block text-xs text-slate-400 mb-1">NTRP (실력)</label>
                                    {/* 드롭다운 렌더링 부분 */}
                                    {/* 커스텀 선택 UI로 변경 (네이티브 select 가독성 문제 해결) */}
                                    <div className="border border-slate-600 rounded-lg overflow-hidden bg-slate-900">
                                        <div className="max-h-40 overflow-y-auto custom-scrollbar p-1 space-y-1">
                                            {ntrpOptions.map((opt) => (
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
                            </div>
                            <div className="text-center bg-slate-700/50 p-2 rounded-lg border border-slate-600">
                                <span className="text-xs text-slate-400">예상 시작 ELO 점수: </span>
                                <span className="text-lime-400 font-black text-sm">{getInitialElo(ntrp)}점</span>
                            </div>
                        </div>
                    )}

                    <button type="submit" disabled={loading} className="w-full bg-lime-500 hover:bg-lime-400 text-slate-900 font-bold py-3 rounded-xl transition-all mt-4">
                        {loading ? '처리 중...' : isSignUp ? '가입하기' : '로그인'}
                    </button>
                </form>

                <div className="mt-6 text-center">
                    <button onClick={() => setIsSignUp(!isSignUp)} className="text-sm text-slate-400 hover:text-white underline">
                        {isSignUp ? '이미 계정이 있나요? 로그인' : '계정이 없나요? 회원가입'}
                    </button>
                </div>
            </div>
        </div>
    );
}