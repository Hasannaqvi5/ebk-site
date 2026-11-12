-- EBK backend schema. Paste into Supabase: SQL Editor -> New query -> Run.

-- Every finished game: one row per player per day.
create table if not exists public.plays (
  id          bigint generated always as identity primary key,
  puzzle_date date        not null,
  player_id   text        not null,              -- random id stored in the player's browser
  answers     text[]      not null,              -- 7 entries, null = skipped / timed out
  score       int         not null default 0,
  created_at  timestamptz not null default now(),
  unique (puzzle_date, player_id),
  check (coalesce(array_length(answers, 1), 0) <= 7),
  check (score between 0 and 700)
);

-- Manual tier fixes made in the in-game editor (tier 0 = NPC ... 5 = Elite Ball Knowledge).
create table if not exists public.overrides (
  puzzle_date date not null,
  prompt_idx  int  not null check (prompt_idx between 0 and 6),
  answer      text not null,
  tier        int  not null check (tier between 0 and 5),
  updated_at  timestamptz not null default now(),
  primary key (puzzle_date, prompt_idx, answer)
);

-- Who can use the tier editor.
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

alter table public.plays     enable row level security;
alter table public.overrides enable row level security;
alter table public.admins    enable row level security;

-- Anyone can submit their game. Nobody can read raw plays directly (only the aggregate RPC below).
drop policy if exists "submit a play" on public.plays;
create policy "submit a play" on public.plays
  for insert to anon, authenticated with check (true);

-- Everyone can read tier overrides; only admins can change them.
drop policy if exists "read overrides" on public.overrides;
create policy "read overrides" on public.overrides
  for select to anon, authenticated using (true);

drop policy if exists "admins edit overrides" on public.overrides;
create policy "admins edit overrides" on public.overrides
  for all to authenticated
  using (exists (select 1 from public.admins a where a.user_id = auth.uid()))
  with check (exists (select 1 from public.admins a where a.user_id = auth.uid()));

-- Is the signed-in person an admin?
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- How many players gave each answer for a day (excluding the asking player).
-- Rows with answer = null carry the total number of players for that prompt.
create or replace function public.answer_counts(p_date date, p_player text default null)
returns table (prompt_idx int, answer text, n bigint)
language sql stable security definer set search_path = public as $$
  with p as (
    select answers from public.plays
    where puzzle_date = p_date and player_id <> coalesce(p_player, '')
  ),
  u as (
    select (i - 1)::int as prompt_idx, p.answers[i] as answer
    from p, generate_subscripts(p.answers, 1) as i
  )
  select prompt_idx, null::text, count(*) from u group by prompt_idx
  union all
  select prompt_idx, answer, count(*) from u where answer is not null group by prompt_idx, answer;
$$;

grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.answer_counts(date, text) to anon, authenticated;

create index if not exists plays_by_date on public.plays (puzzle_date);
