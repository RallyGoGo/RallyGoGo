/**
 * ARCHITECTURE RULE:
 * - ELO represents long-term player skill
 * - ELO is derived ONLY from base NTRP
 * - Match balance adjustments (e.g. +0.25) NEVER affect ELO
 * - Frontend calculates, RPC validates & commits
 */

export function initialEloFromNtrp(ntrp: number): number {
    switch (ntrp) {
        case 1.0: return 600;
        case 1.5: return 800;
        case 2.0: return 1000;
        case 2.5: return 1100;
        case 3.0: return 1200;
        case 3.5: return 1400;
        case 4.0: return 1600;
        case 4.5: return 1800;
        case 5.0: return 2000;
        case 5.5: return 2200;
        case 6.0: return 2400;
        case 7.0: return 2800;
        default:
            if (ntrp < 2.5) return 1000;
            if (ntrp > 7.0) return 3000;
            return 1200;
    }
}

export const NTRP_OPTIONS = [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 7.0];
