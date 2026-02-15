export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.1"
  }
  public: {
    Tables: {
      admin_operation_log: {
        Row: {
          action: string
          created_at: string | null
          id: string
          new_value: string | null
          old_value: string | null
          operated_by: string
          reason: string | null
          target_id: string | null
          target_type: string
        }
        Insert: {
          action: string
          created_at?: string | null
          id?: string
          new_value?: string | null
          old_value?: string | null
          operated_by: string
          reason?: string | null
          target_id?: string | null
          target_type: string
        }
        Update: {
          action?: string
          created_at?: string | null
          id?: string
          new_value?: string | null
          old_value?: string | null
          operated_by?: string
          reason?: string | null
          target_id?: string | null
          target_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "admin_operation_log_operated_by_fkey"
            columns: ["operated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      bets: {
        Row: {
          amount: number
          created_at: string | null
          id: string
          match_id: string
          odds_at_bet: number
          pick_team: string
          result: Database["public"]["Enums"]["bet_result_t"]
          user_id: string
        }
        Insert: {
          amount: number
          created_at?: string | null
          id?: string
          match_id: string
          odds_at_bet: number
          pick_team: string
          result?: Database["public"]["Enums"]["bet_result_t"]
          user_id: string
        }
        Update: {
          amount?: number
          created_at?: string | null
          id?: string
          match_id?: string
          odds_at_bet?: number
          pick_team?: string
          result?: Database["public"]["Enums"]["bet_result_t"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bets_match_id_fkey"
            columns: ["match_id"]
            isOneToOne: false
            referencedRelation: "matches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bets_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      elo_history: {
        Row: {
          applied_multiplier: number | null
          calculation_version: string | null
          created_at: string | null
          delta: number | null
          id: string
          is_correction: boolean | null
          match_id: string | null
          match_type: Database["public"]["Enums"]["match_type_t"] | null
          new_rating: number
          old_rating: number
          player_id: string
          related_history_id: string | null
          was_guest: boolean | null
        }
        Insert: {
          applied_multiplier?: number | null
          calculation_version?: string | null
          created_at?: string | null
          delta?: number | null
          id?: string
          is_correction?: boolean | null
          match_id?: string | null
          match_type?: Database["public"]["Enums"]["match_type_t"] | null
          new_rating: number
          old_rating: number
          player_id: string
          related_history_id?: string | null
          was_guest?: boolean | null
        }
        Update: {
          applied_multiplier?: number | null
          calculation_version?: string | null
          created_at?: string | null
          delta?: number | null
          id?: string
          is_correction?: boolean | null
          match_id?: string | null
          match_type?: Database["public"]["Enums"]["match_type_t"] | null
          new_rating?: number
          old_rating?: number
          player_id?: string
          related_history_id?: string | null
          was_guest?: boolean | null
        }
        Relationships: [
          {
            foreignKeyName: "elo_history_match_id_fkey"
            columns: ["match_id"]
            isOneToOne: false
            referencedRelation: "matches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "elo_history_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "elo_history_related_history_id_fkey"
            columns: ["related_history_id"]
            isOneToOne: false
            referencedRelation: "elo_history"
            referencedColumns: ["id"]
          },
        ]
      }
      match_audit_log: {
        Row: {
          action: string
          confirmation_type: string | null
          correction_chain_id: string | null
          correction_error: string | null
          correction_finished_at: string | null
          correction_reason: string | null
          correction_started_at: string | null
          correction_status:
          | Database["public"]["Enums"]["correction_status_t"]
          | null
          created_at: string | null
          id: string
          is_force_confirm: boolean | null
          match_id: string
          match_status_after: Database["public"]["Enums"]["match_status_t"]
          match_status_before: Database["public"]["Enums"]["match_status_t"]
          related_action_id: string | null
          score_team1: number | null
          score_team2: number | null
          trigger_role: string
          triggered_by: string
        }
        Insert: {
          action: string
          confirmation_type?: string | null
          correction_chain_id?: string | null
          correction_error?: string | null
          correction_finished_at?: string | null
          correction_reason?: string | null
          correction_started_at?: string | null
          correction_status?:
          | Database["public"]["Enums"]["correction_status_t"]
          | null
          created_at?: string | null
          id?: string
          is_force_confirm?: boolean | null
          match_id: string
          match_status_after: Database["public"]["Enums"]["match_status_t"]
          match_status_before: Database["public"]["Enums"]["match_status_t"]
          related_action_id?: string | null
          score_team1?: number | null
          score_team2?: number | null
          trigger_role: string
          triggered_by: string
        }
        Update: {
          action?: string
          confirmation_type?: string | null
          correction_chain_id?: string | null
          correction_error?: string | null
          correction_finished_at?: string | null
          correction_reason?: string | null
          correction_started_at?: string | null
          correction_status?:
          | Database["public"]["Enums"]["correction_status_t"]
          | null
          created_at?: string | null
          id?: string
          is_force_confirm?: boolean | null
          match_id?: string
          match_status_after?: Database["public"]["Enums"]["match_status_t"]
          match_status_before?: Database["public"]["Enums"]["match_status_t"]
          related_action_id?: string | null
          score_team1?: number | null
          score_team2?: number | null
          trigger_role?: string
          triggered_by?: string
        }
        Relationships: [
          {
            foreignKeyName: "match_audit_log_correction_chain_id_fkey"
            columns: ["correction_chain_id"]
            isOneToOne: false
            referencedRelation: "match_audit_log"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "match_audit_log_match_id_fkey"
            columns: ["match_id"]
            isOneToOne: false
            referencedRelation: "matches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "match_audit_log_triggered_by_fkey"
            columns: ["triggered_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      match_events: {
        Row: {
          client_request_id: string | null
          created_at: string | null
          event_type: string
          id: string
          match_id: string
          payload: Json
          version: number | null
        }
        Insert: {
          client_request_id?: string | null
          created_at?: string | null
          event_type: string
          id?: string
          match_id: string
          payload: Json
          version?: number | null
        }
        Update: {
          client_request_id?: string | null
          created_at?: string | null
          event_type?: string
          id?: string
          match_id?: string
          payload?: Json
          version?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "match_events_match_id_fkey"
            columns: ["match_id"]
            isOneToOne: false
            referencedRelation: "matches"
            referencedColumns: ["id"]
          },
        ]
      }
      matches: {
        Row: {
          betting_closes_at: string | null
          confirmed_by: string | null
          court_name: string | null
          created_at: string | null
          end_time: string | null
          id: string
          is_auto_generated: boolean | null
          match_type: Database["public"]["Enums"]["match_type_t"] | null
          player_1: string | null
          player_2: string | null
          player_3: string | null
          player_4: string | null
          reported_by: string | null
          score_team1: number | null
          score_team2: number | null
          start_time: string | null
          status: Database["public"]["Enums"]["match_status_t"]
          winner_team: string | null
        }
        Insert: {
          betting_closes_at?: string | null
          confirmed_by?: string | null
          court_name?: string | null
          created_at?: string | null
          end_time?: string | null
          id?: string
          is_auto_generated?: boolean | null
          match_type?: Database["public"]["Enums"]["match_type_t"] | null
          player_1?: string | null
          player_2?: string | null
          player_3?: string | null
          player_4?: string | null
          reported_by?: string | null
          score_team1?: number | null
          score_team2?: number | null
          start_time?: string | null
          status?: Database["public"]["Enums"]["match_status_t"]
          winner_team?: string | null
        }
        Update: {
          betting_closes_at?: string | null
          confirmed_by?: string | null
          court_name?: string | null
          created_at?: string | null
          end_time?: string | null
          id?: string
          is_auto_generated?: boolean | null
          match_type?: Database["public"]["Enums"]["match_type_t"] | null
          player_1?: string | null
          player_2?: string | null
          player_3?: string | null
          player_4?: string | null
          reported_by?: string | null
          score_team1?: number | null
          score_team2?: number | null
          start_time?: string | null
          status?: Database["public"]["Enums"]["match_status_t"]
          winner_team?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "matches_confirmed_by_fkey"
            columns: ["confirmed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "matches_player_1_fkey"
            columns: ["player_1"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "matches_player_2_fkey"
            columns: ["player_2"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "matches_player_3_fkey"
            columns: ["player_3"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "matches_player_4_fkey"
            columns: ["player_4"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "matches_reported_by_fkey"
            columns: ["reported_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      mvp_votes: {
        Row: {
          created_at: string | null
          id: string
          match_id: string
          tag: string | null
          target_id: string
          voter_id: string
        }
        Insert: {
          created_at?: string | null
          id?: string
          match_id: string
          tag?: string | null
          target_id: string
          voter_id: string
        }
        Update: {
          created_at?: string | null
          id?: string
          match_id?: string
          tag?: string | null
          target_id?: string
          voter_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "mvp_votes_match_id_fkey"
            columns: ["match_id"]
            isOneToOne: false
            referencedRelation: "matches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "mvp_votes_target_id_fkey"
            columns: ["target_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "mvp_votes_voter_id_fkey"
            columns: ["voter_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      notices: {
        Row: {
          content: string
          created_at: string | null
          id: string
          is_active: boolean | null
        }
        Insert: {
          content: string
          created_at?: string | null
          id?: string
          is_active?: boolean | null
        }
        Update: {
          content?: string
          created_at?: string | null
          id?: string
          is_active?: boolean | null
        }
        Relationships: []
      }
      profile_merge_log: {
        Row: {
          created_at: string | null
          id: string
          merged_by: string
          source_profile: string
          target_profile: string
        }
        Insert: {
          created_at?: string | null
          id?: string
          merged_by: string
          source_profile: string
          target_profile: string
        }
        Update: {
          created_at?: string | null
          id?: string
          merged_by?: string
          source_profile?: string
          target_profile?: string
        }
        Relationships: [
          {
            foreignKeyName: "profile_merge_log_merged_by_fkey"
            columns: ["merged_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          admin_memo: string | null
          avatar_url: string | null
          created_at: string | null
          elo_mens_doubles: number | null
          elo_mixed_doubles: number | null
          elo_singles: number | null
          elo_womens_doubles: number | null
          email: string | null
          emoji: string | null
          games_played_today: number | null
          gender: Database["public"]["Enums"]["gender_t"] | null
          id: string
          is_guest: boolean | null
          name: string
          ntrp: number | null
          phone: string | null
          rally_point: number | null
          role: Database["public"]["Enums"]["user_role_t"] | null
          total_draws: number | null
          total_games_history: number | null
          total_losses: number | null
          total_wins: number | null
          updated_at: string | null
          winning_streak: number | null
        }
        Insert: {
          admin_memo?: string | null
          avatar_url?: string | null
          created_at?: string | null
          elo_mens_doubles?: number | null
          elo_mixed_doubles?: number | null
          elo_singles?: number | null
          elo_womens_doubles?: number | null
          email?: string | null
          emoji?: string | null
          games_played_today?: number | null
          gender?: Database["public"]["Enums"]["gender_t"] | null
          id: string
          is_guest?: boolean | null
          name: string
          ntrp?: number | null
          phone?: string | null
          rally_point?: number | null
          role?: Database["public"]["Enums"]["user_role_t"] | null
          total_draws?: number | null
          total_games_history?: number | null
          total_losses?: number | null
          total_wins?: number | null
          updated_at?: string | null
          winning_streak?: number | null
        }
        Update: {
          admin_memo?: string | null
          avatar_url?: string | null
          created_at?: string | null
          elo_mens_doubles?: number | null
          elo_mixed_doubles?: number | null
          elo_singles?: number | null
          elo_womens_doubles?: number | null
          email?: string | null
          emoji?: string | null
          games_played_today?: number | null
          gender?: Database["public"]["Enums"]["gender_t"] | null
          id?: string
          is_guest?: boolean | null
          name?: string
          ntrp?: number | null
          phone?: string | null
          rally_point?: number | null
          role?: Database["public"]["Enums"]["user_role_t"] | null
          total_draws?: number | null
          total_games_history?: number | null
          total_losses?: number | null
          total_wins?: number | null
          updated_at?: string | null
          winning_streak?: number | null
        }
        Relationships: []
      }
      queue: {
        Row: {
          departure_time: string | null
          id: string
          is_active: boolean | null
          joined_at: string | null
          last_no_show_at: string | null
          no_show_count: number | null
          player_id: string
          priority_score: number | null
        }
        Insert: {
          departure_time?: string | null
          id?: string
          is_active?: boolean | null
          joined_at?: string | null
          last_no_show_at?: string | null
          no_show_count?: number | null
          player_id: string
          priority_score?: number | null
        }
        Update: {
          departure_time?: string | null
          id?: string
          is_active?: boolean | null
          joined_at?: string | null
          last_no_show_at?: string | null
          no_show_count?: number | null
          player_id?: string
          priority_score?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "queue_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      rating_adjustment_log: {
        Row: {
          adjusted_by: string
          created_at: string | null
          id: string
          new_rating: number
          old_rating: number
          player_id: string
          reason: string | null
        }
        Insert: {
          adjusted_by: string
          created_at?: string | null
          id?: string
          new_rating: number
          old_rating: number
          player_id: string
          reason?: string | null
        }
        Update: {
          adjusted_by?: string
          created_at?: string | null
          id?: string
          new_rating?: number
          old_rating?: number
          player_id?: string
          reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "rating_adjustment_log_adjusted_by_fkey"
            columns: ["adjusted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rating_adjustment_log_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      seasons: {
        Row: {
          created_at: string | null
          id: string
          is_active: boolean | null
          title: string
        }
        Insert: {
          created_at?: string | null
          id?: string
          is_active?: boolean | null
          title: string
        }
        Update: {
          created_at?: string | null
          id?: string
          is_active?: boolean | null
          title?: string
        }
        Relationships: []
      }
      system_flags: {
        Row: {
          description: string | null
          key: string
          updated_at: string | null
          updated_by: string | null
          value: boolean
        }
        Insert: {
          description?: string | null
          key: string
          updated_at?: string | null
          updated_by?: string | null
          value?: boolean
        }
        Update: {
          description?: string | null
          key?: string
          updated_at?: string | null
          updated_by?: string | null
          value?: boolean
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      update_queue_departure_time: {
        Args: {
          p_queue_id: string;
          p_departure_time: string;
        };
        Returns: { success: boolean; error?: string };
      };
      remove_guest_from_queue: {
        Args: { p_guest_id: string }
        Returns: Json
      }
      admin_clear_queue: {
        Args: Record<string, never>
        Returns: Json
      }
      get_betting_pool: {
        Args: { p_match_id: string }
        Returns: Json
      }
      place_bet_parimutuel: {
        Args: { p_match_id: string; p_pick_team: string; p_amount: number }
        Returns: Json
      }
      check_and_reset_daily: {
        Args: Record<PropertyKey, never>;
        Returns: boolean;
      };
      cast_mvp_vote: {
        Args: { p_match_id: string; p_tag?: string; p_target_id: string }
        Returns: Json
      }
      admin_confirm_match: {
        Args: { p_match_id: string }
        Returns: Json
      }
      admin_rollback_match: {
        Args: { p_match_id: string; p_reason?: string }
        Returns: Json
      }
      admin_season_soft_reset: {
        Args: Record<PropertyKey, never>
        Returns: Json
      }
      admin_update_profile: {
        Args: {
          p_profile_id: string
          p_name?: string
          p_gender?: string
          p_ntrp?: number
          p_role?: string
          p_elo_mens_doubles?: number
          p_elo_womens_doubles?: number
          p_elo_mixed_doubles?: number
          p_elo_singles?: number
          p_rally_point_delta?: number
        }
        Returns: Json
      }
      cancel_match: {
        Args: { p_match_id: string }
        Returns: Json
      }
      create_match_draft: {
        Args: {
          p_court_name?: string
          p_match_type?: Database["public"]["Enums"]["match_type_t"]
          p_player_ids: string[]
        }
        Returns: Json
      }
      dispute_match: {
        Args: { p_match_id: string }
        Returns: Json
      }
      end_match: {
        Args: { p_match_id: string }
        Returns: Json
      }
      finish_match_v2: {
        Args: {
          p_confirmation_type?: string
          p_match_id: string
          p_team1_score: number
          p_team2_score: number
        }
        Returns: Json
      }
      get_current_user_id: { Args: never; Returns: string }
      get_elo_policy: {
        Args: { p_is_guest: boolean }
        Returns: {
          k_factor: number
          multiplier: number
        }[]
      }
      join_queue: {
        Args: { p_departure_time?: string; p_priority_score?: number }
        Returns: Json
      }
      leave_queue: { Args: never; Returns: Json }
      lock_expired_bets: { Args: { p_match_id?: string }; Returns: number }
      place_bet_v2: {
        Args: { p_amount: number; p_match_id: string; p_pick_team: string }
        Returns: Json
      }
      register_guest_and_enqueue: {
        Args: {
          p_name: string
          p_ntrp: number
          p_gender: string
          p_departure_time: string
        }
        Returns: Json
      }
      report_score: {
        Args: {
          p_match_id: string
          p_team1_score: number
          p_team2_score: number
          p_winner?: string
        }
        Returns: Json
      }
      settle_match_bets: {
        Args: { p_match_id: string; p_winner_team: string }
        Returns: number
      }
      start_match: { Args: { p_match_id: string }; Returns: Json }
      swap_player: {
        Args: { p_match_id: string; p_old_player_id: string; p_new_player_id: string }
        Returns: Json
      }
      remove_expired_from_queue: {
        Args: { p_queue_ids?: string[] | null }
        Returns: Json
      }
      create_profile: {
        Args: { p_name: string; p_ntrp: number; p_gender: string }
        Returns: Json
      }
      convert_guest_to_member: {
        Args: { p_guest_id: string; p_name: string; p_email: string }
        Returns: Json
      }
      admin_add_notice: {
        Args: { p_content: string }
        Returns: Json
      }
      admin_delete_notice: {
        Args: { p_notice_id: string }
        Returns: Json
      }
      update_my_profile: {
        Args: { p_emoji?: string; p_avatar_url?: string }
        Returns: Json
      }
    }
    Enums: {
      bet_result_t: "OPEN" | "LOCKED" | "WON" | "LOST" | "DRAW" | "CANCELLED"
      correction_status_t: "PENDING" | "APPLYING" | "APPLIED" | "FAILED"
      gender_t: "MALE" | "FEMALE" | "OTHER"
      match_status_t:
      | "DRAFT"
      | "PLAYING"
      | "SCORING"
      | "PENDING"
      | "FINISHED"
      | "CANCELLED"
      | "DISPUTED"
      match_type_t: "MIXED" | "MENS_DOUBLES" | "WOMENS_DOUBLES" | "SINGLES"
      user_role_t: "admin" | "player" | "coach"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
  | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
    DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
  : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
    DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
  ? R
  : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
    DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] &
    DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
  ? R
  : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
  | keyof DefaultSchema["Tables"]
  | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
  : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
    Insert: infer I
  }
  ? I
  : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
    Insert: infer I
  }
  ? I
  : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
  | keyof DefaultSchema["Tables"]
  | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
  : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
    Update: infer U
  }
  ? U
  : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
    Update: infer U
  }
  ? U
  : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
  | keyof DefaultSchema["Enums"]
  | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
  : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
  | keyof DefaultSchema["CompositeTypes"]
  | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
  : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  public: {
    Enums: {
      bet_result_t: ["OPEN", "LOCKED", "WON", "LOST", "DRAW", "CANCELLED"],
      correction_status_t: ["PENDING", "APPLYING", "APPLIED", "FAILED"],
      gender_t: ["MALE", "FEMALE", "OTHER"],
      match_status_t: [
        "DRAFT",
        "PLAYING",
        "SCORING",
        "PENDING",
        "FINISHED",
        "CANCELLED",
        "DISPUTED",
      ],
      match_type_t: ["MIXED", "MENS_DOUBLES", "WOMENS_DOUBLES", "SINGLES"],
      user_role_t: ["admin", "player", "coach"],
    },
  },
} as const
