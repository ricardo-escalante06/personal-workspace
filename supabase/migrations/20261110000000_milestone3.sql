-- Milestone 3: starred tasks, start dates, project milestones, auto-star tags.

alter table public.tasks
  add column if not exists is_starred   boolean not null default false,
  add column if not exists start_date   date,
  -- A project milestone (phase) with its own start/due dates.
  add column if not exists is_milestone boolean not null default false,
  -- The milestone this task belongs to.
  add column if not exists milestone_id uuid references public.tasks (id) on delete set null,
  -- Position in its assignment series (HW 1 = 0), so edits to the series find it again.
  add column if not exists series_index integer;

alter table public.tasks drop constraint if exists tasks_start_before_due;
alter table public.tasks
  add constraint tasks_start_before_due check (start_date is null or due_date is null or start_date <= due_date);

create index if not exists tasks_milestone on public.tasks (milestone_id);

-- Tasks with this tag show in the Starred list without being starred by hand (Exam).
alter table public.categories
  add column if not exists auto_star boolean not null default false;
