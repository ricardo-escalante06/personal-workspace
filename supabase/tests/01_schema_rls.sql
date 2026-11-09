-- Schema integrity + RLS tests. Run via scripts/test-db.sh.
-- Each failed assertion raises and stops the run (psql ON_ERROR_STOP).

insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b');

set role authenticated;
select test.login('00000000-0000-0000-0000-00000000000a');

-- ── Tree + path ────────────────────────────────────────────────────────────
insert into containers (id, parent_id, kind, name) values
  ('10000000-0000-0000-0000-000000000001', null, 'folder', 'School'),
  ('10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'class', 'CS61B'),
  ('10000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'project', 'Project 3'),
  ('10000000-0000-0000-0000-000000000004', null, 'folder', 'Personal'),
  ('10000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000004', 'list', 'General');

do $$ begin
  assert (select path from containers where id = '10000000-0000-0000-0000-000000000003')
       = '/10000000-0000-0000-0000-000000000001/10000000-0000-0000-0000-000000000002/10000000-0000-0000-0000-000000000003/',
         'nested path computed in a single multi-row insert';
  assert (select owner_id from containers where id = '10000000-0000-0000-0000-000000000001')
       = '00000000-0000-0000-0000-00000000000a', 'owner defaults to auth.uid()';
end $$;

-- ── Nesting rules ──────────────────────────────────────────────────────────
select test.expect_error($$insert into containers (parent_id, kind, name)
  values ('10000000-0000-0000-0000-000000000002', 'folder', 'X')$$, '23514');   -- folder inside a class
select test.expect_error($$insert into containers (parent_id, kind, name)
  values ('10000000-0000-0000-0000-000000000002', 'list', 'X')$$, '23514');     -- list inside a class
select test.expect_error($$update containers set parent_id = '10000000-0000-0000-0000-000000000003'
  where id = '10000000-0000-0000-0000-000000000002'$$, '23514');                 -- cycle
select test.expect_error($$update containers set default_list_id = '10000000-0000-0000-0000-000000000001'
  where id = '10000000-0000-0000-0000-000000000005'$$, '23514');                 -- default list on a non-folder

-- Default list on a folder is fine.
update containers set default_list_id = '10000000-0000-0000-0000-000000000005'
  where id = '10000000-0000-0000-0000-000000000004';

-- ── Move re-paths the whole subtree ────────────────────────────────────────
update containers set parent_id = '10000000-0000-0000-0000-000000000004'
  where id = '10000000-0000-0000-0000-000000000002';   -- CS61B moves under Personal
do $$ begin
  assert (select path from containers where id = '10000000-0000-0000-0000-000000000003')
       = '/10000000-0000-0000-0000-000000000004/10000000-0000-0000-0000-000000000002/10000000-0000-0000-0000-000000000003/',
         'grandchild path follows a move';
end $$;
update containers set parent_id = '10000000-0000-0000-0000-000000000001'
  where id = '10000000-0000-0000-0000-000000000002';   -- and back

-- ── Tasks ──────────────────────────────────────────────────────────────────
select test.expect_error($$insert into tasks (container_id, title)
  values ('10000000-0000-0000-0000-000000000001', 'In a folder')$$, '23514');

insert into tasks (id, container_id, title, due_date) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'HW 9', '2026-11-13');
insert into tasks (id, container_id, title) values
  ('20000000-0000-0000-0000-000000000002', null, 'Inbox task');

-- Kind change rules
select test.expect_error($$update containers set kind = 'folder'
  where id = '10000000-0000-0000-0000-000000000002'$$, '23514');                 -- class with tasks -> folder
select test.expect_error($$update containers set kind = 'list'
  where id = '10000000-0000-0000-0000-000000000004'$$, '23514');                 -- folder with a list child -> list
update containers set kind = 'list' where id = '10000000-0000-0000-0000-000000000002';   -- class -> list keeps tasks
update containers set kind = 'class' where id = '10000000-0000-0000-0000-000000000002';

-- completed_at follows status
update tasks set status = 'done' where id = '20000000-0000-0000-0000-000000000001';
do $$ begin
  assert (select completed_at from tasks where id = '20000000-0000-0000-0000-000000000001') is not null, 'completed_at set';
end $$;
update tasks set status = 'not_started' where id = '20000000-0000-0000-0000-000000000001';
do $$ begin
  assert (select completed_at from tasks where id = '20000000-0000-0000-0000-000000000001') is null, 'completed_at cleared';
end $$;

-- ── Timestamps are server-owned ────────────────────────────────────────────
do $$
declare
  before_update timestamptz;
  created timestamptz;
begin
  select updated_at, created_at into before_update, created from tasks where id = '20000000-0000-0000-0000-000000000001';
  update tasks set title = 'HW 9 (renamed)', updated_at = '2000-01-01', created_at = '2000-01-01'
    where id = '20000000-0000-0000-0000-000000000001';
  assert (select updated_at from tasks where id = '20000000-0000-0000-0000-000000000001') > before_update, 'updated_at bumped';
  assert (select created_at from tasks where id = '20000000-0000-0000-0000-000000000001') = created, 'created_at preserved';
end $$;

-- ── Schedule blocks ────────────────────────────────────────────────────────
select test.expect_error($$insert into task_schedule_blocks (task_id, starts_at, ends_at)
  values ('20000000-0000-0000-0000-000000000001', '2026-11-10 20:00Z', '2026-11-10 19:00Z')$$, '23514');
insert into task_schedule_blocks (task_id, starts_at, ends_at)
  values ('20000000-0000-0000-0000-000000000001', '2026-11-10 19:00Z', '2026-11-10 20:00Z');

-- ── Upsert (what PostgREST sends) ──────────────────────────────────────────
insert into containers (id, parent_id, kind, name) values
  ('10000000-0000-0000-0000-000000000001', null, 'folder', 'School (renamed)')
on conflict (id) do update set name = excluded.name;
do $$ begin
  assert (select name from containers where id = '10000000-0000-0000-0000-000000000001') = 'School (renamed)', 'upsert updates';
end $$;

-- ── History ────────────────────────────────────────────────────────────────
do $$ begin
  assert (select count(*) from row_history where row_id = '20000000-0000-0000-0000-000000000001') >= 3,
         'previous task versions recorded';
end $$;
select test.expect_error($$insert into row_history (owner_id, table_name, row_id, old_row)
  values ('00000000-0000-0000-0000-00000000000a', 'tasks', gen_random_uuid(), '{}')$$, '42501');

-- ── RLS: user B ────────────────────────────────────────────────────────────
select test.login('00000000-0000-0000-0000-00000000000b');

do $$ begin
  assert (select count(*) from containers) = 0, 'B sees none of A''s containers';
  assert (select count(*) from tasks) = 0, 'B sees none of A''s tasks';
  assert (select count(*) from row_history) = 0, 'B sees none of A''s history';
end $$;

-- B cannot modify A's rows (silently matches zero rows).
update tasks set title = 'pwned' where id = '20000000-0000-0000-0000-000000000001';
delete from containers where id = '10000000-0000-0000-0000-000000000001';

-- B cannot write rows owned by A.
select test.expect_error($$insert into containers (owner_id, kind, name)
  values ('00000000-0000-0000-0000-00000000000a', 'folder', 'Sneaky')$$, '42501');

-- B cannot attach to A's rows by UUID.
select test.expect_error($$insert into containers (parent_id, kind, name)
  values ('10000000-0000-0000-0000-000000000001', 'list', 'Sneaky')$$, '23503');
select test.expect_error($$insert into tasks (container_id, title)
  values ('10000000-0000-0000-0000-000000000002', 'Sneaky')$$, '23503');
select test.expect_error($$insert into task_schedule_blocks (task_id, starts_at, ends_at)
  values ('20000000-0000-0000-0000-000000000001', now(), now() + interval '1 hour')$$, '23503');

-- B's own data works.
insert into containers (kind, name) values ('folder', 'B''s folder');

-- A session with no user id sees nothing and can write nothing.
select set_config('request.jwt.claim.sub', '', false);
do $$ begin
  assert (select count(*) from containers) = 0, 'no-user session sees nothing';
end $$;
select test.expect_error($$insert into containers (kind, name) values ('folder', 'Nobody')$$, '42501');  -- RLS rejects before NOT NULL

reset role;
do $$ begin
  assert (select title from tasks where id = '20000000-0000-0000-0000-000000000001') = 'HW 9 (renamed)', 'B''s update had no effect';
  assert (select count(*) from containers where owner_id = '00000000-0000-0000-0000-00000000000a') = 5, 'B''s delete had no effect';
end $$;

\echo '  ✓ schema + RLS tests passed'
