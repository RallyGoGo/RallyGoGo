import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  // Load env file based on `mode` in the current working directory.
  // Set the third parameter to '' to load all env regardless of the `VITE_` prefix.
  // Note: Vite default loads variables prefixed with VITE_
  const env = loadEnv(mode, process.cwd(), '')

  console.log("🛠️ Vite Config Loading...")
  console.log(`🌍 Mode: ${mode}`)
  console.log(`🔗 VITE_SUPABASE_URL: ${env.VITE_SUPABASE_URL || 'UNDEFINED'}`)
  const anonKey = env.VITE_SUPABASE_ANON_KEY;
  console.log(`🔑 VITE_SUPABASE_ANON_KEY: ${anonKey ? `Present (Length: ${anonKey.length})` : 'UNDEFINED'}`)

  return {
    plugins: [react()],
  }
})
