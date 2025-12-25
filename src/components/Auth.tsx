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

    const handleAuth = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);

        try {
            if (isSignUp) {
                // 1. 회원가입
                const { data, error } = await supabase.auth.signUp({
                    email,
                    password,
                });
                if (error) throw error;

                // 2. 프로필 저장 (중요: elo_doubles가 있으면 안 됩니다!)
                if (data.user) {
                    const { error: profileError } = await supabase.from('profiles').insert({
                        id: data.user.id,
                        email: email,
                        name: name,
                        ntrp: parseFloat(ntrp),
                        gender: gender,
                        // 👇 여기를 잘 보세요! elo_doubles는 없고, 4개로 나뉜 점수만 있어야 합니다.
                        elo_men_doubles: 1250,
                        elo_women_doubles: 1250,
                        elo_mixed_doubles: 1250,
                        elo_singles: 1250
                    });

                    if (profileError) {
                        console.error('Profile save error:', profileError);
                        alert('프로필 저장 실패: ' + profileError.message);
                    } else {
                        alert('가입 성공! 로그인해주세요.');
                        setIsSignUp(false);
                    }
                }
            } else {
                // 3. 로그인
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
        <div className="flex justify-center items-center min-h-screen bg-slate-900 p-4">
            <div className="w-full max-w-md bg-slate-800 p-8 rounded-2xl shadow-2xl border border-slate-700">
                <h2 className="text-3xl font-black text-white mb-6 text-center">
                    {isSignUp ? '✨ 회원가입' : '🎾 RallyGoGo'}
                </h2>

                <form onSubmit={handleAuth} className="space-y-4">
                    <div>
                        <label className="block text-xs text-slate-400 mb-1">Email</label>
                        <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white focus:border-lime-400 outline-none" placeholder="example@gmail.com" />
                    </div>
                    <div>
                        <label className="block text-xs text-slate-400 mb-1">Password</label>
                        <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white focus:border-lime-400 outline-none" placeholder="******" />
                    </div>

                    {isSignUp && (
                        <div className="space-y-4 animate-fadeIn">
                            <div>
                                <label className="block text-xs text-slate-400 mb-1">Name (실명)</label>
                                <input type="text" value={name} onChange={(e) => setName(e.target.value)} required className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white focus:border-lime-400 outline-none" placeholder="홍길동" />
                            </div>
                            <div className="grid grid-cols-2 gap-4">
                                <div>
                                    <label className="block text-xs text-slate-400 mb-1">Gender</label>
                                    <select value={gender} onChange={(e) => setGender(e.target.value)} className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white outline-none">
                                        <option value="Male">남성 (Male)</option>
                                        <option value="Female">여성 (Female)</option>
                                    </select>
                                </div>
                                <div>
                                    <label className="block text-xs text-slate-400 mb-1">NTRP</label>
                                    <select value={ntrp} onChange={(e) => setNtrp(e.target.value)} className="w-full bg-slate-900 border border-slate-600 rounded-lg p-3 text-white outline-none">
                                        {[1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0].map(n => <option key={n} value={n}>{n.toFixed(1)}</option>)}
                                    </select>
                                </div>
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