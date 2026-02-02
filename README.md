# 🎾 RallyGoGo

> **Korea's Premier Tennis Matching Platform**  
> Real-time doubles matching, ELO rankings, and betting system

**Version:** 9.7.2 | **Architecture:** Strict RPC Model

---

## 🚀 Quick Start

### Prerequisites

- Node.js 18+
- npm 9+
- Supabase Account (with project set up)

### Installation

```bash
# Clone the repository
git clone https://github.com/your-username/rallygogo.git
cd rallygogo

# Install dependencies
npm install

# Set up environment variables
cp .env.example .env.local
# Edit .env.local with your Supabase credentials
```

### Development

```bash
npm run dev
```

### Production Build

```bash
npm run build
npm run preview
```

---

## 🏗️ Architecture Overview

RallyGoGo follows a **Strict RPC Model** where all business logic resides in Supabase Database Functions (RPCs). The frontend never performs direct INSERT/UPDATE/DELETE operations.

```
┌─────────────────────────────────────────────────────────────┐
│                     React Frontend (Vite)                   │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────┐   │
│   │CourtBoard│  │QueueBoard│  │  Ranking │  │AdminPanel │   │
│   └────┬─────┘  └────┬─────┘  └────┬─────┘  └─────┬─────┘   │
│        │             │             │              │         │
│        └─────────────┴─────────────┴──────────────┘         │
│                          │                                  │
│                    supabase.rpc()                           │
└──────────────────────────┼──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   Supabase Backend                          │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                  RPC Functions                      │   │
│   │  • join_queue          • create_match_draft         │   │
│   │  • leave_queue         • start_match                │   │
│   │  • report_score        • finish_match_v2            │   │
│   │  • dispute_match       • place_bet_v2               │   │
│   │  • cast_mvp_vote       • admin_* (5 functions)      │   │
│   └─────────────────────────────────────────────────────┘   │
│   ┌─────────────────────────────────────────────────────┐   │
│   │              Row Level Security (RLS)               │   │
│   │          Deny-by-default on all tables              │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 📁 Project Structure

```
rallygogo/
├── src/
│   ├── components/          # React UI components
│   │   ├── CourtBoard.tsx   # Main match management
│   │   ├── QueueBoard.tsx   # Queue display & management
│   │   ├── JoinQueue.tsx    # Queue join/leave controls
│   │   ├── Ranking.tsx      # Leaderboard
│   │   ├── BettingModal.tsx # Betting interface
│   │   └── AdminDashboard.tsx # Admin controls
│   ├── services/
│   │   ├── matchingSystem.ts # Matching algorithm (read-only)
│   │   └── bettingSystem.ts  # Betting helpers
│   ├── lib/
│   │   └── supabase.ts      # Typed Supabase client
│   └── types/
│       └── database.types.ts # Generated DB types
├── supabase/
│   └── migrations/          # SQL migrations
│       ├── migration_v1_full_reset.sql
│       ├── migration_v2_logic.sql
│       ├── phase_4e_admin_rpcs.sql
│       └── phase_5_dispute_rpc.sql
└── vite.config.ts           # Build configuration
```

---

## 🔑 Environment Variables

Create a `.env.local` file in the project root:

```env
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key-here
```

### For Vercel Deployment

Add these in **Vercel Project Settings → Environment Variables**:

| Variable | Description |
|----------|-------------|
| `VITE_SUPABASE_URL` | Supabase project URL |
| `VITE_SUPABASE_ANON_KEY` | Supabase anon (public) key |

---

## 🎮 Core Features

### Match Lifecycle

1. **Join Queue** → Players enter the waiting queue
2. **Draft Match** → Admin creates a match from queued players
3. **Start Match** → Match status: DRAFT → PLAYING (betting opens for 5 min)
4. **Report Score** → Either team reports the final score
5. **Confirm/Dispute** → Opponent confirms or disputes the score
6. **Finish Match** → ELO calculated, bets settled, MVP voting opens

### Admin Functions

| RPC | Description |
|-----|-------------|
| `admin_rollback_match` | Revert a finished match (undo ELO changes) |
| `admin_confirm_match` | Force-confirm a match without player approval |
| `admin_season_soft_reset` | Apply seasonal ELO decay |
| `admin_update_profile` | Update any player profile |
| `admin_clear_queue` | Clear all queue entries |

---

## 🛡️ Security Model

- **RLS (Row Level Security)**: All tables have deny-by-default policies
- **RPC Validation**: All RPCs validate `auth.uid()` before operations
- **Admin Role Check**: Admin RPCs verify `role = 'admin'` in profiles table
- **No Direct Writes**: Frontend cannot INSERT/UPDATE/DELETE directly

---

## 📊 Performance Optimizations

- **Bundle Splitting**: React + Supabase in separate cacheable chunks
- **Code Splitting**: Lazy-load AdminDashboard, Ranking, BettingModal
- **Main Bundle**: ~248KB (gzipped: ~76KB)

---

## 🧪 Development Commands

```bash
# Development server
npm run dev

# Production build
npm run build

# Preview production build locally
npm run preview

# Lint check
npm run lint

# Type check
npx tsc --noEmit
```

---

## 📝 License

MIT License - See [LICENSE](LICENSE) for details.

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

**Built with ❤️ for the Korean Tennis Community**
