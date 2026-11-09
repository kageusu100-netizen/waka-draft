-- 日程あわせ（schedule/）用のテーブルと関数
-- Supabase の SQL Editor に貼って一度実行すれば使えます（何度実行しても大丈夫）。
-- テーブルには直接アクセスさせず、すべて security definer の関数経由で読み書きする。
-- 主催者は admin_token、お客さんは edit_token を持っている人だけが操作できる。

create table if not exists public.sched_events (
  id          text primary key,
  admin_token text not null,
  title       text not null check (char_length(title) between 1 and 100),
  note        text not null default '' check (char_length(note) <= 1000),
  settings    jsonb not null,  -- {start,end,duration,gap,perDay,dayStart,dayEnd}
  deadline    timestamptz,     -- お客さんの入力締切（null なら締切なし）
  assignment  jsonb,           -- {response_id: {date,start,end} | null}
  published   boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.sched_responses (
  id         uuid primary key,
  event_id   text not null references public.sched_events(id) on delete cascade,
  edit_token text not null,
  name       text not null check (char_length(name) between 1 and 50),
  avail      jsonb not null,   -- [{date,from,to}]
  comment    text not null default '' check (char_length(comment) <= 500),
  by_admin   boolean not null default false,
  updated_at timestamptz not null default now()
);
create index if not exists sched_responses_event_idx on public.sched_responses(event_id);

alter table public.sched_events    enable row level security;
alter table public.sched_responses enable row level security;
revoke all on public.sched_events, public.sched_responses from anon, authenticated;

create or replace function public.sched_check_avail(p jsonb) returns void language plpgsql immutable as $$
begin
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) < 1 or jsonb_array_length(p) > 100 then
    raise exception 'bad avail';
  end if;
end $$;

-- 予定を作る
create or replace function public.sched_create_event(p_title text, p_note text, p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text; v_tok text;
begin
  v_id  := substr(replace(gen_random_uuid()::text,'-',''),1,10);
  v_tok := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  insert into sched_events(id, admin_token, title, note, settings)
  values (v_id, v_tok, p_title, coalesce(p_note,''), p_settings);
  return jsonb_build_object('id', v_id, 'admin_token', v_tok);
end $$;

-- お客さん向けの公開情報（ほかの人の入力は見えない）
create or replace function public.sched_get_event(p_id text)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'title', title, 'note', note, 'settings', settings,
    'deadline', deadline, 'published', published,
    'open', assignment is null and (deadline is null or now() <= deadline))
  from sched_events where id = p_id;
$$;

-- 自分の入力と（公開済みなら）決まった日時
create or replace function public.sched_get_my(p_response_id uuid, p_edit_token text)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'name', r.name, 'avail', r.avail, 'comment', r.comment,
    'published', e.published,
    'assigned', case when e.published then coalesce(e.assignment -> (r.id::text), 'null'::jsonb) else null end)
  from sched_responses r join sched_events e on e.id = r.event_id
  where r.id = p_response_id and r.edit_token = p_edit_token;
$$;

-- お客さんが入力する／直す（受付中のみ）
create or replace function public.sched_submit(
  p_event_id text, p_response_id uuid, p_edit_token text, p_name text, p_avail jsonb, p_comment text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare e sched_events; v_old sched_responses;
begin
  select * into e from sched_events where id = p_event_id;
  if not found then raise exception 'not found'; end if;
  if e.assignment is not null or (e.deadline is not null and now() > e.deadline) then raise exception 'closed'; end if;
  perform sched_check_avail(p_avail);
  select * into v_old from sched_responses where id = p_response_id;
  if found then
    if v_old.edit_token <> p_edit_token or v_old.event_id <> p_event_id then raise exception 'forbidden'; end if;
    update sched_responses set name = p_name, avail = p_avail, comment = coalesce(p_comment,''), updated_at = now()
      where id = p_response_id;
  else
    if (select count(*) from sched_responses where event_id = p_event_id) >= 300 then raise exception 'too many'; end if;
    insert into sched_responses(id, event_id, edit_token, name, avail, comment)
      values (p_response_id, p_event_id, p_edit_token, p_name, p_avail, coalesce(p_comment,''));
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.sched_withdraw(p_response_id uuid, p_edit_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  delete from sched_responses r using sched_events e
   where r.id = p_response_id and r.edit_token = p_edit_token and e.id = r.event_id
     and e.assignment is null and (e.deadline is null or now() <= e.deadline);
  return jsonb_build_object('ok', found);
end $$;

-- 主催者向け：全員の入力つきで取得
create or replace function public.sched_admin_get(p_id text, p_admin_token text)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'title', title, 'note', note, 'settings', settings,
    'deadline', deadline, 'assignment', assignment, 'published', published,
    'responses', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.id, 'name', r.name, 'avail', r.avail, 'comment', r.comment, 'by_admin', r.by_admin, 'updated_at', r.updated_at)
        order by r.name) from sched_responses r where r.event_id = e.id), '[]'::jsonb))
  from sched_events e where id = p_id and admin_token = p_admin_token;
$$;

-- 主催者向け：お客さんの空き日を代わりに入力・修正・削除
create or replace function public.sched_admin_put_response(
  p_id text, p_admin_token text, p_response_id uuid, p_name text, p_avail jsonb, p_comment text
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sched_events where id = p_id and admin_token = p_admin_token) then raise exception 'forbidden'; end if;
  perform sched_check_avail(p_avail);
  insert into sched_responses(id, event_id, edit_token, name, avail, comment, by_admin)
    values (p_response_id, p_id, replace(gen_random_uuid()::text,'-',''), p_name, p_avail, coalesce(p_comment,''), true)
  on conflict (id) do update set name = excluded.name, avail = excluded.avail, comment = excluded.comment, updated_at = now()
    where sched_responses.event_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.sched_admin_delete_response(p_id text, p_admin_token text, p_response_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sched_events where id = p_id and admin_token = p_admin_token) then raise exception 'forbidden'; end if;
  delete from sched_responses where id = p_response_id and event_id = p_id;
  return jsonb_build_object('ok', found);
end $$;

-- 主催者向け：設定・締切・割り振り結果・公開状態を変更
create or replace function public.sched_admin_update(
  p_id text, p_admin_token text, p_patch jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update sched_events set
    title      = case when p_patch ? 'title'      then p_patch->>'title' else title end,
    note       = case when p_patch ? 'note'       then p_patch->>'note' else note end,
    settings   = case when p_patch ? 'settings'   then p_patch->'settings' else settings end,
    deadline   = case when p_patch ? 'deadline'   then (p_patch->>'deadline')::timestamptz else deadline end,
    assignment = case when p_patch ? 'assignment' then nullif(p_patch->'assignment','null'::jsonb) else assignment end,
    published  = case when p_patch ? 'published'  then (p_patch->>'published')::boolean else published end
  where id = p_id and admin_token = p_admin_token;
  if not found then raise exception 'forbidden'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.sched_admin_delete(p_id text, p_admin_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  delete from sched_events where id = p_id and admin_token = p_admin_token;
  return jsonb_build_object('ok', found);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'sched_create_event(text,text,jsonb)', 'sched_get_event(text)', 'sched_get_my(uuid,text)',
    'sched_submit(text,uuid,text,text,jsonb,text)', 'sched_withdraw(uuid,text)',
    'sched_admin_get(text,text)', 'sched_admin_put_response(text,text,uuid,text,jsonb,text)',
    'sched_admin_delete_response(text,text,uuid)', 'sched_admin_update(text,text,jsonb)', 'sched_admin_delete(text,text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
  revoke all on function public.sched_check_avail(jsonb) from public, anon, authenticated;
end $$;
