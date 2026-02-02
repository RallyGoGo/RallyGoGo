import { useEffect, useState, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import { BettingSystem, Bet } from '../services/bettingSystem';
import { Database } from '../types/database.types';

type MatchRow = Database['public']['Tables']['matches']['Row'];

type Props = {
    isOpen: boolean;
    onClose: () => void;
    myId: string;
};

// Simplified Match Type for Betting List
type BettingMatch = MatchRow & {
    p1_name?: string; p2_name?: string; p3_name?: string; p4_name?: string;
    elo_team1: number; elo_team2: number;
    odds_team1?: number;
    odds_team2?: number;
};

export default function BettingModal({ isOpen, onClose, myId }: Props) {
    const [activeTab, setActiveTab] = useState<'LIVE' | 'HISTORY'>('LIVE');
    const [matches, setMatches] = useState<BettingMatch[]>([]);
    const [myPoint, setMyPoint] = useState<number>(0);
    const [history, setHistory] = useState<Bet[]>([]);
    const [loading, setLoading] = useState(false);
    const [placing, setPlacing] = useState(false);

    // Use useCallback to fix hoisting and dependency issues
    const fetchMyPoint = useCallback(async () => {
        const { data } = await supabase.from('profiles').select('rally_point').eq('id', myId).maybeSingle();
        if (data) setMyPoint(data.rally_point || 0);
    }, [myId]);

    const fetchDraftMatches = useCallback(async () => {
        setLoading(true);
        // ✅ [Fix] Include PLAYING for 5-minute betting window
        const { data: matchesData } = await supabase
            .from('matches')
            .select('*')
            .in('status', ['DRAFT', 'PLAYING'])
            .order('created_at', { ascending: false });

        if (matchesData && matchesData.length > 0) {
            // Filter out matches where betting window closed
            const now = new Date();
            const bettableMatches = matchesData.filter((m) => {
                // If no betting_closes_at set, allow betting (pre-start)
                if (!m.betting_closes_at) return true;
                // If set, check if still within window
                return new Date(m.betting_closes_at) > now;
            });

            // Need names
            const pIds = new Set<string>();
            bettableMatches.forEach((m) => {
                if (m.player_1) pIds.add(m.player_1);
                if (m.player_2) pIds.add(m.player_2);
                if (m.player_3) pIds.add(m.player_3);
                if (m.player_4) pIds.add(m.player_4);
            });

            const { data: pNames } = await supabase
                .from('profiles')
                .select('id, name, elo_mixed_doubles, ntrp')
                .in('id', Array.from(pIds));

            const profilesMap = new Map((pNames || []).map(p => [p.id, p]));

            const enriched = bettableMatches.map((m) => {
                const p1 = m.player_1 ? profilesMap.get(m.player_1) : null;
                const p2 = m.player_2 ? profilesMap.get(m.player_2) : null;
                const p3 = m.player_3 ? profilesMap.get(m.player_3) : null;
                const p4 = m.player_4 ? profilesMap.get(m.player_4) : null;

                // Estimate Team ELO (Avg)
                const t1Elo = ((p1?.elo_mixed_doubles || 1200) + (p2?.elo_mixed_doubles || 1200)) / 2;
                const t2Elo = ((p3?.elo_mixed_doubles || 1200) + (p4?.elo_mixed_doubles || 1200)) / 2;

                return {
                    ...m,
                    p1_name: p1?.name, p2_name: p2?.name, p3_name: p3?.name, p4_name: p4?.name,
                    elo_team1: t1Elo, elo_team2: t2Elo
                } as BettingMatch;
            });
            setMatches(enriched);
        } else {
            setMatches([]);
        }
        setLoading(false);
    }, []);

    const fetchHistory = useCallback(async () => {
        setLoading(true);
        try {
            const bets = await BettingSystem.fetchMyBets(myId);
            setHistory(bets || []);
        } catch (e) {
            console.error(e);
        }
        setLoading(false);
    }, [myId]);

    useEffect(() => {
        if (isOpen) {
            // Data fetching on modal open - valid pattern
            // eslint-disable-next-line react-hooks/set-state-in-effect
            void fetchMyPoint();
            if (activeTab === 'LIVE') void fetchDraftMatches();
            else void fetchHistory();
        }
    }, [isOpen, activeTab, fetchMyPoint, fetchDraftMatches, fetchHistory]);


    const handleBet = async (m: BettingMatch, pick: 'TEAM_1' | 'TEAM_2') => {
        const calcOdds = BettingSystem.calculateOdds(m.elo_team1, m.elo_team2);
        const myOdds = pick === 'TEAM_1' ? calcOdds.team1 : calcOdds.team2;

        const input = prompt(`[${pick === 'TEAM_1' ? 'Team 1' : 'Team 2'}] 승리에 배팅하시겠습니까?\n\n💰 현재 배당률: ${myOdds}배\n💸 보유 포인트: ${myPoint} P\n\n배팅할 포인트를 입력하세요:`);
        if (!input) return;

        const amount = parseInt(input, 10);
        if (isNaN(amount) || amount <= 0) return alert("올바른 금액을 입력하세요.");
        if (amount > myPoint) return alert("보유 포인트가 부족합니다.");

        if (!confirm(`${amount} 포인트를 배팅하시겠습니까? (취소 불가)`)) return;

        setPlacing(true);
        try {
            await BettingSystem.placeBet(m.id, myId, pick, amount, myOdds);
            alert("✅ 배팅 성공! 행운을 빕니다!");
            fetchMyPoint(); // Refresh Point
            fetchDraftMatches(); // Refresh UI
        } catch (e: unknown) {
            const err = e as { message?: string; details?: string };
            alert("🚨 배팅 실패: " + (err.message || err.details || JSON.stringify(e)));
        }
        setPlacing(false);
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
                                    const odds = BettingSystem.calculateOdds(m.elo_team1, m.elo_team2);
                                    return (
                                        <div key={m.id} className="bg-slate-800 rounded-xl border border-slate-700 overflow-hidden shadow-lg relative group">
                                            <div className="bg-slate-900/50 p-2 text-center text-[10px] text-slate-500 font-mono uppercase tracking-widest border-b border-slate-700/50">
                                                Match Preview
                                            </div>
                                            <div className="p-4 flex justify-between items-center gap-2">

                                                {/* Team 1 */}
                                                <div
                                                    onClick={() => handleBet(m, 'TEAM_1')}
                                                    className="flex-1 text-center bg-slate-700/30 hover:bg-lime-900/30 rounded-lg p-2 cursor-pointer transition-all active:scale-95 border border-transparent hover:border-lime-500/50"
                                                >
                                                    <p className="text-xs text-slate-400 mb-1">{m.p1_name}</p>
                                                    <p className="text-xs text-slate-400 mb-2">{m.p2_name}</p>
                                                    <div className="text-xl font-black text-lime-400">x{odds.team1}</div>
                                                </div>

                                                <div className="text-center text-slate-600 font-bold text-xs">VS</div>

                                                {/* Team 2 */}
                                                <div
                                                    onClick={() => handleBet(m, 'TEAM_2')}
                                                    className="flex-1 text-center bg-slate-700/30 hover:bg-rose-900/30 rounded-lg p-2 cursor-pointer transition-all active:scale-95 border border-transparent hover:border-rose-500/50"
                                                >
                                                    <p className="text-xs text-slate-400 mb-1">{m.p3_name}</p>
                                                    <p className="text-xs text-slate-400 mb-2">{m.p4_name}</p>
                                                    <div className="text-xl font-black text-rose-400">x{odds.team2}</div>
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
                                        <p className="text-sm font-bold text-white mt-1">{b.amount.toLocaleString()} P <span className="text-slate-500 text-xs">(@{b.odds_at_bet})</span></p>
                                    </div>
                                    <div className="text-right">
                                        {b.result === 'PENDING' && <span className="text-xs bg-slate-700 text-slate-300 px-2 py-1 rounded">진행중</span>}
                                        {b.result === 'WIN' && <span className="text-xs bg-yellow-600 text-white px-2 py-1 rounded font-bold">WIN (+{Math.floor(b.amount * b.odds_at_bet).toLocaleString()})</span>}
                                        {b.result === 'LOSE' && <span className="text-xs bg-slate-800 text-slate-600 border border-slate-700 px-2 py-1 rounded line-through">LOSE</span>}
                                        {b.result === 'DRAW' && <span className="text-xs bg-slate-700 text-slate-200 px-2 py-1 rounded">DRAW (Refund)</span>}
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}