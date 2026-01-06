-- ========================================================================
-- 20260104_fix_rls_and_access.sql - Fix 406 Errors & Guest Access
-- ========================================================================
-- ROOT CAUSE #1: Missing columns in profiles table (406 Not Acceptable)
-- ROOT CAUSE #2: RLS policies or foreign key constraints blocking guest access
-- PHILOSOPHY: "게스트와 회원의 경계가 느껴지지 않는 ELO 연속성"

-- ========================================================================
-- STEP 0: ADD ALL MISSING COLUMNS TO PROFILES (Critical for 406 Fix!)
-- ========================================================================
-- The 406 error occurs when PostgREST can't find the requested columns
-- Frontend expects these columns but init.sql doesn't define them

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS emoji TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_guest BOOLEAN DEFAULT FALSE;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_men_doubles INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_women_doubles INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_mixed_doubles INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS elo_singles INTEGER;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS ntrp NUMERIC(3,1);
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_wins INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_losses INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_draws INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS winning_streak INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS games_played_today INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_games_history INTEGER DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS departure_time VARCHAR;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS rally_point INTEGER DEFAULT 1000;

-- Update role column to allow 'member' value
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_role_check 
    CHECK (role IN ('admin', 'manager', 'player', 'member', 'coach'));

-- ========================================================================
-- STEP 1: Remove restrictive foreign key on profiles.id (if exists)
-- ========================================================================
-- ❌ PROBLEM: profiles.id references auth.users, but guests don't exist in auth.users
-- ✅ SOLUTION: Remove the FK constraint entirely
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_id_fkey;

-- ========================================================================
-- STEP 2: Ensure elo_history table exists with proper structure
-- ========================================================================
CREATE TABLE IF NOT EXISTS public.elo_history (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    player_id UUID,  -- NO FK to allow orphan records temporarily
    match_type VARCHAR,
    elo_score INTEGER NOT NULL,
    delta INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS on elo_history
ALTER TABLE public.elo_history ENABLE ROW LEVEL SECURITY;

-- ========================================================================
-- STEP 2.5: FIX MATCHES TABLE - Add missing columns and fix constraints
-- ========================================================================
-- ❌ PROBLEM: init.sql status check only allows 'pending','completed','cancelled'
-- ❌ PROBLEM: App uses 'DRAFT','PLAYING','SCORING','FINISHED','PENDING'
-- ✅ SOLUTION: Drop old constraint and add new one with all valid statuses

-- Add missing columns
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS player_1 UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS player_2 UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS player_3 UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS player_4 UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS score_team1 INTEGER;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS score_team2 INTEGER;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS winner_team VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS court_name VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_category VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS match_type VARCHAR;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS start_time TIMESTAMPTZ;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS end_time TIMESTAMPTZ;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS reported_by UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS confirmed_by UUID;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS betting_closes_at TIMESTAMPTZ;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS is_auto_generated BOOLEAN DEFAULT FALSE;

-- Fix status constraint to allow all app states
ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_status_check;
ALTER TABLE public.matches ADD CONSTRAINT matches_status_check 
    CHECK (status IN (
        'pending', 'completed', 'cancelled',  -- Legacy lowercase
        'DRAFT', 'PLAYING', 'SCORING', 'PENDING', 'FINISHED', 'DISPUTED'  -- App uppercase
    ));

-- ========================================================================
-- STEP 2.6: FIX QUEUE TABLE - Remove restrictive FK
-- ========================================================================
ALTER TABLE public.queue DROP CONSTRAINT IF EXISTS queue_player_id_fkey;
ALTER TABLE public.queue ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;

-- ========================================================================
-- STEP 3: PROFILES - Most Critical Table
-- ========================================================================
-- ❌ PROBLEM: auth.uid() = id blocks guest access (guests have no auth.uid)
-- ✅ SOLUTION: Allow all operations, use app-level security

DROP POLICY IF EXISTS "Public profiles are viewable by everyone" ON public.profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
DROP POLICY IF EXISTS "Admins can do all on profiles" ON public.profiles;
DROP POLICY IF EXISTS "Allow public read" ON public.profiles;
DROP POLICY IF EXISTS "Allow insert" ON public.profiles;
DROP POLICY IF EXISTS "Allow update" ON public.profiles;
DROP POLICY IF EXISTS "profiles_select_all" ON public.profiles;
DROP POLICY IF EXISTS "profiles_insert_all" ON public.profiles;
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
DROP POLICY IF EXISTS "profiles_update_all" ON public.profiles;
DROP POLICY IF EXISTS "profiles_delete_admin" ON public.profiles;
DROP POLICY IF EXISTS "profiles_delete_all" ON public.profiles;

-- ★ All operations allowed (Guest-First Design)
CREATE POLICY "profiles_select_all" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "profiles_insert_all" ON public.profiles FOR INSERT WITH CHECK (true);
CREATE POLICY "profiles_update_all" ON public.profiles FOR UPDATE USING (true);
CREATE POLICY "profiles_delete_all" ON public.profiles FOR DELETE USING (true);

-- ========================================================================
-- STEP 4: MATCHES - Match Management
-- ========================================================================
DROP POLICY IF EXISTS "Matches viewable by everyone" ON public.matches;
DROP POLICY IF EXISTS "Admins can do all on matches" ON public.matches;
DROP POLICY IF EXISTS "matches_select_all" ON public.matches;
DROP POLICY IF EXISTS "matches_insert_all" ON public.matches;
DROP POLICY IF EXISTS "matches_update_all" ON public.matches;
DROP POLICY IF EXISTS "matches_delete_all" ON public.matches;

CREATE POLICY "matches_select_all" ON public.matches FOR SELECT USING (true);
CREATE POLICY "matches_insert_all" ON public.matches FOR INSERT WITH CHECK (true);
CREATE POLICY "matches_update_all" ON public.matches FOR UPDATE USING (true);
CREATE POLICY "matches_delete_all" ON public.matches FOR DELETE USING (true);

-- ========================================================================
-- STEP 5: QUEUE - Player Queue Management
-- ========================================================================
DROP POLICY IF EXISTS "Queue viewable by everyone" ON public.queue;
DROP POLICY IF EXISTS "Users can insert themselves into queue" ON public.queue;
DROP POLICY IF EXISTS "Users can delete themselves from queue" ON public.queue;
DROP POLICY IF EXISTS "Admins can do all on queue" ON public.queue;
DROP POLICY IF EXISTS "queue_select_all" ON public.queue;
DROP POLICY IF EXISTS "queue_insert_all" ON public.queue;
DROP POLICY IF EXISTS "queue_update_all" ON public.queue;
DROP POLICY IF EXISTS "queue_delete_all" ON public.queue;

CREATE POLICY "queue_select_all" ON public.queue FOR SELECT USING (true);
CREATE POLICY "queue_insert_all" ON public.queue FOR INSERT WITH CHECK (true);
CREATE POLICY "queue_update_all" ON public.queue FOR UPDATE USING (true);
CREATE POLICY "queue_delete_all" ON public.queue FOR DELETE USING (true);

-- ========================================================================
-- STEP 6: ELO_HISTORY - Score Tracking
-- ========================================================================
DROP POLICY IF EXISTS "elo_history_select_all" ON public.elo_history;
DROP POLICY IF EXISTS "elo_history_insert_all" ON public.elo_history;
DROP POLICY IF EXISTS "elo_history_update_all" ON public.elo_history;
DROP POLICY IF EXISTS "elo_history_delete_all" ON public.elo_history;

CREATE POLICY "elo_history_select_all" ON public.elo_history FOR SELECT USING (true);
CREATE POLICY "elo_history_insert_all" ON public.elo_history FOR INSERT WITH CHECK (true);
CREATE POLICY "elo_history_update_all" ON public.elo_history FOR UPDATE USING (true);
CREATE POLICY "elo_history_delete_all" ON public.elo_history FOR DELETE USING (true);

-- ========================================================================
-- STEP 7: BETS - Betting System
-- ========================================================================
DROP POLICY IF EXISTS "bets_select_all" ON public.bets;
DROP POLICY IF EXISTS "bets_insert_all" ON public.bets;
DROP POLICY IF EXISTS "bets_update_all" ON public.bets;
DROP POLICY IF EXISTS "bets_delete_all" ON public.bets;
DROP POLICY IF EXISTS "Users can view their own bets" ON public.bets;
DROP POLICY IF EXISTS "Users can insert their own bets" ON public.bets;

CREATE POLICY "bets_select_all" ON public.bets FOR SELECT USING (true);
CREATE POLICY "bets_insert_all" ON public.bets FOR INSERT WITH CHECK (true);
CREATE POLICY "bets_update_all" ON public.bets FOR UPDATE USING (true);
CREATE POLICY "bets_delete_all" ON public.bets FOR DELETE USING (true);

-- ========================================================================
-- STEP 8: MVP_VOTES - MVP Voting
-- ========================================================================
DROP POLICY IF EXISTS "Public Read" ON public.mvp_votes;
DROP POLICY IF EXISTS "Authenticated Insert" ON public.mvp_votes;
DROP POLICY IF EXISTS "mvp_votes_select_all" ON public.mvp_votes;
DROP POLICY IF EXISTS "mvp_votes_insert_all" ON public.mvp_votes;
DROP POLICY IF EXISTS "mvp_votes_update_all" ON public.mvp_votes;
DROP POLICY IF EXISTS "mvp_votes_delete_all" ON public.mvp_votes;

CREATE POLICY "mvp_votes_select_all" ON public.mvp_votes FOR SELECT USING (true);
CREATE POLICY "mvp_votes_insert_all" ON public.mvp_votes FOR INSERT WITH CHECK (true);
CREATE POLICY "mvp_votes_update_all" ON public.mvp_votes FOR UPDATE USING (true);
CREATE POLICY "mvp_votes_delete_all" ON public.mvp_votes FOR DELETE USING (true);

-- ========================================================================
-- STEP 9: SEASONS - Season Management
-- ========================================================================
DROP POLICY IF EXISTS "Seasons viewable by everyone" ON public.seasons;
DROP POLICY IF EXISTS "Admins can do all on seasons" ON public.seasons;
DROP POLICY IF EXISTS "seasons_select_all" ON public.seasons;
DROP POLICY IF EXISTS "seasons_insert_all" ON public.seasons;
DROP POLICY IF EXISTS "seasons_update_all" ON public.seasons;
DROP POLICY IF EXISTS "seasons_delete_all" ON public.seasons;

CREATE POLICY "seasons_select_all" ON public.seasons FOR SELECT USING (true);
CREATE POLICY "seasons_insert_all" ON public.seasons FOR INSERT WITH CHECK (true);
CREATE POLICY "seasons_update_all" ON public.seasons FOR UPDATE USING (true);
CREATE POLICY "seasons_delete_all" ON public.seasons FOR DELETE USING (true);

-- ========================================================================
-- STEP 10: Reload schema
-- ========================================================================
NOTIFY pgrst, 'reload schema';

