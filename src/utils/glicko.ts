import { Database } from '../types/supabase';

export type PlayerInput = {
    id: string;
    rating: number; // Current ELO/Rating
    isGuest: boolean;
}

export type EloUpdate = {
    id: string;
    delta: number;
    result: 'WIN' | 'LOSS' | 'DRAW';
    newRating: number;
}

const K_FACTOR = 32;
const GUEST_MULTIPLIER = 1.5;

export const calculateMatchDeltas = (
    team1: PlayerInput[],
    team2: PlayerInput[],
    score1: number,
    score2: number
): EloUpdate[] => {
    // 1. Team Ratings (Average)
    const t1Rating = team1.reduce((acc, p) => acc + p.rating, 0) / (team1.length || 1);
    const t2Rating = team2.reduce((acc, p) => acc + p.rating, 0) / (team2.length || 1);

    // 2. Result
    let t1Actual = 0;
    if (score1 > score2) t1Actual = 1;
    else if (score1 === score2) t1Actual = 0.5;

    const t2Actual = 1 - t1Actual;

    // 3. Expected
    const t1Expected = 1 / (1 + Math.pow(10, (t2Rating - t1Rating) / 400));
    const t2Expected = 1 / (1 + Math.pow(10, (t1Rating - t2Rating) / 400));

    // 4. Base Delta
    const t1BaseDelta = K_FACTOR * (t1Actual - t1Expected);
    const t2BaseDelta = K_FACTOR * (t2Actual - t2Expected);

    // 5. Updates
    const generateUpdates = (team: PlayerInput[], baseDelta: number, actual: number) => {
        return team.map(p => {
            let delta = baseDelta;
            if (p.isGuest) delta *= GUEST_MULTIPLIER;
            return {
                id: p.id,
                delta: Math.round(delta),
                result: actual === 1 ? 'WIN' : actual === 0.5 ? 'DRAW' : 'LOSS',
                newRating: Math.round(p.rating + delta),
            } as EloUpdate;
        });
    };

    return [
        ...generateUpdates(team1, t1BaseDelta, t1Actual),
        ...generateUpdates(team2, t2BaseDelta, t2Actual)
    ];
};
