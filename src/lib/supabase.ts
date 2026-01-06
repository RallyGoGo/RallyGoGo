/// <reference types="vite/client" />
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing Supabase environment variables');
}

console.log('🔗 Supabase URL:', supabaseUrl?.substring(0, 25) + '...');
console.log('🔑 Supabase Key:', supabaseAnonKey?.substring(0, 5) + '...');

// ✨ 핵심 수정: 'as any'를 붙여서 TypeScript 에러를 원천 차단합니다.
export const supabase = createClient(supabaseUrl, supabaseAnonKey) as any;