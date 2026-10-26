#!/bin/sh
set -eu

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_password="$APP_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE nano_app LOGIN PASSWORD %L', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'nano_app') \gexec
GRANT CONNECT ON DATABASE nanotateczki TO nano_app;
GRANT USAGE ON SCHEMA public TO nano_app;
ALTER DEFAULT PRIVILEGES FOR ROLE nano_admin IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO nano_app;
ALTER DEFAULT PRIVILEGES FOR ROLE nano_admin IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO nano_app;
SQL
