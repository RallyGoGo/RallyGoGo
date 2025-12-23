import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import type { User } from '@supabase/supabase-js';
import QueueBoard from '../components/QueueBoard';
import CourtBoard from '../components/CourtBoard';

export default function Lobby() {
    const navigate = useNavigate();
    const [user, setUser] = useState<User | null>(null);

    // Fetch User logic (Simplified to just auth check)
    useEffect(() => {
        const checkUser = async () => {
            const { data: { user } } = await supabase.auth.getUser();
            if (user) {
                setUser(user);
            } else {
                navigate('/');
            }
        };
        checkUser();
    }, [navigate]);

    const handleLogout = async () => {
        await supabase.auth.signOut();
        navigate('/');
    };

    return (
        <div className="min-h-screen w-full flex flex-col items-center bg-slate-900 p-4 pt-8">
            {/* Lobby Header */}
            <div className="w-full max-w-4xl flex items-center justify-between mb-8 px-2">
                <div>
                    <h1 className="text-3xl font-bold text-lime-400">RallyGoGo 🎾</h1>
                    <p className="text-slate-400 text-sm">
                        Welcome, <span className="text-white font-semibold">{user?.user_metadata?.name || user?.email?.split('@')[0]}</span>
                    </p>
                </div>
                <button
                    onClick={handleLogout}
                    className="text-slate-500 hover:text-white text-sm transition-colors border border-slate-700 px-3 py-1.5 rounded-lg hover:border-slate-500"
                >
                    Log Out
                </button>
            </div>

            {/* Main Grid Layout */}
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6 w-full max-w-4xl">

                {/* Left Column: Queue Board */}
                <div className="w-full">
                    <QueueBoard user={user} />
                </div>

                {/* Right Column: Active Courts */}
                <div className="w-full">
                    <CourtBoard />
                </div>

            </div>
        </div>
    );
}
