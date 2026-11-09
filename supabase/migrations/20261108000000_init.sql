-- Personal Workspace — initial schema (DESIGN.md §10)
--
-- Conventions for every synced table:
--   id uuid PK (client-generated), owner_id (RLS boundary), created_at, updated_at, deleted_at.
--   updated_at is always set by the server (clock_timestamp) and is the sync pull cursor.
--   Rows are soft-deleted via deleted_at (tombstones) so deletions sync to other devices.
--   Integrity rules are enforced here even though clients validate too: the server is the last line.

-- ─────────────────────────────────────────────────────────────────────────────
-- Types
-- ─────────────────────────────────────────────────────────────────────────────
create type public.container_kind as enum ('folder', 'list', 'class', 'project');
create type public.task_status as enum ('not_started', 'in_progress', 'done', 'cancelled');

-- ─────────────────────────────────────────────────────────────────────────────
-- Shared trigger functions
-- ─────────────────────────────────────────────────────────────────────────────

-- Server-owned timestamps; owner and created_at can never change after insert.
create or replace function public.stamp_row() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := clock_timestamp();
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, clock_timestamp());
  else
    new.created_at := old.created_at;
    new.owner_id := old.owner_id;
  end if;
  return new;
end $$;

-- Reject references to rows the writer does not own. FK checks bypass RLS,
-- so without this a client could point at someone else's row by UUID.
-- Usage: execute function assert_ref_owned('<ref table>', '<column>')
create or replace function public.assert_ref_owned() returns trigger
language plpgsql set search_path = public as $$
declare
  ref_table text := tg_argv[0];
  ref_col   text := tg_argv[1];
  ref_id    uuid := (to_jsonb(new) ->> ref_col)::uuid;
  ok        boolean;
begin
  if ref_id is null then
    return new;
  end if;
  execute format('select exists (select 1 from public.%I where id = $1 and owner_id = $2)', ref_table)
    into ok using ref_id, new.owner_id;
  if not ok then
    raise exception '%.% references missing %: %', tg_table_name, ref_col, ref_table, ref_id
      using errcode = 'foreign_key_violation';
  end if;
  return new;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Containers: folder / list / class / project tree
-- ─────────────────────────────────────────────────────────────────────────────
create table public.containers (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  parent_id       uuid references public.containers (id) on delete cascade,
  kind            public.container_kind not null,
  name            text not null check (length(btrim(name)) > 0),
  color           text not null default 'grey',
  icon            text,
  -- Materialized path of ids: '/<root id>/<child id>/'. Maintained by trigger.
  path            text not null default '',
  -- Folders only: where quick-add from the folder's dashboard puts tasks.
  default_list_id uuid references public.containers (id) on delete set null,
  sort_rank       text not null default 'V',
  archived_at     timestamptz,
  settings        jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);

create or replace function public.containers_before_write() returns trigger
language plpgsql set search_path = public as $$
declare
  p record;
begin
  if new.parent_id is null then
    new.path := '/' || new.id || '/';
  else
    if new.parent_id = new.id then
      raise exception 'container % cannot be its own parent', new.id using errcode = 'check_violation';
    end if;

    select kind, path into p from containers where id = new.parent_id and owner_id = new.owner_id;
    if not found then
      raise exception 'parent container % not found', new.parent_id using errcode = 'foreign_key_violation';
    end if;
    if p.path like '%/' || new.id || '/%' then
      raise exception 'cannot move container % under its own descendant', new.id using errcode = 'check_violation';
    end if;
    -- Folders can contain anything; task-holding containers can only contain child projects.
    if p.kind <> 'folder' and new.kind <> 'project' then
      raise exception 'a % can only contain projects, not a %', p.kind, new.kind using errcode = 'check_violation';
    end if;
    new.path := p.path || new.id || '/';
  end if;

  if new.kind <> 'folder' and new.default_list_id is not null then
    raise exception 'only folders have a default list' using errcode = 'check_violation';
  end if;

  if tg_op = 'UPDATE' and new.kind is distinct from old.kind and new.deleted_at is null then
    if new.kind = 'folder'
       and exists (select 1 from tasks where container_id = new.id and deleted_at is null) then
      raise exception 'container % still holds tasks and cannot become a folder', new.id
        using errcode = 'check_violation';
    end if;
    if new.kind <> 'folder'
       and exists (select 1 from containers c
                   where c.parent_id = new.id and c.kind <> 'project' and c.deleted_at is null) then
      raise exception 'container % has non-project children and must stay a folder', new.id
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end $$;

-- When a container's path changes (moved), touch direct children; their BEFORE
-- trigger recomputes their path, which recursively cascades down the subtree.
create or replace function public.containers_cascade_path() returns trigger
language plpgsql set search_path = public as $$
begin
  update containers set path = path where parent_id = new.id;
  return null;
end $$;

create trigger containers_before_write
  before insert or update on public.containers
  for each row execute function public.containers_before_write();

-- Plain AFTER UPDATE (not "UPDATE OF path"): the path is changed by the BEFORE
-- trigger, and column-specific triggers only see columns named in the SET list.
create trigger containers_cascade_path
  after update on public.containers
  for each row when (old.path is distinct from new.path)
  execute function public.containers_cascade_path();

create index containers_owner_parent on public.containers (owner_id, parent_id);
create index containers_owner_path on public.containers (owner_id, path text_pattern_ops);

-- ─────────────────────────────────────────────────────────────────────────────
-- Class and project extras (1:1 with a container)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.class_terms (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null default auth.uid() references auth.users (id) on delete cascade,
  container_id        uuid not null references public.containers (id) on delete cascade,
  term_start          date,
  term_end            date,
  skip_ranges         jsonb not null default '[]'::jsonb,  -- [{"start":"2026-11-23","end":"2026-11-27","label":"Thanksgiving"}]
  course_code         text,
  event_title_pattern text,                                -- e.g. 'COMPSCI 61A'
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  check (term_end is null or term_start is null or term_end >= term_start)
);
create unique index class_terms_one_per_container on public.class_terms (container_id) where deleted_at is null;

create table public.project_meta (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  container_id uuid not null references public.containers (id) on delete cascade,
  status       text not null default 'active' check (status in ('planning', 'active', 'paused', 'done')),
  target_date  date,
  description  text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz
);
create unique index project_meta_one_per_container on public.project_meta (container_id) where deleted_at is null;

create table public.board_columns (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  container_id   uuid not null references public.containers (id) on delete cascade,
  name           text not null check (length(btrim(name)) > 0),
  maps_to_status public.task_status not null,
  sort_rank      text not null default 'V',
  wip_limit      integer check (wip_limit is null or wip_limit > 0),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index board_columns_container on public.board_columns (container_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- Categories (Homework, Quiz, Exam, …)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.categories (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name             text not null check (length(btrim(name)) > 0),
  symbol           text not null default 'circle',      -- SF Symbol name
  color            text,
  default_due_time time,
  default_estimate integer check (default_estimate is null or default_estimate > 0),
  default_subtasks jsonb not null default '[]'::jsonb,  -- ["Start", "Review", "Submit"]
  is_global        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);

create table public.container_categories (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  container_id uuid not null references public.containers (id) on delete cascade,
  category_id  uuid not null references public.categories (id) on delete cascade,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz
);
create unique index container_categories_unique
  on public.container_categories (container_id, category_id) where deleted_at is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- Templates and class assignment rules (used from Milestone 3)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.templates (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind       text not null check (kind in ('folder', 'list', 'class', 'project', 'task')),
  name       text not null check (length(btrim(name)) > 0),
  spec       jsonb not null default '{}'::jsonb,
  is_builtin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.assignment_rules (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  container_id       uuid not null references public.containers (id) on delete cascade,
  category_id        uuid references public.categories (id) on delete set null,
  title_pattern      text not null,                 -- 'HW {n}'
  start_number       integer not null default 1,
  count              integer check (count is null or count > 0),
  first_due_date     date,
  due_time           time,
  repeat             jsonb not null default '{}'::jsonb,  -- {"every":1,"unit":"week","weekdays":[5]}
  explicit_dates     date[],
  source_url_pattern text,
  estimated_minutes  integer,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Tasks
-- ─────────────────────────────────────────────────────────────────────────────
create table public.tasks (
  id                   uuid primary key default gen_random_uuid(),
  owner_id             uuid not null default auth.uid() references auth.users (id) on delete cascade,
  container_id         uuid references public.containers (id) on delete cascade,  -- null = Inbox
  parent_task_id       uuid references public.tasks (id) on delete cascade,
  title                text not null check (length(btrim(title)) > 0),
  notes                text not null default '',
  category_id          uuid references public.categories (id) on delete set null,
  priority             smallint check (priority between 0 and 3),
  status               public.task_status not null default 'not_started',
  -- Deadline: local date + optional local time, so date-only deadlines never drift.
  due_date             date,
  due_time             time,
  due_tz               text,
  estimated_minutes    integer check (estimated_minutes is null or estimated_minutes > 0),
  source_url           text,
  board_column_id      uuid references public.board_columns (id) on delete set null,
  board_rank           text,
  sort_rank            text not null default 'V',
  -- Present => this task is a recurring series (occurrences computed client-side).
  rrule                text,
  rrule_tz             text,
  rrule_anchor         date,
  generated_by_rule_id uuid references public.assignment_rules (id) on delete set null,
  template_origin_id   uuid references public.templates (id) on delete set null,
  -- Fields the user edited by hand on a generated task; series edits leave them alone.
  detached_fields      text[] not null default '{}',
  completed_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  check (due_time is null or due_date is not null),
  check (rrule is null or rrule_tz is not null)
);

create or replace function public.tasks_before_write() returns trigger
language plpgsql set search_path = public as $$
declare
  k public.container_kind;
begin
  if new.container_id is not null then
    select kind into k from containers where id = new.container_id and owner_id = new.owner_id;
    if not found then
      raise exception 'container % not found', new.container_id using errcode = 'foreign_key_violation';
    end if;
    if k = 'folder' then
      raise exception 'tasks cannot live directly in a folder; use its default list'
        using errcode = 'check_violation';
    end if;
  end if;

  if new.parent_task_id = new.id then
    raise exception 'task % cannot be its own parent', new.id using errcode = 'check_violation';
  end if;

  -- completed_at follows status.
  if new.status = 'done' then
    new.completed_at := coalesce(new.completed_at, clock_timestamp());
  else
    new.completed_at := null;
  end if;
  return new;
end $$;

create trigger tasks_before_write
  before insert or update on public.tasks
  for each row execute function public.tasks_before_write();

create index tasks_owner_container on public.tasks (owner_id, container_id);
create index tasks_owner_due on public.tasks (owner_id, due_date);
create index tasks_owner_status on public.tasks (owner_id, status);
create index tasks_parent on public.tasks (parent_task_id);
create index tasks_generated_by_rule on public.tasks (generated_by_rule_id);

create table public.task_schedule_blocks (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  task_id            uuid not null references public.tasks (id) on delete cascade,
  starts_at          timestamptz not null,
  ends_at            timestamptz not null,
  occurrence_key     text,
  external_event_key text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  check (ends_at > starts_at)
);
create index task_schedule_blocks_owner_starts on public.task_schedule_blocks (owner_id, starts_at);
create index task_schedule_blocks_task on public.task_schedule_blocks (task_id);

create table public.task_occurrence_overrides (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  task_id        uuid not null references public.tasks (id) on delete cascade,
  occurrence_key text not null,          -- local date (and time) in the series timezone
  status         public.task_status,
  completed_at   timestamptz,
  due_date       date,
  due_time       time,
  skipped        boolean not null default false,
  title          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create unique index task_occurrence_overrides_key
  on public.task_occurrence_overrides (task_id, occurrence_key) where deleted_at is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- Calendar mapping (Milestone 2; events themselves come from EventKit)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.event_mapping_rules (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  match_type   text not null check (match_type in ('calendar', 'title_prefix', 'title_regex')),
  match_value  text not null,
  container_id uuid not null references public.containers (id) on delete cascade,
  priority     integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz
);

create table public.event_links (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  external_event_key text not null,
  occurrence_start   timestamptz,
  container_id       uuid references public.containers (id) on delete set null,
  task_id            uuid references public.tasks (id) on delete set null,
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz
);
create unique index event_links_key
  on public.event_links (owner_id, external_event_key, coalesce(occurrence_start, 'epoch'::timestamptz))
  where deleted_at is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-user settings
-- ─────────────────────────────────────────────────────────────────────────────
create table public.user_settings (
  id                   uuid primary key default gen_random_uuid(),
  owner_id             uuid not null default auth.uid() references auth.users (id) on delete cascade,
  today_policy         jsonb not null default '{"scheduled": true, "due": true, "overdue": "collapsed"}'::jsonb,
  week_start           smallint not null default 0 check (week_start between 0 and 6),  -- 0 = Sunday
  default_calendar_key text,
  visible_calendars    jsonb not null default '[]'::jsonb,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz
);
create unique index user_settings_one_per_owner on public.user_settings (owner_id) where deleted_at is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- Ownership checks on references
-- ─────────────────────────────────────────────────────────────────────────────
create trigger ref_parent_owned          before insert or update on public.tasks                     for each row execute function public.assert_ref_owned('tasks', 'parent_task_id');
create trigger ref_category_owned        before insert or update on public.tasks                     for each row execute function public.assert_ref_owned('categories', 'category_id');
create trigger ref_column_owned          before insert or update on public.tasks                     for each row execute function public.assert_ref_owned('board_columns', 'board_column_id');
create trigger ref_rule_owned            before insert or update on public.tasks                     for each row execute function public.assert_ref_owned('assignment_rules', 'generated_by_rule_id');
create trigger ref_task_owned            before insert or update on public.task_schedule_blocks      for each row execute function public.assert_ref_owned('tasks', 'task_id');
create trigger ref_task_owned            before insert or update on public.task_occurrence_overrides for each row execute function public.assert_ref_owned('tasks', 'task_id');
create trigger ref_container_owned       before insert or update on public.class_terms               for each row execute function public.assert_ref_owned('containers', 'container_id');
create trigger ref_container_owned       before insert or update on public.project_meta              for each row execute function public.assert_ref_owned('containers', 'container_id');
create trigger ref_container_owned       before insert or update on public.board_columns             for each row execute function public.assert_ref_owned('containers', 'container_id');
create trigger ref_container_owned       before insert or update on public.container_categories      for each row execute function public.assert_ref_owned('containers', 'container_id');
create trigger ref_category_owned        before insert or update on public.container_categories      for each row execute function public.assert_ref_owned('categories', 'category_id');
create trigger ref_container_owned       before insert or update on public.assignment_rules          for each row execute function public.assert_ref_owned('containers', 'container_id');
create trigger ref_container_owned       before insert or update on public.event_mapping_rules       for each row execute function public.assert_ref_owned('containers', 'container_id');
create trigger ref_container_owned       before insert or update on public.event_links               for each row execute function public.assert_ref_owned('containers', 'container_id');
create trigger ref_task_owned            before insert or update on public.event_links               for each row execute function public.assert_ref_owned('tasks', 'task_id');

-- ─────────────────────────────────────────────────────────────────────────────
-- Row history: last 30 days of prior row versions, to recover from a lost
-- last-write-wins edit. (Purge with pg_cron: delete where changed_at < now() - '30 days'.)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.row_history (
  id         bigint generated always as identity primary key,
  owner_id   uuid not null,
  table_name text not null,
  row_id     uuid not null,
  old_row    jsonb not null,
  changed_at timestamptz not null default now()
);
create index row_history_lookup on public.row_history (owner_id, table_name, row_id, changed_at desc);

create or replace function public.record_history() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into row_history (owner_id, table_name, row_id, old_row)
  values (old.owner_id, tg_table_name, old.id, to_jsonb(old));
  return null;
end $$;

alter table public.row_history enable row level security;
create policy row_history_read_own on public.row_history
  for select to authenticated using (owner_id = (select auth.uid()));
revoke insert, update, delete on public.row_history from anon, authenticated;
grant select on public.row_history to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Standard wiring for every synced table: timestamps, history, RLS, sync index
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array[
    'containers', 'class_terms', 'project_meta', 'board_columns', 'categories',
    'container_categories', 'templates', 'assignment_rules', 'tasks',
    'task_schedule_blocks', 'task_occurrence_overrides', 'event_mapping_rules',
    'event_links', 'user_settings'
  ] loop
    -- "a_" prefix so timestamps are stamped before the other BEFORE triggers run.
    execute format('create trigger a_stamp_row before insert or update on public.%I
                    for each row execute function public.stamp_row()', t);
    execute format('create trigger z_record_history after update or delete on public.%I
                    for each row execute function public.record_history()', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy owner_all on public.%I for all to authenticated
                    using (owner_id = (select auth.uid()))
                    with check (owner_id = (select auth.uid()))', t);
    execute format('create index %I on public.%I (owner_id, updated_at)', t || '_sync_cursor', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
