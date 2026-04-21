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
    PostgrestVersion: "14.5"
  }
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      audit_events: {
        Row: {
          actor_id: string | null
          id: string
          kind: string
          meta: Json | null
          practice_id: string
          ref_id: string | null
          ts: string
        }
        Insert: {
          actor_id?: string | null
          id?: string
          kind: string
          meta?: Json | null
          practice_id: string
          ref_id?: string | null
          ts?: string
        }
        Update: {
          actor_id?: string | null
          id?: string
          kind?: string
          meta?: Json | null
          practice_id?: string
          ref_id?: string | null
          ts?: string
        }
        Relationships: [
          {
            foreignKeyName: "audit_events_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      clients: {
        Row: {
          client_exercise_defaults: Json
          created_at: string
          deleted_at: string | null
          id: string
          name: string
          practice_id: string
          updated_at: string
          video_consent: Json
        }
        Insert: {
          client_exercise_defaults?: Json
          created_at?: string
          deleted_at?: string | null
          id?: string
          name: string
          practice_id: string
          updated_at?: string
          video_consent?: Json
        }
        Update: {
          client_exercise_defaults?: Json
          created_at?: string
          deleted_at?: string | null
          id?: string
          name?: string
          practice_id?: string
          updated_at?: string
          video_consent?: Json
        }
        Relationships: [
          {
            foreignKeyName: "clients_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      credit_ledger: {
        Row: {
          created_at: string
          delta: number
          id: string
          notes: string | null
          payfast_payment_id: string | null
          plan_id: string | null
          practice_id: string
          type: string
        }
        Insert: {
          created_at?: string
          delta: number
          id?: string
          notes?: string | null
          payfast_payment_id?: string | null
          plan_id?: string | null
          practice_id: string
          type: string
        }
        Update: {
          created_at?: string
          delta?: number
          id?: string
          notes?: string | null
          payfast_payment_id?: string | null
          plan_id?: string | null
          practice_id?: string
          type?: string
        }
        Relationships: [
          {
            foreignKeyName: "credit_ledger_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_ledger_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      error_logs: {
        Row: {
          id: string
          kind: string
          message: string | null
          meta: Json | null
          practice_id: string | null
          severity: string
          sha: string | null
          source: string
          trainer_id: string | null
          ts: string
        }
        Insert: {
          id?: string
          kind: string
          message?: string | null
          meta?: Json | null
          practice_id?: string | null
          severity: string
          sha?: string | null
          source: string
          trainer_id?: string | null
          ts?: string
        }
        Update: {
          id?: string
          kind?: string
          message?: string | null
          meta?: Json | null
          practice_id?: string | null
          severity?: string
          sha?: string | null
          source?: string
          trainer_id?: string | null
          ts?: string
        }
        Relationships: [
          {
            foreignKeyName: "error_logs_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      exercises: {
        Row: {
          circuit_id: string | null
          created_at: string | null
          custom_duration_seconds: number | null
          hold_seconds: number | null
          id: string
          include_audio: boolean | null
          media_type: string
          media_url: string | null
          name: string | null
          notes: string | null
          plan_id: string
          position: number
          preferred_treatment: string | null
          prep_seconds: number | null
          rep_duration_seconds: number | null
          reps: number | null
          set_rest_seconds: number | null
          sets: number | null
          thumbnail_url: string | null
        }
        Insert: {
          circuit_id?: string | null
          created_at?: string | null
          custom_duration_seconds?: number | null
          hold_seconds?: number | null
          id?: string
          include_audio?: boolean | null
          media_type: string
          media_url?: string | null
          name?: string | null
          notes?: string | null
          plan_id: string
          position: number
          preferred_treatment?: string | null
          prep_seconds?: number | null
          rep_duration_seconds?: number | null
          reps?: number | null
          set_rest_seconds?: number | null
          sets?: number | null
          thumbnail_url?: string | null
        }
        Update: {
          circuit_id?: string | null
          created_at?: string | null
          custom_duration_seconds?: number | null
          hold_seconds?: number | null
          id?: string
          include_audio?: boolean | null
          media_type?: string
          media_url?: string | null
          name?: string | null
          notes?: string | null
          plan_id?: string
          position?: number
          preferred_treatment?: string | null
          prep_seconds?: number | null
          rep_duration_seconds?: number | null
          reps?: number | null
          set_rest_seconds?: number | null
          sets?: number | null
          thumbnail_url?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "exercises_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
        ]
      }
      pending_payments: {
        Row: {
          amount_zar: number
          bundle_key: string | null
          completed_at: string | null
          created_at: string
          credits: number
          id: string
          notes: string | null
          pf_payment_id: string | null
          practice_id: string
          status: string
        }
        Insert: {
          amount_zar: number
          bundle_key?: string | null
          completed_at?: string | null
          created_at?: string
          credits: number
          id: string
          notes?: string | null
          pf_payment_id?: string | null
          practice_id: string
          status?: string
        }
        Update: {
          amount_zar?: number
          bundle_key?: string | null
          completed_at?: string | null
          created_at?: string
          credits?: number
          id?: string
          notes?: string | null
          pf_payment_id?: string | null
          practice_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "pending_payments_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      plan_issuances: {
        Row: {
          credits_charged: number
          exercise_count: number
          id: string
          issued_at: string
          plan_id: string
          practice_id: string
          trainer_id: string
          version: number
        }
        Insert: {
          credits_charged: number
          exercise_count: number
          id?: string
          issued_at?: string
          plan_id: string
          practice_id: string
          trainer_id: string
          version: number
        }
        Update: {
          credits_charged?: number
          exercise_count?: number
          id?: string
          issued_at?: string
          plan_id?: string
          practice_id?: string
          trainer_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "plan_issuances_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_issuances_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      plans: {
        Row: {
          circuit_cycles: Json | null
          client_id: string | null
          client_name: string
          created_at: string | null
          deleted_at: string | null
          exercise_count: number | null
          first_opened_at: string | null
          id: string
          practice_id: string | null
          preferred_rest_interval_seconds: number | null
          sent_at: string | null
          title: string | null
          version: number
        }
        Insert: {
          circuit_cycles?: Json | null
          client_id?: string | null
          client_name: string
          created_at?: string | null
          deleted_at?: string | null
          exercise_count?: number | null
          first_opened_at?: string | null
          id?: string
          practice_id?: string | null
          preferred_rest_interval_seconds?: number | null
          sent_at?: string | null
          title?: string | null
          version?: number
        }
        Update: {
          circuit_cycles?: Json | null
          client_id?: string | null
          client_name?: string
          created_at?: string | null
          deleted_at?: string | null
          exercise_count?: number | null
          first_opened_at?: string | null
          id?: string
          practice_id?: string | null
          preferred_rest_interval_seconds?: number | null
          sent_at?: string | null
          title?: string | null
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "plans_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plans_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      practice_invite_codes: {
        Row: {
          claimed_at: string | null
          claimed_by: string | null
          code: string
          created_at: string
          created_by: string | null
          practice_id: string
          revoked_at: string | null
        }
        Insert: {
          claimed_at?: string | null
          claimed_by?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          practice_id: string
          revoked_at?: string | null
        }
        Update: {
          claimed_at?: string | null
          claimed_by?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          practice_id?: string
          revoked_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "practice_invite_codes_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      practice_members: {
        Row: {
          joined_at: string
          practice_id: string
          role: string
          trainer_id: string
        }
        Insert: {
          joined_at?: string
          practice_id: string
          role: string
          trainer_id: string
        }
        Update: {
          joined_at?: string
          practice_id?: string
          role?: string
          trainer_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "practice_members_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      practice_referrals: {
        Row: {
          claimed_at: string
          code_used: string
          goodwill_floor_applied: boolean
          referee_named_consent: boolean
          referee_practice_id: string
          referrer_practice_id: string
          signup_bonus_paid_at: string | null
        }
        Insert: {
          claimed_at?: string
          code_used: string
          goodwill_floor_applied?: boolean
          referee_named_consent?: boolean
          referee_practice_id: string
          referrer_practice_id: string
          signup_bonus_paid_at?: string | null
        }
        Update: {
          claimed_at?: string
          code_used?: string
          goodwill_floor_applied?: boolean
          referee_named_consent?: boolean
          referee_practice_id?: string
          referrer_practice_id?: string
          signup_bonus_paid_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "practice_referrals_referee_practice_id_fkey"
            columns: ["referee_practice_id"]
            isOneToOne: true
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "practice_referrals_referrer_practice_id_fkey"
            columns: ["referrer_practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      practices: {
        Row: {
          created_at: string
          id: string
          name: string
          owner_trainer_id: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          owner_trainer_id?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          owner_trainer_id?: string | null
        }
        Relationships: []
      }
      referral_codes: {
        Row: {
          code: string
          created_at: string
          practice_id: string
          revoked_at: string | null
        }
        Insert: {
          code: string
          created_at?: string
          practice_id: string
          revoked_at?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          practice_id?: string
          revoked_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "referral_codes_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: true
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
      referral_rebate_ledger: {
        Row: {
          created_at: string
          credits: number
          id: string
          kind: Database["public"]["Enums"]["referral_rebate_kind"]
          referee_practice_id: string | null
          referrer_practice_id: string
          source_credit_ledger_id: string | null
          zar_amount: number | null
        }
        Insert: {
          created_at?: string
          credits: number
          id?: string
          kind: Database["public"]["Enums"]["referral_rebate_kind"]
          referee_practice_id?: string | null
          referrer_practice_id: string
          source_credit_ledger_id?: string | null
          zar_amount?: number | null
        }
        Update: {
          created_at?: string
          credits?: number
          id?: string
          kind?: Database["public"]["Enums"]["referral_rebate_kind"]
          referee_practice_id?: string | null
          referrer_practice_id?: string
          source_credit_ledger_id?: string | null
          zar_amount?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "referral_rebate_ledger_referee_practice_id_fkey"
            columns: ["referee_practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "referral_rebate_ledger_referrer_practice_id_fkey"
            columns: ["referrer_practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "referral_rebate_ledger_source_credit_ledger_id_fkey"
            columns: ["source_credit_ledger_id"]
            isOneToOne: false
            referencedRelation: "credit_ledger"
            referencedColumns: ["id"]
          },
        ]
      }
      share_events: {
        Row: {
          channel: string
          event_kind: string
          id: string
          meta: Json | null
          occurred_at: string
          practice_id: string
          trainer_id: string | null
        }
        Insert: {
          channel: string
          event_kind: string
          id?: string
          meta?: Json | null
          occurred_at?: string
          practice_id: string
          trainer_id?: string | null
        }
        Update: {
          channel?: string
          event_kind?: string
          id?: string
          meta?: Json | null
          occurred_at?: string
          practice_id?: string
          trainer_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "share_events_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      publish_health: {
        Row: {
          failed_24h: number | null
          last_issued_ts: string | null
          practice_id: string | null
          stuck_pending: number | null
          succeeded_24h: number | null
        }
        Relationships: [
          {
            foreignKeyName: "plans_practice_id_fkey"
            columns: ["practice_id"]
            isOneToOne: false
            referencedRelation: "practices"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      _generate_slug_7: { Args: never; Returns: string }
      bootstrap_practice_for_user: { Args: never; Returns: string }
      can_write_to_raw_archive: { Args: { p_path: string }; Returns: boolean }
      claim_practice_invite: {
        Args: { p_code: string }
        Returns: {
          practice_id: string
          practice_name: string
        }[]
      }
      claim_referral_code: {
        Args: {
          p_code: string
          p_consent_to_naming: boolean
          p_referee_practice_id: string
        }
        Returns: boolean
      }
      consume_credit: {
        Args: { p_credits: number; p_plan_id: string; p_practice_id: string }
        Returns: Json
      }
      delete_client: {
        Args: { p_client_id: string }
        Returns: {
          deleted_at: string
          id: string
          name: string
          practice_id: string
        }[]
      }
      generate_referral_code: {
        Args: { p_practice_id: string }
        Returns: string
      }
      get_client_by_id: {
        Args: { p_client_id: string }
        Returns: {
          client_exercise_defaults: Json
          id: string
          name: string
          video_consent: Json
        }[]
      }
      get_plan_full: { Args: { p_plan_id: string }; Returns: Json }
      leave_practice: { Args: { p_practice_id: string }; Returns: undefined }
      list_practice_audit: {
        Args: {
          p_actor?: string
          p_from?: string
          p_kinds?: string[]
          p_limit?: number
          p_offset?: number
          p_practice_id: string
          p_to?: string
        }
        Returns: {
          balance_after: number
          credits_delta: number
          email: string
          full_name: string
          kind: string
          meta: Json
          ref_id: string
          title: string
          total_count: number
          trainer_id: string
          ts: string
        }[]
      }
      list_practice_clients: {
        Args: { p_practice_id: string }
        Returns: {
          client_exercise_defaults: Json
          id: string
          last_plan_at: string
          name: string
          video_consent: Json
        }[]
      }
      list_practice_members_with_profile: {
        Args: { p_practice_id: string }
        Returns: {
          email: string
          full_name: string
          is_current_user: boolean
          joined_at: string
          role: string
          trainer_id: string
        }[]
      }
      list_practice_sessions: {
        Args: { p_practice_id: string }
        Returns: {
          client_name: string
          exercise_count: number
          first_opened_at: string
          id: string
          is_own_session: boolean
          issuance_count: number
          last_published_at: string
          title: string
          trainer_email: string
          trainer_id: string
          version: number
        }[]
      }
      list_sessions_for_client: {
        Args: { p_client_id: string }
        Returns: {
          client_name: string
          exercise_count: number
          first_opened_at: string
          id: string
          is_own_session: boolean
          issuance_count: number
          last_published_at: string
          title: string
          trainer_email: string
          trainer_id: string
          version: number
        }[]
      }
      log_error: {
        Args: {
          p_kind: string
          p_message?: string
          p_meta?: Json
          p_practice_id?: string
          p_severity: string
          p_sha?: string
          p_source: string
        }
        Returns: string
      }
      log_share_event: {
        Args: {
          p_channel: string
          p_event_kind: string
          p_meta?: Json
          p_practice_id: string
        }
        Returns: string
      }
      mint_practice_invite_code: {
        Args: { p_practice_id: string }
        Returns: string
      }
      practice_credit_balance: {
        Args: { p_practice_id: string }
        Returns: number
      }
      practice_has_credits: {
        Args: { p_cost: number; p_practice_id: string }
        Returns: boolean
      }
      practice_rebate_balance: {
        Args: { p_practice_id: string }
        Returns: number
      }
      record_audit_event: {
        Args: {
          p_actor_id?: string
          p_kind: string
          p_meta?: Json
          p_practice_id: string
          p_ref_id?: string
        }
        Returns: string
      }
      record_purchase_with_rebates: {
        Args: {
          p_amount_zar: number
          p_bundle_key: string
          p_cost_per_credit_zar: number
          p_credits: number
          p_payfast_payment_id: string
          p_practice_id: string
        }
        Returns: Json
      }
      referral_dashboard_stats: {
        Args: { p_practice_id: string }
        Returns: {
          lifetime_rebate_credits: number
          qualifying_spend_total_zar: number
          rebate_balance_credits: number
          referee_count: number
        }[]
      }
      referral_referees_list: {
        Args: { p_practice_id: string }
        Returns: {
          is_named: boolean
          joined_at: string
          qualifying_spend_zar: number
          rebate_earned_credits: number
          referee_label: string
          referee_practice_id: string
        }[]
      }
      refund_credit: { Args: { p_plan_id: string }; Returns: boolean }
      remove_practice_member: {
        Args: { p_practice_id: string; p_trainer_id: string }
        Returns: undefined
      }
      rename_client: {
        Args: { p_client_id: string; p_new_name: string }
        Returns: undefined
      }
      rename_practice: {
        Args: { p_new_name: string; p_practice_id: string }
        Returns: {
          created_at: string
          id: string
          name: string
          owner_trainer_id: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "practices"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      restore_client: {
        Args: { p_client_id: string }
        Returns: {
          deleted_at: string
          id: string
          name: string
          practice_id: string
        }[]
      }
      revoke_referral_code: {
        Args: { p_practice_id: string }
        Returns: boolean
      }
      set_client_exercise_default: {
        Args: { p_client_id: string; p_field: string; p_value: Json }
        Returns: undefined
      }
      set_client_video_consent: {
        Args: {
          p_client_id: string
          p_grayscale: boolean
          p_line_drawing: boolean
          p_original: boolean
        }
        Returns: undefined
      }
      set_practice_member_role: {
        Args: {
          p_new_role: string
          p_practice_id: string
          p_trainer_id: string
        }
        Returns: undefined
      }
      sign_storage_url: {
        Args: { p_bucket: string; p_expires_in?: number; p_path: string }
        Returns: string
      }
      signed_url_self_check: {
        Args: never
        Returns: {
          jwt_secret_present: boolean
          ok: boolean
          sample_url: string
          supabase_url_present: boolean
        }[]
      }
      upsert_client: {
        Args: { p_name: string; p_practice_id: string }
        Returns: string
      }
      upsert_client_with_id: {
        Args: { p_id: string; p_name: string; p_practice_id: string }
        Returns: string
      }
      user_is_practice_owner: { Args: { pid: string }; Returns: boolean }
      user_practice_ids: { Args: never; Returns: string[] }
    }
    Enums: {
      referral_rebate_kind:
        | "signup_bonus_referrer"
        | "signup_bonus_referee"
        | "lifetime_rebate"
        | "redeemed"
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
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      referral_rebate_kind: [
        "signup_bonus_referrer",
        "signup_bonus_referee",
        "lifetime_rebate",
        "redeemed",
      ],
    },
  },
} as const
