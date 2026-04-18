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
  public: {
    Tables: {
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
          reps: number | null
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
          reps?: number | null
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
          reps?: number | null
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
          client_name: string
          created_at: string | null
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
          client_name: string
          created_at?: string | null
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
          client_name?: string
          created_at?: string | null
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
            foreignKeyName: "plans_practice_id_fkey"
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
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      bootstrap_practice_for_user: { Args: never; Returns: string }
      consume_credit: {
        Args: { p_credits: number; p_plan_id: string; p_practice_id: string }
        Returns: Json
      }
      get_plan_full: { Args: { p_plan_id: string }; Returns: Json }
      practice_credit_balance: {
        Args: { p_practice_id: string }
        Returns: number
      }
      practice_has_credits: {
        Args: { p_cost: number; p_practice_id: string }
        Returns: boolean
      }
      refund_credit: { Args: { p_plan_id: string }; Returns: boolean }
      user_is_practice_owner: { Args: { pid: string }; Returns: boolean }
      user_practice_ids: { Args: never; Returns: string[] }
    }
    Enums: {
      [_ in never]: never
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
    Enums: {},
  },
} as const
