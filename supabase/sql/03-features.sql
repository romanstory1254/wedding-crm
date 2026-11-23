-- ============================================================
-- 추가 기능: 휴무일 / 식순표 업로드 / 촬영 체크리스트 / 문의 응대
-- 실행 순서: supabase-schema.sql → supabase-multitenant.sql
--            → supabase-seed-content.sql → 이 파일
-- ============================================================

-- ============================================================
-- 1. blackout_dates — 휴무일·개인 일정 차단
-- ============================================================
create table if not exists public.blackout_dates (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid not null references public.studios(id) on delete cascade,
  date       date not null,
  reason     text,
  created_at timestamptz not null default now(),
  unique (studio_id, date)
);

alter table public.blackout_dates enable row level security;

drop policy if exists studio_blackout on public.blackout_dates;
create policy studio_blackout on public.blackout_dates
  for all to authenticated
  using (studio_id = public.my_studio_id())
  with check (studio_id = public.my_studio_id());

drop trigger if exists blackout_set_studio on public.blackout_dates;
create trigger blackout_set_studio before insert on public.blackout_dates
  for each row execute function public.set_studio_id();

-- 방문자용: 휴무일 목록 (사유는 내보내지 않음)
create or replace function public.get_blackout_dates(p_slug text, from_date date default current_date)
returns table (date date)
language sql security definer set search_path = public as $$
  select b.date from public.blackout_dates b
   where b.studio_id = public.studio_id_by_slug(p_slug) and b.date >= from_date;
$$;
grant execute on function public.get_blackout_dates(text,date) to anon, authenticated;

-- 예약 접수 시 휴무일이면 거부
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
  if exists (select 1 from public.blackout_dates where studio_id = sid and date = p_date) then
    raise exception '해당 일자는 촬영이 어렵습니다';
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
grant execute on function public.submit_inquiry(text,text,text,text,date,text,text,text,text,jsonb,boolean,integer,text,text) to anon, authenticated;

-- ============================================================
-- 2. projects 확장 — 체크리스트 / 식순표 파일 / 응대 기록
-- ============================================================
alter table public.projects add column if not exists checklist       jsonb   not null default '[]'::jsonb;
alter table public.projects add column if not exists timeline_files  jsonb   not null default '[]'::jsonb;
alter table public.projects add column if not exists first_replied_at timestamptz;

-- ============================================================
-- 3. Storage — 고객이 올리는 식순표 파일
-- ============================================================
insert into storage.buckets (id, name, public)
values ('client-files', 'client-files', true)
on conflict (id) do nothing;

drop policy if exists client_files_upload on storage.objects;
create policy client_files_upload on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'client-files');

drop policy if exists client_files_read on storage.objects;
create policy client_files_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'client-files');

-- 업로드한 파일을 본인 예약에 연결 (이름+연락처 확인 후에만)
create or replace function public.attach_client_file(
  p_slug text, p_name text, p_phone text, p_url text, p_filename text
) returns boolean
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  select p.id into pid from public.projects p
   where p.studio_id = public.studio_id_by_slug(p_slug)
     and p.status <> '문의'
     and p.phone_digits = regexp_replace(p_phone,'[^0-9]','','g')
     and (p.groom = btrim(p_name) or p.bride = btrim(p_name))
   limit 1;
  if pid is null then return false; end if;

  update public.projects
     set timeline_files = timeline_files || jsonb_build_object(
           'url', p_url, 'name', p_filename, 'at', now()
         )
   where id = pid;
  return true;
end $$;
grant execute on function public.attach_client_file(text,text,text,text,text) to anon, authenticated;

-- 고객 포털에서 올린 파일 목록을 되돌려받기 위해 verify_client_booking 확장
-- (반환 컬럼이 바뀌므로 먼저 기존 함수를 삭제해야 합니다)
drop function if exists public.verify_client_booking(text,text,text);

create or replace function public.verify_client_booking(p_slug text, p_name text, p_phone text)
returns table (
  id uuid, display_name text, wedding_date date, venue text,
  package_name text, status project_status, edit_stage edit_stage,
  amount integer, paid integer, balance integer,
  timeline text, shotlist text, timeline_files jsonb,
  youtube_url text, drive_url text, invoice_no text
)
language sql security definer set search_path = public as $$
  select p.id, p.display_name, p.wedding_date, p.venue,
         p.package_name, p.status, p.edit_stage,
         p.amount, p.paid, p.balance, p.timeline, p.shotlist, p.timeline_files,
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
grant execute on function public.verify_client_booking(text,text,text) to anon, authenticated;

-- ============================================================
-- 4. 기본 촬영 체크리스트를 설정에 추가
-- ============================================================
do $$
declare sid uuid;
declare items jsonb := '[
  {"id":"bat","label":"배터리 전량 충전 (본체 4 + 짐벌 2)"},
  {"id":"sd","label":"메모리카드 포맷 · 여유 용량 확인"},
  {"id":"lens","label":"렌즈 청소 · 필터 확인"},
  {"id":"fix","label":"고정캠 삼각대 2대 · 포토테이블 무인캠"},
  {"id":"aud","label":"핀마이크 배터리 · 녹음기 테스트"},
  {"id":"route","label":"예식장 주차·반입 동선 확인"},
  {"id":"order","label":"식순표 재확인 · 필수 컷 메모"},
  {"id":"snap","label":"동행 스냅 업체 연락처 저장"}
]'::jsonb;
begin
  select id into sid from public.studios where slug = 'romancestory' limit 1;
  insert into public.app_settings (studio_id, key, value) values (sid, 'checklist', items)
  on conflict (studio_id, key) do nothing;

  insert into public.setting_defaults (key, value) values ('checklist', items)
  on conflict (key) do update set value = excluded.value;
end $$;
