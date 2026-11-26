-- Calendars (or whole accounts) the user switched off, synced so hiding the
-- Holidays calendar on the Mac hides it on the iPhone too. One row per hidden
-- calendar; showing it again soft-deletes the row.
create table public.hidden_calendars (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind        text not null check (kind in ('calendar', 'account')),
  key         text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

create trigger a_stamp_row before insert or update on public.hidden_calendars
  for each row execute function public.stamp_row();
create trigger z_record_history after update or delete on public.hidden_calendars
  for each row execute function public.record_history();
alter table public.hidden_calendars enable row level security;
create policy owner_all on public.hidden_calendars for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));
create index hidden_calendars_sync_cursor on public.hidden_calendars (owner_id, updated_at);
grant select, insert, update, delete on public.hidden_calendars to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.hidden_calendars;
  end if;
end $$;
