-- =====================================================================
-- 유니로그 한 번에 실행 (12 + 13 + 14 + 15단계)
-- Supabase > SQL Editor > + (새 칸) 에 이 파일 내용을 전부 붙여넣고 Run 한 번만 누르세요.
-- 여러 번 실행해도 괜찮아요. (12~14를 이미 실행했어도 그냥 이걸 실행하면 돼요)
-- =====================================================================

-- =====================================================================
-- 유니로그 12단계: 로그인 없이 둘러보기 + 리뷰에 방문 인증 횟수 + 나만의 맛집 리스트
-- Supabase > SQL Editor > + (새 칸) 에 전부 붙여넣고 Run 하세요. 여러 번 실행해도 괜찮아요.
--
-- 1) 로그인 안 한 사람도 맛집·리뷰·로그톡·랭킹을 "보기만" 할 수 있어요
--    (쓰기·도움돼요·저장은 지금처럼 로그인한 사람만 돼요)
--    회원 정보는 닉네임·사진·학교·학번·등급처럼 원래 화면에 보이는 것만 보여요
-- 2) 리뷰마다 "그 사람이 이 가게에 방문 인증한 횟수"를 보여줘요 (언제 갔는지는 안 보여요)
-- 3) 맛집 리스트: 만들고, 링크로 공유하고, 다른 사람 리스트를 내 리스트로 복사할 수 있어요
-- =====================================================================

-- ---------- 1) 둘러보기 (로그인 안 한 사람은 읽기만) ----------
grant select on public.ul_places, public.ul_reviews, public.ul_posts, public.ul_comments to anon;
grant select (id, nick, photo_url, school_id, school_name, school_short, campus, year, status, helpful, verified, founder, created_at)
  on public.ul_profiles to anon;

drop policy if exists "guest read" on public.ul_places;
create policy "guest read" on public.ul_places for select to anon using (true);
drop policy if exists "guest read" on public.ul_reviews;
create policy "guest read" on public.ul_reviews for select to anon using (not hidden);
drop policy if exists "guest read" on public.ul_posts;
create policy "guest read" on public.ul_posts for select to anon using (not hidden);
drop policy if exists "guest read" on public.ul_comments;
create policy "guest read" on public.ul_comments for select to anon using (not hidden);
drop policy if exists "guest read" on public.ul_profiles;
create policy "guest read" on public.ul_profiles for select to anon using (status <> 'banned');

grant execute on function public.ul_ranking(text,text,int) to anon;
grant execute on function public.ul_place_regular(text) to anon;

-- ---------- 2) 리뷰에 보일 방문 인증 횟수 (가게별 · 사람별 횟수만) ----------
create or replace function public.ul_visit_counts(p_places text[])
returns table (place_id text, user_id uuid, n bigint)
language sql stable security definer set search_path = public as $$
  select v.place_id, v.user_id, count(*)::bigint
    from public.ul_visits v
   where v.place_id = any(p_places[1:200])
   group by v.place_id, v.user_id
$$;
grant execute on function public.ul_visit_counts(text[]) to anon, authenticated;

-- ---------- 3) 나만의 맛집 리스트 ----------
create table if not exists public.ul_lists (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.ul_profiles(id) on delete cascade,
  school_id text,
  title text not null check (char_length(btrim(title)) between 1 and 30),
  intro text not null default '' check (char_length(intro) <= 200),
  is_public boolean not null default true,
  copied_from bigint references public.ul_lists(id) on delete set null,
  copies int not null default 0,
  item_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ul_lists_user on public.ul_lists (user_id, updated_at desc);
create index if not exists ul_lists_school on public.ul_lists (school_id, is_public, updated_at desc);

create table if not exists public.ul_list_items (
  list_id bigint not null references public.ul_lists(id) on delete cascade,
  place_id text not null references public.ul_places(id) on delete cascade,
  note text not null default '' check (char_length(note) <= 60),
  pos int not null default 0,
  created_at timestamptz not null default now(),
  primary key (list_id, place_id)
);
create index if not exists ul_list_items_place on public.ul_list_items (place_id);

-- 리스트 만들 때: 주인·학교는 자동, 한 사람 30개까지
create or replace function public.ul_lists_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.user_id := auth.uid(); end if;
    new.school_id := (select school_id from public.ul_profiles where id = new.user_id);
    new.copies := 0; new.item_count := 0;
    if (select count(*) from public.ul_lists where user_id = new.user_id) >= 30 then
      raise exception '리스트는 30개까지 만들 수 있어요' using errcode = 'P0001';
    end if;
  else
    new.user_id := old.user_id; new.school_id := old.school_id; new.copied_from := old.copied_from;
  end if;
  new.title := btrim(new.title); new.updated_at := now();
  return new;
end $$;
drop trigger if exists ul_lists_before on public.ul_lists;
create trigger ul_lists_before before insert or update on public.ul_lists
  for each row execute function public.ul_lists_before();

-- 가게 담기/빼기: 개수 맞추기, 리스트 하나에 100곳까지
create or replace function public.ul_list_items_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if (select count(*) from public.ul_list_items where list_id = new.list_id) > 100 then
      raise exception '리스트 하나에 100곳까지 담을 수 있어요' using errcode = 'P0001';
    end if;
    update public.ul_lists set item_count = item_count + 1, updated_at = now() where id = new.list_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.ul_lists set item_count = greatest(0, item_count - 1), updated_at = now() where id = old.list_id;
    return old;
  end if;
  return new;
end $$;
drop trigger if exists ul_list_items_after on public.ul_list_items;
create trigger ul_list_items_after after insert or delete on public.ul_list_items
  for each row execute function public.ul_list_items_after();

alter table public.ul_lists enable row level security;
alter table public.ul_list_items enable row level security;

drop policy if exists "read" on public.ul_lists;
create policy "read" on public.ul_lists for select to anon, authenticated using (is_public or user_id = auth.uid());
drop policy if exists "own add" on public.ul_lists;
create policy "own add" on public.ul_lists for insert to authenticated with check (user_id = auth.uid() and public.ul_is_approved());
drop policy if exists "own edit" on public.ul_lists;
create policy "own edit" on public.ul_lists for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own delete" on public.ul_lists;
create policy "own delete" on public.ul_lists for delete to authenticated using (user_id = auth.uid() or public.ul_is_admin());

drop policy if exists "read" on public.ul_list_items;
create policy "read" on public.ul_list_items for select to anon, authenticated
  using (exists (select 1 from public.ul_lists l where l.id = list_id and (l.is_public or l.user_id = auth.uid())));
drop policy if exists "own add" on public.ul_list_items;
create policy "own add" on public.ul_list_items for insert to authenticated
  with check (exists (select 1 from public.ul_lists l where l.id = list_id and l.user_id = auth.uid()));
drop policy if exists "own edit" on public.ul_list_items;
create policy "own edit" on public.ul_list_items for update to authenticated
  using (exists (select 1 from public.ul_lists l where l.id = list_id and l.user_id = auth.uid()));
drop policy if exists "own delete" on public.ul_list_items;
create policy "own delete" on public.ul_list_items for delete to authenticated
  using (exists (select 1 from public.ul_lists l where l.id = list_id and l.user_id = auth.uid()));

grant select on public.ul_lists, public.ul_list_items to anon, authenticated;
grant insert (user_id, title, intro, is_public) on public.ul_lists to authenticated;
grant update (title, intro, is_public) on public.ul_lists to authenticated;
grant delete on public.ul_lists to authenticated;
grant insert (list_id, place_id, note, pos) on public.ul_list_items to authenticated;
grant update (note, pos) on public.ul_list_items to authenticated;
grant delete on public.ul_list_items to authenticated;

-- 다른 사람 리스트를 내 리스트로 복사
create or replace function public.ul_copy_list(p_list bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_src public.ul_lists; v_new bigint;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요' using errcode = 'P0001'; end if;
  if not public.ul_is_approved() then raise exception '이용이 정지된 계정이에요' using errcode = 'P0001'; end if;
  select * into v_src from public.ul_lists where id = p_list and (is_public or user_id = auth.uid());
  if v_src.id is null then raise exception '리스트를 찾지 못했어요' using errcode = 'P0001'; end if;
  insert into public.ul_lists (user_id, title, intro, is_public, copied_from)
  values (auth.uid(), left(v_src.title, 30), v_src.intro, true, v_src.id) returning id into v_new;
  insert into public.ul_list_items (list_id, place_id, note, pos)
  select v_new, place_id, note, pos from public.ul_list_items where list_id = v_src.id order by pos, created_at limit 100;
  if v_src.user_id <> auth.uid() then
    update public.ul_lists set copies = copies + 1 where id = v_src.id;
  end if;
  return v_new;
end $$;
revoke execute on function public.ul_copy_list(bigint) from public, anon;
grant execute on function public.ul_copy_list(bigint) to authenticated;

-- =====================================================================
-- 유니로그 13단계: 로그톡 글·댓글에 "나만의 로그" 달기
-- Supabase > SQL Editor > + (새 칸) 에 전부 붙여넣고 Run 하세요. 12_guest_lists.sql 다음에 실행해요.
-- 여러 번 실행해도 괜찮아요.
-- · 글이나 댓글에 내가 만든 로그(맛집 리스트) 하나를 붙일 수 있어요
-- · 로그를 지우면 글·댓글에서는 로그만 빠지고 글은 그대로 남아요
-- =====================================================================

alter table public.ul_posts add column if not exists list_id bigint references public.ul_lists(id) on delete set null;
alter table public.ul_comments add column if not exists list_id bigint references public.ul_lists(id) on delete set null;

grant insert (cat, title, body, place_id, list_id) on public.ul_posts to authenticated;
grant update (cat, title, body, place_id, list_id) on public.ul_posts to authenticated;
grant insert (post_id, parent_id, mention, body, place_id, list_id) on public.ul_comments to authenticated;

-- 내가 만든 로그만 붙일 수 있어요
create or replace function public.ul_attach_list_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.list_id is not null and (tg_op = 'INSERT' or new.list_id is distinct from old.list_id) then
    if not exists (select 1 from public.ul_lists l where l.id = new.list_id and l.user_id = new.user_id) then
      raise exception '내가 만든 로그만 붙일 수 있어요' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ul_posts_list_check on public.ul_posts;
create trigger ul_posts_list_check before insert or update of list_id on public.ul_posts
  for each row execute function public.ul_attach_list_check();
drop trigger if exists ul_comments_list_check on public.ul_comments;
create trigger ul_comments_list_check before insert on public.ul_comments
  for each row execute function public.ul_attach_list_check();

-- =====================================================================
-- 유니로그 14단계: 다른 학교에도 글쓰기 + 리뷰어 등급은 "쓴 리뷰 수"로
-- Supabase > SQL Editor > + (새 칸) 에 전부 붙여넣고 Run 하세요. 13번 다음에 실행해요.
-- 여러 번 실행해도 괜찮아요.
-- · 다른 학교를 보고 있을 때 쓴 로그톡 글은 그 학교 로그톡에 올라가요 (그 학교 학생들에게 새 글 알림)
-- · 리뷰어 등급은 쓴 리뷰 수로: 새내기 0개 · 단골 5개 · 미식가 20개 · 미식왕 50개 (가려진 리뷰는 안 세요)
--   등급이 오르면 알림도 리뷰 수 기준으로 가요
-- · 리뷰어 랭킹은 예전 그대로 "도움돼요" 기준이에요
-- =====================================================================

-- ---------- 1) 로그톡 글은 지금 보고 있는 학교에 ----------
create or replace function public.ul_posts_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.user_id := auth.uid();
    new.school_id := coalesce(nullif(left(btrim(coalesce(new.school_id, '')), 60), ''),
                              (select school_id from public.ul_profiles where id = auth.uid()));
    new.likes := 0; new.comment_count := 0; new.adopted := false; new.hidden := false; new.edited := false;
  else
    new.school_id := old.school_id;
    if new.title is distinct from old.title or new.body is distinct from old.body
       or new.cat is distinct from old.cat or new.place_id is distinct from old.place_id
       or new.list_id is distinct from old.list_id then
      new.edited := true; new.updated_at := now();
    end if;
  end if;
  return new;
end $$;

grant insert (cat, title, body, place_id, list_id, school_id) on public.ul_posts to authenticated;

-- ---------- 2) 회원마다 "쓴 리뷰 수" (등급에 써요) ----------
alter table public.ul_profiles add column if not exists review_count int not null default 0;
grant select (review_count) on public.ul_profiles to anon;

create or replace function public.ul_review_count_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_old int; v_new int; v_lv text;
begin
  foreach v_uid in array array[case when tg_op <> 'INSERT' then old.user_id end,
                               case when tg_op <> 'DELETE' then new.user_id end]
  loop
    if v_uid is not null then
      select review_count into v_old from public.ul_profiles where id = v_uid for update;
      v_new := (select count(*) from public.ul_reviews r where r.user_id = v_uid and not r.hidden);
      update public.ul_profiles set review_count = v_new where id = v_uid;
      -- 등급이 오르면 알림 (단골 5개 · 미식가 20개 · 미식왕 50개)
      v_lv := case when v_old < 50 and v_new >= 50 then '미식왕'
                   when v_old < 20 and v_new >= 20 then '미식가'
                   when v_old < 5  and v_new >= 5  then '단골' end;
      if v_lv is not null then
        perform public.ul_notify(v_uid, 'up:' || v_lv, 'up', null, null, null, null, null, jsonb_build_object('level', v_lv));
      end if;
    end if;
  end loop;
  return null;
exception when others then
  return null;   -- 숫자 맞추기에 문제가 생겨도 리뷰는 그대로
end $$;
drop trigger if exists ul_review_count_sync on public.ul_reviews;
create trigger ul_review_count_sync after insert or delete or update of hidden, user_id on public.ul_reviews
  for each row execute function public.ul_review_count_sync();

-- "도움돼요"는 랭킹에만 쓰고, 등급 알림은 이제 리뷰 수로만 보내요
create or replace function public.ul_add_helpful(p_user uuid, p_delta int) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.ul_profiles set helpful = greatest(0, helpful + p_delta) where id = p_user;
end $$;
revoke execute on function public.ul_add_helpful(uuid,int) from public, anon, authenticated;

-- 지금까지 쓴 리뷰 수 채우기 (이때는 알림 안 보내요)
update public.ul_profiles p
   set review_count = coalesce((select count(*) from public.ul_reviews r where r.user_id = p.id and not r.hidden), 0);

-- ---------- 3) 리뷰어 랭킹은 예전 그대로 (도움돼요 기준) ----------
create or replace function public.ul_ranking(p_school text, p_period text default 'all', p_limit int default 100)
returns table (user_id uuid, nick text, photo_url text, school_short text, year text, helpful int,
               score bigint, reviews bigint, comments bigint, verified boolean)
language sql stable security definer set search_path = public as $$
  with since as (
    select case p_period
      when 'week'  then (date_trunc('week',  now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')
      when 'month' then (date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')
      else null end as t
  ), got as (
    select r.user_id as uid, count(*) as c
      from public.ul_review_likes l join public.ul_reviews r on r.id = l.review_id, since
     where since.t is not null and l.created_at >= since.t group by r.user_id
    union all
    select c.user_id, count(*)
      from public.ul_comment_likes l join public.ul_comments c on c.id = l.comment_id, since
     where since.t is not null and l.created_at >= since.t group by c.user_id
  ), per as (select uid, sum(c)::bigint as s from got group by uid)
  select p.id, p.nick, p.photo_url, p.school_short, p.year, p.helpful,
         case when (select t from since) is null then p.helpful::bigint else coalesce(per.s, 0) end as score,
         (select count(*) from public.ul_reviews r where r.user_id = p.id and not r.hidden),
         (select count(*) from public.ul_comments c where c.user_id = p.id and not c.hidden),
         p.verified
    from public.ul_profiles p left join per on per.uid = p.id
   where p.school_id = p_school and p.status = 'approved' and p.nick is not null
   order by score desc, p.helpful desc, p.created_at
   limit greatest(1, least(p_limit, 300));
$$;
grant execute on function public.ul_ranking(text,text,int) to anon, authenticated;

-- =====================================================================
-- 유니로그 15단계: 관리자 전용 예시(샘플) 데이터 — /admin/seed
-- Supabase > SQL Editor > + (새 칸) 에 전부 붙여넣고 Run 하세요. 14번 다음에 실행해요.
-- 여러 번 실행해도 괜찮아요.
--
-- · 관리자만 데모 프로필을 만들고, 그 프로필로 예시 리뷰를 올릴 수 있어요
-- · 예시 리뷰도 실제 유저 리뷰와 똑같이 가게 평점·리뷰 수·리뷰 목록에 들어가요
-- · 리뷰어 랭킹·개척자 배지에도 데모 프로필이 똑같이 들어가요
-- · 데모 프로필의 재학생 인증 표시는 만들 때 7:3 정도로 섞여요 (random() < 0.7)
-- · 데모 프로필을 지우면 그 프로필의 예시 리뷰도 함께 지워져요
-- =====================================================================

alter table public.ul_profiles add column if not exists is_demo boolean not null default false;
alter table public.ul_reviews  add column if not exists is_demo boolean not null default false;
grant select (is_demo) on public.ul_profiles to anon;
create index if not exists ul_profiles_demo on public.ul_profiles (is_demo) where is_demo;

-- 학번(year)을 비워 둔 데모 프로필이 들어갈 수 있도록 (이미 비울 수 있으면 그냥 지나가요)
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'ul_profiles'
                and column_name = 'year' and is_nullable = 'NO') then
    alter table public.ul_profiles alter column year drop not null;
  end if;
end $$;

-- 예전에 만든 데모 프로필의 학번("예시") 정리: 이제 학번 칸을 비워 둬요
update public.ul_profiles set year = null where is_demo and year = '예시';

-- 리뷰 쓸 때 규칙 (예시 리뷰만 예외)
create or replace function public.ul_reviews_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_visits int;
begin
  -- 관리자 예시 리뷰 (/admin/seed 에서만): 작성자는 데모 프로필, 방문 인증 검사 없음
  if tg_op = 'INSERT' and current_setting('ul.seed', true) = 'on' and public.ul_is_admin() then
    new.likes := 0; new.hidden := false; new.edited := false; new.visit_count := 0; new.is_demo := true;
    new.round := (select count(*) from public.ul_reviews where user_id = new.user_id and place_id = new.place_id) + 1;
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.user_id := auth.uid(); new.is_demo := false;
    new.likes := 0; new.hidden := false; new.edited := false;
    new.round := (select count(*) from public.ul_reviews where user_id = new.user_id and place_id = new.place_id) + 1;
  else
    new.is_demo := old.is_demo;
    if (new.rating, new.body, new.menu, new.price_level, new.kind, new.tags, new.photos)
       is not distinct from (old.rating, old.body, old.menu, old.price_level, old.kind, old.tags, old.photos) then
      return new;   -- 도움돼요 수·숨김처럼 내부에서 바뀌는 경우
    end if;
    new.edited := true; new.updated_at := now();
    if new.kind = old.kind then return new; end if;
  end if;
  select count(*) into v_visits from public.ul_visits where user_id = new.user_id and place_id = new.place_id;
  if new.kind = 'visit' then
    if not exists (select 1 from public.ul_visits where user_id = new.user_id and place_id = new.place_id
                   and visit_day >= ((now() at time zone 'Asia/Seoul')::date - 7)) then
      raise exception '매장 리뷰는 7일 안에 방문 인증을 해야 쓸 수 있어요' using errcode = 'P0001';
    end if;
    new.visit_count := v_visits;
  else
    new.visit_count := 0;
  end if;
  return new;
end $$;

-- 개척자 배지 (데모 프로필도 포함)
create or replace function public.ul_founder_fill(p_school text) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_n int;
begin
  if p_school is null then return; end if;
  perform pg_advisory_xact_lock(hashtext('ul_founder:' || p_school));
  for r in
    select p.id, p.school_short, min(rv.created_at) as t
      from public.ul_profiles p join public.ul_reviews rv on rv.user_id = p.id
     where p.school_id = p_school and p.status = 'approved' and p.founder is null
     group by p.id, p.school_short
     order by t, p.id
  loop
    select g.n into v_n from generate_series(1, 3) as g(n)
     where not exists (select 1 from public.ul_profiles x where x.school_id = p_school and x.founder = g.n)
     order by g.n limit 1;
    exit when v_n is null;   -- 3자리 모두 찼어요
    update public.ul_profiles set founder = v_n where id = r.id and founder is null;
    perform public.ul_notify(r.id, null, 'founder', null, null, null, null, null,
                             jsonb_build_object('rank', v_n, 'school', r.school_short));
  end loop;
end $$;
revoke execute on function public.ul_founder_fill(text) from public, anon, authenticated;

-- 리뷰어 랭킹 (데모 프로필도 포함)
create or replace function public.ul_ranking(p_school text, p_period text default 'all', p_limit int default 100)
returns table (user_id uuid, nick text, photo_url text, school_short text, year text, helpful int,
               score bigint, reviews bigint, comments bigint, verified boolean)
language sql stable security definer set search_path = public as $$
  with since as (
    select case p_period
      when 'week'  then (date_trunc('week',  now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')
      when 'month' then (date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')
      else null end as t
  ), got as (
    select r.user_id as uid, count(*) as c
      from public.ul_review_likes l join public.ul_reviews r on r.id = l.review_id, since
     where since.t is not null and l.created_at >= since.t group by r.user_id
    union all
    select c.user_id, count(*)
      from public.ul_comment_likes l join public.ul_comments c on c.id = l.comment_id, since
     where since.t is not null and l.created_at >= since.t group by c.user_id
  ), per as (select uid, sum(c)::bigint as s from got group by uid)
  select p.id, p.nick, p.photo_url, p.school_short, p.year, p.helpful,
         case when (select t from since) is null then p.helpful::bigint else coalesce(per.s, 0) end as score,
         (select count(*) from public.ul_reviews r where r.user_id = p.id and not r.hidden),
         (select count(*) from public.ul_comments c where c.user_id = p.id and not c.hidden),
         p.verified
    from public.ul_profiles p left join per on per.uid = p.id
   where p.school_id = p_school and p.status = 'approved' and p.nick is not null
   order by score desc, p.helpful desc, p.created_at
   limit greatest(1, least(p_limit, 300));
$$;
grant execute on function public.ul_ranking(text,text,int) to anon, authenticated;

-- ---------- 데모 프로필 만들기 (관리자만) ----------
create or replace function public.ul_seed_profile(p_nick text, p_campus text) returns uuid
language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid := gen_random_uuid(); v_msg text; v_sid text; v_campus text;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  p_nick := btrim(coalesce(p_nick, ''));
  v_msg := public.ul_nick_ok(p_nick);
  if v_msg <> 'ok' then raise exception '%', v_msg using errcode = 'P0001'; end if;
  if p_campus = 'global' then v_sid := 'hufs-g'; v_campus := '글로벌캠퍼스';
  else v_sid := 'hufs-s'; v_campus := '서울캠퍼스'; end if;
  -- 로그인할 수 없는 빈 계정 (프로필이 계정에 묶여 있어서 필요해요)
  insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
          'demo-' || replace(v_id::text, '-', '') || '@demo.uni1og.invalid',
          jsonb_build_object('provider', 'demo', 'providers', jsonb_build_array('demo')), '{}'::jsonb, now(), now());
  insert into public.ul_profiles (id, nick, school_id, school_name, school_short, campus, year, status, is_demo)
  values (v_id, p_nick, v_sid, '한국외국어대학교', '외대', v_campus, null, 'approved', true);
  update public.ul_profiles set verified = (random() < 0.7) where id = v_id;   -- 재학생 인증 표시: 7:3 정도로 섞이게
  return v_id;
end $$;

-- ---------- 예시 리뷰 올리기 (관리자만, 데모 프로필로만) ----------
create or replace function public.ul_seed_review(p_user uuid, p_place text, p_rating numeric, p_kind text,
                                                 p_body text, p_menu text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 고를 수 있어요' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.ul_places where id = p_place) then
    raise exception '가게를 먼저 골라 주세요' using errcode = 'P0001';
  end if;
  perform set_config('ul.seed', 'on', true);
  insert into public.ul_reviews (place_id, user_id, rating, body, menu, kind)
  values (p_place, p_user, round(p_rating * 2) / 2, btrim(p_body), nullif(btrim(coalesce(p_menu, '')), ''),
          coalesce(nullif(p_kind, ''), 'visit'))
  returning id into v_id;
  perform set_config('ul.seed', 'off', true);
  return v_id;
end $$;

-- ---------- 지우기 (관리자만) ----------
create or replace function public.ul_seed_delete_review(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  delete from public.ul_reviews where id = p_id and is_demo;
end $$;

create or replace function public.ul_seed_delete_profile(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 지울 수 있어요' using errcode = 'P0001';
  end if;
  delete from auth.users where id = p_user;   -- 프로필·예시 리뷰도 함께 지워져요
end $$;

revoke execute on function public.ul_seed_profile(text,text), public.ul_seed_review(uuid,text,numeric,text,text,text),
  public.ul_seed_delete_review(bigint), public.ul_seed_delete_profile(uuid) from public, anon;
grant execute on function public.ul_seed_profile(text,text), public.ul_seed_review(uuid,text,numeric,text,text,text),
  public.ul_seed_delete_review(bigint), public.ul_seed_delete_profile(uuid) to authenticated;

