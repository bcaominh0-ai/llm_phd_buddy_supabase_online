-- 双人科研打卡站｜Supabase 在线共享版
-- 使用方式：在 Supabase Dashboard -> SQL Editor 中完整运行本文件。
-- 运行后，把生成的 invite_code 填入网页中的“共享邀请码”。

create extension if not exists pgcrypto;

-- 1) 科研搭子空间：一个 pair 对应你和搭子的一组共享打卡数据
create table if not exists public.buddy_pairs (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'LLM 博士生科研搭子',
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

-- 2) 空间成员：只有加入同一 pair 的账号才能读写该 pair 的记录
create table if not exists public.buddy_members (
  pair_id uuid not null references public.buddy_pairs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  joined_at timestamptz not null default now(),
  primary key (pair_id, user_id)
);

-- 3) 打卡记录
create table if not exists public.research_checkins (
  id uuid primary key default gen_random_uuid(),
  pair_id uuid not null references public.buddy_pairs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  person text not null,
  period text not null check (period in ('上午', '下午', '晚上')),
  category text not null,
  work text not null,
  output text,
  hours numeric(5,2) not null default 0 check (hours >= 0),
  pomodoros integer not null default 0 check (pomodoros >= 0),
  completion integer not null default 0 check (completion >= 0 and completion <= 100),
  energy integer not null default 3 check (energy >= 1 and energy <= 5),
  blocker text,
  next_step text,
  sync_done boolean not null default false,
  status text not null default '进行中',
  score numeric(8,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_research_checkins_pair_date on public.research_checkins(pair_id, date desc, created_at desc);
create index if not exists idx_buddy_members_user on public.buddy_members(user_id);

-- 4) 自动更新时间戳
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_research_checkins_updated_at on public.research_checkins;
create trigger trg_research_checkins_updated_at
before update on public.research_checkins
for each row execute function public.set_updated_at();

-- 5) 加入搭子空间：前端输入 invite_code 后调用这个函数，无需手工查 auth.users.id
create or replace function public.join_buddy_pair(p_invite_code text, p_display_name text default null)
returns table(pair_id uuid, pair_name text, display_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pair public.buddy_pairs%rowtype;
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'You must be authenticated to join a buddy pair.';
  end if;

  select * into v_pair
  from public.buddy_pairs
  where invite_code = p_invite_code;

  if not found then
    raise exception 'Invalid invite code.';
  end if;

  v_name := coalesce(
    nullif(trim(p_display_name), ''),
    nullif(current_setting('request.jwt.claim.email', true), ''),
    auth.uid()::text
  );

  insert into public.buddy_members(pair_id, user_id, display_name)
  values (v_pair.id, auth.uid(), v_name)
  on conflict (pair_id, user_id)
  do update set display_name = excluded.display_name;

  return query select v_pair.id, v_pair.name, v_name;
end;
$$;


-- Helper for RLS policies. SECURITY DEFINER avoids recursive RLS checks on buddy_members.
create or replace function public.is_buddy_member(p_pair_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.buddy_members m
    where m.pair_id = p_pair_id
      and m.user_id = auth.uid()
  );
$$;

revoke all on function public.is_buddy_member(uuid) from public;
grant execute on function public.is_buddy_member(uuid) to authenticated;

-- 6) RLS：只允许同一个 pair 的成员访问数据
alter table public.buddy_pairs enable row level security;
alter table public.buddy_members enable row level security;
alter table public.research_checkins enable row level security;

drop policy if exists "members can select their pairs" on public.buddy_pairs;
create policy "members can select their pairs"
on public.buddy_pairs
for select
to authenticated
using (public.is_buddy_member(id));

drop policy if exists "members can select same pair members" on public.buddy_members;
create policy "members can select same pair members"
on public.buddy_members
for select
to authenticated
using (public.is_buddy_member(pair_id));

drop policy if exists "members can update own display name" on public.buddy_members;
create policy "members can update own display name"
on public.buddy_members
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "members can select checkins" on public.research_checkins;
create policy "members can select checkins"
on public.research_checkins
for select
to authenticated
using (public.is_buddy_member(pair_id));

drop policy if exists "members can insert checkins" on public.research_checkins;
create policy "members can insert checkins"
on public.research_checkins
for insert
to authenticated
with check (
  user_id = auth.uid()
  and public.is_buddy_member(pair_id)
);

drop policy if exists "members can update checkins" on public.research_checkins;
create policy "members can update checkins"
on public.research_checkins
for update
to authenticated
using (public.is_buddy_member(pair_id))
with check (public.is_buddy_member(pair_id));

drop policy if exists "members can delete checkins" on public.research_checkins;
create policy "members can delete checkins"
on public.research_checkins
for delete
to authenticated
using (public.is_buddy_member(pair_id));

-- 7) API 权限
revoke all on function public.join_buddy_pair(text, text) from public;
grant execute on function public.join_buddy_pair(text, text) to authenticated;
grant usage on schema public to authenticated;
grant select on public.buddy_pairs to authenticated;
grant select, update on public.buddy_members to authenticated;
grant select, insert, update, delete on public.research_checkins to authenticated;

-- 8) 创建一个默认科研搭子空间。
-- 你可以把 invite_code 改成更私密的字符串，例如 'dmnes-stageweaver-2026-xxxx'。
insert into public.buddy_pairs(name, invite_code)
values ('LLM 博士生科研搭子', 'llm-buddy-2026')
on conflict (invite_code) do nothing;
