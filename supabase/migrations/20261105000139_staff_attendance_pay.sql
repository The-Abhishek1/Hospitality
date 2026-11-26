-- Hotel employee records are independent of team logins. Financial data is manager-only.
create table public.hotel_staff(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id)on delete cascade,
 code text not null check(length(code)between 1 and 30),full_name text not null check(length(full_name)between 2 and 120),
 department text not null default ''check(length(department)<=80),phone text not null default ''check(length(phone)<=40),email text not null default ''check(length(email)<=254),
 joined_on date not null,active boolean not null default true,version integer not null default 1,created_at timestamptz not null default now(),unique(property_id,code),unique(id,property_id)
);
create table public.staff_salary_rates(
 staff_id uuid not null,property_id uuid not null,effective_month date not null check(extract(day from effective_month)=1),
 monthly_salary numeric(14,2)not null check(monthly_salary between 0 and 999999999),actor uuid,created_at timestamptz not null default now(),
 primary key(staff_id,effective_month),foreign key(staff_id,property_id)references public.hotel_staff(id,property_id)on delete cascade
);
create table public.staff_attendance(
 staff_id uuid not null,property_id uuid not null,day date not null,status text not null check(status in('present','half_day','absent','paid_leave','unpaid_leave','weekly_off')),
 note text not null default ''check(length(note)<=500),version integer not null default 1,actor uuid,updated_at timestamptz not null default now(),
 primary key(staff_id,day),foreign key(staff_id,property_id)references public.hotel_staff(id,property_id)on delete cascade
);
create table public.staff_leave_requests(
 id uuid primary key default gen_random_uuid(),staff_id uuid not null,property_id uuid not null,start_day date not null,end_day date not null,
 paid boolean not null default false,status text not null default 'pending'check(status in('pending','approved','rejected')),
 reason text not null check(length(reason)between 3 and 500),version integer not null default 1,actor uuid,reviewed_at timestamptz,created_at timestamptz not null default now(),
 check(end_day>=start_day and end_day-start_day<31),foreign key(staff_id,property_id)references public.hotel_staff(id,property_id)on delete cascade
);
create table private.staff_commands(property_id uuid not null references public.properties(id)on delete cascade,request_id uuid not null,actor uuid not null,action text not null,payload jsonb not null,created_at timestamptz not null default now(),primary key(property_id,request_id));
revoke all on private.staff_commands from public,anon,authenticated,service_role;
create table public.staff_activity(id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id)on delete cascade,actor uuid,action text not null,details jsonb not null,created_at timestamptz not null default now());
do $$declare tab text;begin foreach tab in array array['hotel_staff','staff_salary_rates','staff_attendance','staff_leave_requests','staff_activity']loop
 execute format('alter table public.%I enable row level security',tab);
 execute format('create policy staff_manager_read on public.%I for select to authenticated using(private.has_permission(property_id,''staff.manage''))',tab);
 execute format('revoke all on public.%I from anon,authenticated',tab);
 end loop;end $$;

create function public.staff_manage(p_property uuid,p_request uuid,p_action text,p_data jsonb)returns void language plpgsql security definer set search_path=''as $$
declare cmd private.staff_commands;row jsonb;emp public.hotel_staff;ids uuid[];sid uuid;target_day date;finish date;month date;salary numeric;leave public.staff_leave_requests;n integer;begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel staff manager access required.'using errcode='42501';end if;
 perform 1 from public.properties where id=p_property and archived_at is null for update;if not found then raise exception 'Active hotel required.'using errcode='22023';end if;
 if p_request is null or p_data is null or jsonb_typeof(p_data)<>'object'or pg_column_size(p_data)>250000 then raise exception 'Reload this form.'using errcode='22023';end if;
 select *into cmd from private.staff_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.actor<>auth.uid()or cmd.action<>p_action or cmd.payload<>p_data then raise exception 'Request already used.'using errcode='22023';end if;return;end if;
 if p_action in('create','import')then
  if p_action='create'then p_data:=jsonb_build_object('rows',jsonb_build_array(p_data));end if;
  if jsonb_typeof(p_data->'rows')is distinct from'array'or jsonb_array_length(p_data->'rows')not between 1 and 200 then raise exception 'Import 1–200 employees at a time.'using errcode='22023';end if;
  for row in select *from jsonb_array_elements(p_data->'rows')loop
   if length(trim(coalesce(row->>'code','')))not between 1 and 30 or length(trim(coalesce(row->>'full_name','')))not between 2 and 120 or length(coalesce(row->>'department',''))>80 or length(coalesce(row->>'phone',''))>40 or length(coalesce(row->>'email',''))>254 then raise exception 'Check staff code, name and contact lengths.'using errcode='22023';end if;
   target_day:=(row->>'joined_on')::date;salary:=nullif(row->>'monthly_salary','')::numeric;
   if target_day is null or target_day not between date '2000-01-01'and current_date+366 or salary is not null and(salary<0 or salary>999999999 or salary<>round(salary,2))then raise exception 'Check joining date and salary.'using errcode='22023';end if;
   if exists(select 1 from public.hotel_staff where property_id=p_property and lower(code)=lower(trim(row->>'code')))then raise exception 'A staff code already exists. Import creates new employees; edit existing employees separately.'using errcode='22023';end if;
   insert into public.hotel_staff(property_id,code,full_name,department,phone,email,joined_on)values(p_property,trim(row->>'code'),trim(row->>'full_name'),trim(coalesce(row->>'department','')),trim(coalesce(row->>'phone','')),trim(coalesce(row->>'email','')),target_day)returning id into sid;
   if salary is not null then insert into public.staff_salary_rates(staff_id,property_id,effective_month,monthly_salary,actor)values(sid,p_property,date_trunc('month',target_day)::date,salary,auth.uid());end if;
  end loop;
 elsif p_action='edit'then
  select *into emp from public.hotel_staff where id=(p_data->>'id')::uuid and property_id=p_property for update;
  if emp.id is null or emp.version<>(p_data->>'version')::integer then raise exception 'Staff record changed. Refresh first.'using errcode='40001';end if;
  if length(trim(coalesce(p_data->>'full_name','')))not between 2 and 120 or length(coalesce(p_data->>'department',''))>80 or length(coalesce(p_data->>'phone',''))>40 or length(coalesce(p_data->>'email',''))>254 or p_data->>'active'not in('true','false')then raise exception 'Check staff details.'using errcode='22023';end if;
  update public.hotel_staff set full_name=trim(p_data->>'full_name'),department=trim(p_data->>'department'),phone=trim(p_data->>'phone'),email=trim(p_data->>'email'),active=(p_data->>'active')::boolean,version=version+1 where id=emp.id;
 elsif p_action in('attendance','salary')then
  if jsonb_typeof(p_data->'ids')is distinct from'array'or jsonb_array_length(p_data->'ids')not between 1 and 200 then raise exception 'Select 1–200 staff members.'using errcode='22023';end if;
  select array_agg(distinct value::uuid)into ids from jsonb_array_elements_text(p_data->'ids');
  if exists(select 1 from unnest(ids)x where not exists(select 1 from public.hotel_staff s where s.id=x and s.property_id=p_property and s.active))then raise exception 'Choose active employees from this hotel.'using errcode='22023';end if;
  if p_action='salary'then
   month:=(p_data->>'month')::date;salary:=(p_data->>'amount')::numeric;
   if month is null or extract(day from month)<>1 or month not between date '2000-01-01'and current_date+366 or salary is null or salary<0 or salary>999999999 or salary<>round(salary,2)then raise exception 'Check salary and effective month.'using errcode='22023';end if;
   insert into public.staff_salary_rates(staff_id,property_id,effective_month,monthly_salary,actor)select x,p_property,month,salary,auth.uid()from unnest(ids)x on conflict(staff_id,effective_month)do update set monthly_salary=excluded.monthly_salary,actor=auth.uid(),created_at=now();
  else
   target_day:=(p_data->>'day')::date;
   if target_day is null or target_day>current_date or p_data->>'status'not in('present','half_day','absent','paid_leave','unpaid_leave','weekly_off')or length(coalesce(p_data->>'note',''))>500 then raise exception 'Choose a past or current date and valid attendance status.'using errcode='22023';end if;
   if exists(select 1 from public.hotel_staff where id=any(ids)and joined_on>target_day)then raise exception 'Attendance cannot precede joining date.'using errcode='22023';end if;
   if exists(select 1 from public.staff_attendance where staff_id=any(ids)and target_day=staff_attendance.day)and coalesce((p_data->>'replace')::boolean,false)is not true then raise exception 'Some staff already have attendance for this date. Select Replace existing to correct them.'using errcode='22023';end if;
   insert into public.staff_attendance(staff_id,property_id,day,status,note,actor)select x,p_property,target_day,p_data->>'status',coalesce(p_data->>'note',''),auth.uid()from unnest(ids)x on conflict(staff_id,day)do update set status=excluded.status,note=excluded.note,actor=auth.uid(),updated_at=now(),version=staff_attendance.version+1;
  end if;
 elsif p_action='leave'then
  select *into emp from public.hotel_staff where id=(p_data->>'staff_id')::uuid and property_id=p_property and active for update;
  target_day:=(p_data->>'from')::date;finish:=(p_data->>'to')::date;
  if emp.id is null or target_day is null or finish is null or target_day<emp.joined_on or finish<target_day or finish-target_day>=31 or length(trim(coalesce(p_data->>'reason','')))not between 3 and 500 then raise exception 'Choose an employee, 1–31 leave days and a reason.'using errcode='22023';end if;
  insert into public.staff_leave_requests(staff_id,property_id,start_day,end_day,paid,reason,actor)values(emp.id,p_property,target_day,finish,coalesce((p_data->>'paid')::boolean,false),trim(p_data->>'reason'),auth.uid());
 elsif p_action='review_leave'then
  select *into leave from public.staff_leave_requests where id=(p_data->>'id')::uuid and property_id=p_property for update;
  if leave.id is null or leave.version<>(p_data->>'version')::integer or leave.status<>'pending'or p_data->>'status'not in('approved','rejected')then raise exception 'Leave request changed. Refresh first.'using errcode='40001';end if;
  if p_data->>'status'='approved'then
   if exists(select 1 from public.staff_attendance a where a.staff_id=leave.staff_id and a.day between leave.start_day and leave.end_day)then raise exception 'Attendance already exists in this leave period. Correct it before approving.'using errcode='22023';end if;
   insert into public.staff_attendance(staff_id,property_id,day,status,note,actor)select leave.staff_id,p_property,x::date,case when leave.paid then'paid_leave'else'unpaid_leave'end,leave.reason,auth.uid()from generate_series(leave.start_day::timestamp,leave.end_day::timestamp,interval '1 day')x;
  end if;
  update public.staff_leave_requests set status=p_data->>'status',version=version+1,actor=auth.uid(),reviewed_at=now()where id=leave.id;
 else raise exception 'Unknown staff action.'using errcode='22023';end if;
 insert into private.staff_commands values(p_property,p_request,auth.uid(),p_action,case when p_action='create'then p_data->'rows'->0 else p_data end,now());
 insert into public.staff_activity(property_id,actor,action,details)values(p_property,auth.uid(),p_action,jsonb_build_object('request',p_request,'count',coalesce(array_length(ids,1),case when p_action in('create','import')then jsonb_array_length(p_data->'rows')else 1 end)));
end $$;

create function public.staff_workspace(p_property uuid,p_month date,p_query text default '',p_page integer default 1)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare month date:=date_trunc('month',p_month)::date;finish date;zone text;today date;pg integer:=greatest(1,least(100000,p_page));begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel staff manager access required.'using errcode='42501';end if;
 if month is null or month not between date '2000-01-01'and date '2100-12-01'then raise exception 'Choose a valid month.'using errcode='22023';end if;
 finish:=(month+interval '1 month - 1 day')::date;select timezone into zone from public.properties where id=p_property;today:=(now()at time zone zone)::date;
 return jsonb_build_object('month',month,'today',today,'timezone',zone,'days',extract(day from finish),'page',pg,
 'total',(select count(*)from public.hotel_staff where property_id=p_property and(full_name ilike '%'||left(p_query,100)||'%'or code ilike '%'||left(p_query,100)||'%')),
 'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select s.*,rate.monthly_salary,
  count(a.*)filter(where a.status='present')as present,count(a.*)filter(where a.status='paid_leave')as paid_leave,count(a.*)filter(where a.status='weekly_off')as weekly_off,
  count(a.*)filter(where a.status in('absent','unpaid_leave'))as unpaid,count(a.*)filter(where a.status='half_day')as half_day,
  greatest(0,least(finish,today)-greatest(month,s.joined_on)+1)-count(a.*)filter(where a.day<=today)as unmarked,
  case when rate.monthly_salary is not null then round(rate.monthly_salary/extract(day from finish)*greatest(0,(finish-greatest(month,s.joined_on)+1)-count(a.*)filter(where a.status in('absent','unpaid_leave'))-0.5*count(a.*)filter(where a.status='half_day')),2)end as estimated_salary,
  coalesce(jsonb_object_agg(a.day::text,jsonb_build_object('status',a.status,'version',a.version,'note',a.note))filter(where a.day is not null),'{}'::jsonb)as attendance
 from public.hotel_staff s left join lateral(select monthly_salary from public.staff_salary_rates where staff_id=s.id and effective_month<=month order by effective_month desc limit 1)rate on true
 left join public.staff_attendance a on a.staff_id=s.id and a.day between month and finish
 where s.property_id=p_property and(s.full_name ilike '%'||left(p_query,100)||'%'or s.code ilike '%'||left(p_query,100)||'%')group by s.id,rate.monthly_salary order by s.active desc,s.full_name,s.id limit 25 offset(pg-1)*25)x),'[]'::jsonb),
 'leaves',coalesce((select jsonb_agg(to_jsonb(x))from(select l.*,s.full_name from public.staff_leave_requests l join public.hotel_staff s on s.id=l.staff_id where l.property_id=p_property and l.start_day<=finish and l.end_day>=month order by l.created_at desc limit 100)x),'[]'::jsonb),
 'activity',coalesce((select jsonb_agg(to_jsonb(x))from(select action,created_at,details from public.staff_activity where property_id=p_property order by created_at desc limit 20)x),'[]'::jsonb));
end $$;
revoke all on function public.staff_manage(uuid,uuid,text,jsonb),public.staff_workspace(uuid,date,text,integer)from public,anon;
grant execute on function public.staff_manage(uuid,uuid,text,jsonb),public.staff_workspace(uuid,date,text,integer)to authenticated;
