-- Minimal stand-in for Supabase's auth schema and roles, so migrations and
-- RLS tests can run against a plain local Postgres (scripts/test-db.sh).
-- NOT a migration. Never apply this to a real Supabase project.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create table auth.users (id uuid primary key);

create function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

-- Test helpers
create schema test;
grant usage on schema test to authenticated;

create function test.expect_error(stmt text, code text) returns void
language plpgsql as $$
declare
  failed boolean := false;
begin
  begin
    execute stmt;
  exception when others then
    if sqlstate <> code then
      raise exception 'expected SQLSTATE % but got % (%) for: %', code, sqlstate, sqlerrm, stmt;
    end if;
    failed := true;
  end;
  if not failed then
    raise exception 'expected SQLSTATE % but statement succeeded: %', code, stmt;
  end if;
end $$;
grant execute on function test.expect_error(text, text) to authenticated;

create function test.login(uid uuid) returns void
language sql as $$
  select set_config('request.jwt.claim.sub', uid::text, false);
$$;
grant execute on function test.login(uuid) to authenticated;
