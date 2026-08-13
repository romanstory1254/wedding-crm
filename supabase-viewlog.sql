-- ============================================================
-- 고객 조회 기록 + 새 예약 알림 기반 마련
-- 실행 순서: schema → multitenant → features → seed-content → 이 파일
-- ============================================================

alter table public.projects add column if not exists view_count    integer not null default 0;
alter table public.projects add column if not exists last_viewed_at timestamptz;

-- 고객이 조회 포털에 로그인(이름+연락처 확인)할 때마다 조회 기록을 남깁니다.
create or replace function public.verify_client_booking(p_slug text, p_name text, p_phone text)
returns table (
  id uuid, display_name text, wedding_date date, venue text,
  package_name text, status project_status, edit_stage edit_stage,
  amount integer, paid integer, balance integer,
  timeline text, shotlist text, timeline_files jsonb,
  youtube_url text, drive_url text, invoice_no text
)
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  select p.id into pid from public.projects p
   where p.studio_id = public.studio_id_by_slug(p_slug)
     and p.status <> '문의'
     and p.phone_digits = regexp_replace(p_phone,'[^0-9]','','g')
     and (p.groom = btrim(p_name) or p.bride = btrim(p_name))
   limit 1;

  if pid is not null then
    update public.projects
       set view_count = coalesce(view_count,0) + 1, last_viewed_at = now()
     where id = pid;
  end if;

  return query
    select p.id, p.display_name, p.wedding_date, p.venue,
           p.package_name, p.status, p.edit_stage,
           p.amount, p.paid, p.balance, p.timeline, p.shotlist, p.timeline_files,
           case when p.status = '납품' then p.youtube_url end,
           case when p.status = '납품' then p.drive_url   end,
           case when p.status = '납품' then p.invoice_no  end
      from public.projects p
     where p.id = pid;
end $$;

grant execute on function public.verify_client_booking(text,text,text) to anon, authenticated;
