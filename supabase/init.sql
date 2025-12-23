-- Enable necessary extensions
create extension if not exists "moddatetime" schema "extensions";

-- 1. PROFILES
create table public.profiles (
  id uuid references auth.users not null primary key,
  email text,
  name text,
  phone text,
  gender text,
  ntrp float,
  elo_singles int default 1200,
  elo_doubles int default 1200,
  role text default 'player' check (role in ('admin', 'manager', 'player')),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 2. SEASONS
create table public.seasons (
  id uuid default gen_random_uuid() primary key,
  title text not null,
  is_active boolean default false,
  created_at timestamptz default now()
);

-- 3. MATCHES
create table public.matches (
  id uuid default gen_random_uuid() primary key,
  players uuid[] not null,
  winners uuid[],
  status text default 'pending' check (status in ('pending', 'completed', 'cancelled')),
  played_at timestamptz,
  created_at timestamptz default now()
);

-- 4. QUEUE
create table public.queue (
  id uuid default gen_random_uuid() primary key,
  player_id uuid references public.profiles(id) not null,
  priority_score float default 0,
  departure_time text,
  joined_at timestamptz default now()
);

-- Enable RLS
alter table public.profiles enable row level security;
alter table public.seasons enable row level security;
alter table public.matches enable row level security;
alter table public.queue enable row level security;

-- TRIGGER FUNCTION: handle_new_user
create or replace function public.handle_new_user()
returns trigger as $$
declare
  v_ntrp float;
  v_elo int;
begin
  -- Get NTRP from metadata (default to 2.5 if missing/invalid to match logic base)
  v_ntrp := coalesce((new.raw_user_meta_data->>'ntrp')::float, 2.5);
  
  -- Auto-Elo Logic
  if v_ntrp < 2.5 then
    v_elo := 800;
  elseif v_ntrp < 3.0 then
    v_elo := 1000;
  elseif v_ntrp < 3.5 then
    v_elo := 1200;
  elseif v_ntrp < 4.0 then
    v_elo := 1400;
  else
    v_elo := 1600;
  end if;

  insert into public.profiles (id, email, name, phone, gender, ntrp, elo_singles, elo_doubles, role)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data->>'name',
    new.raw_user_meta_data->>'phone',
    new.raw_user_meta_data->>'gender',
    v_ntrp,
    v_elo,
    v_elo,
    'player'
  );
  return new;
end;
$$ language plpgsql security definer;

-- Trigger
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- RLS POLICIES

-- PROFILES
create policy "Public profiles are viewable by everyone" on public.profiles
  for select using (true);

create policy "Users can update own profile" on public.profiles
  for update using (auth.uid() = id);

create policy "Admins can do all on profiles" on public.profiles
  for all using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- SEASONS
create policy "Seasons viewable by everyone" on public.seasons
  for select using (true);

create policy "Admins can do all on seasons" on public.seasons
  for all using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- MATCHES
create policy "Matches viewable by everyone" on public.matches
  for select using (true);

create policy "Admins can do all on matches" on public.matches
  for all using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );

-- QUEUE
create policy "Queue viewable by everyone" on public.queue
  for select using (true);

create policy "Users can insert themselves into queue" on public.queue
  for insert with check (auth.uid() = player_id);

create policy "Users can delete themselves from queue" on public.queue
  for delete using (auth.uid() = player_id);

create policy "Admins can do all on queue" on public.queue
  for all using (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
  );
