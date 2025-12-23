import { useState, useEffect } from 'react';
import { supabase } from './lib/supabase';
import Auth from './components/Auth';
import JoinQueue from './components/JoinQueue';
import QueueBoard from './components/QueueBoard';
import CourtBoard from './components/CourtBoard';
import RankingBoard from './components/RankingBoard';
import MyStatsModal from './components/MyStatsModal';
import AdminDashboard from './components/AdminDashboard';

export default function App() {
  const [session, setSession] = useState<any>(null);
  const [activeTab, setActiveTab] = useState<'PLAY' | 'RANK'>('PLAY');

  // Modals & Data
  const [isMyPageOpen, setIsMyPageOpen] = useState(false);
  const [isAdminOpen, setIsAdminOpen] = useState(false);
  const [activeNotice, setActiveNotice] = useState<string | null>(null); // ✨ Notice State

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => setSession(session));
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => setSession(session));

    // Fetch initial notice
    fetchNotice();

    // Real-time listener for Notice updates
    const channel = supabase.channel('public:notices')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'notices' }, () => fetchNotice())
      .subscribe();

    return () => { subscription.unsubscribe(); supabase.removeChannel(channel); };
  }, []);

  const fetchNotice = async () => {
    // Get the latest ACTIVE notice
    const { data } = await supabase.from('notices').select('content')
      .eq('is_active', true).order('created_at', { ascending: false }).limit(1).maybeSingle();
    if (data) setActiveNotice(data.content);
    else setActiveNotice(null);
  };

  const handleAdminClick = () => {
    const pin = prompt("🔐 Enter Admin PIN:");
    if (pin === '7777') setIsAdminOpen(true);
    else if (pin) alert("❌ Wrong PIN");
  };

  if (!session) return <Auth />;

  return (
    <div className="min-h-screen bg-slate-900 text-white font-sans pb-24">

      {/* 1. Header */}
      <header className="p-4 border-b border-white/10 flex justify-between items-center bg-slate-900/80 backdrop-blur-md sticky top-0 z-40 shadow-lg">
        <h1 className="text-2xl font-black tracking-tighter flex items-center gap-2">
          RallyGoGo <span className="text-2xl">🎾</span>
        </h1>
        <div className="flex gap-2">
          <button onClick={handleAdminClick} className="w-8 h-8 rounded-full bg-rose-900/30 border border-rose-500/50 flex items-center justify-center hover:bg-rose-900/50 transition-all text-xs">🔒</button>
          <button onClick={() => setIsMyPageOpen(true)} className="w-8 h-8 rounded-full bg-slate-700 border border-slate-500 flex items-center justify-center hover:bg-slate-600 transition-all text-sm">⚙️</button>
          <button onClick={() => supabase.auth.signOut()} className="px-3 py-1 text-xs border border-slate-600 rounded hover:bg-slate-800">Log Out</button>
        </div>
      </header>

      {/* ✨ 📢 NOTICE BANNER */}
      {activeNotice && (
        <div className="bg-amber-400 text-amber-900 text-sm font-bold py-2 px-4 text-center animate-pulse relative z-30 shadow-md">
          📢 {activeNotice}
        </div>
      )}

      {/* 2. Main Content */}
      <main className="p-4 max-w-7xl mx-auto">
        {activeTab === 'PLAY' ? (
          <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
            <div className="order-1 lg:col-span-4 lg:order-1"><JoinQueue user={session.user} /></div>
            <div className="order-2 lg:col-span-8 lg:order-2 lg:row-span-2"><CourtBoard /></div>
            <div className="order-3 lg:col-span-4 lg:order-3"><QueueBoard user={session.user} /></div>
          </div>
        ) : (
          <div className="max-w-3xl mx-auto h-[80vh]"><RankingBoard user={session.user} /></div>
        )}
      </main>

      {/* 3. Bottom Navigation */}
      <div className="fixed bottom-0 left-0 right-0 bg-slate-900 border-t border-white/10 p-3 flex justify-center gap-4 z-50">
        <button onClick={() => setActiveTab('PLAY')} className={`flex-1 max-w-[150px] py-3 rounded-xl font-bold transition-all flex items-center justify-center gap-2 ${activeTab === 'PLAY' ? 'bg-lime-500 text-slate-900' : 'bg-slate-800 text-slate-400'}`}><span>🎾</span> Match</button>
        <button onClick={() => setActiveTab('RANK')} className={`flex-1 max-w-[150px] py-3 rounded-xl font-bold transition-all flex items-center justify-center gap-2 ${activeTab === 'RANK' ? 'bg-cyan-500 text-slate-900' : 'bg-slate-800 text-slate-400'}`}><span>🏆</span> Ranking</button>
      </div>

      {/* Modals */}
      {isMyPageOpen && <MyStatsModal user={session.user} onClose={() => setIsMyPageOpen(false)} onUpdate={() => window.location.reload()} />}
      {isAdminOpen && <AdminDashboard onClose={() => setIsAdminOpen(false)} />}

    </div>
  );
}