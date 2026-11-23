-- ============================================================
-- Database Webhook UI가 고장난 경우의 대안:
-- pg_net으로 직접 새 예약(문의) 발생 시 notify-kakao 함수를 호출하는 트리거
-- 실행 전: Database → Extensions 에서 pg_net 활성화 확인
-- ============================================================

create or replace function public.notify_kakao_trigger()
returns trigger
language plpgsql
as $$
begin
  if new.status = '문의' then
    perform net.http_post(
      url := 'https://jitajqvdquowumxowkdq.supabase.co/functions/v1/notify-kakao',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('type','INSERT','table','projects','record', row_to_json(new))
    );
  end if;
  return new;
end;
$$;

drop trigger if exists projects_notify_kakao on public.projects;
create trigger projects_notify_kakao
  after insert on public.projects
  for each row execute function public.notify_kakao_trigger();

-- 확인: 예약 문의를 하나 접수하면 아래로 최근 호출 기록이 보입니다 (pg_net 응답 로그)
-- select * from net._http_response order by created desc limit 5;
