import { useEffect, useState, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';
import GuestRegistrar from './GuestRegistrar';

type QueueItem = {
    id: string;
    player_id: string;
    joined_at: string;
    arrived_at?: string;
    departure_time: string | null;
    priority_score: number;
    profiles: { email: string; ntrp: number; name?: string; is_guest?: boolean; };
    gamesPlayedToday: number;
    finalScore: number;
};

type Props = { user: User | null };

export default function QueueBoard({ user }: Props) {
    const [queueList, setQueueList] = useState<QueueItem[]>([]);
    const [isGuestModalOpen, setIsGuestModalOpen] = useState(false);

    const formatTime = (isoString: string | null) => {
        if (!isoString) return '--:--';
        return new Date(isoString).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    };

    const fetchQueue = useCallback(async () => {
        try {
            const { data: queueData } = await supabase.from('queue').select('*');
            if (!queueData) return;

            const playerIds = queueData.map(q => q.player_id);
            let profilesData: any[] = [];
            if (playerIds.length > 0) {
                const { data: pData } = await supabase.from('profiles').select('id, email, ntrp, name, is_guest').in('id', playerIds);
                profilesData = pData || [];
            }

            const { data: matches } = await supabase.from('matches').select('player_1, player_2, player_3, player_4').eq('status', 'FINISHED');
            const gameCounts: { [key: string]: number } = {};
            if (matches) {
                matches.forEach(m => {
                    [m.player_1, m.player_2, m.player_3, m.player_4].forEach(pid => { if (pid) gameCounts[pid] = (gameCounts[pid] || 0) + 1; });
                });
            }

            const mergedList = queueData.map((item) => {
                const profile = profilesData?.find(p => p.id === item.player_id) || { email: 'Unknown', ntrp: 2.5, name: 'Unknown' };
                const gamesPlayedToday = gameCounts[item.player_id] || 0;

                let score = item.priority_score || 2.5;
                if (gamesPlayedToday === 0) score += 2000;
                score -= (gamesPlayedToday * 500);
                const waitMins = (Date.now() - new Date(item.joined_at).getTime()) / 60000;
                score += (waitMins * 10);
                if (item.departure_time) score += 500;
                if (profile.is_guest) score += 300;

                return { ...item, profiles: profile, gamesPlayedToday, finalScore: Math.floor(score) };
            });

            setQueueList(mergedList.sort((a: any, b: any) => b.finalScore - a.finalScore));
        } catch (err: any) { console.error(err); }
    }, []);

    useEffect(() => {
        fetchQueue();
        const channel = supabase.channel('public:queue_list').on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => { fetchQueue(); }).subscribe();
        return () => { supabase.removeChannel(channel); };
    }, [fetchQueue]);

    return (
        <div className="bg-slate-800/50 p-6 rounded-2xl border border-white/10 h-full flex flex-col relative">
            <div className="flex items-center justify-between mb-4">
                <h2 className="text-xl font-bold text-white flex items-center gap-2">Current Queue <span className="text-lime-400">({queueList.length})</span></h2>
                <button onClick={() => setIsGuestModalOpen(true)} className="text-xs bg-indigo-600 hover:bg-indigo-500 text-white px-3 py-1.5 rounded-lg font-bold shadow transition-all flex items-center gap-1">🏃 Add Guest</button>
            </div>
            <div className="space-y-3">
                {queueList.length === 0 ? <div className="text-center py-8 text-slate-500 bg-slate-800/30 rounded-xl border border-white/5">No players in queue.</div> : queueList.map((item, index) => (
                    <div key={item.id} className={`relative p-4 rounded-xl border flex items-center justify-between transition-all ${item.player_id === user?.id ? 'bg-lime-500/10 border-lime-500/50 scale-[1.02]' : 'bg-slate-800/80 border-slate-700'}`}>
                        <div className="absolute -left-2 -top-2 w-6 h-6 bg-slate-700 border border-slate-500 rounded-full flex items-center justify-center text-xs font-bold text-white shadow-md z-10">{index + 1}</div>
                        <div className="flex items-center space-x-3">
                            <div className="text-left">
                                <p className="text-white font-bold text-sm flex items-center gap-2">
                                    {item.profiles?.name || item.profiles?.email?.split('@')[0]}
                                    {item.profiles?.is_guest && <span className="text-[9px] bg-indigo-500 text-white px-1 rounded">GUEST</span>}
                                    {item.gamesPlayedToday === 0 && <span className="px-1.5 py-0.5 bg-lime-500 text-slate-900 text-[10px] uppercase font-extrabold rounded-md shadow-sm">New!</span>}
                                </p>
                                <div className="text-xs text-slate-400 flex gap-3 mt-1">
                                    <span>🕒 In: <span className="text-white">{formatTime(item.arrived_at || item.joined_at)}</span></span>
                                    <span>🚪 Out: <span className="text-lime-300 font-mono">{item.departure_time || 'Unknown'}</span></span>
                                </div>
                            </div>
                        </div>
                        <div className="text-right">
                            <p className="text-lime-400 font-bold text-lg">{item.finalScore}</p>
                            <p className="text-slate-500 text-[10px]">Games: {item.gamesPlayedToday}</p>
                        </div>
                    </div>
                ))}
            </div>
            {isGuestModalOpen && <GuestRegistrar onClose={() => setIsGuestModalOpen(false)} onSuccess={() => { fetchQueue(); }} />}
        </div>
    );
}