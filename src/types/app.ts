
import { Database } from './database.types';

// Helper to access DB types
type QueueRow = Database['public']['Tables']['queue']['Row'];
type ProfileRow = Database['public']['Tables']['profiles']['Row'];

// Queue Item as used in the UI (enriched with Profile)
export interface AppQueueItem extends QueueRow {
    profiles: ProfileRow | null;
    finalScore?: number; // Calculated on client
    waitMinutes?: number; // Calculated on client
}

// Match Item as used in the UI (enriched with Player Names)
type MatchRow = Database['public']['Tables']['matches']['Row'];
export interface AppMatch extends MatchRow {
    p1_name: string;
    p2_name: string;
    p3_name: string;
    p4_name: string;
}
