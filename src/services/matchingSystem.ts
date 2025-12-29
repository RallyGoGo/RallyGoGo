import { supabase } from '../lib/supabase';

// ------------------------------------------------------------------
// Type Definitions
// ------------------------------------------------------------------
export type PlayerProfile = {
    id: string;
    name: string;
    gender: string; // 'Male', 'Female' normalized
    is_guest: boolean;
    ntrp: number;
    elo_men_doubles: number;
    elo_women_doubles: number;
    elo_mixed_doubles: number;
    elo_singles: number;
    games_played_today: number;
};

export type QueueItem = {
    player_id?: string;
    user_id?: string;
    joined_at: string;
    departure_time: string | null;
    profiles: PlayerProfile;
    finalScore: number;
    waitMinutes: number;
};

// ------------------------------------------------------------------
// 1. New Scoring Algorithm (V8.2 - Polished)
// ------------------------------------------------------------------
// (점수 계산 로직은 기존과 동일하며 완벽합니다. 그대로 유지합니다.)
export const calculatePriorityScore = (item: any): number => {
    try {
        const profile = item.profiles || {};
        const now = new Date();
        const joinedAt = new Date(item.joined_at);

        // 1. Time Calculation (Safety Check)
        let waitMinutes = 0;
        if (!isNaN(joinedAt.getTime())) {
            const waitMs = now.getTime() - joinedAt.getTime();
            waitMinutes = Math.floor(waitMs / 60000);
        }

        // 2. Number Conversion (Prevent NaN)
        const gamesPlayed = Number(profile.games_played_today) || 0;

        // A. Base Logic
        const initialBoost = gamesPlayed === 0 ? 5000 : 0;
        const waitScore = waitMinutes * 200;
        const gamePenalty = Math.pow(gamesPlayed, 2) * 500;

        // B. Bonus Logic
        let bonus = 0;
        if (profile.is_guest) {
            const maxElo = Math.max(
                Number(profile.elo_men_doubles) || 0,
                Number(profile.elo_women_doubles) || 0,
                Number(profile.elo_mixed_doubles) || 0
            );
            if (maxElo >= 2000) bonus += 999999;
            else bonus += 3000;
        }

        // C. Last Game Bonus (Safe Parsing)
        if (item.departure_time && typeof item.departure_time === 'string' && item.departure_time.includes(':')) {
            const parts = item.departure_time.split(':');
            const targetH = Number(parts[0]);
            const targetM = Number(parts[1]);

            if (!isNaN(targetH) && !isNaN(targetM)) {
                const targetDate = new Date(now);
                targetDate.setHours(targetH, targetM, 0, 0);

                // Handle late night cases (crossing midnight) if needed, or keep simple
                if (targetDate.getTime() < now.getTime() - 12 * 60 * 60 * 1000) {
                    targetDate.setDate(targetDate.getDate() + 1);
                }

                const diffMinutes = (targetDate.getTime() - now.getTime()) / 60000;
                if (diffMinutes > 0 && diffMinutes <= 40) {
                    bonus += 8000;
                }
            }
        }

        const total = initialBoost + waitScore - gamePenalty + bonus;
        return isNaN(total) ? 0 : Math.round(total);
    } catch (e) {
        return 0; // Absolute fallback
    }
};

// ------------------------------------------------------------------
// 2. Matching Engine (V8.3 - Outlier Protection & Balanced Mix)
// ------------------------------------------------------------------
export const generateV83Match = (queue: QueueItem[]) => {
    // 0. 점수 계산 및 정렬
    const scoredQueue = queue.map(item => ({
        ...item,
        finalScore: calculatePriorityScore(item)
    })).sort((a, b) => b.finalScore - a.finalScore);

    if (scoredQueue.length < 4) return null;

    // -----------------------------------------------------------
    // [Step A] VIP 긴급 매칭 (Guest ELO 2000+)
    // -----------------------------------------------------------
    const vip = scoredQueue.find(p =>
        p.profiles.is_guest &&
        Math.max(p.profiles.elo_men_doubles || 0, p.profiles.elo_women_doubles || 0) >= 2000
    );

    if (vip) {
        const highEloPlayers = scoredQueue
            .filter(p => (p.player_id || p.user_id) !== (vip.player_id || vip.user_id))
            .filter(p => Math.max(p.profiles.elo_men_doubles || 0, p.profiles.elo_women_doubles || 0) >= 1800)
            .slice(0, 3);

        if (highEloPlayers.length === 3) {
            // VIP는 예외적으로 밸런스 로직 없이 최상위 조합 매칭
            return prepareMatchResult([vip, ...highEloPlayers], 'VIP_MATCH', true);
        }
    }

    // -----------------------------------------------------------
    // [Step B] 후보군 추출 (Smart Pooling)
    // -----------------------------------------------------------
    let pool = scoredQueue.slice(0, 6);

    // 성비 불균형 시 와일드카드(7~10위) 투입
    const normalizeGender = (g: string) => g && g.toLowerCase().startsWith('m') ? 'Male' : 'Female';
    const maleCount = pool.filter(p => normalizeGender(p.profiles.gender) === 'Male').length;

    if (maleCount >= 6 || maleCount === 0) {
        const candidates = scoredQueue.slice(6, 10);
        const targetGender = maleCount >= 6 ? 'Female' : 'Male';
        const wildCard = candidates.find(p => normalizeGender(p.profiles.gender) === targetGender);
        if (wildCard) {
            pool.pop();
            pool.push(wildCard);
        }
    }

    // -----------------------------------------------------------
    // [Step C] 최적 4인 선정 및 "외로운 고수" 방지 (Outlier Check)
    // -----------------------------------------------------------
    let selected4: QueueItem[] = [];
    let matchType = 'MIXED';

    // 1차적으로 성비/점수 고려하여 4명 선택
    const men = pool.filter(p => normalizeGender(p.profiles.gender) === 'Male');
    const women = pool.filter(p => normalizeGender(p.profiles.gender) === 'Female');

    if (women.length >= 4) {
        selected4 = women.slice(0, 4);
        matchType = 'WOMEN_D';
    } else if (men.length >= 4) {
        selected4 = men.slice(0, 4);
        matchType = 'MEN_D';
    } else {
        if (men.length >= 2 && women.length >= 2) {
            selected4 = [...men.slice(0, 2), ...women.slice(0, 2)];
        } else {
            selected4 = pool.sort((a, b) => b.finalScore - a.finalScore).slice(0, 4);
        }
        matchType = 'MIXED';
    }

    // 🚨 Outlier Check (핵심 로직 변경)
    // 선택된 4명을 임시로 ELO 정렬해봅니다.
    const tempSorted = [...selected4].sort((a, b) => getElo(b, matchType) - getElo(a, matchType));

    // 1등(고수)과 2등의 점수 차가 400점 이상이면 "1 High + 3 Low" 상황으로 판단
    const eloDiffTop = getElo(tempSorted[0], matchType) - getElo(tempSorted[1], matchType);

    if (eloDiffTop > 400) {
        // [전략 수정] 고수(1등)를 이번 매칭에서 제외(Skip)합니다.
        // Pool에 남아있는 예비 인원(5등, 6등) 중에서 대체자를 찾습니다.
        const outlier = tempSorted[0];
        const reserves = pool.filter(p => !selected4.includes(p)); // 선택되지 않은 나머지 인원

        // Outlier의 성별과 같은 대체자를 찾음 (성비 유지 위해)
        const replacement = reserves.find(p => normalizeGender(p.profiles.gender) === normalizeGender(outlier.profiles.gender));

        if (replacement) {
            // Outlier를 빼고 대체자 투입
            selected4 = selected4.filter(p => p !== outlier);
            selected4.push(replacement);
        } else {
            // 대체자가 없으면... 이번 매칭은 Outlier 때문에 밸런스가 붕괴되므로
            // 차라리 Outlier를 제외하고 3명만 남아서 매칭 실패 처리(다음 틱에 다른 사람 오길 기다림)하거나
            // 어쩔 수 없이 진행해야 한다면 진행.
            // 여기서는 "하수 보호"가 우선이므로, 대체 불가능하면 그냥 진행하되
            // 아래 Step D에서 1+4 배치를 통해 최대한 밸런스를 맞춥니다.
        }
    }

    // -----------------------------------------------------------
    // [Step D] 팀 나누기 (Snake Draft: 1+4 vs 2+3)
    // -----------------------------------------------------------
    // 확정된 4명을 ELO 순으로 최종 정렬
    // (Outlier 로직을 거쳤으므로 1등과 2등 차이가 줄어들었거나, 어쩔 수 없는 경우임)
    const finalSorted = [...selected4].sort((a, b) => getElo(b, matchType) - getElo(a, matchType));

    // ✅ 무조건 1등(고수)+4등(하수) vs 2등(고수)+3등(하수)
    // 이것이 "고수1+하수1 vs 고수1+하수1" 구도입니다.
    const team1 = [finalSorted[0], finalSorted[3]];
    const team2 = [finalSorted[1], finalSorted[2]];

    return {
        players: selected4,
        team1,
        team2,
        matchType,
        playerIds: [
            team1[0].player_id || team1[0].user_id,
            team1[1].player_id || team1[1].user_id,
            team2[0].player_id || team2[0].user_id,
            team2[1].player_id || team2[1].user_id
        ]
    };
};

// --- Helper Functions ---

// ELO 가져오기 (매칭 타입별)
const getElo = (p: QueueItem, type: string) => {
    if (type === 'MEN_D') return p.profiles.elo_men_doubles || 1200;
    if (type === 'WOMEN_D') return p.profiles.elo_women_doubles || 1200;
    return p.profiles.elo_mixed_doubles || 1200;
};

// VIP용 최고 ELO 가져오기
const getMaxElo = (p: QueueItem) => {
    return Math.max(
        p.profiles.elo_men_doubles || 0,
        p.profiles.elo_women_doubles || 0,
        p.profiles.elo_mixed_doubles || 0
    ) || 1200;
};

const prepareMatchResult = (players: QueueItem[], type: string, isVip: boolean = false) => {
    if (isVip) {
        // VIP의 경우도 밸런스 있게 1+4 vs 2+3 (여기서 1은 VIP)
        const sorted = [...players].sort((a, b) => getMaxElo(b) - getMaxElo(a));
        return {
            players,
            team1: [sorted[0], sorted[3]],
            team2: [sorted[1], sorted[2]],
            matchType: type,
            playerIds: players.map(p => p.player_id || p.user_id)
        };
    }

    return {
        players,
        team1: [players[0], players[1]],
        team2: [players[2], players[3]],
        matchType: type,
        playerIds: players.map(p => p.player_id || p.user_id)
    };
};