import { supabase } from '../lib/supabase';
import { updateEloAfterMatch } from './eloSystem';

// 1. 결과 입력 (Report) - 점수를 명확하게 분리해서 입력받음
export const reportMatchResult = async (matchId: string, scoreTeam1: number, scoreTeam2: number, reporterId: string) => {
    // UI에서 "6 : 4"를 입력했더라도, Team1 점수와 Team2 점수를 분리해서 보내야 함

    const { data, error } = await supabase
        .from('matches')
        .update({
            score_team1: scoreTeam1, // DB 컬럼: integer
            score_team2: scoreTeam2, // DB 컬럼: integer
            match_score: `${scoreTeam1}:${scoreTeam2}`, // 표기용 문자열 (선택)
            reported_by: reporterId,
            status: 'pending',
            end_time: new Date().toISOString()
        })
        .eq('id', matchId)
        .select()
        .single();

    if (error) throw error;
    // TODO: 상대 팀에게 푸시 알림 발송 (Verification 요청)
    return data;
};

// 2. 결과 승인 (Confirm) - 승패 판독 및 ELO 반영
export const confirmMatchResult = async (matchId: string, confirmerId: string, isAdmin: boolean = false) => {
    // A. Fetch Match Data
    const { data: match, error } = await supabase
        .from('matches')
        .select('*')
        .eq('id', matchId)
        .single();

    if (error || !match) throw new Error('Match not found');
    if (match.status === 'completed') throw new Error('Match already confirmed');

    // B. Security Check (상대방 검증)
    // DB 컬럼이 player_1, player_2 (Team1) / player_3, player_4 (Team2) 라고 가정
    const team1Ids = [match.player_1, match.player_2].filter(Boolean);
    const team2Ids = [match.player_3, match.player_4].filter(Boolean);

    if (!isAdmin) {
        if (!match.reported_by) throw new Error('Match has not been reported yet.');

        const isReporterTeam1 = team1Ids.includes(match.reported_by);
        const isConfirmerTeam1 = team1Ids.includes(confirmerId);

        // 같은 팀 자가 승인 방지
        if (isReporterTeam1 === isConfirmerTeam1) {
            throw new Error('Permission denied: Only the opposing team can confirm the result.');
        }

        // 제3자 승인 방지
        const isParticipant = [...team1Ids, ...team2Ids].includes(confirmerId);
        if (!isParticipant) {
            throw new Error('Permission denied: You are not a participant.');
        }
    }

    // C. Update Status
    const { error: updateError } = await supabase
        .from('matches')
        .update({
            status: 'completed',
            confirmed_by: confirmerId
        })
        .eq('id', matchId);

    if (updateError) throw updateError;

    // D. ★ Trigger ELO Calculation (Winner Mapping) ★
    // 점수를 비교하여 누가 승자(Team 1 for ELO function)인지 정의해야 함
    const score1 = match.score_team1 || 0;
    const score2 = match.score_team2 || 0;

    // 무승부는 없다고 가정 (테니스는 승패 명확)하거나, ELO 로직에 무승부 처리 추가 필요
    // 여기서는 승자/패자 구조로 넘김
    let winners: string[] = [];
    let losers: string[] = [];

    if (score1 > score2) {
        winners = team1Ids;
        losers = team2Ids;
    } else {
        winners = team2Ids;
        losers = team1Ids;
    }

    // ELO 함수 호출 (V3.1 규격에 맞춤)
    // Refactored updateEloAfterMatch accepts: { match_type, team1_ids, team2_ids, is_tournament }
    await updateEloAfterMatch({
        match_type: match.match_category || 'MIXED', // Key mapping fix: pass category as match_type
        team1_ids: winners, // 승자 팀 ID 배열
        team2_ids: losers,  // 패자 팀 ID 배열
        is_tournament: match.match_type === 'TOURNAMENT' // Check match_type literal
    });

    return { success: true, message: 'Match confirmed and ELO updated.' };
};

// 3. 결과 거절 (Reject)
export const rejectMatchResult = async (matchId: string, rejectorId: string) => {
    const { error } = await supabase
        .from('matches')
        .update({
            status: 'disputed',
            confirmed_by: null
        })
        .eq('id', matchId);

    if (error) throw error;
    // TODO: 관리자에게 알림 전송
    return { success: true, message: 'Match result rejected. Admin notified.' };
};

// 4. 관리자 강제 승인
export const adminForceConfirm = async (matchId: string, adminId: string) => {
    return await confirmMatchResult(matchId, adminId, true);
};
