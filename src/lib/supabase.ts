/// <reference types="vite/client" />
import { createClient } from '@supabase/supabase-js';
import type { Database } from '../types/database.types';

// ============================================================================
// SUPABASE CLIENT CONFIGURATION
// ============================================================================
// Using generated types for full type safety across all queries and RPCs.
// 
// To regenerate types after schema changes:
//   npx supabase gen types typescript --project-id <your-project-id> > src/types/database.types.ts
// Or for local development:
//   npx supabase gen types typescript --local > src/types/database.types.ts
// ============================================================================

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing Supabase environment variables: VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY required');
}

// ============================================================================
// TYPED SUPABASE CLIENT
// ============================================================================
// This provides full IntelliSense for:
//   - Table names and columns (supabase.from('profiles').select(...))
//   - RPC function names and parameters (supabase.rpc('place_bet_v2', {...}))
//   - Return types for all queries
// ============================================================================
export const supabase = createClient<Database>(supabaseUrl, supabaseAnonKey);

// ============================================================================
// TYPE EXPORTS FOR CONVENIENCE
// ============================================================================
// Use these throughout the app for consistent typing

// Table row types
export type Profile = Database['public']['Tables']['profiles']['Row'];
export type Match = Database['public']['Tables']['matches']['Row'];
export type Queue = Database['public']['Tables']['queue']['Row'];
export type Bet = Database['public']['Tables']['bets']['Row'];
export type EloHistory = Database['public']['Tables']['elo_history']['Row'];
export type MvpVote = Database['public']['Tables']['mvp_votes']['Row'];
export type Notice = Database['public']['Tables']['notices']['Row'];

// Insert types (for creating new rows)
export type ProfileInsert = Database['public']['Tables']['profiles']['Insert'];
export type MatchInsert = Database['public']['Tables']['matches']['Insert'];
export type BetInsert = Database['public']['Tables']['bets']['Insert'];

// Update types (for updating existing rows)
export type ProfileUpdate = Database['public']['Tables']['profiles']['Update'];
export type MatchUpdate = Database['public']['Tables']['matches']['Update'];

// Enum types (from database)
export type MatchStatus = Database['public']['Enums']['match_status_t'];
export type BetResult = Database['public']['Enums']['bet_result_t'];
export type UserRole = Database['public']['Enums']['user_role_t'];
export type Gender = Database['public']['Enums']['gender_t'];
export type MatchType = Database['public']['Enums']['match_type_t'];

// ============================================================================
// RPC RESPONSE TYPES
// ============================================================================
// Common response structure for our RPC functions

export type RpcSuccessResponse = {
  success: true;
  [key: string]: unknown;
};

export type RpcErrorResponse = {
  success: false;
  error: string;
  message?: string;
};

export type RpcResponse = RpcSuccessResponse | RpcErrorResponse;

// Specific RPC response types (using type intersection instead of interface extends)
export type PlaceBetResponse = RpcResponse & {
  bet_id?: string;
  new_balance?: number;
  odds?: number;
  amount?: number;
  pick_team?: string;
};

export type FinishMatchResponse = RpcResponse & {
  match_id?: string;
  winner_team?: string;
  elo_updates?: Array<{
    player_id: string;
    old_rating: number;
    new_rating: number;
    delta: number;
  }>;
  bets_settled?: number;
  mvp_voting_open?: boolean;
};

export type JoinQueueResponse = RpcResponse & {
  queue_id?: string;
  player_id?: string;
  is_guest?: boolean;
  was_duplicate?: boolean;
};

export type CreateMatchResponse = RpcResponse & {
  match_id?: string;
  players?: string[];
  status?: string;
};

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * Type guard to check if RPC response is successful
 */
export function isRpcSuccess(response: RpcResponse): response is RpcSuccessResponse {
  return response.success === true;
}

/**
 * Type guard to check if RPC response is an error
 */
export function isRpcError(response: RpcResponse): response is RpcErrorResponse {
  return response.success === false;
}