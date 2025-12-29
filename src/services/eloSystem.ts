import { supabase } from '../lib/supabase';

// ------------------------------------------------------------------
// V3.1 ELO Calculation Logic
// ------------------------------------------------------------------

interface EloParams {
    match_type: string; // "MEN_D", "MIXED", "WOMEN_D", "SINGLES"
    team1_ids: string[]; // WINNERS
    team2_ids: string[]; // LOSERS
    is_tournament: boolean;
}

export const updateEloAfterMatch = async (params: EloParams) => {
    // 1. Fetch profiles
    // role, is_guest, games_played_today, total_games_history 등의 컬럼이 필요함
    const pIds = [...params.team1_ids, ...params.team2_ids].filter(Boolean);
    const { data: players, error } = await supabase
        .from('profiles')
        .select('*')
        .in('id', pIds);

    if (error || !players) throw new Error('Failed to fetch player profiles');

    // 2. Select Target ELO Field
    let eloField = 'elo_mixed_doubles';
    if (params.match_type === 'MEN_D') eloField = 'elo_men_doubles';
    if (params.match_type === 'WOMEN_D') eloField = 'elo_women_doubles';
    if (params.match_type === 'SINGLES') eloField = 'elo_singles';

    // 3. Helper to get current ELO
    const getElo = (id: string) => {
        const p = players.find((p: any) => p.id === id);
        return p ? (p[eloField] || 1200) : 1200;
    };

    // 4. Calculate Team Averages
    const team1Ids = params.team1_ids;
    const team2Ids = params.team2_ids;

    const team1Avg = team1Ids.reduce((sum: number, id: string) => sum + getElo(id), 0) / team1Ids.length;
    const team2Avg = team2Ids.reduce((sum: number, id: string) => sum + getElo(id), 0) / team2Ids.length;

    // 5. Calculate Win Probability for Team 1 (Winners)
    const expectedScoreTeam1 = 1 / (1 + Math.pow(10, (team2Avg - team1Avg) / 400));

    // Team 1 is Winner, so actual score is 1.0
    const actualScoreTeam1 = 1.0;

    // 6. Calculate Delta & Prepare Updates
    const updates = players.map((player: any) => {
        const isTeam1 = team1Ids.includes(player.id);
        const actual = isTeam1 ? actualScoreTeam1 : (1.0 - actualScoreTeam1);
        const expected = isTeam1 ? expectedScoreTeam1 : (1.0 - expectedScoreTeam1);

        // --- Dynamic K-Factor Logic (V3.1) ---
        let K = 32; // Regular Default

        // A. Coach (Anchor) - 코치 점수 불변
        if (player.role === 'coach') K = 0;
        // B. Guest (Volatile) - 게스트 점수 급변
        else if (player.is_guest) K = 80;
        // C. Tournament
        else if (params.is_tournament) K = 40;
        // D. New Member (Placement)
        else {
            const totalGames = (player.games_played_today || 0) + (player.total_games_history || 0);
            if (totalGames < 10) K = 64;
            else if ((player[eloField] || 1200) > 1800 && totalGames > 100) K = 20;
        }

        const delta = Math.round(K * (actual - expected));
        const newElo = (player[eloField] || 1200) + delta;

        return {
            id: player.id,
            [eloField]: newElo,
            delta: delta,
            is_guest: player.is_guest
        };
    });

    // 7. Execute Updates
    for (const update of updates) {
        // 변동폭이 0이면(예: 코치) DB 업데이트 생략
        if (update.delta === 0) continue;

        // A. Update Profile
        await supabase
            .from('profiles')
            .update({ [eloField]: update[eloField] }) // 동적 필드 업데이트
            .eq('id', update.id);

        // B. Log History (핵심 수정 사항)
        // delta(변동폭)를 저장해야 히스토리 그래프나 분석이 가능함
        await supabase
            .from('elo_history')
            .insert({
                player_id: update.id,
                match_type: params.match_type, // DB 컬럼명이 match_type이라고 가정
                elo_score: update[eloField],   // 변동 후 최종 점수
                delta: update.delta,           // 변동폭 (+32, -15 등)
                created_at: new Date().toISOString()
            });

        // C. Game Count Increment
        await supabase.rpc('increment_games_played', { user_id: update.id });
    }

    return updates;
};