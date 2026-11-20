-- Move RLS helper functions out of the exposed API schema (not callable via /rest/v1/rpc)
create schema if not exists private;
grant usage on schema private to authenticated;
alter function public.current_role_name() set schema private;
alter function public.is_active_user() set schema private;
alter function public.is_admin() set schema private;
alter function public.can_edit() set schema private;
create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(private.current_role_name() = 'admin', false)
$$;
create or replace function private.can_edit()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(private.current_role_name() in ('admin','editor'), false)
$$;
