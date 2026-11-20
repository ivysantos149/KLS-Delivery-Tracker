-- KLS Delivery Tracker — initial schema
-- Tracks client delivery commitment dates against production and shipment lead times.

-- ───────────────────────── Profiles & roles ─────────────────────────
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  full_name   text,
  role        text not null default 'viewer' check (role in ('admin','editor','viewer')),
  is_active   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Helper functions (security definer so RLS policies can call them without recursion)
create or replace function public.current_role_name()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and is_active
$$;

create or replace function public.is_active_user()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and is_active)
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role_name() = 'admin', false)
$$;

create or replace function public.can_edit()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role_name() in ('admin','editor'), false)
$$;

revoke execute on function public.current_role_name(), public.is_active_user(), public.is_admin(), public.can_edit() from anon, public;
grant  execute on function public.current_role_name(), public.is_active_user(), public.is_admin(), public.can_edit() to authenticated;

-- New auth users get an INACTIVE viewer profile, so a stray self-signup can see nothing.
-- The very first user becomes an active admin. Admin-created users are activated by the admin-users function.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare first_user boolean;
begin
  select not exists (select 1 from public.profiles) into first_user;
  insert into public.profiles (id, email, full_name, role, is_active)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
    case when first_user then 'admin' else 'viewer' end,
    first_user
  );
  return new;
end $$;
revoke execute on function public.handle_new_user() from anon, authenticated, public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;
-- Users can always read their own profile; active users can see teammates (for owner names / assignment)
create policy "profiles: read own or active users read all" on public.profiles
  for select to authenticated using (id = (select auth.uid()) or public.is_active_user());
-- All profile changes go through the admin-users edge function (service role).

-- ───────────────────────── Deliveries ─────────────────────────
create table public.deliveries (
  id                       bigint generated always as identity primary key,
  so_number                text not null,                 -- sales order / job ref
  client                   text not null,
  project                  text,                          -- project / site name
  description              text,                          -- items
  supplier                 text,
  order_date               date not null,                 -- PO received / production start basis
  commitment_date          date not null,                 -- date promised to client
  production_leadtime_days integer not null default 0 check (production_leadtime_days >= 0),
  shipment_leadtime_days   integer not null default 0 check (shipment_leadtime_days >= 0),
  production_done_date     date,                          -- actual production completion
  shipped_date             date,                          -- actual ETD
  delivered_date           date,                          -- actual delivery to client
  status                   text not null default 'open'
                           check (status in ('open','in_production','ready','shipped','delivered','cancelled')),
  owner_id                 uuid references public.profiles(id) on delete set null,
  remarks                  text,
  created_by               uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index deliveries_commitment_idx on public.deliveries (commitment_date);
create index deliveries_status_idx on public.deliveries (status);
create index deliveries_owner_idx on public.deliveries (owner_id);
create index deliveries_created_by_idx on public.deliveries (created_by);

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;

create trigger deliveries_touch before update on public.deliveries
  for each row execute function public.touch_updated_at();
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

alter table public.deliveries enable row level security;
create policy "deliveries: active users read" on public.deliveries
  for select to authenticated using (public.is_active_user());
create policy "deliveries: editors insert" on public.deliveries
  for insert to authenticated with check (public.can_edit());
create policy "deliveries: editors update" on public.deliveries
  for update to authenticated using (public.can_edit()) with check (public.can_edit());
create policy "deliveries: admins delete" on public.deliveries
  for delete to authenticated using (public.is_admin());

-- ───────────────────────── Alert settings ─────────────────────────
create table public.alert_settings (
  id                   integer primary key default 1 check (id = 1),
  due_soon_days        integer not null default 7,   -- warn when commitment is within N days and not yet shipped
  tight_buffer_days    integer not null default 3,   -- warn when planned buffer is below N days
  ship_deadline_days   integer not null default 3,   -- warn when the latest ship-by date is within N days
  updated_at           timestamptz not null default now()
);
insert into public.alert_settings (id) values (1);

alter table public.alert_settings enable row level security;
create policy "alert_settings: active users read" on public.alert_settings
  for select to authenticated using (public.is_active_user());
create policy "alert_settings: admins update" on public.alert_settings
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ───────────────────────── Alert acknowledgements ─────────────────────────
create table public.alert_acks (
  delivery_id  bigint not null references public.deliveries(id) on delete cascade,
  alert_type   text not null,
  user_id      uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  acked_at     timestamptz not null default now(),
  primary key (delivery_id, alert_type, user_id)
);
create index alert_acks_user_idx on public.alert_acks (user_id);

alter table public.alert_acks enable row level security;
create policy "alert_acks: read own" on public.alert_acks
  for select to authenticated using (user_id = (select auth.uid()) and public.is_active_user());
create policy "alert_acks: insert own" on public.alert_acks
  for insert to authenticated with check (user_id = (select auth.uid()) and public.is_active_user());
create policy "alert_acks: delete own" on public.alert_acks
  for delete to authenticated using (user_id = (select auth.uid()));

-- ───────────────────────── Computed view ─────────────────────────
-- Singapore local "today"
create or replace function public.sg_today()
returns date language sql stable set search_path = public as $$
  select (now() at time zone 'Asia/Singapore')::date
$$;

create or replace view public.delivery_timeline with (security_invoker = true) as
select
  d.*,
  o.full_name                                                    as owner_name,
  (d.order_date + d.production_leadtime_days)                    as planned_production_done,
  (d.order_date + d.production_leadtime_days + d.shipment_leadtime_days) as planned_delivery,
  (d.commitment_date - d.shipment_leadtime_days)                 as latest_ship_by,
  (d.commitment_date - d.order_date)                             as committed_days,
  (d.production_leadtime_days + d.shipment_leadtime_days)        as total_leadtime_days,
  (d.commitment_date - (d.order_date + d.production_leadtime_days + d.shipment_leadtime_days)) as planned_buffer_days,
  -- Forecast delivery uses actuals where known, otherwise the plan (never earlier than today for unfinished stages)
  case
    when d.delivered_date is not null then d.delivered_date
    when d.shipped_date is not null then greatest(d.shipped_date + d.shipment_leadtime_days, public.sg_today())
    when d.production_done_date is not null then greatest(d.production_done_date, public.sg_today()) + d.shipment_leadtime_days
    else greatest(d.order_date + d.production_leadtime_days, public.sg_today()) + d.shipment_leadtime_days
  end                                                            as forecast_delivery,
  (d.commitment_date - public.sg_today())                        as days_to_commitment
from public.deliveries d
left join public.profiles o on o.id = d.owner_id;

-- Status rollup per delivery
create or replace view public.delivery_status with (security_invoker = true) as
select
  t.*,
  (t.commitment_date - t.forecast_delivery) as forecast_buffer_days,
  case
    when t.status = 'cancelled' then 'cancelled'
    when t.delivered_date is not null and t.delivered_date <= t.commitment_date then 'delivered_on_time'
    when t.delivered_date is not null then 'delivered_late'
    when public.sg_today() > t.commitment_date then 'late'
    when t.forecast_delivery > t.commitment_date then 'at_risk'
    when (t.commitment_date - t.forecast_delivery) < s.tight_buffer_days then 'tight'
    else 'on_track'
  end as health
from public.delivery_timeline t
cross join public.alert_settings s;

-- Live alerts, one row per (delivery, alert type)
create or replace view public.delivery_alerts with (security_invoker = true) as
with s as (select * from public.alert_settings where id = 1),
base as (
  select t.* from public.delivery_status t
  where t.status not in ('delivered','cancelled') and t.delivered_date is null
)
select b.id as delivery_id, b.so_number, b.client, b.project, b.commitment_date, b.owner_id, b.owner_name,
       a.alert_type, a.severity, a.message, a.sort_date
from base b cross join s
cross join lateral (values
  ('late', 'critical',
     case when public.sg_today() > b.commitment_date
          then format('Past commitment date by %s day(s); not yet delivered', public.sg_today() - b.commitment_date) end,
     b.commitment_date),
  ('at_risk', 'high',
     case when public.sg_today() <= b.commitment_date and b.forecast_delivery > b.commitment_date
          then format('Forecast delivery %s is %s day(s) after commitment', to_char(b.forecast_delivery,'DD Mon YYYY'), b.forecast_delivery - b.commitment_date) end,
     b.forecast_delivery),
  ('production_overdue', 'high',
     case when b.production_done_date is null and b.shipped_date is null and public.sg_today() > b.planned_production_done
          then format('Production planned to finish %s; %s day(s) overdue', to_char(b.planned_production_done,'DD Mon YYYY'), public.sg_today() - b.planned_production_done) end,
     b.planned_production_done),
  ('ship_deadline', 'medium',
     case when b.shipped_date is null and public.sg_today() <= b.commitment_date
               and b.latest_ship_by - public.sg_today() between 0 and s.ship_deadline_days
          then format('Must ship by %s (%s day(s) left) to meet commitment', to_char(b.latest_ship_by,'DD Mon YYYY'), b.latest_ship_by - public.sg_today())
          when b.shipped_date is null and public.sg_today() > b.latest_ship_by and public.sg_today() <= b.commitment_date
          then format('Ship-by date %s has passed; not yet shipped', to_char(b.latest_ship_by,'DD Mon YYYY')) end,
     b.latest_ship_by),
  ('leadtime_exceeds_commitment', 'medium',
     case when b.planned_buffer_days < 0
          then format('Production + shipment lead time (%s days) exceeds committed window (%s days) by %s day(s)', b.total_leadtime_days, b.committed_days, -b.planned_buffer_days) end,
     b.commitment_date),
  ('tight_buffer', 'low',
     case when b.forecast_delivery <= b.commitment_date and (b.commitment_date - b.forecast_delivery) < s.tight_buffer_days
          then format('Only %s day(s) buffer before commitment', b.commitment_date - b.forecast_delivery) end,
     b.commitment_date),
  ('due_soon', 'low',
     case when b.shipped_date is null and b.days_to_commitment between 0 and s.due_soon_days
          then format('Commitment in %s day(s) and not yet shipped', b.days_to_commitment) end,
     b.commitment_date)
) as a(alert_type, severity, message, sort_date)
where a.message is not null;

grant select on public.delivery_timeline, public.delivery_status, public.delivery_alerts to authenticated;
revoke all on public.delivery_timeline, public.delivery_status, public.delivery_alerts from anon;
