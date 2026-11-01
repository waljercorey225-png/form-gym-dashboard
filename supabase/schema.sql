create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null default '',
  initials text not null default '',
  subscription_active boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.create_member_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  member_name text;
begin
  member_name := coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1));
  insert into public.profiles (id, email, display_name, initials)
  values (new.id, new.email, member_name, upper(left(member_name, 1)))
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute procedure public.create_member_profile();

create table if not exists public.workout_plans (
  plan_id integer primary key check (plan_id between 0 and 7),
  day_index integer not null unique check (day_index between 0 and 7),
  title text not null,
  subtitle text not null,
  duration_minutes integer not null check (duration_minutes between 1 and 600)
);

create table if not exists public.exercises (
  plan_id integer not null references public.workout_plans(plan_id) on delete cascade,
  exercise_order integer not null check (exercise_order >= 0),
  exercise_name text not null,
  details text not null,
  muscle text not null,
  primary key (plan_id, exercise_order)
);

create table if not exists public.exercise_catalog (
  exercise_id text primary key,
  name text not null,
  category text not null,
  entry_type text not null check (entry_type in ('strength', 'time')),
  details text not null default ''
);

create table if not exists public.exercise_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  exercise_id text not null references public.exercise_catalog(exercise_id),
  exercise_name text not null,
  category text not null,
  entry_type text not null check (entry_type in ('strength', 'time')),
  activity_date date not null,
  duration_minutes integer,
  sets integer,
  reps integer,
  weight_kg numeric(7, 2),
  created_at timestamptz not null default now(),
  check (
    (entry_type = 'time' and duration_minutes between 1 and 1440 and sets is null and reps is null and weight_kg is null)
    or
    (entry_type = 'strength' and duration_minutes is null and sets between 1 and 30 and reps between 1 and 100 and (weight_kg is null or weight_kg between 0 and 2000))
  )
);

create table if not exists public.step_records (
  user_id uuid not null references public.profiles(id) on delete cascade,
  activity_date date not null,
  actual_steps integer not null check (actual_steps >= 0),
  goal_steps integer not null check (goal_steps > 0),
  primary key (user_id, activity_date)
);

create table if not exists public.daily_health_metrics (
  user_id uuid not null references public.profiles(id) on delete cascade,
  activity_date date not null,
  heart_rate numeric(6, 2),
  hrv numeric(6, 2),
  spo2 numeric(5, 2),
  respiration numeric(5, 2),
  skin_temperature numeric(6, 2),
  stress numeric(5, 2),
  body_battery_peak numeric(5, 2),
  primary key (user_id, activity_date)
);

create table if not exists public.sleep_metrics (
  user_id uuid not null references public.profiles(id) on delete cascade,
  activity_date date not null,
  duration_minutes integer check (duration_minutes is null or duration_minutes >= 0),
  score numeric(5, 2),
  respiration numeric(5, 2),
  primary key (user_id, activity_date)
);

create table if not exists public.readiness_metrics (
  user_id uuid not null references public.profiles(id) on delete cascade,
  activity_date date not null,
  score numeric(5, 2),
  primary key (user_id, activity_date)
);

create table if not exists public.training_load_metrics (
  user_id uuid not null references public.profiles(id) on delete cascade,
  activity_date date not null,
  acute numeric(8, 2),
  chronic numeric(8, 2),
  ratio numeric(8, 3),
  primary key (user_id, activity_date)
);

create table if not exists public.endurance_metrics (
  user_id uuid not null references public.profiles(id) on delete cascade,
  activity_date date not null,
  score numeric(8, 2),
  primary key (user_id, activity_date)
);

create table if not exists public.exercise_completions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  activity_date date not null,
  plan_id integer not null,
  exercise_order integer not null,
  completed boolean not null default true,
  weight_kg numeric(7, 2) check (weight_kg is null or weight_kg between 0 and 2000),
  sets integer check (sets is null or sets between 1 and 30),
  reps integer check (reps is null or reps between 1 and 100),
  completed_at timestamptz not null default now(),
  primary key (user_id, activity_date, plan_id, exercise_order),
  foreign key (plan_id, exercise_order) references public.exercises(plan_id, exercise_order)
);

alter table public.exercise_completions add column if not exists sets integer check (sets is null or sets between 1 and 30);
alter table public.exercise_completions add column if not exists reps integer check (reps is null or reps between 1 and 100);

create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  legacy_session_id text,
  activity_date date not null,
  plan_id integer not null references public.workout_plans(plan_id),
  duration_minutes integer not null check (duration_minutes between 1 and 600),
  exercises_completed integer not null default 0 check (exercises_completed >= 0),
  completed_at timestamptz not null default now(),
  unique (user_id, legacy_session_id)
);

create or replace function public.is_active_member()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and subscription_active
  );
$$;

alter table public.profiles enable row level security;
alter table public.workout_plans enable row level security;
alter table public.exercises enable row level security;
alter table public.exercise_catalog enable row level security;
alter table public.exercise_logs enable row level security;
alter table public.step_records enable row level security;
alter table public.daily_health_metrics enable row level security;
alter table public.sleep_metrics enable row level security;
alter table public.readiness_metrics enable row level security;
alter table public.training_load_metrics enable row level security;
alter table public.endurance_metrics enable row level security;
alter table public.exercise_completions enable row level security;
alter table public.sessions enable row level security;

drop policy if exists "members read own profile" on public.profiles;
create policy "members read own profile" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);

drop policy if exists "active members read plans" on public.workout_plans;
create policy "active members read plans" on public.workout_plans
  for select to authenticated using ((select public.is_active_member()));

drop policy if exists "active members read exercises" on public.exercises;
create policy "active members read exercises" on public.exercises
  for select to authenticated using ((select public.is_active_member()));

drop policy if exists "active members read exercise catalog" on public.exercise_catalog;
create policy "active members read exercise catalog" on public.exercise_catalog
  for select to authenticated using ((select public.is_active_member()));

drop policy if exists "members manage own exercise logs" on public.exercise_logs;
create policy "members manage own exercise logs" on public.exercise_logs
  for all to authenticated
  using ((select auth.uid()) = user_id and (select public.is_active_member()))
  with check ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "members manage own steps" on public.step_records;
create policy "members manage own steps" on public.step_records
  for all to authenticated
  using ((select auth.uid()) = user_id and (select public.is_active_member()))
  with check ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "active members read own health metrics" on public.daily_health_metrics;
create policy "active members read own health metrics" on public.daily_health_metrics
  for select to authenticated using ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "active members read own sleep metrics" on public.sleep_metrics;
create policy "active members read own sleep metrics" on public.sleep_metrics
  for select to authenticated using ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "active members read own readiness metrics" on public.readiness_metrics;
create policy "active members read own readiness metrics" on public.readiness_metrics
  for select to authenticated using ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "active members read own training load metrics" on public.training_load_metrics;
create policy "active members read own training load metrics" on public.training_load_metrics
  for select to authenticated using ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "active members read own endurance metrics" on public.endurance_metrics;
create policy "active members read own endurance metrics" on public.endurance_metrics
  for select to authenticated using ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "members manage own completions" on public.exercise_completions;
create policy "members manage own completions" on public.exercise_completions
  for all to authenticated
  using ((select auth.uid()) = user_id and (select public.is_active_member()))
  with check ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "members read own sessions" on public.sessions;
create policy "members read own sessions" on public.sessions
  for select to authenticated
  using ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "members create own sessions" on public.sessions;
create policy "members create own sessions" on public.sessions
  for insert to authenticated
  with check ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "members delete own sessions" on public.sessions;
create policy "members delete own sessions" on public.sessions
  for delete to authenticated
  using ((select auth.uid()) = user_id and (select public.is_active_member()));

create table if not exists public.rest_days (
  user_id uuid not null references public.profiles(id) on delete cascade,
  activity_date date not null,
  plan_id integer references public.workout_plans(plan_id),
  created_at timestamptz not null default now(),
  primary key (user_id, activity_date)
);

create table if not exists public.vacations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  label text not null default '' check (char_length(label) <= 60),
  created_at timestamptz not null default now(),
  check (end_date >= start_date and end_date - start_date <= 366)
);

alter table public.rest_days enable row level security;
alter table public.vacations enable row level security;

drop policy if exists "members manage own rest days" on public.rest_days;
create policy "members manage own rest days" on public.rest_days
  for all to authenticated
  using ((select auth.uid()) = user_id and (select public.is_active_member()))
  with check ((select auth.uid()) = user_id and (select public.is_active_member()));

drop policy if exists "members manage own vacations" on public.vacations;
create policy "members manage own vacations" on public.vacations
  for all to authenticated
  using ((select auth.uid()) = user_id and (select public.is_active_member()))
  with check ((select auth.uid()) = user_id and (select public.is_active_member()));

grant select, insert, delete on public.rest_days, public.vacations to authenticated;

grant select on public.profiles to authenticated;
grant select on public.workout_plans, public.exercises, public.exercise_catalog to authenticated;
grant select, insert, update, delete on public.exercise_logs to authenticated;
grant select, insert, update, delete on public.step_records, public.exercise_completions to authenticated;
grant select on public.daily_health_metrics, public.sleep_metrics, public.readiness_metrics, public.training_load_metrics, public.endurance_metrics to authenticated;
grant select, insert, delete on public.sessions to authenticated;

grant execute on function public.is_active_member() to authenticated;

insert into public.workout_plans (plan_id, day_index, title, subtitle, duration_minutes) values
  (0, 0, 'Upper body strength', 'Build strength, one rep at a time.', 45),
  (1, 1, 'Lower body power', 'Strong foundations start here.', 50),
  (2, 2, 'Active recovery', 'Move well. Feel even better.', 30),
  (3, 3, 'Full body circuit', 'A little bit of everything.', 40),
  (4, 4, 'Rest & reset', 'Rest is part of the work.', 20),
  (5, 5, 'Push day', 'Press, build, repeat.', 45),
  (6, 6, 'Pull day', 'Strength from every angle.', 45),
  (7, 7, 'Cardio', 'Get the heart rate up.', 30)
on conflict (plan_id) do nothing;

insert into public.exercises (plan_id, exercise_order, exercise_name, details, muscle) values
  (0, 0, 'Dumbbell bench press', '4 sets · 8 reps', 'Chest'),
  (0, 1, 'Seated cable row', '3 sets · 10 reps', 'Back'),
  (0, 2, 'Shoulder press', '3 sets · 10 reps', 'Shoulders'),
  (0, 3, 'Incline dumbbell fly', '3 sets · 12 reps', 'Chest'),
  (0, 4, 'Tricep rope pushdown', '3 sets · 12 reps', 'Arms'),
  (1, 0, 'Barbell back squat', '4 sets · 8 reps', 'Quads'),
  (1, 1, 'Romanian deadlift', '3 sets · 10 reps', 'Hamstrings'),
  (1, 2, 'Walking lunges', '3 sets · 12 reps', 'Glutes'),
  (1, 3, 'Leg extension', '3 sets · 12 reps', 'Quads'),
  (1, 4, 'Standing calf raise', '4 sets · 15 reps', 'Calves'),
  (2, 0, 'Incline treadmill walk', '15 minutes · easy pace', 'Cardio'),
  (2, 1, 'World''s greatest stretch', '3 rounds · each side', 'Mobility'),
  (2, 2, 'Hip flexor stretch', '2 sets · 45 sec', 'Mobility'),
  (2, 3, 'Thoracic rotations', '2 sets · 10 reps', 'Mobility'),
  (3, 0, 'Kettlebell deadlift', '3 sets · 12 reps', 'Full body'),
  (3, 1, 'Push-ups', '3 sets · 10 reps', 'Chest'),
  (3, 2, 'Goblet squat', '3 sets · 12 reps', 'Legs'),
  (3, 3, 'Single-arm row', '3 sets · 10 reps', 'Back'),
  (3, 4, 'Plank hold', '3 sets · 45 sec', 'Core'),
  (4, 0, 'Easy outdoor walk', '20 minutes · relaxed', 'Recovery'),
  (4, 1, 'Full-body mobility', '10 minutes · gentle', 'Mobility'),
  (5, 0, 'Barbell bench press', '4 sets · 8 reps', 'Chest'),
  (5, 1, 'Arnold press', '3 sets · 10 reps', 'Shoulders'),
  (5, 2, 'Cable lateral raise', '3 sets · 12 reps', 'Shoulders'),
  (5, 3, 'Dips', '3 sets · 10 reps', 'Arms'),
  (6, 0, 'Lat pulldown', '4 sets · 10 reps', 'Back'),
  (6, 1, 'Chest-supported row', '3 sets · 10 reps', 'Back'),
  (6, 2, 'Face pulls', '3 sets · 15 reps', 'Shoulders'),
  (6, 3, 'Dumbbell curls', '3 sets · 12 reps', 'Arms')
on conflict (plan_id, exercise_order) do nothing;

insert into public.exercise_catalog (exercise_id, name, category, entry_type, details) values
  ('DB-BENCH', 'Dumbbell bench press', 'Chest', 'strength', '4 sets · 8 reps'),
  ('CABLE-ROW', 'Seated cable row', 'Back', 'strength', '3 sets · 10 reps'),
  ('SHOULDER-PRESS', 'Shoulder press', 'Shoulders', 'strength', '3 sets · 10 reps'),
  ('DB-FLY', 'Incline dumbbell fly', 'Chest', 'strength', '3 sets · 12 reps'),
  ('TRICEP-PUSHDOWN', 'Tricep rope pushdown', 'Arms', 'strength', '3 sets · 12 reps'),
  ('BACK-SQUAT', 'Barbell back squat', 'Legs', 'strength', '4 sets · 8 reps'),
  ('RDL', 'Romanian deadlift', 'Legs', 'strength', '3 sets · 10 reps'),
  ('LUNGES', 'Walking lunges', 'Legs', 'strength', '3 sets · 12 reps'),
  ('LEG-EXTENSION', 'Leg extension', 'Legs', 'strength', '3 sets · 12 reps'),
  ('CALF-RAISE', 'Standing calf raise', 'Legs', 'strength', '4 sets · 15 reps'),
  ('INCLINE-WALK', 'Incline treadmill walk', 'Cardio', 'time', '15 min · easy pace'),
  ('WORLD-GREATEST-STRETCH', 'World''s greatest stretch', 'Mobility', 'strength', '3 rounds · each side'),
  ('HIP-FLEXOR-STRETCH', 'Hip flexor stretch', 'Mobility', 'time', 'Time only'),
  ('THORACIC-ROTATION', 'Thoracic rotations', 'Mobility', 'strength', '2 sets · 10 reps'),
  ('KETTLEBELL-DEADLIFT', 'Kettlebell deadlift', 'Legs', 'strength', '3 sets · 12 reps'),
  ('PUSH-UPS', 'Push-ups', 'Chest', 'strength', '3 sets · 10 reps'),
  ('GOBLET-SQUAT', 'Goblet squat', 'Legs', 'strength', '3 sets · 12 reps'),
  ('SINGLE-ARM-ROW', 'Single-arm row', 'Back', 'strength', '3 sets · 10 reps'),
  ('PLANK', 'Plank hold', 'Core', 'time', 'Time only'),
  ('OUTDOOR-WALK', 'Easy outdoor walk', 'Cardio', 'time', '20 min · relaxed'),
  ('FULL-BODY-MOBILITY', 'Full-body mobility', 'Mobility', 'time', 'Time only'),
  ('BARBELL-BENCH', 'Barbell bench press', 'Chest', 'strength', '4 sets · 8 reps'),
  ('ARNOLD-PRESS', 'Arnold press', 'Shoulders', 'strength', '3 sets · 10 reps'),
  ('LATERAL-RAISE', 'Cable lateral raise', 'Shoulders', 'strength', '3 sets · 12 reps'),
  ('DIPS', 'Dips', 'Chest', 'strength', '3 sets · 10 reps'),
  ('LAT-PULLDOWN', 'Lat pulldown', 'Back', 'strength', '4 sets · 10 reps'),
  ('CHEST-SUPPORTED-ROW', 'Chest-supported row', 'Back', 'strength', '3 sets · 10 reps'),
  ('FACE-PULLS', 'Face pulls', 'Shoulders', 'strength', '3 sets · 15 reps'),
  ('DB-CURL', 'Dumbbell curls', 'Arms', 'strength', '3 sets · 12 reps'),
  ('OUTDOOR-RUN', 'Outdoor run', 'Cardio', 'time', 'Time only'),
  ('STAIRMASTER', 'Stairmaster', 'Cardio', 'time', 'Time only'),
  ('ELLIPTICAL', 'Elliptical', 'Cardio', 'time', 'Time only'),
  ('STATIONARY-BIKE', 'Stationary bike', 'Cardio', 'time', 'Time only')
on conflict (exercise_id) do nothing;
