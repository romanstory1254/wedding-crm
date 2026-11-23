-- 현금영수증 / 세금계산서 신청 저장 (고객 → 관리자)
alter table public.projects add column if not exists receipt_request jsonb;

create or replace function public.submit_receipt_request(p_slug text, p_name text, p_phone text, p_req jsonb)
returns boolean
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  select p.id into pid from public.projects p
   where p.studio_id = public.studio_id_by_slug(p_slug)
     and p.phone_digits = regexp_replace(p_phone,'[^0-9]','','g')
     and (p.groom = btrim(p_name) or p.bride = btrim(p_name))
   limit 1;
  if pid is null then return false; end if;
  update public.projects p2
     set receipt_request = coalesce(p_req,'{}'::jsonb) || jsonb_build_object('requestedAt', now(), 'done', false)
   where p2.id = pid;
  return true;
end $$;

grant execute on function public.submit_receipt_request(text,text,text,jsonb) to anon, authenticated;
