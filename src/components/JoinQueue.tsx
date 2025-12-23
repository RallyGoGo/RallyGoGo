import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';

type Props = { user: User | null };

export default function JoinQueue({ user }: Props) {
    const [isSearching, setIsSearching] = useState(false);
    const [departureTime, setDepartureTime] = useState('');

    useEffect(() => {
        if (!user) return;
        const checkStatus = async () => {
            const { data } = await supabase.from('queue').select('departure_time').eq('player_id', user.id).maybeSingle();
            if (data) {
                setIsSearching(true);
                if (data.departure_time) setDepartureTime(data.departure_time);
            }
        };
        checkStatus();

        // 내 상태 실시간 감지 (삭제/등록 등)
        const channel = supabase.channel('my_queue_status')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue', filter: `player_id=eq.${user.id}` }, () => checkStatus())
            .subscribe();
        return () => { supabase.removeChannel(channel); };
    }, [user]);

    const handleQueueAction = async () => {
        if (!user) return;
        if (isSearching) {
            await supabase.from('queue').delete().eq('player_id', user.id);
            setIsSearching(false); setDepartureTime('');
        } else {
            if (!departureTime) { alert("⏰ Select Departure Time!"); return; }
            const ntrp = user.user_metadata?.ntrp || 2.5;
            await supabase.from('queue').insert({
                player_id: user.id, priority_score: ntrp, departure_time: departureTime,
                joined_at: new Date().toISOString(), arrived_at: new Date().toISOString()
            });
            setIsSearching(true);
        }
    };

    const handleUpdateTime = async () => {
        if (!user || !isSearching) return;
        await supabase.from('queue').update({ departure_time: departureTime }).eq('player_id', user.id);
        alert("✅ Time Updated!");
    };

    return (
        <div className="w-full bg-white/10 backdrop-blur-md border border-white/20 rounded-2xl shadow-xl p-6 text-center">
            <h2 className="text-xl font-bold text-lime-400 mb-4">Join Queue</h2>
            <div className="flex items-center space-x-2 mb-4">
                <div className="relative w-full">
                    <label className="absolute -top-2 left-3 bg-slate-800 px-1 text-[10px] text-lime-400">Departure Time</label>
                    <input type="time" value={departureTime} onChange={(e) => setDepartureTime(e.target.value)} className="w-full bg-slate-800/50 border border-slate-600 text-white p-3 rounded-lg text-center text-xl focus:border-lime-500 outline-none" />
                </div>
                {isSearching && <button onClick={handleUpdateTime} className="bg-slate-700 hover:bg-slate-600 text-white p-3 rounded-lg border border-slate-500 transition-colors">Update</button>}
            </div>
            <button onClick={handleQueueAction} className={`w-full py-3 font-bold rounded-xl text-lg transition-all shadow-lg flex items-center justify-center space-x-2 ${isSearching ? 'bg-rose-500 hover:bg-rose-400 text-white animate-pulse shadow-rose-500/20' : 'bg-lime-500 hover:bg-lime-400 text-slate-900 hover:shadow-lime-500/20'}`}>
                {isSearching ? <span>🚫 Cancel Searching</span> : <span>🎾 Join Queue</span>}
            </button>
        </div>
    );
}