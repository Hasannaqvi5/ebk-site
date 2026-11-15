-- =====================================================================
-- EBK backend (Supabase / Postgres)
--
-- How to install: Supabase dashboard -> SQL Editor -> New query ->
-- paste this whole file -> Run.
--
-- Safe to run again at any time. It only adds or replaces what is
-- needed and never deletes plays or tier overrides.
--
-- What the browser is allowed to do (with the public anon key):
--   submit_play()    record one finished game per player per day
--   answer_counts()  read how many players gave each answer (totals only)
--   is_admin()       ask "am I signed in as an admin?"
--   overrides        read tier overrides; admins can also change them
-- Everything else (raw plays, the admin list) is closed to the browser.
-- =====================================================================


-- ---------- tables ----------

-- Every finished game: one row per player per day.
create table if not exists public.plays (
  id          bigint generated always as identity primary key,
  puzzle_date date        not null,
  player_id   text        not null,              -- random id stored in the player's browser
  answers     text[]      not null,              -- one entry per lore check, null = skipped / timed out
  score       int         not null default 0,
  ip_hash     text,                              -- salted hash, only used to cap spam
  created_at  timestamptz not null default now(),
  unique (puzzle_date, player_id)
);
-- Upgrading from the first version of this file: add the column it lacked.
alter table public.plays add column if not exists ip_hash text;

-- Manual tier fixes made in the in-game editor (tier 0 = NPC Trap ... 5 = Internet Phenomenon).
create table if not exists public.overrides (
  puzzle_date date not null,
  prompt_idx  int  not null,
  answer      text not null,
  tier        int  not null,
  updated_at  timestamptz not null default now(),
  primary key (puzzle_date, prompt_idx, answer)
);

-- Value limits. Dropped and re-added on every run, so changing the number of
-- lore checks (10 per day now; it used to be 7) only means editing them here.
do $$
declare c record;
begin
  for c in
    select conname, conrelid::regclass as tbl
    from pg_constraint
    where contype = 'c'
      and conrelid in ('public.plays'::regclass, 'public.overrides'::regclass)
  loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
end $$;
alter table public.plays     add constraint plays_answers_len   check (coalesce(array_length(answers, 1), 0) <= 10);
alter table public.plays     add constraint plays_score_range   check (score between 0 and 1000);
alter table public.overrides add constraint overrides_prompt_idx check (prompt_idx between 0 and 9);
alter table public.overrides add constraint overrides_tier      check (tier between 0 and 5);

-- Who can use the tier editor.
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- Things the API must never expose live in their own schema.
create schema if not exists private;

create table if not exists private.settings (
  key   text primary key,
  value text not null
);
-- Random per-project salt so stored IP hashes cannot be reversed.
insert into private.settings (key, value)
values ('ip_salt', gen_random_uuid()::text)
on conflict (key) do nothing;

create index if not exists plays_by_ip on public.plays (puzzle_date, ip_hash);
-- The unique (puzzle_date, player_id) index already covers lookups by date.
drop index if exists public.plays_by_date;


-- ---------- functions ----------

-- Is the signed-in person an admin?
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.admins a where a.user_id = (select auth.uid())
  );
$$;

-- Record a finished game. Returns true if it was stored, false if it was
-- rejected (wrong shape, already played that day, or too many from one network).
-- The browser cannot write to public.plays directly; this is the only way in.
create or replace function public.submit_play(
  p_date    date,
  p_player  text,
  p_answers jsonb,
  p_score   int
)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_answers text[];
  v_given   int;
  v_headers json;
  v_ip      text;
  v_hash    text;
  v_rows    int;
begin
  if p_date is null or p_player is null or p_answers is null or p_score is null then
    return false;
  end if;

  -- No puzzles from the future (+1 day covers players whose clock is ahead of UTC).
  if p_date > (now() at time zone 'utc')::date + 1 or p_date < date '2026-01-01' then
    return false;
  end if;

  if p_player !~ '^[A-Za-z0-9._-]{8,64}$' then
    return false;
  end if;

  -- Exactly 10 entries (or 7 for older puzzles), each either null or a short piece of text.
  if jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) not in (7, 10) then
    return false;
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_answers) as e(v)
    where jsonb_typeof(e.v) not in ('string', 'null')
       or (jsonb_typeof(e.v) = 'string' and char_length(e.v #>> '{}') not between 1 and 80)
  ) then
    return false;
  end if;

  select array_agg(e.v #>> '{}' order by e.ord), count(e.v #>> '{}')
    into v_answers, v_given
  from jsonb_array_elements(p_answers) with ordinality as e(v, ord);

  -- Answers are worth -25 (NPC trap) up to 100 points, always multiples of 5, and the
  -- final score is never below 0. So: a multiple of 5, from 0 up to 100 per answer given.
  if p_score % 5 <> 0 or p_score < 0 or p_score > v_given * 100 then
    return false;
  end if;

  -- Spam cap: at most 30 plays per puzzle from one network address.
  -- If the address is unknown the play is still accepted.
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
    v_ip := coalesce(
      nullif(trim(v_headers ->> 'cf-connecting-ip'), ''),
      nullif(trim(v_headers ->> 'x-real-ip'), ''),
      nullif(trim(split_part(v_headers ->> 'x-forwarded-for', ',', 1)), '')
    );
  exception when others then
    v_ip := null;
  end;

  if v_ip is not null then
    select encode(sha256(convert_to(s.value || v_ip, 'UTF8')), 'hex')
      into v_hash
    from private.settings s
    where s.key = 'ip_salt';

    if (select count(*) from public.plays p
        where p.puzzle_date = p_date and p.ip_hash = v_hash) >= 30 then
      return false;
    end if;
  end if;

  insert into public.plays (puzzle_date, player_id, answers, score, ip_hash)
  values (p_date, p_player, v_answers, p_score, v_hash)
  on conflict (puzzle_date, player_id) do nothing;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

-- How many players gave each answer for a day (leaving out the asking player).
-- Rows with answer = null carry the total number of players for that prompt.
create or replace function public.answer_counts(p_date date, p_player text default null)
returns table (prompt_idx int, answer text, n bigint)
language sql stable security definer set search_path = ''
as $$
  with u as (
    select (a.ord - 1)::int as prompt_idx, a.answer
    from public.plays p
    cross join lateral unnest(p.answers) with ordinality as a(answer, ord)
    where p.puzzle_date = p_date
      and p.player_id is distinct from p_player
  )
  select u.prompt_idx, null::text, count(*) from u group by u.prompt_idx
  union all
  select u.prompt_idx, u.answer, count(*) from u where u.answer is not null
  group by u.prompt_idx, u.answer;
$$;

-- Keep overrides.updated_at honest when a tier is changed again.
create or replace function private.touch_updated_at()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists overrides_touch on public.overrides;
create trigger overrides_touch
  before update on public.overrides
  for each row execute function private.touch_updated_at();


-- ---------- row level security ----------

alter table public.plays     enable row level security;
alter table public.overrides enable row level security;
alter table public.admins    enable row level security;

-- plays and admins get no policies on purpose: the browser can't touch them.
-- (The first version of this file let anyone insert plays directly.)
drop policy if exists "submit a play" on public.plays;

-- Everyone can read tier overrides; only admins can change them.
drop policy if exists "read overrides" on public.overrides;
create policy "read overrides" on public.overrides
  for select to anon, authenticated
  using (true);

drop policy if exists "admins edit overrides" on public.overrides;
create policy "admins edit overrides" on public.overrides
  for all to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));


-- ---------- permissions ----------
-- Spelled out in full so the result is the same whatever the project defaults are.

revoke all on schema private from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;

revoke all on public.plays     from public, anon, authenticated;
revoke all on public.admins    from public, anon, authenticated;
revoke all on public.overrides from public, anon, authenticated;
grant select                 on public.overrides to anon, authenticated;
grant insert, update, delete on public.overrides to authenticated;
grant all on public.plays, public.overrides, public.admins to service_role;

revoke all on function public.is_admin()                             from public;
revoke all on function public.submit_play(date, text, jsonb, int)    from public;
revoke all on function public.answer_counts(date, text)              from public;
grant execute on function public.is_admin()                          to anon, authenticated, service_role;
grant execute on function public.submit_play(date, text, jsonb, int) to anon, authenticated, service_role;
grant execute on function public.answer_counts(date, text)           to anon, authenticated, service_role;
