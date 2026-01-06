export type Json =
    | string
    | number
    | boolean
    | null
    | { [key: string]: Json | undefined }
    | Json[]

export interface Database {
    public: {
        Tables: {
            profiles: {
                Row: {
                    id: string
                    email: string | null
                    name: string | null
                    phone: string | null
                    gender: string | null
                    ntrp: number | null
                    elo_singles: number
                    elo_doubles: number // Legacy, prefer elo_mixed_doubles
                    elo_men_doubles: number
                    elo_women_doubles: number
                    elo_mixed_doubles: number
                    role: 'admin' | 'manager' | 'player'
                    is_guest: boolean
                    games_played_today: number
                    rally_point: number
                    departure_time: string | null
                    avatar_url: string | null
                    emoji: string | null
                    created_at: string
                    updated_at: string
                }
                Insert: {
                    id: string
                    email?: string | null
                    name?: string | null
                    is_guest?: boolean
                    // ... allow partials
                }
                Update: {
                    name?: string | null
                    // ... allow partials
                }
            }
            matches: {
                Row: {
                    id: string
                    players: string[] // Legacy array
                    player_1: string | null
                    player_2: string | null
                    player_3: string | null
                    player_4: string | null
                    winner_team: string | null
                    status: 'pending' | 'completed' | 'cancelled' | 'DRAFT' | 'PLAYING' | 'SCORING' | 'PENDING' | 'FINISHED' | 'DISPUTED'
                    score_team1: number | null
                    score_team2: number | null
                    match_category: string | null
                    match_type: string | null
                    court_name: string | null
                    reported_by: string | null
                    confirmed_by: string | null
                    start_time: string | null
                    end_time: string | null
                    betting_closes_at: string | null
                    created_at: string
                }
            }
            queue: {
                Row: {
                    id: string
                    player_id: string
                    priority_score: number
                    is_active: boolean
                    joined_at: string
                    departure_time: string | null
                }
            }
            elo_history: {
                Row: {
                    id: string
                    player_id: string
                    match_type: string
                    elo_score: number
                    delta: number
                    created_at: string
                }
            }
            match_events: {
                Row: {
                    id: string
                    client_request_id: string
                    match_id: string
                    event_type: string
                    version: number
                    payload: Json
                    created_at: string
                }
                Insert: {
                    id?: string
                    client_request_id: string
                    match_id: string
                    event_type: string
                    version?: number
                    payload: Json
                    created_at?: string
                }
                Update: {
                    id?: string
                    client_request_id?: string
                    match_id?: string
                    event_type?: string
                    version?: number
                    payload?: Json
                    created_at?: string
                }
            }
            mvp_votes: {
                Row: {
                    id: string
                    match_id: string
                    voter_id: string
                    target_id: string
                    tag: string
                    created_at: string
                }
                Insert: {
                    id?: string
                    match_id: string
                    voter_id: string
                    target_id: string
                    tag: string
                    created_at?: string
                }
                Update: {
                    id?: string
                    match_id?: string
                    voter_id?: string
                    target_id?: string
                    tag?: string
                    created_at?: string
                }
            }
        }
    }
}
