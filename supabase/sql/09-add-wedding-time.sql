alter table public.projects add column if not exists wedding_time text;

-- 예약 폼에서 예식 시간도 함께 받도록 submit_inquiry 갱신
create or replace function public.submit_inquiry(
  p_slug text,
  p_groom text, p_bride text, p_phone text, p_date date,
  p_venue text default null, p_region text default null,
  p_package_id text default null, p_package_name text default null,
  p_options jsonb default '[]'::jsonb, p_sns boolean default false,
  p_amount integer default 0, p_source text default null, p_memo text default null,
  p_time text default null
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
    (studio_id, groom, bride, phone, wedding_date, wedding_time, venue, venue_region,
     package_id, package_name, options, sns_agreed, amount, source, memo, status)
  values
    (sid, btrim(p_groom), btrim(p_bride), p_phone, p_date, p_time, p_venue, p_region,
     p_package_id, p_package_name, coalesce(p_options,'[]'::jsonb), p_sns,
     greatest(p_amount,0), p_source, p_memo, '문의')
  returning id into new_id;
  return new_id;
end $$;
grant execute on function public.submit_inquiry(text,text,text,text,date,text,text,text,text,jsonb,boolean,integer,text,text,text) to anon, authenticated;
