-- ============================================================
-- 로맨스토리 CRM → 멀티 스튜디오(SaaS) 전환 마이그레이션
-- supabase-schema.sql 을 먼저 실행한 프로젝트에 이어서 실행하세요.
-- SQL Editor → New query → 전체 붙여넣기 → Run
-- ============================================================

-- ============================================================
-- 1. studios — 업체(테넌트)
-- ============================================================
create table if not exists public.studios (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  slug        text unique not null,          -- 공개 주소용: /s/romancestory
  name        text not null,
  owner_id    uuid references auth.users(id) on delete set null,
  plan        text not null default 'free',
  active      boolean not null default true
);

-- ============================================================
-- 2. studio_members — 누가 어느 업체에 속하는가
-- ============================================================
create table if not exists public.studio_members (
  studio_id  uuid not null references public.studios(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null default 'owner',   -- owner | staff
  created_at timestamptz not null default now(),
  primary key (studio_id, user_id)
);

create index if not exists studio_members_user_idx on public.studio_members (user_id);

-- ============================================================
-- 3. 기존 테이블에 studio_id 추가
-- ============================================================
alter table public.projects     add column if not exists studio_id uuid references public.studios(id) on delete cascade;
alter table public.payments     add column if not exists studio_id uuid references public.studios(id) on delete cascade;
alter table public.contracts    add column if not exists studio_id uuid references public.studios(id) on delete cascade;
alter table public.app_settings add column if not exists studio_id uuid references public.studios(id) on delete cascade;

create index if not exists projects_studio_idx on public.projects (studio_id);

-- ── 기본 설정값을 별도 테이블로 분리 ────────────
create table if not exists public.setting_defaults (
  key   text primary key,
  value jsonb not null
);

-- 기존 app_settings 의 템플릿 행(studio_id IS NULL)을 defaults 로 이동
insert into public.setting_defaults (key, value)
select key, value from public.app_settings where studio_id is null
on conflict (key) do nothing;

-- ── 기본 스튜디오 생성 + 기존 데이터 귀속 ───────
insert into public.studios (slug, name)
values ('romancestory', '로맨스토리')
on conflict (slug) do nothing;

update public.projects     set studio_id = (select id from public.studios where slug='romancestory') where studio_id is null;
update public.payments     set studio_id = (select id from public.studios where slug='romancestory') where studio_id is null;
update public.contracts    set studio_id = (select id from public.studios where slug='romancestory') where studio_id is null;
update public.app_settings set studio_id = (select id from public.studios where slug='romancestory') where studio_id is null;

-- 이제 studio_id 가 모두 채워졌으므로 PK 를 안전하게 교체 (실패하면 에러가 보이도록)
alter table public.app_settings drop constraint if exists app_settings_pkey;
alter table public.app_settings alter column studio_id set not null;
alter table public.app_settings add primary key (studio_id, key);

-- ============================================================
-- 4. 현재 로그인 사용자의 studio_id
-- ============================================================
create or replace function public.my_studio_id()
returns uuid language sql stable security definer set search_path = public as $$
  select studio_id from public.studio_members where user_id = auth.uid() limit 1;
$$;

-- ============================================================
-- 5. 소셜 로그인 직후 자동 온보딩
--    처음 로그인한 사용자에게 스튜디오를 자동 생성해 줍니다.
-- ============================================================
create or replace function public.ensure_studio(p_name text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; base text; s text; n int := 0;
begin
  select studio_id into sid from public.studio_members where user_id = auth.uid() limit 1;
  if sid is not null then return sid; end if;

  base := lower(regexp_replace(coalesce(p_name, split_part(coalesce(auth.jwt()->>'email','studio'),'@',1)), '[^a-z0-9]+', '-', 'g'));
  if base = '' or base is null then base := 'studio'; end if;
  s := base;
  while exists (select 1 from public.studios where slug = s) loop
    n := n + 1; s := base || '-' || n;
  end loop;

  insert into public.studios (slug, name, owner_id)
  values (s, coalesce(p_name, s), auth.uid())
  returning id into sid;

  insert into public.studio_members (studio_id, user_id, role) values (sid, auth.uid(), 'owner');

  -- 기본 설정 복사
  insert into public.app_settings (studio_id, key, value)
  select sid, key, value from public.setting_defaults
  on conflict (studio_id, key) do nothing;

  return sid;
end $$;

grant execute on function public.ensure_studio(text) to authenticated;

-- 내 스튜디오 정보 조회
create or replace function public.my_studio()
returns table (id uuid, slug text, name text, role text)
language sql stable security definer set search_path = public as $$
  select s.id, s.slug, s.name, m.role
    from public.studio_members m join public.studios s on s.id = m.studio_id
   where m.user_id = auth.uid() limit 1;
$$;
grant execute on function public.my_studio() to authenticated;

-- ============================================================
-- 6. RLS 재작성 — 자기 스튜디오 데이터만
-- ============================================================
alter table public.studios        enable row level security;
alter table public.studio_members enable row level security;

drop policy if exists admin_all_projects  on public.projects;
create policy studio_projects on public.projects
  for all to authenticated
  using (studio_id = public.my_studio_id())
  with check (studio_id = public.my_studio_id());

drop policy if exists admin_all_payments on public.payments;
create policy studio_payments on public.payments
  for all to authenticated
  using (studio_id = public.my_studio_id())
  with check (studio_id = public.my_studio_id());

drop policy if exists admin_all_contracts on public.contracts;
create policy studio_contracts on public.contracts
  for all to authenticated
  using (studio_id = public.my_studio_id())
  with check (studio_id = public.my_studio_id());

drop policy if exists admin_write_settings on public.app_settings;
create policy studio_settings on public.app_settings
  for all to authenticated
  using (studio_id = public.my_studio_id())
  with check (studio_id = public.my_studio_id());

drop policy if exists read_own_studio on public.studios;
create policy read_own_studio on public.studios
  for select to authenticated
  using (id = public.my_studio_id());

drop policy if exists read_own_membership on public.studio_members;
create policy read_own_membership on public.studio_members
  for select to authenticated using (user_id = auth.uid());

-- 홈페이지 설정은 방문자도 읽어야 함 (가격·문구만 들어있음)
drop policy if exists public_read_settings on public.app_settings;
create policy public_read_settings on public.app_settings
  for select to anon, authenticated using (true);

-- ============================================================
-- 7. RPC 를 스튜디오 단위로 재작성 (slug 로 지정)
-- ============================================================
create or replace function public.studio_id_by_slug(p_slug text)
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.studios where slug = p_slug and active limit 1;
$$;
grant execute on function public.studio_id_by_slug(text) to anon, authenticated;

create or replace function public.get_public_booking_dates(p_slug text, from_date date default current_date)
returns table (wedding_date date, is_taken boolean)
language sql security definer set search_path = public as $$
  select p.wedding_date, true
    from public.projects p
   where p.studio_id = public.studio_id_by_slug(p_slug)
     and p.status <> '문의' and p.wedding_date >= from_date
   group by p.wedding_date;
$$;

create or replace function public.get_month_load(p_slug text, from_date date default current_date)
returns table (ym text, booked integer)
language sql security definer set search_path = public as $$
  select to_char(p.wedding_date,'YYYY-MM'), count(*)::int
    from public.projects p
   where p.studio_id = public.studio_id_by_slug(p_slug)
     and p.status <> '문의' and p.wedding_date >= date_trunc('month', from_date)
   group by 1;
$$;

create or replace function public.verify_client_booking(p_slug text, p_name text, p_phone text)
returns table (
  id uuid, display_name text, wedding_date date, venue text,
  package_name text, status project_status, edit_stage edit_stage,
  amount integer, paid integer, balance integer,
  timeline text, shotlist text,
  youtube_url text, drive_url text, invoice_no text
)
language sql security definer set search_path = public as $$
  select p.id, p.display_name, p.wedding_date, p.venue,
         p.package_name, p.status, p.edit_stage,
         p.amount, p.paid, p.balance, p.timeline, p.shotlist,
         case when p.status = '납품' then p.youtube_url end,
         case when p.status = '납품' then p.drive_url   end,
         case when p.status = '납품' then p.invoice_no  end
    from public.projects p
   where p.studio_id = public.studio_id_by_slug(p_slug)
     and p.status <> '문의'
     and p.phone_digits = regexp_replace(p_phone,'[^0-9]','','g')
     and (p.groom = btrim(p_name) or p.bride = btrim(p_name))
   limit 1;
$$;

create or replace function public.get_payment_summary(p_slug text, p_name text, p_phone text)
returns table (
  id uuid, display_name text, wedding_date date,
  package_name text, amount integer, paid integer, balance integer, deposit_due integer
)
language sql security definer set search_path = public as $$
  with sid as (select public.studio_id_by_slug(p_slug) v),
       fixed as (select coalesce((value->>'depositFixed')::int, 300000) d
                   from public.app_settings
                  where key = 'pricing' and studio_id = (select v from sid))
  select p.id, p.display_name, p.wedding_date, p.package_name,
         p.amount, p.paid, p.balance,
         greatest(0, least(coalesce((select d from fixed),300000) - p.paid, p.balance))
    from public.projects p
   where p.studio_id = (select v from sid)
     and p.status <> '문의'
     and p.phone_digits = regexp_replace(p_phone,'[^0-9]','','g')
     and (p.groom = btrim(p_name) or p.bride = btrim(p_name))
   limit 1;
$$;

create or replace function public.submit_inquiry(
  p_slug text,
  p_groom text, p_bride text, p_phone text, p_date date,
  p_venue text default null, p_region text default null,
  p_package_id text default null, p_package_name text default null,
  p_options jsonb default '[]'::jsonb, p_sns boolean default false,
  p_amount integer default 0, p_source text default null, p_memo text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare new_id uuid; sid uuid;
begin
  sid := public.studio_id_by_slug(p_slug);
  if sid is null then raise exception '존재하지 않는 스튜디오입니다'; end if;
  if btrim(coalesce(p_groom,'')) = '' or btrim(coalesce(p_bride,'')) = ''
     or btrim(coalesce(p_phone,'')) = '' or p_date is null then
    raise exception '필수 항목이 누락되었습니다';
  end if;

  insert into public.projects
    (studio_id, groom, bride, phone, wedding_date, venue, venue_region,
     package_id, package_name, options, sns_agreed, amount, source, memo, status)
  values
    (sid, btrim(p_groom), btrim(p_bride), p_phone, p_date, p_venue, p_region,
     p_package_id, p_package_name, coalesce(p_options,'[]'::jsonb), p_sns,
     greatest(p_amount,0), p_source, p_memo, '문의')
  returning id into new_id;
  return new_id;
end $$;

-- 방문자용 설정 조회 (slug 기준)
create or replace function public.get_public_settings(p_slug text)
returns table (key text, value jsonb)
language sql security definer set search_path = public as $$
  select a.key, a.value from public.app_settings a
   where a.studio_id = public.studio_id_by_slug(p_slug);
$$;

grant execute on function public.get_public_booking_dates(text,date)        to anon, authenticated;
grant execute on function public.get_month_load(text,date)                  to anon, authenticated;
grant execute on function public.verify_client_booking(text,text,text)      to anon, authenticated;
grant execute on function public.get_payment_summary(text,text,text)        to anon, authenticated;
grant execute on function public.get_public_settings(text)                  to anon, authenticated;
grant execute on function public.submit_inquiry(text,text,text,text,date,text,text,text,text,jsonb,boolean,integer,text,text) to anon, authenticated;

-- 구버전(스튜디오 없는) 함수 제거
drop function if exists public.get_public_booking_dates(date);
drop function if exists public.get_month_load(date);
drop function if exists public.verify_client_booking(text,text);
drop function if exists public.get_payment_summary(text,text);
drop function if exists public.submit_inquiry(text,text,text,date,text,text,text,text,jsonb,boolean,integer,text,text);

-- ============================================================
-- 8. projects insert 시 studio_id 자동 채우기 (관리자가 직접 추가할 때)
-- ============================================================
create or replace function public.set_studio_id()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.studio_id is null then new.studio_id := public.my_studio_id(); end if;
  return new;
end $$;

drop trigger if exists projects_set_studio on public.projects;
create trigger projects_set_studio before insert on public.projects
  for each row execute function public.set_studio_id();

drop trigger if exists payments_set_studio on public.payments;
create trigger payments_set_studio before insert on public.payments
  for each row execute function public.set_studio_id();
