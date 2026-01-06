-- ========================================================================
-- 20260105_surgical_fix_406_409.sql
-- ========================================================================
-- 외과 수술형 수정: 오류 원인 최소 지점만 교정
-- 406 (Schema Mismatch) & 409 (Constraint Violation) 해결
-- ========================================================================

-- ========================================================================
-- FIX 1: 406 Not Acceptable (Missing Columns)
-- 원인: 프론트엔드가 요청하는 컬럼이 DB에 없음
-- 수정: 누락된 모든 컬럼을 "NULL 허용"으로 추가 (기존 데이터 영향 없음)
-- ========================================================================

-- [PROFILES] Missing Columns
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS emoji TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS rally_point INTEGER DEFAULT 1000;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS departure_time TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_guest BOOLEAN DEFAULT FALSE;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS games_played_today INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_games_history INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_wins INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_losses INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_draws INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS winning_streak INTEGER DEFAULT 0;

-- ELO Columns (if not exists)
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_men_doubles INTEGER DEFAULT 1200;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_women_doubles INTEGER DEFAULT 1200;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_mixed_doubles INTEGER DEFAULT 1200;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_singles INTEGER DEFAULT 1200;

-- [MATCHES] Missing Columns
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS betting_closes_at TIMESTAMPTZ;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS start_time TIMESTAMPTZ;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS end_time TIMESTAMPTZ;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS winner_team VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_category VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_type VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS court_name VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS is_auto_generated BOOLEAN DEFAULT FALSE;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS reported_by UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS confirmed_by UUID;

-- Player & Score Columns (Frontend explicitly selects these vs uuid[])
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS player_1 UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS player_2 UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS player_3 UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS player_4 UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS score_team1 INTEGER;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS score_team2 INTEGER;

-- [QUEUE] Missing Columns
ALTER TABLE public.queue ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;

-- ========================================================================
-- FIX 2: 409 Conflict (Constraint Violation)
-- 원인: matches.status CHECK 제약이 앱에서 사용하는 값('DRAFT' 등)을 거부
-- 수정: CHECK 제약조건의 허용 값 범위 확장 (기존 값 + 신규 값)
-- ========================================================================
ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_status_check;
ALTER TABLE public.matches ADD CONSTRAINT matches_status_check 
    CHECK (status IN (
        'pending', 'completed', 'cancelled', -- Legacy
        'DRAFT', 'PLAYING', 'SCORING', 'PENDING', 'FINISHED', 'DISPUTED' -- App Usage
    ));

-- ========================================================================
-- FIX 3: PostgREST 스키마 캐시 갱신
-- ========================================================================
NOTIFY pgrst, 'reload schema';
