import { useState } from 'react';
import { supabase } from '../lib/supabase';

export default function Auth() {
    const [loading, setLoading] = useState(false);
    const [isSignUp, setIsSignUp] = useState(false); // 로그인 vs 회원가입 모드

    // 입력 폼 데이터
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [name, setName] = useState('');
    const [gender, setGender] = useState('Male'); // 기본값 남성
    const [ntrp, setNtrp] = useState(2.5); // 기본 NTRP

    // NTRP 설명 데이터
    const getNtrpDescription = (score: number) => {
        if (score <= 1.5) return "🎾 입문자: 이제 막 레슨을 시작했어요.";
        if (score <= 2.0) return "초급: 랠리가 조금씩 되지만 아직 서툴러요.";
        if (score <= 2.5) return "초중급: 느린 공은 랠리가 가능해요 (동호인 입문).";
        if (score <= 3.0) return "중급: 중간 속도의 공을 꾸준히 넘길 수 있어요.";
        if (score <= 3.5) return "중상급: 네트 플레이가 가능하고 컨트롤이 좋아졌어요.";
        if (score <= 4.0) return "상급: 스핀과 파워를 자유롭게 구사해요 (동호인 고수).";
        if (score <= 4.5) return "최상급: 파워와 꾸준함을 모두 갖췄어요.";
        return "🔥 선수급: 설명이 필요 없는 수준!";
    };

    const handleAuth = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);

        try {
            if (isSignUp) {
                // [회원가입]
                // 1. Supabase 계정 생성
                const { data, error: signUpError } = await supabase.auth.signUp({
                    email,
                    password,
                });
                if (signUpError) throw signUpError;

                // 2. 추가 정보(이름, 성별, NTRP, 초기 ELO)를 profiles 테이블에 저장
                if (data.user) {
                    // 초기 ELO 점수 계산 공식: 기본 1000점 + (NTRP * 100)
                    // 예: NTRP 2.5 = 1250점 시작
                    const initialElo = 1000 + (ntrp * 100);

                    const { error: profileError } = await supabase.from('profiles').insert({
                        id: data.user.id, // 계정 ID와 똑같이 맞춤
                        email: email,
                        name: name,
                        gender: gender,
                        ntrp: ntrp,
                        is_guest: false,
                        // 각종 게임 모드별 초기 점수 설정
                        elo_singles: initialElo,
                        elo_doubles: initialElo,
                        elo_mixed_doubles: initialElo,
                        elo_men_doubles: initialElo,
                        elo_women_doubles: initialElo,
                    });

                    if (profileError) {
                        // 프로필 저장 실패 시 (혹시 모르니 알림)
                        console.error('Profile Error:', profileError);
                        alert('가입은 됐는데 프로필 저장에 실패했습니다. 관리자에게 문의하세요.');
                    } else {
                        alert(`환영합니다, ${name}님! 회원가입이 완료되었습니다.`);
                        setIsSignUp(false); // 로그인 화면으로 전환
                    }
                }
            } else {
                // [로그인]
                const { error } = await supabase.auth.signInWithPassword({
                    email,
                    password,
                });
                if (error) throw error;
            }
        } catch (error: any) {
            alert(error.error_description || error.message);
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="flex flex-col items-center justify-center min-h-screen bg-slate-900 text-white p-4 animate-fadeIn">
            <div className="max-w-md w-full bg-slate-800 p-8 rounded-2xl shadow-xl border border-slate-700">
                <div className="text-center mb-6">
                    <h1 className="text-4xl font-black text-transparent bg-clip-text bg-gradient-to-r from-lime-400 to-emerald-500 mb-2">
                        RallyGoGo 🎾
                    </h1>
                    <p className="text-slate-400">Tennis Match & Ranking System</p>
                </div>

                <form onSubmit={handleAuth} className="space-y-4">
                    {/* 로그인/회원가입 공통: 이메일 & 비번 */}
                    <div>
                        <label className="block text-sm font-bold text-slate-400 mb-1">Email</label>
                        <input type="email" placeholder="email@example.com" value={email} onChange={e => setEmail(e.target.value)} className="w-full bg-slate-900 border border-slate-700 rounded-lg p-3 focus:outline-none focus:border-lime-500" required />
                    </div>
                    <div>
                        <label className="block text-sm font-bold text-slate-400 mb-1">Password</label>
                        <input type="password" placeholder="6자리 이상 입력" value={password} onChange={e => setPassword(e.target.value)} className="w-full bg-slate-900 border border-slate-700 rounded-lg p-3 focus:outline-none focus:border-lime-500" required minLength={6} />
                    </div>

                    {/* ✨ 회원가입 모드일 때만 보이는 추가 정보들 ✨ */}
                    {isSignUp && (
                        <div className="space-y-4 pt-4 border-t border-slate-700 animate-slideDown">
                            <div>
                                <label className="block text-sm font-bold text-slate-400 mb-1">Name (Nickname)</label>
                                <input type="text" placeholder="홍길동" value={name} onChange={e => setName(e.target.value)} className="w-full bg-slate-900 border border-slate-700 rounded-lg p-3 focus:outline-none focus:border-lime-500" required />
                            </div>

                            <div>
                                <label className="block text-sm font-bold text-slate-400 mb-1">Gender</label>
                                <div className="flex gap-4">
                                    <label className={`flex-1 p-3 rounded-lg border cursor-pointer text-center font-bold ${gender === 'Male' ? 'bg-blue-600 border-blue-500' : 'bg-slate-900 border-slate-700'}`}>
                                        <input type="radio" name="gender" value="Male" checked={gender === 'Male'} onChange={() => setGender('Male')} className="hidden" /> 👨 남성
                                    </label>
                                    <label className={`flex-1 p-3 rounded-lg border cursor-pointer text-center font-bold ${gender === 'Female' ? 'bg-rose-600 border-rose-500' : 'bg-slate-900 border-slate-700'}`}>
                                        <input type="radio" name="gender" value="Female" checked={gender === 'Female'} onChange={() => setGender('Female')} className="hidden" /> 👩 여성
                                    </label>
                                </div>
                            </div>

                            <div>
                                <label className="block text-sm font-bold text-slate-400 mb-2 flex justify-between">
                                    <span>NTRP Level</span>
                                    <span className="text-lime-400 font-mono text-lg">{ntrp.toFixed(1)}</span>
                                </label>
                                <input
                                    type="range" min="1.0" max="7.0" step="0.5"
                                    value={ntrp} onChange={e => setNtrp(parseFloat(e.target.value))}
                                    className="w-full accent-lime-500 h-2 bg-slate-700 rounded-lg appearance-none cursor-pointer"
                                />
                                <p className="text-xs text-emerald-400 mt-2 text-center font-medium bg-emerald-400/10 p-2 rounded">
                                    {getNtrpDescription(ntrp)}
                                </p>
                            </div>
                        </div>
                    )}

                    <button type="submit" disabled={loading} className="w-full bg-gradient-to-r from-lime-500 to-lime-600 hover:from-lime-400 hover:to-lime-500 text-slate-900 font-black py-4 rounded-xl text-lg shadow-lg shadow-lime-500/20 mt-6">
                        {loading ? 'Processing...' : (isSignUp ? '✨ Sign Up (가입완료)' : '🚀 Log In')}
                    </button>
                </form>

                <div className="mt-6 text-center">
                    <button onClick={() => setIsSignUp(!isSignUp)} className="text-slate-400 hover:text-white underline text-sm transition-colors">
                        {isSignUp ? '이미 계정이 있나요? 로그인하러 가기' : '아직 계정이 없나요? 회원가입하기'}
                    </button>
                </div>
            </div>
        </div>
    );
}