import { useState } from 'react';
import { supabase } from '../lib/supabase';

export default function Auth() {
    const [loading, setLoading] = useState(false);
    const [email, setEmail] = useState('');

    const handleLogin = async (e: any) => {
        e.preventDefault();
        setLoading(true);
        // Supabase 매직 링크 로그인 (이메일로 링크 발송)
        const { error } = await supabase.auth.signInWithOtp({ email });
        if (error) {
            alert(error.message);
        } else {
            alert('이메일로 로그인 링크가 발송되었습니다! 메일함을 확인해주세요.');
        }
        setLoading(false);
    };

    return (
        <div className="flex flex-col items-center justify-center min-h-screen bg-slate-900 text-white p-4">
            <div className="text-center mb-8">
                <h1 className="text-5xl font-black tracking-tighter mb-2 flex items-center justify-center gap-2">
                    RallyGoGo <span className="text-lime-400">🎾</span>
                </h1>
                <p className="text-slate-400">Tennis Match & Ranking System</p>
            </div>

            <div className="bg-slate-800 border border-slate-700 p-8 rounded-2xl shadow-2xl w-full max-w-md">
                <h2 className="text-2xl font-bold mb-6 text-center">Sign In</h2>

                <form onSubmit={handleLogin} className="space-y-4">
                    <div>
                        <label className="block text-xs text-slate-400 mb-1 ml-1">Email Address</label>
                        <input
                            type="email"
                            placeholder="name@example.com"
                            className="w-full p-4 rounded-xl bg-slate-900 border border-slate-600 focus:border-lime-500 focus:ring-1 focus:ring-lime-500 outline-none transition-all text-white"
                            value={email}
                            onChange={(e) => setEmail(e.target.value)}
                        />
                    </div>

                    <button
                        disabled={loading}
                        className="w-full py-4 bg-lime-500 hover:bg-lime-400 text-slate-900 font-bold rounded-xl shadow-lg hover:shadow-lime-500/20 transition-all disabled:opacity-50 disabled:cursor-not-allowed text-lg"
                    >
                        {loading ? 'Sending Magic Link...' : 'Send Login Link'}
                    </button>
                </form>

                <div className="mt-6 text-center">
                    <p className="text-xs text-slate-500">
                        링크가 안 오나요? 스팸 메일함을 확인해 보세요.
                    </p>
                </div>
            </div>
        </div>
    );
}