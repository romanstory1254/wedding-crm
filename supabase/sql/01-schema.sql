-- ============================================================
-- 로맨스토리 웨딩 CRM — Supabase 초기 스키마
-- Supabase → SQL Editor → New query → 전체 붙여넣기 → Run
-- 한 번만 실행하면 됩니다. (재실행해도 안전하도록 작성됨)
-- ============================================================

create extension if not exists "pgcrypto";

-- ============================================================
-- 1. ENUM 타입
-- ============================================================
do $$ begin
  create type project_status as enum ('문의','예약','촬영','편집','납품');
exception when duplicate_object then null; end $$;

do $$ begin
  create type edit_stage as enum ('원본 백업','1차 컷편집','색보정','사운드·렌더링');
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_kind as enum ('deposit','balance','refund');
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_method as enum ('transfer','kakao','toss','cash');
exception when duplicate_object then null; end $$;

-- ============================================================
-- 2. projects — 예약 / 문의 본체
-- ============================================================
create table if not exists public.projects (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- 고객 정보
  groom         text not null,
  bride         text not null,
  display_name  text generated always as (bride || ' · ' || groom) stored,
  phone         text not null,
  phone_digits  text generated always as (regexp_replace(phone,'[^0-9]','','g')) stored,
  email         text,
  source        text,                      -- 유입 경로 (네이버 블로그, 인스타그램 …)

  -- 예식 정보
  wedding_date  date not null,
  venue         text,
  venue_region  text,                      -- 출장 지역 id (metro, cw, gj, jeju)
  memo          text,

  -- 상품 / 금액
  package_id    text,
  package_name  text,
  options       jsonb not null default '[]'::jsonb,
  sns_agreed    boolean not null default false,
  amount        integer not null default 0,   -- 총 계약 금액
  paid          integer not null default 0,   -- 입금 합계 (payments 트리거로 자동 갱신)
  balance       integer generated always as (greatest(amount - paid, 0)) stored,

  -- 진행 상태
  status        project_status not null default '문의',
  edit_stage    edit_stage     not null default '원본 백업',

  -- 촬영 준비
  timeline      text,                      -- 예식 시간표
  shotlist      text,                      -- 꼭 담아야 할 순간

  -- 납품
  youtube_url   text,
  drive_url     text,
  invoice_no    text,
  delivered_at  timestamptz
);

create index if not exists projects_wedding_date_idx on public.projects (wedding_date);
create index if not exists projects_status_idx       on public.projects (status);
create index if not exists projects_phone_idx        on public.projects (phone_digits);

-- updated_at 자동 갱신
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists projects_touch on public.projects;
create trigger projects_touch before update on public.projects
  for each row execute function public.touch_updated_at();

-- ============================================================
-- 3. payments — 입금 내역
-- ============================================================
create table if not exists public.payments (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  project_id  uuid not null references public.projects(id) on delete cascade,
  kind        payment_kind   not null,
  method      payment_method not null default 'transfer',
  amount      integer not null,
  paid_at     timestamptz not null default now(),
  payer_name  text,                       -- 입금자명
  pg_order_id text,                       -- 토스페이먼츠 orderId
  pg_key      text,                       -- 토스페이먼츠 paymentKey
  receipt_url text,
  note        text
);

create index if not exists payments_project_idx on public.payments (project_id);

-- 입금 내역이 바뀌면 projects.paid 를 자동으로 다시 계산
create or replace function public.recalc_paid()
returns trigger language plpgsql as $$
declare pid uuid;
begin
  pid := coalesce(new.project_id, old.project_id);
  update public.projects p
     set paid = coalesce((
           select sum(case when kind = 'refund' then -amount else amount end)
             from public.payments where project_id = pid), 0)
   where p.id = pid;
  return null;
end $$;

drop trigger if exists payments_recalc on public.payments;
create trigger payments_recalc after insert or update or delete on public.payments
  for each row execute function public.recalc_paid();

-- ============================================================
-- 4. contracts — 계약서 스냅샷 + 전자서명
-- ============================================================
create table if not exists public.contracts (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  project_id   uuid not null references public.projects(id) on delete cascade,
  snapshot     jsonb not null,            -- 발급 당시 계약 내용 전체
  signed       boolean not null default false,
  signed_at    timestamptz,
  signed_ip    text,
  signer_name  text,
  pdf_url      text
);

create index if not exists contracts_project_idx on public.contracts (project_id);

-- ============================================================
-- 5. app_settings — CMS (홈페이지 문구, 가격, 템플릿)
-- ============================================================
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

drop trigger if exists settings_touch on public.app_settings;
create trigger settings_touch before update on public.app_settings
  for each row execute function public.touch_updated_at();

-- 설정 행의 자리만 만들어 둡니다. 실제 문구·가격은
-- supabase-seed-content.sql 을 실행해서 채워 넣으세요.
-- (비어 있으면 앱이 코드에 내장된 기본값을 사용합니다)
insert into public.app_settings (key, value) values
('homepage',  '{}'::jsonb),
('pricing',   '{}'::jsonb),
('templates', '{}'::jsonb)
on conflict (key) do nothing;

-- ============================================================
-- 6. 보안 — RLS 활성화
--    projects / payments / contracts 는 기본적으로 아무도 못 읽습니다.
--    로그인한 관리자(authenticated)만 통과.
-- ============================================================
alter table public.projects     enable row level security;
alter table public.payments     enable row level security;
alter table public.contracts    enable row level security;
alter table public.app_settings enable row level security;

-- 관리자(로그인 사용자) = 전권
drop policy if exists admin_all_projects  on public.projects;
create policy admin_all_projects  on public.projects
  for all to authenticated using (true) with check (true);

drop policy if exists admin_all_payments  on public.payments;
create policy admin_all_payments  on public.payments
  for all to authenticated using (true) with check (true);

drop policy if exists admin_all_contracts on public.contracts;
create policy admin_all_contracts on public.contracts
  for all to authenticated using (true) with check (true);

-- app_settings 는 홈페이지가 읽어야 하므로 읽기만 공개
drop policy if exists public_read_settings on public.app_settings;
create policy public_read_settings on public.app_settings
  for select to anon, authenticated using (true);

drop policy if exists admin_write_settings on public.app_settings;
create policy admin_write_settings on public.app_settings
  for all to authenticated using (true) with check (true);

-- ⚠ anon(방문자)에게는 projects 정책을 주지 않습니다.
--    따라서 select * from projects 를 시도해도 0건이 나옵니다.
--    방문자에게 필요한 데이터는 아래 RPC 함수로만 나갑니다.

-- ============================================================
-- 7. RPC — 방문자용 안전 통로
-- ============================================================

-- (1) 예약 가능 여부 캘린더용 — 날짜와 마감 여부만. 개인정보 없음.
create or replace function public.get_public_booking_dates(from_date date default current_date)
returns table (wedding_date date, is_taken boolean)
language sql security definer set search_path = public as $$
  select p.wedding_date, true
    from public.projects p
   where p.status <> '문의'
     and p.wedding_date >= from_date
   group by p.wedding_date;
$$;

-- (2) 월별 확정 건수 — FOMO 메시지용
create or replace function public.get_month_load(from_date date default current_date)
returns table (ym text, booked integer)
language sql security definer set search_path = public as $$
  select to_char(p.wedding_date,'YYYY-MM'), count(*)::int
    from public.projects p
   where p.status <> '문의'
     and p.wedding_date >= date_trunc('month', from_date)
   group by 1;
$$;

-- (3) 고객 조회 포털 — 이름+연락처가 정확히 일치할 때만 본인 1건
create or replace function public.verify_client_booking(p_name text, p_phone text)
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
         p.amount, p.paid, p.balance,
         p.timeline, p.shotlist,
         case when p.status = '납품' then p.youtube_url end,
         case when p.status = '납품' then p.drive_url   end,
         case when p.status = '납품' then p.invoice_no  end
    from public.projects p
   where p.status <> '문의'
     and p.phone_digits = regexp_replace(p_phone,'[^0-9]','','g')
     and (p.groom = btrim(p_name) or p.bride = btrim(p_name))
   limit 1;
$$;

-- (4) 결제 탭 — 금액 정보만. 연락처·납품링크는 반환하지 않음.
create or replace function public.get_payment_summary(p_name text, p_phone text)
returns table (
  id uuid, display_name text, wedding_date date,
  package_name text, amount integer, paid integer, balance integer,
  deposit_due integer
)
language sql security definer set search_path = public as $$
  with fixed as (select coalesce((value->>'depositFixed')::int, 300000) d
                   from public.app_settings where key = 'pricing')
  select p.id, p.display_name, p.wedding_date,
         p.package_name, p.amount, p.paid, p.balance,
         greatest(0, least((select d from fixed) - p.paid, p.balance))
    from public.projects p
   where p.status <> '문의'
     and p.phone_digits = regexp_replace(p_phone,'[^0-9]','','g')
     and (p.groom = btrim(p_name) or p.bride = btrim(p_name))
   limit 1;
$$;

-- (5) 문의 접수 — 방문자가 insert 권한 없이 문의만 넣을 수 있는 통로
create or replace function public.submit_inquiry(
  p_groom text, p_bride text, p_phone text, p_date date,
  p_venue text default null, p_region text default null,
  p_package_id text default null, p_package_name text default null,
  p_options jsonb default '[]'::jsonb, p_sns boolean default false,
  p_amount integer default 0, p_source text default null, p_memo text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if btrim(coalesce(p_groom,'')) = '' or btrim(coalesce(p_bride,'')) = ''
     or btrim(coalesce(p_phone,'')) = '' or p_date is null then
    raise exception '필수 항목이 누락되었습니다';
  end if;

  insert into public.projects
    (groom, bride, phone, wedding_date, venue, venue_region,
     package_id, package_name, options, sns_agreed, amount, source, memo, status)
  values
    (btrim(p_groom), btrim(p_bride), p_phone, p_date, p_venue, p_region,
     p_package_id, p_package_name, coalesce(p_options,'[]'::jsonb), p_sns,
     greatest(p_amount,0), p_source, p_memo, '문의')
  returning id into new_id;

  return new_id;
end $$;

-- 방문자(anon)에게 허용할 함수만 실행 권한 부여
revoke all on function public.get_public_booking_dates(date) from public;
revoke all on function public.get_month_load(date)           from public;
revoke all on function public.verify_client_booking(text,text) from public;
revoke all on function public.get_payment_summary(text,text)   from public;
revoke all on function public.submit_inquiry(text,text,text,date,text,text,text,text,jsonb,boolean,integer,text,text) from public;

grant execute on function public.get_public_booking_dates(date)  to anon, authenticated;
grant execute on function public.get_month_load(date)            to anon, authenticated;
grant execute on function public.verify_client_booking(text,text) to anon, authenticated;
grant execute on function public.get_payment_summary(text,text)   to anon, authenticated;
grant execute on function public.submit_inquiry(text,text,text,date,text,text,text,text,jsonb,boolean,integer,text,text) to anon, authenticated;

-- ============================================================
-- 8. 관리자용 집계 뷰 (대시보드 KPI)
-- ============================================================
create or replace view public.admin_kpi as
select
  count(*) filter (where status = '문의')                    as inquiries,
  count(*) filter (where status <> '문의')                   as booked,
  coalesce(sum(amount) filter (where status <> '문의'), 0)   as expected_revenue,
  coalesce(sum(balance) filter (where status <> '문의'), 0)  as outstanding
from public.projects;

-- ============================================================
-- 9. 확인용 — 실행 후 결과를 눈으로 검증
-- ============================================================
-- select * from public.app_settings;
-- select * from public.get_public_booking_dates();
-- select * from public.admin_kpi;
