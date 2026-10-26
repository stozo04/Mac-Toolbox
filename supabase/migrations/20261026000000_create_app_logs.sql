-- App-wide log events written by Sources/Toolbox/Support/Logging/SupabaseLogSink.swift.
-- The app uses the publishable key, so it can insert but never read.
create table public.mactoolkit_app_logs (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  "timestamp" timestamptz not null,
  level       text not null check (level in ('info', 'warning', 'error', 'critical')),
  category    text not null check (char_length(category) <= 64),
  message     text not null check (char_length(message) <= 500),
  metadata    jsonb not null default '{}' check (pg_column_size(metadata) <= 4096),
  app_version text check (char_length(app_version) <= 32),
  os_version  text check (char_length(os_version) <= 128),
  install_id  text check (char_length(install_id) <= 64),
  session_id  text check (char_length(session_id) <= 64)
);

create index mactoolkit_app_logs_level_created_idx on public.mactoolkit_app_logs (level, created_at desc);

alter table public.mactoolkit_app_logs enable row level security;

create policy "mactoolkit_app can insert logs" on public.mactoolkit_app_logs
  for insert to anon, authenticated with check (true);
-- No select/update/delete policy: read the table from the dashboard or with the service role.
