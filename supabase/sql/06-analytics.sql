-- ============================================================
-- 방문자 / 마케팅 분석
-- Supabase SQL Editor 에서 전체 실행
-- ============================================================

create table if not exists public.site_events (
  id          bigserial primary key,
  studio_id   uuid not null references public.studios(id) on delete cascade,
  visitor_id  text not null,
  kind        text not null,          -- 'visit' | 'quote' | 'kakao'
  created_at  timestamptz not null default now()
);

create index if not exists site_events_studio_kind_idx on public.site_events(studio_id, kind);
create unique index if not exists site_events_visit_uniq
  on public.site_events(studio_id, visitor_id, kind);

alter table public.site_events enable row level security;

drop policy if exists site_events_owner_read on public.site_events;
create policy site_events_owner_read on public.site_events
  for select using (
    studio_id in (select id from public.studios where owner_id = auth.uid())
  );

-- 방문자 기록 (중복 방문자는 무시)
create or replace function public.track_event(p_slug text, p_visitor text, p_kind text)
returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if p_kind not in ('visit','quote','kakao') then return; end if;
  sid := public.studio_id_by_slug(p_slug);
  if sid is null or coalesce(btrim(p_visitor),'') = '' then return; end if;
  insert into public.site_events (studio_id, visitor_id, kind)
  values (sid, btrim(p_visitor), p_kind)
  on conflict do nothing;
end $$;

grant execute on function public.track_event(text,text,text) to anon, authenticated;

-- 관리자용 집계
create or replace function public.get_marketing_stats()
returns table (visitors integer, quotes integer, kakaos integer)
language sql security definer set search_path = public as $$
  select
    count(*) filter (where kind = 'visit')::int,
    count(*) filter (where kind = 'quote')::int,
    count(*) filter (where kind = 'kakao')::int
  from public.site_events
  where studio_id in (select id from public.studios where owner_id = auth.uid());
$$;

grant execute on function public.get_marketing_stats() to authenticated;

-- 통계 초기화
create or replace function public.reset_marketing_stats()
returns void
language sql security definer set search_path = public as $$
  delete from public.site_events
  where studio_id in (select id from public.studios where owner_id = auth.uid());
$$;

grant execute on function public.reset_marketing_stats() to authenticated;
