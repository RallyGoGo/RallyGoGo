import { useState, useEffect } from 'react';
import { supabase } from './lib/supabase';

import Auth from './components/Auth';
// ✅ Ranking.tsx를 불러옵니다.
import Ranking from './components/Ranking';

import JoinQueue from './components/JoinQueue';
import QueueBoard from './components/QueueBoard';
import CourtBoard from './components/CourtBoard';
import MyStatsModal from './components/MyStatsModal';
import AdminDashboard from './components/AdminDashboard';
import BettingModal from './components/BettingModal';

interface Profile {
  name: string;
  ntrp: number;
  gender: string;
  emoji?: string;
}

export default function App() {
  const [session, setSession] = useState<any>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [activeTab, setActiveTab] = useState<'PLAY' | 'RANK'>('PLAY');

  const [isMyPageOpen, setIsMyPageOpen] = useState(false);
  const [isAdminOpen, setIsAdminOpen] = useState(false);
  const [isBettingOpen, setIsBettingOpen] = useState(false); // [New]
  const [activeNotice, setActiveNotice] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }: any) => {
      setSession(session);
      if (session) fetchProfile(session.user.id);
    });

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event: any, session: any) => {
      setSession(session);
      if (session) fetchProfile(session.user.id);
      else setProfile(null);
    });

    fetchNotice();
    const channel = supabase.channel('public:notices')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'notices' }, () => fetchNotice())
      .subscribe();

    return () => { subscription.unsubscribe(); supabase.removeChannel(channel); };
  }, []);

  const fetchProfile = async (userId: string) => {
    const { data } = await supabase.from('profiles').select('name, ntrp, gender, emoji').eq('id', userId).maybeSingle();
    if (data) setProfile(data);
  };

  const fetchNotice = async () => {
    const { data } = await supabase.from('notices').select('content').eq('is_active', true).order('created_at', { ascending: false }).limit(1).maybeSingle();
    setActiveNotice(data ? data.content : null);
  };

  const handleAdminClick = () => {
    const pin = prompt("🔐 관리자 모드 PIN:");
    if (pin === '0909') setIsAdminOpen(true);
    else if (pin) alert("❌ 땡!");
  };

  if (!session) return <Auth />;

  return (
    <div className="min-h-screen bg-slate-900 text-white font-sans pb-24 animate-fadeIn">

      {/* 헤더 */}
      <header className="p-4 border-b border-white/10 flex justify-between items-center bg-slate-900/80 backdrop-blur-md sticky top-0 z-40 shadow-lg">
        <div className="flex items-center gap-2">
          <h1 className="text-xl font-black bg-clip-text text-transparent bg-gradient-to-r from-lime-400 to-emerald-400">
            RallyGoGo
          </h1>
        </div>
        <div className="flex items-center gap-3">
          <div className="text-right hidden xs:block">
            <p className="font-bold text-sm text-white">{profile?.name || session.user.email.split('@')[0]} 님</p>
            <p className="text-[10px] text-lime-400 font-mono">NTRP {profile?.ntrp?.toFixed(1) || '?.?'}</p>
          </div>
          <div className="flex gap-2">
            <button onClick={handleAdminClick} className="w-8 h-8 rounded-full bg-rose-900/30 border border-rose-500/50 flex items-center justify-center text-xs">🔒</button>
            <button onClick={() => setIsMyPageOpen(true)} className="w-8 h-8 rounded-full bg-slate-700 border border-slate-500 flex items-center justify-center text-sm">⚙️</button>
            <button onClick={() => supabase.auth.signOut()} className="w-8 h-8 rounded-full bg-slate-800 border border-slate-600 flex items-center justify-center text-xs">🚪</button>
          </div>
        </div>
      </header>

      {/* 공지사항 */}
      {activeNotice && <div className="bg-amber-400 text-amber-900 text-sm font-bold py-2 px-4 text-center animate-pulse relative z-30 shadow-md">📢 {activeNotice}</div>}

      {/* 메인 컨텐츠 */}
      <main className="p-4 max-w-7xl mx-auto">
        {activeTab === 'PLAY' ? (
          <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
            <div className="order-1 lg:col-span-4 lg:order-1"><JoinQueue user={session.user} profile={profile} /></div>
            <div className="order-2 lg:col-span-8 lg:order-2 lg:row-span-2"><CourtBoard user={session.user} /></div>
            <div className="order-3 lg:col-span-4 lg:order-3"><QueueBoard user={session.user} /></div>
          </div>
        ) : (
          <div className="max-w-2xl mx-auto min-h-[80vh]">
            {/* 랭킹 보드 표시 */}
            <Ranking user={session.user} />
          </div>
        )}
      </main>

      {/* 하단 탭바 */}
      <div className="fixed bottom-0 left-0 right-0 bg-slate-900 border-t border-white/10 p-3 flex justify-center gap-4 z-50 safe-area-bottom">
        <button onClick={() => setActiveTab('PLAY')} className={`flex-1 max-w-[150px] py-3 rounded-xl font-bold transition-all flex items-center justify-center gap-2 ${activeTab === 'PLAY' ? 'bg-lime-500 text-slate-900 shadow-lg shadow-lime-500/20' : 'bg-slate-800 text-slate-400'}`}><span>🎾</span> Match</button>
        <button onClick={() => setActiveTab('RANK')} className={`flex-1 max-w-[150px] py-3 rounded-xl font-bold transition-all flex items-center justify-center gap-2 ${activeTab === 'RANK' ? 'bg-cyan-500 text-slate-900 shadow-lg shadow-cyan-500/20' : 'bg-slate-800 text-slate-400'}`}><span>🏆</span> Ranking</button>
      </div>

      {/* 모달들 */}
      {isMyPageOpen && <MyStatsModal user={session.user} onClose={() => setIsMyPageOpen(false)} onUpdate={() => fetchProfile(session.user.id)} />}
      {isAdminOpen && <AdminDashboard onClose={() => setIsAdminOpen(false)} />}
      {isBettingOpen && <BettingModal isOpen={isBettingOpen} onClose={() => setIsBettingOpen(false)} myId={session.user.id} />}

      {/* 🎲 Floating Betting Button */}
      {!isBettingOpen && (
        <button
          onClick={() => setIsBettingOpen(true)}
          className="fixed bottom-24 right-4 z-40 bg-yellow-500 text-slate-900 p-4 rounded-full shadow-2xl border-2 border-yellow-300 animate-bounce active:scale-90 transition-transform"
        >
          <span className="text-2xl">🎲</span>
        </button>
      )}
    </div>
  );
}