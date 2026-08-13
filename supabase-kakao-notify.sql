-- ============================================================
-- 카카오톡 "나에게 보내기" 알림 기반 마련
-- 실행 순서: schema → multitenant → features → seed-content → viewlog → 이 파일
-- ============================================================

create table if not exists public.kakao_tokens (
  studio_id     uuid primary key references public.studios(id) on delete cascade,
  access_token  text not null,
  refresh_token text not null,
  updated_at    timestamptz not null default now()
);

alter table public.kakao_tokens enable row level security;

drop policy if exists studio_kakao_tokens on public.kakao_tokens;
create policy studio_kakao_tokens on public.kakao_tokens
  for all to authenticated
  using (studio_id = public.my_studio_id())
  with check (studio_id = public.my_studio_id());

-- 로그인 시 카카오 토큰을 저장 (프론트에서 호출)
create or replace function public.save_kakao_token(p_access_token text, p_refresh_token text)
returns void
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  sid := public.my_studio_id();
  if sid is null then return; end if;
  insert into public.kakao_tokens (studio_id, access_token, refresh_token, updated_at)
  values (sid, p_access_token, p_refresh_token, now())
  on conflict (studio_id) do update
    set access_token = excluded.access_token,
        refresh_token = excluded.refresh_token,
        updated_at = now();
end $$;

grant execute on function public.save_kakao_token(text,text) to authenticated;

-- Edge Function이 서비스 롤로 토큰을 갱신할 때 쓸 업데이트 권한 (RLS 우회는 service_role 키가 이미 처리)
