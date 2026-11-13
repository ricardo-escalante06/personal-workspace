-- A milestone's own color (a color name like "blue"); null means the project's color.
alter table public.tasks
  add column if not exists color text;
