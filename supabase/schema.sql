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
--   submit_guess()   send a wrong guess to the review queue
--   daily_recap()    yesterday's most common and rarest answers
--   is_admin()       ask "am I signed in as an admin?"
--   overrides        read tier overrides; admins can also change them
--   extra_answers    read approved player-discovered answers; admins can also change them
-- Admins (signed in, listed in public.admins) can also read and clear the
-- review queue (submission_queue(), public.submissions).
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

-- Wrong guesses waiting for review ("discovered by" credits). Players add rows only
-- through submit_guess(); only admins can read or delete them.
create table if not exists public.submissions (
  id          bigint generated always as identity primary key,
  puzzle_date date        not null,
  prompt_idx  int         not null,
  guess       text        not null,              -- what the player typed (trimmed)
  guess_norm  text        not null,              -- the game's matching key: lowercase, no accents/spaces
  player_id   text        not null,
  nickname    text,                              -- optional @name, credited if the guess is approved
  ip_hash     text,
  created_at  timestamptz not null default now()
);
-- One row per player per prompt per guess.
create unique index if not exists submissions_once
  on public.submissions (puzzle_date, prompt_idx, player_id, guess_norm);
create index if not exists submissions_by_guess
  on public.submissions (puzzle_date, prompt_idx, guess_norm);

-- Answers approved from the review queue. A row whose answer matches an existing
-- puzzle answer only adds aliases to it ("merge as alias"); any other row is a new answer.
create table if not exists public.extra_answers (
  puzzle_date   date        not null,
  prompt_idx    int         not null,
  answer        text        not null,
  aliases       text        not null default '',  -- "alias|alias"
  tier          int         not null,
  discovered_by text,                             -- nickname of the first finder, null = anon
  approved_at   timestamptz not null default now(),
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
      and conrelid in ('public.plays'::regclass, 'public.overrides'::regclass,
                       'public.submissions'::regclass, 'public.extra_answers'::regclass)
  loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
end $$;
alter table public.plays     add constraint plays_answers_len   check (coalesce(array_length(answers, 1), 0) <= 10);
alter table public.plays     add constraint plays_score_range   check (score between 0 and 1000);
alter table public.overrides add constraint overrides_prompt_idx check (prompt_idx between 0 and 9);
alter table public.overrides add constraint overrides_tier      check (tier between 0 and 5);
alter table public.submissions add constraint submissions_prompt_idx check (prompt_idx between 0 and 9);
alter table public.submissions add constraint submissions_guess      check (char_length(guess) between 1 and 80);
alter table public.submissions add constraint submissions_guess_norm check (guess_norm ~ '^[a-z0-9]{2,80}$');
alter table public.submissions add constraint submissions_nickname   check (nickname is null or nickname ~ '^[A-Za-z0-9_.]{1,20}$');
alter table public.extra_answers add constraint extra_answers_prompt_idx check (prompt_idx between 0 and 9);
alter table public.extra_answers add constraint extra_answers_answer     check (char_length(btrim(answer)) between 1 and 80);
alter table public.extra_answers add constraint extra_answers_aliases    check (char_length(aliases) <= 500);
alter table public.extra_answers add constraint extra_answers_tier       check (tier between 0 and 5);
alter table public.extra_answers add constraint extra_answers_credit     check (discovered_by is null or discovered_by ~ '^[A-Za-z0-9_.]{1,20}$');

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

-- Salted hash of the caller's network address (from the API gateway's headers),
-- or null if it can't be read. Only used to cap spam; the address itself is never stored.
create or replace function private.request_ip_hash()
returns text
language plpgsql stable set search_path = ''
as $$
declare
  v_headers json;
  v_ip      text;
begin
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
    v_ip := coalesce(
      nullif(trim(v_headers ->> 'cf-connecting-ip'), ''),
      nullif(trim(v_headers ->> 'x-real-ip'), ''),
      nullif(trim(split_part(v_headers ->> 'x-forwarded-for', ',', 1)), '')
    );
  exception when others then
    return null;
  end;
  if v_ip is null then
    return null;
  end if;
  return (select encode(sha256(convert_to(s.value || v_ip, 'UTF8')), 'hex')
          from private.settings s where s.key = 'ip_salt');
end;
$$;

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

  -- Answers are worth 0 (NPC trap) up to 100 points, always multiples of 5.
  -- So: a multiple of 5, from 0 up to 100 per answer given.
  if p_score % 5 <> 0 or p_score < 0 or p_score > v_given * 100 then
    return false;
  end if;

  -- Spam cap: at most 30 plays per puzzle from one network address.
  -- If the address is unknown the play is still accepted.
  v_hash := private.request_ip_hash();
  if v_hash is not null
     and (select count(*) from public.plays p
          where p.puzzle_date = p_date and p.ip_hash = v_hash) >= 30 then
    return false;
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

-- Send a wrong guess to the review queue. p_norm is the game's matching key for the
-- guess (lowercase letters and digits only), so "Pelé", "pele" and "PELE!" group together.
-- Returns true if a new row was stored. Quietly refuses bad input, repeats, and floods
-- (60 guesses per player per puzzle, 600 per network address per puzzle).
create or replace function public.submit_guess(
  p_date     date,
  p_prompt   int,
  p_guess    text,
  p_norm     text,
  p_player   text,
  p_nickname text default null
)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_guess text := btrim(coalesce(p_guess, ''));
  v_nick  text := nullif(ltrim(btrim(coalesce(p_nickname, '')), '@'), '');
  v_hash  text;
  v_rows  int;
begin
  if p_date is null or p_prompt is null or p_norm is null or p_player is null then
    return false;
  end if;
  -- Only for a puzzle someone could be playing right now (it may be a few days old
  -- if no new puzzle was published).
  if p_date > v_today + 1 or p_date < v_today - 7 then
    return false;
  end if;
  if p_prompt not between 0 and 9
     or char_length(v_guess) not between 1 and 80
     or p_norm !~ '^[a-z0-9]{2,80}$'
     or p_player !~ '^[A-Za-z0-9._-]{8,64}$' then
    return false;
  end if;
  -- A nickname that isn't valid is dropped rather than refusing the guess.
  if v_nick is not null and v_nick !~ '^[A-Za-z0-9_.]{1,20}$' then
    v_nick := null;
  end if;

  if (select count(*) from public.submissions s
      where s.puzzle_date = p_date and s.player_id = p_player) >= 60 then
    return false;
  end if;
  v_hash := private.request_ip_hash();
  if v_hash is not null
     and (select count(*) from public.submissions s
          where s.puzzle_date = p_date and s.ip_hash = v_hash) >= 600 then
    return false;
  end if;

  insert into public.submissions (puzzle_date, prompt_idx, guess, guess_norm, player_id, nickname, ip_hash)
  values (p_date, p_prompt, v_guess, p_norm, p_player, v_nick, v_hash)
  on conflict (puzzle_date, prompt_idx, player_id, guess_norm) do nothing;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

-- Admins only: pending guesses for a day, grouped by matching key, most-submitted first.
-- guess = the most common way it was typed; n = how many players sent it;
-- first_nickname = the earliest finder's @name (null = anon), used for the credit.
-- Anyone who isn't an admin gets no rows.
create or replace function public.submission_queue(p_date date)
returns table (prompt_idx int, guess_norm text, guess text, n bigint, first_nickname text, first_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select
    s.prompt_idx,
    s.guess_norm,
    (select s2.guess from public.submissions s2
      where s2.puzzle_date = p_date and s2.prompt_idx = s.prompt_idx and s2.guess_norm = s.guess_norm
      group by s2.guess order by count(*) desc, min(s2.created_at) limit 1),
    count(distinct s.player_id),
    (array_agg(s.nickname order by s.created_at, s.id))[1],
    min(s.created_at)
  from public.submissions s
  where s.puzzle_date = p_date
    and (select public.is_admin())
  group by s.prompt_idx, s.guess_norm
  order by count(distinct s.player_id) desc, min(s.created_at), s.prompt_idx;
$$;

-- Recap of a finished day, per lore check: players, how many answered, the most common
-- answer and its share of players, and the answers tied for rarest (the game breaks ties
-- by tier, which only it knows). Only lore checks at least 5 players answered are returned.
-- A day is only shown once it has ended everywhere on Earth (12:00 UTC the next day),
-- so this can never leak answers to a puzzle someone is still playing.
create or replace function public.daily_recap(p_date date)
returns table (prompt_idx int, players bigint, answered bigint, top_answer text, top_count bigint,
               top_pct int, rarest_count bigint, rarest_answers text[])
language sql stable security definer set search_path = ''
as $$
  with u as (
    select (a.ord - 1)::int as prompt_idx, a.answer
    from public.plays p
    cross join lateral unnest(p.answers) with ordinality as a(answer, ord)
    where p.puzzle_date = p_date
      and (now() at time zone 'utc') >= (p_date + 1)::timestamp + interval '12 hours'
  ),
  tot as (
    select u.prompt_idx, count(*) as players, count(u.answer) as answered
    from u group by u.prompt_idx
  ),
  c as (
    select u.prompt_idx, u.answer, count(*) as n
    from u where u.answer is not null group by u.prompt_idx, u.answer
  ),
  top as (
    select distinct on (c.prompt_idx) c.prompt_idx, c.answer, c.n
    from c order by c.prompt_idx, c.n desc, c.answer
  ),
  low as (
    select c.prompt_idx, min(c.n) as n from c group by c.prompt_idx
  )
  select t.prompt_idx, t.players, t.answered, top.answer, top.n,
         round(100.0 * top.n / t.players)::int,
         low.n,
         (select (array_agg(c.answer order by c.answer))[1:50]
            from c where c.prompt_idx = t.prompt_idx and c.n = low.n)
  from tot t
  join top on top.prompt_idx = t.prompt_idx
  join low on low.prompt_idx = t.prompt_idx
  where t.answered >= 5
  order by t.prompt_idx;
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

alter table public.plays         enable row level security;
alter table public.overrides     enable row level security;
alter table public.admins        enable row level security;
alter table public.submissions   enable row level security;
alter table public.extra_answers enable row level security;

-- Review queue: players can only add guesses (through submit_guess); admins read and clear it.
drop policy if exists "admins read submissions" on public.submissions;
create policy "admins read submissions" on public.submissions
  for select to authenticated
  using ((select public.is_admin()));

drop policy if exists "admins clear submissions" on public.submissions;
create policy "admins clear submissions" on public.submissions
  for delete to authenticated
  using ((select public.is_admin()));

-- Approved discovered answers: everyone reads them, only admins change them.
drop policy if exists "read extra answers" on public.extra_answers;
create policy "read extra answers" on public.extra_answers
  for select to anon, authenticated
  using (true);

drop policy if exists "admins edit extra answers" on public.extra_answers;
create policy "admins edit extra answers" on public.extra_answers
  for all to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

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

revoke all on public.plays         from public, anon, authenticated;
revoke all on public.admins        from public, anon, authenticated;
revoke all on public.overrides     from public, anon, authenticated;
revoke all on public.submissions   from public, anon, authenticated;
revoke all on public.extra_answers from public, anon, authenticated;
grant select                 on public.overrides     to anon, authenticated;
grant insert, update, delete on public.overrides     to authenticated;
grant select                 on public.extra_answers to anon, authenticated;
grant insert, update, delete on public.extra_answers to authenticated;
grant select, delete         on public.submissions   to authenticated;   -- RLS: admins only
grant all on public.plays, public.overrides, public.admins, public.submissions, public.extra_answers to service_role;

revoke all on function private.request_ip_hash()                     from public, anon, authenticated;
revoke all on function public.is_admin()                             from public;
revoke all on function public.submit_play(date, text, jsonb, int)    from public;
revoke all on function public.answer_counts(date, text)              from public;
revoke all on function public.submit_guess(date, int, text, text, text, text) from public;
revoke all on function public.submission_queue(date)                 from public, anon;
revoke all on function public.daily_recap(date)                      from public;
grant execute on function public.is_admin()                          to anon, authenticated, service_role;
grant execute on function public.submit_play(date, text, jsonb, int) to anon, authenticated, service_role;
grant execute on function public.answer_counts(date, text)           to anon, authenticated, service_role;
grant execute on function public.submit_guess(date, int, text, text, text, text) to anon, authenticated, service_role;
grant execute on function public.submission_queue(date)              to authenticated, service_role;
grant execute on function public.daily_recap(date)                   to anon, authenticated, service_role;
