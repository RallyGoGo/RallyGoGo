import { useState, lazy, Suspense, useMemo, useCallback } from 'react';
import { User } from '@supabase/supabase-js';
import { supabase } from './lib/supabase';
import { useRallyData } from './hooks/useRallyData';
import { useAppUpdate } from './hooks/useAppUpdate';

import Auth from './components/Auth';
const JoinQueue = lazy(() => import('./components/JoinQueue'));
const QueueBoard = lazy(() => import('./components/QueueBoard'));
const CourtBoard = lazy(() => import('./components/CourtBoard'));
const MyStatsModal = lazy(() => import('./components/MyStatsModal'));

// ============================================================================
// VERCEL BEST PRACTICES: Dynamic imports for code splitting
// ============================================================================
const Ranking = lazy(() => import('./components/Ranking'));
const AdminDashboard = lazy(() => import('./components/AdminDashboard'));
const BettingModal = lazy(() => import('./components/BettingModal'));

// ============================================================================
// LOADING SPINNER COMPONENT
// ============================================================================
function LoadingSpinner({ message = '로딩 중...' }: { message?: string }) {
  return (
    <div className="min-h-screen bg-slate-900 flex flex-col items-center justify-center gap-4">
      <div className="relative">
        <div className="w-16 h-16 border-4 border-lime-500/30 rounded-full animate-pulse" />
        <div className="absolute inset-0 w-16 h-16 border-4 border-transparent border-t-lime-500 rounded-full animate-spin" />
      </div>
      <p className="text-slate-400 text-sm animate-pulse">{message}</p>
    </div>
  );
}

// ============================================================================
// MAIN APP COMPONENT
// ============================================================================
export default function App() {
  // Use Custom Hook for Data
  const { session, profile, activeNotice, matches, queue, isInitializing, refetch } = useRallyData();
  const { isUpdateAvailable, applyUpdate, dismissUpdate } = useAppUpdate();

  const [activeTab, setActiveTab] = useState<'PLAY' | 'RANK'>('PLAY');

  // Modal states
  const [isMyPageOpen, setIsMyPageOpen] = useState(false);
  const [isAdminOpen, setIsAdminOpen] = useState(false);
  const [isBettingOpen, setIsBettingOpen] = useState(false);

  // ============================================================================
  // DERIVED STATE - Memoized for performance
  // ============================================================================
  const activeMatches = useMemo(() =>
    matches.filter(m => m.status === 'PLAYING' || m.status === 'DRAFT'),
    [matches]
  );

  const isAdmin = useMemo(() =>
    profile?.role === 'admin',
    [profile?.role]
  );

  // ============================================================================
  // EVENT HANDLERS
  // ============================================================================
  const handleAdminClick = useCallback(() => {
    if (isAdmin) {
      setIsAdminOpen(true);
      return;
    }

    const pin = prompt("🔐 관리자 모드 PIN:");
    if (pin === '0909') setIsAdminOpen(true);
    else if (pin) alert("❌ 땡!");
  }, [isAdmin]);

  const handleSignOut = useCallback(async () => {
    await supabase.auth.signOut();
    // Hook will handle state update via auth listener
  }, []);

  const handleProfileUpdate = useCallback(() => {
    if (session?.user?.id) {
      refetch.profile(session.user.id);
    }
  }, [session, refetch]);

  // ============================================================================
  // RENDER: Loading State
  // ============================================================================
  if (isInitializing) {
    return <LoadingSpinner message="RallyGoGo 준비 중..." />;
  }

  // ============================================================================
  // RENDER: Auth Screen (Not logged in)
  // ============================================================================
  if (!session) {
    return <Auth />;
  }

  // ============================================================================
  // RENDER: Main App (Logged in)
  // ============================================================================
  const user: User = session.user;

  return (
    <div className="min-h-screen bg-slate-900 text-white font-sans pb-24 animate-fadeIn">

      {/* 헤더 */}
      <header className="p-4 border-b border-white/10 flex justify-between items-center bg-slate-900/80 backdrop-blur-md sticky top-0 z-40 shadow-lg">
        <div className="flex items-center gap-2">
          <h1 className="text-xl font-black bg-clip-text text-transparent bg-gradient-to-r from-lime-400 to-emerald-400">
            RallyGoGo
          </h1>
          {activeMatches.length > 0 && (
            <span className="px-2 py-0.5 text-xs bg-lime-500/20 text-lime-400 rounded-full border border-lime-500/30 animate-pulse">
              {activeMatches.length} 경기 진행 중
            </span>
          )}
        </div>
        <div className="flex items-center gap-3">
          <div className="text-right hidden xs:block">
            <p className="font-bold text-sm text-white flex items-center gap-1">
              {profile?.emoji && <span>{profile.emoji}</span>}
              {profile?.name || user.email?.split('@')[0] || '사용자'} 님
              {profile?.is_guest && <span className="text-xs text-amber-400">(게스트)</span>}
            </p>
            <p className="text-[10px] text-lime-400 font-mono">
              NTRP {profile?.ntrp?.toFixed(1) || '?.?'} | ELO {profile?.elo_mixed_doubles || 1200}
            </p>
          </div>
          <div className="flex gap-2">
            <button
              onClick={handleAdminClick}
              className={`w-8 h-8 rounded-full flex items-center justify-center text-xs transition-all ${isAdmin
                ? 'bg-rose-500/50 border border-rose-400/70'
                : 'bg-rose-900/30 border border-rose-500/50'
                }`}
              title={isAdmin ? '관리자 대시보드' : '관리자 모드'}
            >
              {isAdmin ? '👑' : '🔒'}
            </button>
            <button
              onClick={() => setIsMyPageOpen(true)}
              className="w-8 h-8 rounded-full bg-slate-700 border border-slate-500 flex items-center justify-center text-sm hover:bg-slate-600 transition-colors"
              title="내 정보"
            >
              ⚙️
            </button>
            <button
              onClick={handleSignOut}
              className="w-8 h-8 rounded-full bg-slate-800 border border-slate-600 flex items-center justify-center text-xs hover:bg-slate-700 transition-colors"
              title="로그아웃"
            >
              🚪
            </button>
          </div>
        </div>
      </header>

      {isUpdateAvailable && (
        <div className="fixed top-20 left-3 right-3 z-[70] bg-cyan-950/95 border border-cyan-500/50 rounded-xl p-3 shadow-2xl">
          <div className="flex items-center justify-between gap-3">
            <p className="text-xs text-cyan-100">
              새 버전이 배포되었습니다. 지금 업데이트하면 최신 기능/수정이 적용됩니다.
            </p>
            <div className="flex items-center gap-2">
              <button
                onClick={dismissUpdate}
                className="px-2 py-1 rounded-md text-xs bg-slate-700 text-slate-200 hover:bg-slate-600"
              >
                나중에
              </button>
              <button
                onClick={applyUpdate}
                className="px-3 py-1 rounded-md text-xs font-bold bg-cyan-500 text-slate-900 hover:bg-cyan-400"
              >
                지금 업데이트
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 공지사항 */}
      {activeNotice && (
        <div className="bg-amber-400 text-amber-900 text-sm font-bold py-2 px-4 text-center animate-pulse relative z-30 shadow-md">
          📢 {activeNotice}
        </div>
      )}

      {/* 메인 컨텐츠 */}
      <main className="p-4 max-w-7xl mx-auto">
        {activeTab === 'PLAY' ? (
          <Suspense fallback={<LoadingSpinner message="경기장 입장 중..." />}>
            <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
              <div className="order-1 lg:col-span-4 lg:order-1">
                <JoinQueue user={user} profile={profile} queue={queue} />
              </div>
              <div className="order-2 lg:col-span-8 lg:order-2 lg:row-span-2">
                <CourtBoard user={user} matches={matches} queue={queue} />
              </div>
              <div className="order-3 lg:col-span-4 lg:order-3">
                <QueueBoard user={user} isAdmin={isAdmin} queue={queue} />
              </div>
            </div>
          </Suspense>
        ) : (
          <div className="max-w-2xl mx-auto min-h-[80vh]">
            <Suspense fallback={<LoadingSpinner message="랭킹 로딩 중..." />}>
              <Ranking user={user} />
            </Suspense>
          </div>
        )}
      </main>

      {/* 하단 탭바 */}
      <div className="fixed bottom-0 left-0 right-0 bg-slate-900 border-t border-white/10 p-3 flex justify-center gap-4 z-50 safe-area-bottom">
        <button
          onClick={() => setActiveTab('PLAY')}
          className={`flex-1 max-w-[150px] py-3 rounded-xl font-bold transition-all flex items-center justify-center gap-2 ${activeTab === 'PLAY'
            ? 'bg-lime-500 text-slate-900 shadow-lg shadow-lime-500/20'
            : 'bg-slate-800 text-slate-400 hover:bg-slate-700'
            }`}
        >
          <span>🎾</span> Match
          {activeMatches.length > 0 && activeTab !== 'PLAY' && (
            <span className="w-2 h-2 bg-lime-400 rounded-full animate-pulse" />
          )}
        </button>
        <button
          onClick={() => setActiveTab('RANK')}
          className={`flex-1 max-w-[150px] py-3 rounded-xl font-bold transition-all flex items-center justify-center gap-2 ${activeTab === 'RANK'
            ? 'bg-cyan-500 text-slate-900 shadow-lg shadow-cyan-500/20'
            : 'bg-slate-800 text-slate-400 hover:bg-slate-700'
            }`}
        >
          <span>🏆</span> Ranking
        </button>
      </div>

      {/* 모달들 */}
      {isMyPageOpen && (
        <Suspense fallback={<div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"><div className="text-white">Loaidng...</div></div>}>
          <MyStatsModal
            user={user}
            onClose={() => setIsMyPageOpen(false)}
            onUpdate={handleProfileUpdate}
          />
        </Suspense>
      )}

      {isAdminOpen && (
        <Suspense fallback={<LoadingSpinner message="관리자 대시보드 로딩 중..." />}>
          <AdminDashboard onClose={() => setIsAdminOpen(false)} />
        </Suspense>
      )}

      {isBettingOpen && (
        <Suspense fallback={<LoadingSpinner message="베팅 로딩 중..." />}>
          <BettingModal
            isOpen={isBettingOpen}
            onClose={() => setIsBettingOpen(false)}
            myId={user.id}
          />
        </Suspense>
      )}

      {/* 🎲 Floating Betting Button */}
      {!isBettingOpen && (
        <button
          onClick={() => setIsBettingOpen(true)}
          className="fixed bottom-24 right-4 z-40 bg-yellow-500 text-slate-900 p-4 rounded-full shadow-2xl border-2 border-yellow-300 animate-bounce active:scale-90 transition-transform hover:bg-yellow-400"
          title="베팅하기"
        >
          <span className="text-2xl">🎲</span>
        </button>
      )}

      {/* 🎾 Queue indicator */}
      {queue.length > 0 && (
        <div className="fixed bottom-24 left-4 z-40 bg-slate-800/90 backdrop-blur-sm text-white px-3 py-2 rounded-full shadow-lg border border-slate-600 text-sm">
          <span className="text-lime-400 font-bold">{queue.length}</span>
          <span className="text-slate-400 ml-1">명 대기 중</span>
        </div>
      )}
    </div>
  );
}
