import { useState } from 'react';
import { supabase } from '../lib/supabase';
import { confirmMatchResult } from '../services/matchVerification';
import { Database } from '../types/supabase';

type EnrichedMatch = any; // Using looser type for compatibility with CourtBoard's usage

interface Props {
    match: EnrichedMatch;
    user: any;
    onClose: () => void;
    onSuccess: () => void;
}

const MVP_TAGS = [
    { label: "🚀 Strong Serve", value: "Strong Serve" },
    { label: "🛡️ Iron Defense", value: "Iron Defense" },
    { label: "🧠 High IQ Play", value: "High IQ Play" },
    { label: "⚡ Lightning Fast", value: "Lightning Fast" },
    { label: "🕸️ Net Dominator", value: "Net Dominator" },
    { label: "🤝 Great Teamwork", value: "Great Teamwork" }
];

export default function MatchReviewModal({ match, user, onClose, onSuccess }: Props) {
    const [selectedMvp, setSelectedMvp] = useState<{ id: string, name: string } | null>(null);
    const [selectedTag, setSelectedTag] = useState<string | null>(null);
    const [loading, setLoading] = useState(false);

    // Identify winners to show in MVP selection
    const winners = match.winner_team === 'TEAM_1'
        ? [{ id: match.player_1, name: match.p1_name }, { id: match.player_2, name: match.p2_name }]
        : [{ id: match.player_3, name: match.p3_name }, { id: match.player_4, name: match.p4_name }];

    // Filter out NULLs (for singles) and SELF (cannot vote for self)
    const candidates = winners.filter(p => p.id && p.id !== user.id);

    const handleSubmit = async () => {
        if (!selectedMvp || !selectedTag) return alert("Please select an MVP and a Reason!");
        setLoading(true);

        try {
            // 1. Submit Vote
            const { error: voteError } = await supabase.from('mvp_votes').insert({
                match_id: match.id,
                voter_id: user.id,
                target_id: selectedMvp.id,
                tag: selectedTag
            });

            if (voteError && voteError.code !== '23505') throw voteError; // Ignore unique constraint violation (already voted)

            // 2. Confirm Match
            await confirmMatchResult(match.id, user.id);

            alert("✅ Match Confirmed & MVP Voted!");
            onSuccess();
            onClose();

        } catch (e: any) {
            console.error(e);
            if (e.message.includes("Match already finished")) {
                alert("⚠️ Match was already confirmed!");
                onSuccess();
                onClose();
            } else {
                alert("Error: " + e.message);
            }
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-fadeIn">
            <div className="bg-slate-800 border-2 border-lime-500/30 rounded-2xl w-full max-w-lg shadow-2xl relative overflow-hidden flex flex-col">
                {/* Header */}
                <div className="bg-gradient-to-r from-lime-600 to-emerald-600 p-4 text-center">
                    <h2 className="text-2xl font-black text-white italic tracking-tighter">MATCH REVIEW</h2>
                    <p className="text-lime-100 text-xs font-bold opacity-80">CONFIRM & VOTE MVP</p>
                </div>

                <div className="p-6 flex flex-col gap-6">
                    {/* A. Match Score */}
                    <div className="flex justify-between items-center bg-slate-900/50 p-4 rounded-xl border border-slate-700">
                        <div className="text-right">
                            <p className="text-xs text-slate-400 font-bold mb-1">TEAM A</p>
                            <p className="text-white font-bold">{match.p1_name}</p>
                            <p className="text-white font-bold">{match.p2_name}</p>
                        </div>
                        <div className="flex flex-col items-center px-4">
                            <span className="text-3xl font-black text-amber-400">{match.score_team1} : {match.score_team2}</span>
                            <span className="text-[10px] text-slate-500 uppercase font-bold mt-1">Final Score</span>
                        </div>
                        <div className="text-left">
                            <p className="text-xs text-slate-400 font-bold mb-1">TEAM B</p>
                            <p className="text-white font-bold">{match.p3_name}</p>
                            <p className="text-white font-bold">{match.p4_name}</p>
                        </div>
                    </div>

                    {/* B. MVP Selection */}
                    <div>
                        <h3 className="text-sm font-bold text-lime-400 uppercase mb-3 flex items-center gap-2">
                            <span>👑 Select MVP</span>
                            <span className="text-[10px] text-slate-500 bg-slate-800 px-2 py-0.5 rounded-full">Winning Team Only</span>
                        </h3>

                        {candidates.length === 0 ? (
                            <p className="text-slate-500 text-center italic text-sm">No eligible candidates (Self-vote disabled or Singles match).</p>
                        ) : (
                            <div className="flex gap-2 mb-4">
                                {candidates.map(p => (
                                    <button
                                        key={p.id}
                                        onClick={() => setSelectedMvp(p)}
                                        className={`flex-1 py-3 px-2 rounded-xl border-2 transition-all ${selectedMvp?.id === p.id ? 'border-lime-500 bg-lime-500/20 text-white' : 'border-slate-700 bg-slate-800 text-slate-400 hover:border-slate-500'}`}
                                    >
                                        <div className="text-xs text-slate-500 mb-1">Candidate</div>
                                        <div className="font-bold">{p.name}</div>
                                    </button>
                                ))}
                            </div>
                        )}

                        {selectedMvp && (
                            <div className="grid grid-cols-2 gap-2 animate-fadeIn">
                                {MVP_TAGS.map(tag => (
                                    <button
                                        key={tag.value}
                                        onClick={() => setSelectedTag(tag.value)}
                                        className={`p-2 rounded-lg text-xs font-bold border transition-all ${selectedTag === tag.value ? 'bg-amber-500 text-slate-900 border-amber-500' : 'bg-slate-800 text-slate-300 border-slate-700 hover:bg-slate-700'}`}
                                    >
                                        {tag.label}
                                    </button>
                                ))}
                            </div>
                        )}
                    </div>
                </div>

                {/* C. Action */}
                <div className="p-4 border-t border-slate-700 flex gap-3">
                    <button onClick={onClose} className="flex-1 py-3 rounded-xl font-bold bg-slate-700 text-slate-300 hover:bg-slate-600">Cancel</button>
                    <button
                        onClick={handleSubmit}
                        disabled={loading || (candidates.length > 0 && (!selectedMvp || !selectedTag))}
                        className="flex-[2] py-3 rounded-xl font-bold bg-gradient-to-r from-lime-500 to-emerald-500 text-slate-900 shadow-lg hover:shadow-lime-500/20 disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                        {loading ? 'Processing...' : '✅ Confirm Match'}
                    </button>
                </div>
            </div>
        </div>
    );
}
