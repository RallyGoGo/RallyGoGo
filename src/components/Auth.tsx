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

    const [errorMsg, setErrorMsg] = useState<string | null>(null);

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

    // ★ [Fix] Use consistent NTRP * 400 formula
    const getInitialElo = (ntrpValue: string) => {
        const n = parseFloat(ntrpValue);
        return Math.round(n * 400); // NTRP 3.0 = 1200, 3.5 = 1400, 4.0 = 1600
    };

    const handleAuth = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);
        setErrorMsg(null);

        try {
            if (isSignUp) {
                // ★ [Guest→Member Conversion] 기존 게스트 프로필 검색
                // 이름 기반으로 검색 (게스트 이름은 "홍길동 (G)" 형식)
                const searchName = `${name.trim()} (G)`;
                const { data: existingGuest } = await supabase
                    .from('profiles')
                    .select('*')
                    .eq('name', searchName)
                    .eq('is_guest', true)
                    .maybeSingle();

                // 1. Auth 계정 생성
                const { data, error } = await supabase.auth.signUp({ email, password });
                if (error) throw error;

                if (data.user) {
                    if (existingGuest) {
                        // ★ [Case A] 게스트 → 회원 전환 (ELO 승계!)
                        const { error: updateError } = await supabase
                            .from('profiles')
                            .update({
                                id: data.user.id,  // Auth ID로 변경
                                email: email,
                                name: name.trim(),  // "(G)" 제거
                                is_guest: false,
                                // ELO, total_games_history, elo_history는 그대로 유지!
                            })
                            .eq('id', existingGuest.id);

                        if (updateError) {
                            setErrorMsg('게스트 전환 실패: ' + updateError.message);
                        } else {
                            const inheritedElo = existingGuest.elo_mixed_doubles || getInitialElo(ntrp);
                            alert(`✅ 게스트 계정이 회원으로 전환되었습니다!\n\n승계된 ELO: ${inheritedElo}점\n경기 기록: ${existingGuest.total_games_history || 0}경기`);
                            setIsSignUp(false);
                        }
                    } else {
                        // ★ [Case B] 신규 회원 생성 (기존 로직)
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
                            setErrorMsg('프로필 저장 실패: ' + profileError.message);
                        } else {
                            alert(`가입 성공! 시작 점수: ${initialScore}점`);
                            setIsSignUp(false);
                        }
                    }
                }
            } else {
                const { error } = await supabase.auth.signInWithPassword({ email, password });
                if (error) throw error;
            }
        } catch (error: any) {
            console.error("Auth Error:", error);
            setErrorMsg(error.error_description || error.message || "로그인 실패");
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="flex justify-center items-center min-h-screen bg-slate-900 p-4">
            <div className="w-full max-w-md bg-slate-800 p-8 rounded-2xl shadow-2xl border border-slate-700">
                {/* 👇 여기가 바뀌었는지 꼭 확인하세요! (Ver 3) */}
                <h2 className="text-3xl font-black text-white mb-6 text-center">
                    {isSignUp ? '✨ 회원가입' : '🎾 RallyGoGo'}
                </h2>

                {errorMsg && (
                    <div className="bg-rose-500/10 border border-rose-500 text-rose-500 p-3 rounded-lg text-sm font-bold mb-4 text-center animate-pulse">
                        🚧 {errorMsg}
                    </div>
                )}

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

                    <button type="submit" disabled={loading} className="w-full bg-lime-500 hover:bg-lime-400 text-slate-900 font-bold py-3 rounded-xl transition-all mt-4 disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2">
                        {loading ? (
                            <>
                                <span className="w-4 h-4 border-2 border-slate-900 border-t-transparent rounded-full animate-spin"></span>
                                <span>로그인 중...</span>
                            </>
                        ) : isSignUp ? '가입하기' : '로그인'}
                    </button>
                </form>

                <div className="mt-6 text-center">
                    <button onClick={() => { setIsSignUp(!isSignUp); setErrorMsg(null); }} className="text-sm text-slate-400 hover:text-white underline">
                        {isSignUp ? '이미 계정이 있나요? 로그인' : '계정이 없나요? 회원가입'}
                    </button>
                </div>
            </div>
        </div>
    );
}