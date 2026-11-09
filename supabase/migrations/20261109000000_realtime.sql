-- Broadcast row changes on synced tables through Supabase Realtime so other
-- devices pull within a second instead of waiting for a timer.
--
-- Clients only use these events as a "something changed, pull now" signal;
-- the actual data still comes through the normal cursor pull. Realtime applies
-- RLS, so each user only hears about their own rows.
--
-- Guarded so the migration also runs on plain Postgres (scripts/test-db.sh),
-- where the supabase_realtime publication does not exist.
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice 'supabase_realtime publication not found; skipping';
    return;
  end if;

  foreach t in array array[
    'containers', 'class_terms', 'project_meta', 'board_columns', 'categories',
    'container_categories', 'templates', 'assignment_rules', 'tasks',
    'task_schedule_blocks', 'task_occurrence_overrides', 'event_mapping_rules',
    'event_links', 'user_settings'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
