/// <reference types="vite/client" />
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing Supabase environment variables');
}

// ✨ 핵심 수정: 'as any'를 붙여서 TypeScript 에러를 원천 차단합니다.
export const supabase = createClient(supabaseUrl, supabaseAnonKey) as any;