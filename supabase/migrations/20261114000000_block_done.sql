-- Work sessions can be checked off in Today without completing the task.
alter table public.task_schedule_blocks add column if not exists completed_at timestamptz;
