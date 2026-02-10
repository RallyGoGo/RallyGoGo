import { useEffect, useState, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import { Database } from '../types/database.types';

type MatchRow = Database['public']['Tables']['matches']['Row'];

type Props = {
    isOpen: boolean;
    onClose: () => void;
    myId: string;
};

// Pool data for each match
type PoolData = {
    team1_total: number;
    team2_total: number;
    team1_odds: number;
    team2_odds: number;
    house_rate: number;
    is_settled: boolean;
};

// Enriched match with player names and pool data
type BettingMatch = MatchRow & {
    p1_name?: string;
    p2_name?: string;
    p3_name?: string;
    p4_name?: string;
    pool?: PoolData;
};

// History bet type
type HistoryBet = {
    id: string;
    match_id: string;
    pick_team: string;
    amount: number;
    odds_at_bet: number;
    result: string;
    payout_amount?: number;
    created_at: string;
};

export default function BettingModal({ isOpen, onClose, myId }: Props) {
    const [activeTab, setActiveTab] = useState<'LIVE' | 'HISTORY'>('LIVE');
    const [matches, setMatches] = useState<BettingMatch[]>([]);
    const [myPoint, setMyPoint] = useState<number>(0);
    const [history, setHistory] = useState<HistoryBet[]>([]);
    const [loading, setLoading] = useState(false);
    const [placing, setPlacing] = useState(false);

    // Fetch user's points
    const fetchMyPoint = useCallback(async () => {
        const { data } = await supabase.from('profiles').select('rally_point').eq('id', myId).maybeSingle();
        if (data) setMyPoint(data.rally_point || 0);
    }, [myId]);

    // Fetch pool data for a match
    const fetchPoolData = useCallback(async (matchId: string): Promise<PoolData> => {
        const { data } = await supabase.rpc('get_betting_pool', { p_match_id: matchId });
        if (data && typeof data === 'object' && 'success' in data && data.success) {
            return {
                team1_total: (data as PoolData).team1_total || 0,
                team2_total: (data as PoolData).team2_total || 0,
                team1_odds: (data as PoolData).team1_odds || 2.0,
                team2_odds: (data as PoolData).team2_odds || 2.0,
                house_rate: (data as PoolData).house_rate || 0.05,
                is_settled: (data as PoolData).is_settled || false
            };
        }
        return { team1_total: 0, team2_total: 0, team1_odds: 2.0, team2_odds: 2.0, house_rate: 0.05, is_settled: false };
    }, []);

    // Fetch bettable matches with pool data
    const fetchDraftMatches = useCallback(async () => {
        setLoading(true);
        try {
            const { data: matchesData } = await supabase
                .from('matches')
                .select('*')
                .in('status', ['DRAFT', 'PLAYING'])
                .order('created_at', { ascending: false });

            if (matchesData && matchesData.length > 0) {
                const now = new Date();
                const bettableMatches = matchesData.filter((m) => {
                    if (!m.betting_closes_at) return true;
                    return new Date(m.betting_closes_at) > now;
                });

                // Get player names
                const pIds = new Set<string>();
                bettableMatches.forEach((m) => {
                    if (m.player_1) pIds.add(m.player_1);
                    if (m.player_2) pIds.add(m.player_2);
                    if (m.player_3) pIds.add(m.player_3);
                    if (m.player_4) pIds.add(m.player_4);
                });

                const { data: pNames } = await supabase
                    .from('profiles')
                    .select('id, name')
                    .in('id', Array.from(pIds));

                const profilesMap = new Map((pNames || []).map(p => [p.id, p.name]));

                // Fetch pool data for each match
                const enriched = await Promise.all(bettableMatches.map(async (m) => {
                    const pool = await fetchPoolData(m.id);
                    return {
                        ...m,
                        p1_name: m.player_1 ? profilesMap.get(m.player_1) : undefined,
                        p2_name: m.player_2 ? profilesMap.get(m.player_2) : undefined,
                        p3_name: m.player_3 ? profilesMap.get(m.player_3) : undefined,
                        p4_name: m.player_4 ? profilesMap.get(m.player_4) : undefined,
                        pool
                    } as BettingMatch;
                }));

                setMatches(enriched);
            } else {
                setMatches([]);
            }
        } catch (e) {
            console.error('[BettingModal] fetchDraftMatches error:', e);
            setMatches([]);
        }
        setLoading(false);
    }, [fetchPoolData]);

    // Fetch betting history
    const fetchHistory = useCallback(async () => {
        setLoading(true);
        try {
            const { data } = await supabase
                .from('bets')
                .select('id, match_id, pick_team, amount, odds_at_bet, result, payout_amount, created_at')
                .eq('user_id', myId)
                .order('created_at', { ascending: false })
                .limit(50);
            setHistory((data || []) as HistoryBet[]);
        } catch (e) {
            console.error('[BettingModal] fetchHistory error:', e);
        }
        setLoading(false);
    }, [myId]);

    // On modal open, fetch data
    useEffect(() => {
        if (isOpen) {
            void fetchMyPoint();
            if (activeTab === 'LIVE') void fetchDraftMatches();
            else void fetchHistory();
        }
    }, [isOpen, activeTab, fetchMyPoint, fetchDraftMatches, fetchHistory]);

    // Real-time subscription for pool updates
    useEffect(() => {
        if (!isOpen || activeTab !== 'LIVE') return;

        const channel = supabase
            .channel('betting-pools-live')
            .on('postgres_changes',
                { event: '*', schema: 'public', table: 'betting_pools' },
                async (payload) => {
                    // Update pool data for affected match
                    const poolData = payload.new as { match_id?: string; team1_total?: number; team2_total?: number };
                    if (poolData?.match_id) {
                        setMatches(prev => prev.map(m => {
                            if (m.id === poolData.match_id && poolData.team1_total !== undefined) {
                                const total = (poolData.team1_total || 0) + (poolData.team2_total || 0);
                                const houseRate = 0.05;
                                const net = total * (1 - houseRate);
                                return {
                                    ...m,
                                    pool: {
                                        ...m.pool!,
                                        team1_total: poolData.team1_total || 0,
                                        team2_total: poolData.team2_total || 0,
                                        team1_odds: (poolData.team1_total || 0) > 0 ? Math.max(1.01, +(net / (poolData.team1_total || 1)).toFixed(2)) : 2.0,
                                        team2_odds: (poolData.team2_total || 0) > 0 ? Math.max(1.01, +(net / (poolData.team2_total || 1)).toFixed(2)) : 2.0,
                                    }
                                };
                            }
                            return m;
                        }));
                    }
                })
            .subscribe();

        return () => {
            supabase.removeChannel(channel);
        };
    }, [isOpen, activeTab]);

    const [selectedMatchForBet, setSelectedMatchForBet] = useState<{ match: BettingMatch, pick: 'TEAM_1' | 'TEAM_2' } | null>(null);
    const [betAmount, setBetAmount] = useState<number>(100);

    // Place bet using parimutuel system
    const executeBet = async () => {
        if (!selectedMatchForBet) return;
        const { match, pick } = selectedMatchForBet;
        const amount = betAmount;

        if (amount <= 0) return alert("올바른 금액을 입력하세요.");
        if (amount > myPoint) return alert("보유 포인트가 부족합니다.");

        setPlacing(true);
        try {
            const { data, error } = await supabase.rpc('place_bet_parimutuel', {
                p_match_id: match.id,
                p_pick_team: pick,
                p_amount: amount
            });

            if (error) throw error;

            type BetResponse = { success: boolean; error?: string; message?: string; new_balance?: number; team1_odds?: number; team2_odds?: number };
            const response = data as BetResponse;

            if (![true, 'true'].includes(response.success as any)) {
                if (response.error) throw new Error(response.error);
                throw new Error(response.message || '배팅 실패');
            }

            alert(`✅ 배팅 성공!\n\n현재 배당률: ${pick === 'TEAM_1' ? response.team1_odds?.toFixed(2) : response.team2_odds?.toFixed(2)}x\n잔액: ${response.new_balance?.toLocaleString()} P`);

            // Refresh data
            void fetchMyPoint();
            void fetchDraftMatches();
            setSelectedMatchForBet(null);
        } catch (e: unknown) {
            const err = e as { message?: string };
            alert("🚨 배팅 실패: " + (err.message || JSON.stringify(e)));
        }
        setPlacing(false);
    };

    const handleBetClick = (m: BettingMatch, pick: 'TEAM_1' | 'TEAM_2') => {
        setSelectedMatchForBet({ match: m, pick });
        setBetAmount(100); // Default
    };

    if (!isOpen) return null;

    return (
        <div className="fixed inset-0 z-[100] bg-black/80 backdrop-blur-sm flex items-center justify-center p-4 animate-fadeIn">
            <div className="bg-slate-900 w-full max-w-md rounded-2xl border border-yellow-500/30 shadow-2xl overflow-hidden flex flex-col max-h-[85vh]">

                {/* Header */}
                <div className="bg-gradient-to-r from-slate-900 to-slate-800 p-4 border-b border-slate-700 flex justify-between items-center">
                    <div>
                        <h2 className="text-xl font-black text-yellow-400 italic tracking-tighter">🎰 RALLY TOTO</h2>
                        <p className="text-xs text-slate-400 font-bold">MY POINT: <span className="text-yellow-400 text-lg">{myPoint.toLocaleString()} P</span></p>
                    </div>
                    <button onClick={onClose} className="bg-slate-800 p-2 rounded-full text-slate-400 hover:text-white transition-colors">✕</button>
                </div>

                {/* Parimutuel Badge */}
                <div className="bg-gradient-to-r from-purple-900/50 to-indigo-900/50 px-4 py-2 text-center">
                    <p className="text-xs text-purple-300">
                        <span className="font-bold">📊 패리뮤추얼 방식</span> — 배당률이 실시간으로 변동됩니다
                    </p>
                </div>

                {/* Tabs */}
                <div className="flex border-b border-slate-700">
                    <button onClick={() => setActiveTab('LIVE')} className={`flex-1 py-3 text-sm font-bold transition-all ${activeTab === 'LIVE' ? 'text-yellow-400 border-b-2 border-yellow-400 bg-yellow-900/10' : 'text-slate-500 hover:text-slate-300'}`}>🔥 진행 중 (LIVE)</button>
                    <button onClick={() => setActiveTab('HISTORY')} className={`flex-1 py-3 text-sm font-bold transition-all ${activeTab === 'HISTORY' ? 'text-blue-400 border-b-2 border-blue-400 bg-blue-900/10' : 'text-slate-500 hover:text-slate-300'}`}>📜 내 배팅 내역</button>
                </div>

                {/* Content */}
                <div className="flex-1 overflow-y-auto custom-scrollbar p-4 space-y-4">
                    {loading && <div className="text-center py-10 text-slate-500 font-mono animate-pulse">Loading Chips...</div>}

                    {/* LIVE TAB */}
                    {!loading && activeTab === 'LIVE' && (
                        <>
                            {matches.length === 0 ? (
                                <div className="text-center py-12 text-slate-600">
                                    <p className="text-4xl mb-2">🏜️</p>
                                    <p>현재 배팅 가능한 경기가 없습니다.</p>
                                </div>
                            ) : (
                                matches.map(m => {
                                    const pool = m.pool || { team1_total: 0, team2_total: 0, team1_odds: 2.0, team2_odds: 2.0, house_rate: 0.05, is_settled: false };
                                    const totalPool = pool.team1_total + pool.team2_total;
                                    const t1Pct = totalPool > 0 ? Math.round((pool.team1_total / totalPool) * 100) : 50;
                                    const t2Pct = 100 - t1Pct;

                                    return (
                                        <div key={m.id} className="bg-slate-800 rounded-xl border border-slate-700 overflow-hidden shadow-lg relative group">
                                            {/* Pool Status Bar */}
                                            <div className="bg-slate-900/50 p-2 border-b border-slate-700/50">
                                                <div className="flex justify-between text-[10px] text-slate-400 mb-1">
                                                    <span>풀: {totalPool.toLocaleString()}P</span>
                                                    <span className="text-purple-400">수수료: 5%</span>
                                                </div>
                                                <div className="h-2 bg-slate-700 rounded-full overflow-hidden flex">
                                                    <div className="bg-lime-500 h-full transition-all duration-500" style={{ width: `${t1Pct}%` }} />
                                                    <div className="bg-rose-500 h-full transition-all duration-500" style={{ width: `${t2Pct}%` }} />
                                                </div>
                                                <div className="flex justify-between text-[10px] mt-1">
                                                    <span className="text-lime-400">{pool.team1_total.toLocaleString()}P ({t1Pct}%)</span>
                                                    <span className="text-rose-400">{pool.team2_total.toLocaleString()}P ({t2Pct}%)</span>
                                                </div>
                                            </div>

                                            <div className="p-4 flex justify-between items-center gap-2">
                                                {/* Team 1 */}
                                                <div
                                                    onClick={() => handleBetClick(m, 'TEAM_1')}
                                                    className="flex-1 text-center bg-slate-700/30 hover:bg-lime-900/30 rounded-lg p-3 cursor-pointer transition-all active:scale-95 border border-transparent hover:border-lime-500/50"
                                                >
                                                    <p className="text-xs text-slate-400 mb-1">{m.p1_name || 'Player 1'}</p>
                                                    <p className="text-xs text-slate-400 mb-2">{m.p2_name || 'Player 2'}</p>
                                                    <div className="text-2xl font-black text-lime-400 animate-pulse">x{pool.team1_odds.toFixed(2)}</div>
                                                </div>

                                                <div className="text-center text-slate-600 font-bold text-xs">VS</div>

                                                {/* Team 2 */}
                                                <div
                                                    onClick={() => handleBetClick(m, 'TEAM_2')}
                                                    className="flex-1 text-center bg-slate-700/30 hover:bg-rose-900/30 rounded-lg p-3 cursor-pointer transition-all active:scale-95 border border-transparent hover:border-rose-500/50"
                                                >
                                                    <p className="text-xs text-slate-400 mb-1">{m.p3_name || 'Player 3'}</p>
                                                    <p className="text-xs text-slate-400 mb-2">{m.p4_name || 'Player 4'}</p>
                                                    <div className="text-2xl font-black text-rose-400 animate-pulse">x{pool.team2_odds.toFixed(2)}</div>
                                                </div>
                                            </div>
                                            {placing && <div className="absolute inset-0 bg-black/50 flex items-center justify-center text-yellow-400 font-bold">Processing...</div>}
                                        </div>
                                    );
                                })
                            )}
                        </>
                    )}

                    {/* HISTORY TAB */}
                    {!loading && activeTab === 'HISTORY' && (
                        <div className="space-y-3">
                            {history.length === 0 && <p className="text-center text-slate-500 py-10">아직 배팅 기록이 없습니다.</p>}
                            {history.map(b => (
                                <div key={b.id} className="bg-slate-800 p-3 rounded-lg border border-slate-700 flex justify-between items-center">
                                    <div>
                                        <div className="flex items-center gap-2">
                                            <span className={`text-xs font-bold px-1.5 py-0.5 rounded ${b.pick_team === 'TEAM_1' ? 'bg-lime-900 text-lime-400' : 'bg-rose-900 text-rose-400'}`}>
                                                {b.pick_team === 'TEAM_1' ? 'Team 1' : 'Team 2'}
                                            </span>
                                            <span className="text-xs text-slate-400">{new Date(b.created_at).toLocaleDateString()}</span>
                                        </div>
                                        <p className="text-sm font-bold text-white mt-1">{b.amount.toLocaleString()} P <span className="text-slate-500 text-xs">(@{b.odds_at_bet?.toFixed(2) || '?'})</span></p>
                                    </div>
                                    <div className="text-right">
                                        {(b.result === 'OPEN' || b.result === 'LOCKED') && <span className="text-xs bg-amber-700/50 text-amber-300 px-2 py-1 rounded animate-pulse">⏳ 진행중</span>}
                                        {b.result === 'WON' && (
                                            <div className="flex flex-col items-end gap-0.5">
                                                <span className="text-xs bg-yellow-500 text-slate-900 px-2 py-1 rounded font-black">
                                                    🏆 WIN
                                                </span>
                                                <span className="text-[10px] text-lime-400 font-bold">
                                                    +{((b.payout_amount || 0) - b.amount).toLocaleString()}P 순이익
                                                </span>
                                            </div>
                                        )}
                                        {b.result === 'LOST' && <span className="text-xs bg-slate-800 text-slate-500 border border-slate-700 px-2 py-1 rounded">💔 LOSE</span>}
                                        {b.result === 'DRAW' && <span className="text-xs bg-slate-600 text-slate-200 px-2 py-1 rounded">🤝 DRAW (환급)</span>}
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                </div>

                {/* BETTING CONFIRMATION OVERLAY */}
                {selectedMatchForBet && (
                    <div className="absolute inset-0 z-20 bg-slate-900 flex flex-col p-6 animate-fadeIn">
                        <div className="flex justify-between items-center mb-6">
                            <h3 className="text-xl font-bold text-white">💰 배팅 금액 설정</h3>
                            <button onClick={() => setSelectedMatchForBet(null)} className="text-slate-400 hover:text-white">✕</button>
                        </div>

                        <div className="flex-1 flex flex-col justify-center space-y-6">
                            <div className="text-center">
                                <p className="text-sm text-slate-400 mb-2">선택한 팀</p>
                                <p className={`text-2xl font-black ${selectedMatchForBet.pick === 'TEAM_1' ? 'text-lime-400' : 'text-rose-400'}`}>
                                    {selectedMatchForBet.pick === 'TEAM_1' ? 'Team 1 (Left)' : 'Team 2 (Right)'}
                                </p>
                            </div>

                            <div className="space-y-2">
                                <div className="flex justify-between text-xs text-slate-400">
                                    <span>보유 포인트: {myPoint.toLocaleString()} P</span>
                                    <span>배팅 후 잔액: {(myPoint - betAmount).toLocaleString()} P</span>
                                </div>
                                <input
                                    type="number"
                                    value={betAmount}
                                    onChange={(e) => setBetAmount(Math.min(myPoint, Math.max(0, parseInt(e.target.value) || 0)))}
                                    className="w-full bg-slate-800 border-2 border-yellow-500/50 rounded-xl p-4 text-center text-3xl font-black text-white focus:border-yellow-400 outline-none"
                                />
                            </div>

                            <div className="grid grid-cols-4 gap-2">
                                <button onClick={() => setBetAmount(prev => Math.min(myPoint, prev + 10))} className="bg-slate-700 hover:bg-slate-600 text-white font-bold py-3 rounded-lg">+10</button>
                                <button onClick={() => setBetAmount(prev => Math.min(myPoint, prev + 50))} className="bg-slate-700 hover:bg-slate-600 text-white font-bold py-3 rounded-lg">+50</button>
                                <button onClick={() => setBetAmount(prev => Math.min(myPoint, prev + 100))} className="bg-slate-700 hover:bg-slate-600 text-white font-bold py-3 rounded-lg">+100</button>
                                <button onClick={() => setBetAmount(myPoint)} className="bg-yellow-600/50 hover:bg-yellow-600 text-yellow-100 font-bold py-3 rounded-lg border border-yellow-500">ALL</button>
                            </div>

                            <div className="grid grid-cols-2 gap-2 mt-2">
                                <button onClick={() => setBetAmount(100)} className="bg-slate-800 text-slate-400 text-xs py-2 rounded">Reset (100)</button>
                                <button onClick={() => setBetAmount(500)} className="bg-slate-800 text-slate-400 text-xs py-2 rounded">500 Flat</button>
                            </div>

                            <button
                                onClick={executeBet}
                                disabled={placing || betAmount <= 0}
                                className="w-full py-4 bg-gradient-to-r from-yellow-500 to-amber-600 hover:from-yellow-400 hover:to-amber-500 text-black font-black text-xl rounded-xl shadow-lg disabled:opacity-50 mt-4"
                            >
                                {placing ? '처리 중...' : `${betAmount.toLocaleString()} P 배팅하기`}
                            </button>

                            <p className="text-[10px] text-center text-slate-500">
                                ※ 배당률은 실시간 변동되며 경기 시작 시 확정됩니다.<br />
                                (상대 배팅이 없을 경우 배당률이 1.01에 근접할 수 있습니다)
                            </p>
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
}