import { useState } from 'react';
import { supabase } from '../lib/supabase';

interface Props {
    onClose: () => void;
    onSuccess: () => void;
}

export default function GuestRegistrar({ onClose, onSuccess }: Props) {
    const [name, setName] = useState('');
    const [ntrp, setNtrp] = useState('3.0'); // Default
    const [gender, setGender] = useState('Male');
    const [loading, setLoading] = useState(false);

    const handleRegister = async () => {
        if (!name) return alert("Please enter a name.");
        setLoading(true);

        try {
            // 1. Create a Fake UUID for Guest
            const guestId = crypto.randomUUID();

            // 2. Logic for "Harder Game" (Guest Penalty)
            // If a guest says they are 3.0, we register them as 3.25 or 3.5 internally
            // so they get matched with stronger players.
            const realScore = parseFloat(ntrp);
            const boostedScore = realScore + 0.25; // Slight boost for balancing

            // 3. Insert into Profiles
            const { error: profileError } = await supabase.from('profiles').insert({
                id: guestId,
                email: `guest_${Date.now()}@temp.com`, // Fake email for constraints
                name: `${name} (G)`, // Visual tag
                ntrp: boostedScore, // Apply boosted score
                gender: gender,
                is_guest: true,
                admin_memo: `Self-rated: ${realScore}`
            });

            if (profileError) throw profileError;

            // 4. Immediately Add to Queue
            const { error: queueError } = await supabase.from('queue').insert({
                player_id: guestId,
                joined_at: new Date().toISOString(),
                arrived_at: new Date().toISOString(),
                priority_score: boostedScore,
                departure_time: '23:00'
            });

            if (queueError) throw queueError;

            alert(`✅ Guest [${name}] registered & queued!`);
            onSuccess();
            onClose();

        } catch (e: any) {
            alert("Error: " + e.message);
        }
        setLoading(false);
    };

    return (
        <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4">
            <div className="bg-slate-800 border border-slate-600 rounded-2xl w-full max-w-sm p-6 shadow-2xl relative">
                <button onClick={onClose} className="absolute top-4 right-4 text-slate-400 hover:text-white">✕</button>

                <h3 className="text-xl font-bold text-white mb-1">🏃 Guest Registration</h3>
                <p className="text-xs text-slate-400 mb-6">Guests are rated +0.25 higher for balance.</p>

                <div className="space-y-4">
                    <div>
                        <label className="block text-xs text-slate-400 mb-1">Guest Name</label>
                        <input
                            type="text"
                            className="w-full bg-slate-900 border border-slate-700 rounded p-2 text-white focus:border-lime-500 outline-none"
                            placeholder="Ex: Minsoo Kim"
                            value={name}
                            onChange={(e) => setName(e.target.value)}
                        />
                    </div>

                    <div className="flex gap-4">
                        <div className="flex-1">
                            <label className="block text-xs text-slate-400 mb-1">NTRP (Self)</label>
                            <select value={ntrp} onChange={(e) => setNtrp(e.target.value)} className="w-full bg-slate-900 border border-slate-700 rounded p-2 text-white">
                                <option value="1.0">1.0 (Novice)</option>
                                <option value="2.0">2.0</option>
                                <option value="2.5">2.5</option>
                                <option value="3.0">3.0 (Avg)</option>
                                <option value="3.5">3.5</option>
                                <option value="4.0">4.0</option>
                                <option value="4.5">4.5 (Pro)</option>
                            </select>
                        </div>
                        <div className="flex-1">
                            <label className="block text-xs text-slate-400 mb-1">Gender</label>
                            <select value={gender} onChange={(e) => setGender(e.target.value)} className="w-full bg-slate-900 border border-slate-700 rounded p-2 text-white">
                                <option value="Male">Male</option>
                                <option value="Female">Female</option>
                            </select>
                        </div>
                    </div>

                    <button
                        onClick={handleRegister}
                        disabled={loading}
                        className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 text-white font-bold rounded-xl mt-4 shadow-lg disabled:opacity-50"
                    >
                        {loading ? "Registering..." : "Add to Queue"}
                    </button>
                </div>
            </div>
        </div>
    );
}