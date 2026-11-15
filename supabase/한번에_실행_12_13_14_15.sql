-- =====================================================================
-- 유니로그 한 번에 실행 (12 + 13 + 14 + 15 + 16 + 17 + 18 + 19단계)
-- Supabase > SQL Editor > + (새 칸) 에 이 파일 내용을 전부 붙여넣고 Run 한 번만 누르세요.
-- 여러 번 실행해도 괜찮아요. (12~15를 이미 실행했어도 그냥 이걸 실행하면 돼요)
-- 16단계: 예시 데이터에서 모든 학교 프로필 + 로그톡 글·댓글까지 (파일 맨 끝)
-- 17단계: 데모 프로필이 로그톡 글·댓글에 공감(도움돼요)까지 누를 수 있게 (그 아래)
-- 18단계: 데모 프로필이 가게 리뷰에 도움돼요까지 누를 수 있게 (그 아래)
--   데모 프로필을 만들 때 학번(예: '24학번', '19학번 이전')과 재학생 인증 표시도 고를 수 있어요.
-- 19단계: 올린 예시 리뷰를 고칠 수 있게 (파일 맨 끝 · 수정해도 "수정됨" 표시는 안 남아요)
-- 15단계의 예시 리뷰는 방문 인증 횟수·사진(5장)·태그·1인 가격대까지 넣을 수 있게 넓혔어요.
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
  -- 방문 인증 횟수는 관리자가 넣은 값을 그대로 둬요 (0 이상)
  if tg_op = 'INSERT' and current_setting('ul.seed', true) = 'on' and public.ul_is_admin() then
    new.likes := 0; new.hidden := false; new.edited := false;
    new.visit_count := greatest(0, coalesce(new.visit_count, 0)); new.is_demo := true;
    new.round := (select count(*) from public.ul_reviews where user_id = new.user_id and place_id = new.place_id) + 1;
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.user_id := auth.uid(); new.is_demo := false;
    new.likes := 0; new.hidden := false; new.edited := false;
    new.round := (select count(*) from public.ul_reviews where user_id = new.user_id and place_id = new.place_id) + 1;
  else
    new.is_demo := old.is_demo;
    -- 관리자 예시 리뷰 수정 (/admin/seed 19단계): 예시 리뷰는 실제로 쓴 사람이 없으니
    --   "수정됨"을 안 남기고, 방문 인증 검사도 건너뛰고, 방문 인증 횟수는 관리자가 넣은 값을 그대로 둬요
    if current_setting('ul.seed', true) = 'on' and old.is_demo and public.ul_is_admin() then
      new.edited := false; new.updated_at := now();
      new.visit_count := case when new.kind = 'visit' then greatest(0, coalesce(new.visit_count, 0)) else 0 end;
      return new;
    end if;
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
-- 16단계에서 학교를 직접 받도록 넓혔어요. 예전 두 칸짜리 호출(p_nick, p_campus='seoul'|'global')도 그대로 돼요.
-- 학번(p_year)은 index.html 가입 화면과 같은 글자로 넣어요(예: '24학번', '19학번 이전'). 비우면 null이에요.
-- 재학생 인증(p_verified): true면 인증 표시, false면 미인증, null이면 7:3 정도로 섞어요.
--   칸이 또 늘어서 예전 시그니처는 먼저 지워요. (칸 수가 다르면 호출이 갈리지 않게 같이 지워야 깔끔해요)
drop function if exists public.ul_seed_profile(text, text);
drop function if exists public.ul_seed_profile(text, text, text);
drop function if exists public.ul_seed_profile(text, text, text, text);
drop function if exists public.ul_seed_profile(text, text, text, text, text);
drop function if exists public.ul_seed_profile(text, text, text, text, text, text);
create or replace function public.ul_seed_profile(p_nick text, p_school_id text default null,
  p_school_name text default null, p_school_short text default null, p_campus text default null,
  p_year text default null, p_verified boolean default null) returns uuid
language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid := gen_random_uuid(); v_msg text;
        v_sid text; v_name text; v_short text; v_campus text; v_year text;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  p_nick := btrim(coalesce(p_nick, ''));
  v_msg := public.ul_nick_ok(p_nick);
  if v_msg <> 'ok' then raise exception '%', v_msg using errcode = 'P0001'; end if;

  v_sid := nullif(btrim(coalesce(p_school_id, '')), '');
  v_campus := nullif(btrim(coalesce(p_campus, '')), '');
  -- 학교를 안 넘기면 예전처럼 캠퍼스로만 고르기 (기본: 한국외대)
  if v_sid is null then
    if v_campus = 'global' then v_sid := 'hufs-g'; else v_sid := 'hufs-s'; end if;
  end if;
  if v_campus in ('seoul', 'global') then
    v_campus := case v_campus when 'global' then '글로벌캠퍼스' else '서울캠퍼스' end;
  end if;
  if v_campus is null then
    v_campus := case v_sid when 'hufs-g' then '글로벌캠퍼스' when 'hufs-s' then '서울캠퍼스' else '' end;
  end if;
  v_name := coalesce(nullif(btrim(coalesce(p_school_name, '')), ''),
                     case when v_sid in ('hufs-s', 'hufs-g') then '한국외국어대학교' else v_sid end);
  v_short := coalesce(nullif(btrim(coalesce(p_school_short, '')), ''),
                      case when v_sid in ('hufs-s', 'hufs-g') then '외대' else left(v_name, 8) end);
  -- 학번: 빈 값은 null, 너무 길면 자르기 ('24학번'·'19학번 이전' 같은 글자를 그대로 넣어요)
  v_year := left(nullif(btrim(coalesce(p_year, '')), ''), 20);

  -- 로그인할 수 없는 빈 계정 (프로필이 계정에 묶여 있어서 필요해요)
  insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
          'demo-' || replace(v_id::text, '-', '') || '@demo.uni1og.invalid',
          jsonb_build_object('provider', 'demo', 'providers', jsonb_build_array('demo')), '{}'::jsonb, now(), now());
  insert into public.ul_profiles (id, nick, school_id, school_name, school_short, campus, year, status, is_demo)
  values (v_id, p_nick, v_sid, v_name, v_short, v_campus, v_year, 'approved', true);
  update public.ul_profiles set verified = coalesce(p_verified, random() < 0.7) where id = v_id;   -- 재학생 인증 표시: 고른 값이 없으면 7:3 정도로 섞이게
  return v_id;
end $$;

-- ---------- 예시 리뷰 올리기 (관리자만, 데모 프로필로만) ----------
-- p_visit_count: "📍 방문 인증 N회"로 보일 횟수 (매장 방문일 때만, 0 이상)
--   ul_reviews.visit_count에 그대로 넣고, 단골왕(최근 30일 방문 인증)까지 맞도록 ul_visits에도 그만큼 넣어요.
--   (ul_visits에 이미 있는 날짜·제약이면 그 줄만 건너뛰고 실패하지 않아요)
-- p_photos: 사진 주소 배열(최대 5장). /admin/seed 에서 ul-photos 버킷에 올린 공개 주소를 그대로 넣어요.
-- p_price_level: 1인 가격대. index.html의 PRICES 배열 순번(0=~5천원 … 4=3만원 이상), 모르면 null
-- p_tags: "이런 곳이에요" 태그 배열 (혼밥 가능·가성비 …). 최대 8개
--   ul_reviews.photos / tags 컬럼 타입(text[] 또는 jsonb)을 보고 맞춰 넣습니다.
drop function if exists public.ul_seed_review(uuid, text, numeric, text, text, text);
drop function if exists public.ul_seed_review(uuid, text, numeric, text, text, text, int);
drop function if exists public.ul_seed_review(uuid, text, numeric, text, text, text, int, text[]);
create or replace function public.ul_seed_review(p_user uuid, p_place text, p_rating numeric, p_kind text,
                                                 p_body text, p_menu text default null,
                                                 p_visit_count int default 0,
                                                 p_photos text[] default null,
                                                 p_price_level int default null,
                                                 p_tags text[] default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_kind text; v_vc int; v_ids bigint[] := '{}'; v_visit bigint;
        v_photos text[] := '{}'; v_tags text[] := '{}'; v_ptype text; v_ttype text; v_changed boolean := false;
        v_price int;
        c_claims text; c_sub text;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 고를 수 있어요' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.ul_places where id = p_place) then
    raise exception '가게를 먼저 골라 주세요' using errcode = 'P0001';
  end if;
  v_kind := coalesce(nullif(btrim(coalesce(p_kind, '')), ''), 'visit');
  v_vc := case when v_kind = 'visit' then greatest(0, least(coalesce(p_visit_count, 0), 999)) else 0 end;
  v_price := case when p_price_level between 0 and 4 then p_price_level else null end;

  -- 사진 주소 정리: http(s) 주소만, 앞에서 5장까지 / 태그: 빈 값·중복 빼고 8개까지
  if p_photos is not null then
    select coalesce(array_agg(t.u order by t.ord), '{}') into v_photos
      from unnest(p_photos) with ordinality as t(u, ord)
     where t.ord <= 5 and t.u ~* '^https?://';
  end if;
  if p_tags is not null then
    select coalesce(array_agg(distinct left(btrim(t.u), 20)), '{}') into v_tags
      from unnest(p_tags[1:8]) as t(u)
     where btrim(coalesce(t.u, '')) <> '';
  end if;

  perform set_config('ul.seed', 'on', true);
  insert into public.ul_reviews (place_id, user_id, rating, body, menu, kind, visit_count, price_level)
  values (p_place, p_user, round(p_rating * 2) / 2, btrim(p_body), nullif(btrim(coalesce(p_menu, '')), ''),
          v_kind, v_vc, v_price)
  returning id into v_id;
  perform set_config('ul.seed', 'off', true);

  -- 사진·태그: ul_reviews 컬럼 타입을 보고 맞춰 넣어요 (없는 컬럼이면 그냥 건너뜀)
  if coalesce(array_length(v_photos, 1), 0) > 0 then
    select data_type into v_ptype from information_schema.columns
     where table_schema = 'public' and table_name = 'ul_reviews' and column_name = 'photos';
    if v_ptype = 'ARRAY' then
      update public.ul_reviews set photos = v_photos where id = v_id; v_changed := true;
    elsif v_ptype is not null then
      update public.ul_reviews set photos = to_jsonb(v_photos) where id = v_id; v_changed := true;
    end if;
  end if;
  if coalesce(array_length(v_tags, 1), 0) > 0 then
    select data_type into v_ttype from information_schema.columns
     where table_schema = 'public' and table_name = 'ul_reviews' and column_name = 'tags';
    if v_ttype = 'ARRAY' then
      update public.ul_reviews set tags = v_tags where id = v_id; v_changed := true;
    elsif v_ttype is not null then
      update public.ul_reviews set tags = to_jsonb(v_tags) where id = v_id; v_changed := true;
    end if;
  end if;
  if v_changed then
    -- 사진·태그를 넣은 걸 리뷰 화면에서 "수정됨"으로 안 남기기
    update public.ul_reviews set edited = false where id = v_id;
  end if;

  -- 방문 인증 기록도 같은 횟수만큼 (오늘부터 하루씩 뒤로) — 단골왕·방문 인증 횟수 표시를 맞춰요
  if v_vc > 0 then
    -- ul_visits 쪽 트리거가 auth.uid()로 작성자를 덮어쓸 수 있어, 잠깐 데모 프로필이 로그인한 것처럼 맞춰 둡니다
    c_claims := current_setting('request.jwt.claims', true);
    c_sub := current_setting('request.jwt.claim.sub', true);
    perform set_config('request.jwt.claim.sub', p_user::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    for i in 0 .. v_vc - 1 loop
      begin
        insert into public.ul_visits (user_id, place_id, visit_day)
        values (p_user, p_place, (now() at time zone 'Asia/Seoul')::date - i)
        returning id into v_visit;
        v_ids := v_ids || v_visit;
      exception when others then null;   -- 이미 있는 날·제약에 걸리면 그 줄만 건너뛰기
      end;
    end loop;
    -- 작성자가 데모 프로필로 안 들어간 줄은 지워요 (관리자 계정에 가짜 방문이 남지 않게)
    if array_length(v_ids, 1) is not null then
      delete from public.ul_visits where id = any(v_ids) and user_id <> p_user;
    end if;
    perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
    perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);
  end if;
  return v_id;
end $$;

-- ---------- 지우기 (관리자만) ----------
create or replace function public.ul_seed_delete_review(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_place text;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  select user_id, place_id into v_user, v_place from public.ul_reviews where id = p_id and is_demo;
  delete from public.ul_reviews where id = p_id and is_demo;
  -- 예시 리뷰와 함께 넣어 둔 방문 인증 기록도 같이 지워요 (데모 프로필 것만)
  if v_user is not null and v_place is not null then
    delete from public.ul_visits v
     where v.user_id = v_user and v.place_id = v_place
       and exists (select 1 from public.ul_profiles p where p.id = v_user and p.is_demo);
  end if;
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

revoke execute on function public.ul_seed_profile(text,text,text,text,text,text,boolean), public.ul_seed_review(uuid,text,numeric,text,text,text,int,text[],int,text[]),
  public.ul_seed_delete_review(bigint), public.ul_seed_delete_profile(uuid) from public, anon;
grant execute on function public.ul_seed_profile(text,text,text,text,text,text,boolean), public.ul_seed_review(uuid,text,numeric,text,text,text,int,text[],int,text[]),
  public.ul_seed_delete_review(bigint), public.ul_seed_delete_profile(uuid) to authenticated;

-- =====================================================================
-- 유니로그 16단계: 예시 데이터 — 로그톡 글·댓글 (관리자 전용)
-- Supabase > SQL Editor > + (새 칸) 에 이 파일 내용을 전부 붙여넣고 Run 하세요. 15번 다음에 실행해요.
-- 여러 번 실행해도 괜찮아요.
--
-- · 데모 프로필이 그 학교 로그톡에 직접 쓴 것처럼 글·댓글을 올려요 (말머리·제목·내용 그대로)
-- · 실제 회원이 쓴 글에도 댓글을 달 수 있어요
-- · 지우기는 데모 프로필이 쓴 글·댓글만 돼요 (실제 회원 글은 안 지워져요)
-- · ul_posts의 작성자(ul_posts_before)는 auth.uid()로 정해져서, 올리는 동안만
--   "데모 프로필이 로그인한 것처럼" 신분(request.jwt.claims)을 잠깐 바꿔 두고 되돌려요.
--   ul_comments 쪽 트리거는 이 파일에 정의가 없어서, 넣은 뒤 작성자를 확인하고
--   데모 프로필로 안 들어갔으면 에러로 되돌려요(엉뚱한 계정 이름으로 남지 않아요).
--
-- (참고) ul_comments에 어떤 트리거가 붙어 있는지 보려면:
--   select tgname, pg_get_triggerdef(oid) from pg_trigger
--    where tgrelid = 'public.ul_comments'::regclass and not tgisinternal;
-- =====================================================================

-- ---------- 로그톡 글 올리기 (관리자만, 데모 프로필로만) ----------
create or replace function public.ul_seed_post(p_user uuid, p_school_id text, p_cat text,
                                               p_title text, p_body text, p_place text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_row public.ul_posts; v_cat text; c_claims text; c_sub text;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 고를 수 있어요' using errcode = 'P0001';
  end if;
  v_cat := coalesce(nullif(btrim(coalesce(p_cat, '')), ''), '질문');
  if v_cat not in ('질문', '추천', '정보') then
    raise exception '말머리는 질문·추천·정보 중 하나예요' using errcode = 'P0001';
  end if;
  if char_length(btrim(coalesce(p_title, ''))) < 2 then
    raise exception '제목을 2자 이상 적어 주세요' using errcode = 'P0001';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) < 5 then
    raise exception '내용을 5자 이상 적어 주세요' using errcode = 'P0001';
  end if;
  if p_place is not null and not exists (select 1 from public.ul_places where id = p_place) then
    raise exception '가게를 먼저 등록해 주세요' using errcode = 'P0001';
  end if;

  -- ul_posts_before 가 new.user_id := auth.uid() 로 정해서, 잠깐 데모 프로필로 맞춰 둡니다
  c_claims := current_setting('request.jwt.claims', true);
  c_sub := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);

  insert into public.ul_posts (user_id, school_id, cat, title, body, place_id)
  values (p_user, nullif(btrim(coalesce(p_school_id, '')), ''), v_cat, btrim(p_title), btrim(p_body),
          nullif(btrim(coalesce(p_place, '')), ''))
  returning * into v_row;

  perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);

  if v_row.user_id <> p_user then
    update public.ul_posts set user_id = p_user where id = v_row.id;
    select * into v_row from public.ul_posts where id = v_row.id;
  end if;
  if v_row.user_id <> p_user then
    raise exception '데모 프로필 이름으로 글이 안 들어갔어요 (ul_posts 작성자 트리거를 확인해 주세요)' using errcode = 'P0001';
  end if;
  return v_row.id;
end $$;

-- ---------- 로그톡 댓글·답글 달기 (관리자만, 데모 프로필로만) ----------
create or replace function public.ul_seed_comment(p_user uuid, p_post bigint, p_body text,
                                                  p_parent bigint default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_row public.ul_comments; c_claims text; c_sub text;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 고를 수 있어요' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.ul_posts where id = p_post) then
    raise exception '댓글을 달 글을 찾지 못했어요' using errcode = 'P0001';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) < 1 then
    raise exception '댓글 내용을 적어 주세요' using errcode = 'P0001';
  end if;
  if p_parent is not null and not exists (select 1 from public.ul_comments where id = p_parent and post_id = p_post) then
    raise exception '답글을 달 댓글을 찾지 못했어요' using errcode = 'P0001';
  end if;

  c_claims := current_setting('request.jwt.claims', true);
  c_sub := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);

  insert into public.ul_comments (post_id, parent_id, body)
  values (p_post, p_parent, btrim(p_body))
  returning * into v_row;

  perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);

  -- 작성자가 데모 프로필로 안 들어갔으면 한 번 더 바로잡아 보고, 그래도 안 되면 되돌려요
  if v_row.user_id <> p_user then
    update public.ul_comments set user_id = p_user where id = v_row.id;
    select * into v_row from public.ul_comments where id = v_row.id;
  end if;
  if v_row.user_id <> p_user then
    raise exception '데모 프로필 이름으로 댓글이 안 들어갔어요 (ul_comments 작성자 트리거를 확인해 주세요)' using errcode = 'P0001';
  end if;

  -- 글의 댓글 수를 실제 개수로 맞춰 둡니다 (댓글 수를 세는 트리거가 있든 없든 맞게)
  update public.ul_posts p
     set comment_count = (select count(*) from public.ul_comments c where c.post_id = p.id)
   where p.id = p_post;
  return v_row.id;
end $$;

-- ---------- 지우기 (관리자만, 데모 프로필이 쓴 것만) ----------
create or replace function public.ul_seed_delete_post(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_posts p join public.ul_profiles u on u.id = p.user_id
                  where p.id = p_id and u.is_demo) then
    raise exception '데모 프로필이 쓴 글만 지울 수 있어요' using errcode = 'P0001';
  end if;
  delete from public.ul_comments where post_id = p_id;   -- 달린 댓글 먼저
  delete from public.ul_posts where id = p_id;
end $$;

create or replace function public.ul_seed_delete_comment(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_post bigint;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_comments c join public.ul_profiles u on u.id = c.user_id
                  where c.id = p_id and u.is_demo) then
    raise exception '데모 프로필이 쓴 댓글만 지울 수 있어요' using errcode = 'P0001';
  end if;
  select post_id into v_post from public.ul_comments where id = p_id;
  delete from public.ul_comments where id = p_id;
  if v_post is not null then
    update public.ul_posts p
       set comment_count = (select count(*) from public.ul_comments c where c.post_id = p.id)
     where p.id = v_post;
  end if;
end $$;

revoke execute on function public.ul_seed_post(uuid,text,text,text,text,text),
  public.ul_seed_comment(uuid,bigint,text,bigint),
  public.ul_seed_delete_post(bigint), public.ul_seed_delete_comment(bigint) from public, anon;
grant execute on function public.ul_seed_post(uuid,text,text,text,text,text),
  public.ul_seed_comment(uuid,bigint,text,bigint),
  public.ul_seed_delete_post(bigint), public.ul_seed_delete_comment(bigint) to authenticated;

-- =====================================================================
-- 유니로그 17단계: 예시 데이터 — 로그톡 글·댓글 공감 (관리자 전용)
-- Supabase > SQL Editor > + (새 칸) 에 이 파일 내용을 전부 붙여넣고 Run 하세요. 16번 다음에 실행해요.
-- 여러 번 실행해도 괜찮아요.
--
-- · 데모 프로필이 로그톡 글에 "공감", 댓글에 "도움돼요"를 누른 것처럼 만들 수 있어요.
--   한 사람씩 누르고 취소하기, 데모 프로필 N명이 한 번에 누르기 둘 다 돼요.
-- · 실제 앱과 똑같은 테이블(ul_post_likes · ul_comment_likes)에 넣어요. 그래서 글·댓글의 공감 수
--   (ul_posts.likes · ul_comments.likes)와 받은 도움돼요(ul_profiles.helpful)도 실제와 똑같이 올라가요.
-- · 공감 테이블에 "작성자를 auth.uid()로 정하는" 트리거가 있어도 되도록, 넣는 동안만 그 데모 프로필이
--   로그인한 것처럼 신분(request.jwt.claims)을 바꿔 두고 되돌려요. (16단계 글·댓글과 같은 방식)
-- · 넣은 뒤에는 글·댓글의 공감 수를 실제 줄 수(count(*))로 다시 맞춰요.
--   트리거가 공감 수를 더하는지와 상관없이 화면에 보이는 숫자가 실제와 똑같아져요.
-- =====================================================================

-- ---------- 공감 한 줄 넣기 / 빼기 (다른 함수에서만 부르는 내부용) ----------
create or replace function public.ul_seed_like_toggle(p_what text, p_id bigint, p_user uuid, p_on boolean)
returns int
language plpgsql security definer set search_path = public as $$
declare v_rows int := 0; v_uid uuid; c_claims text; c_sub text;
begin
  c_claims := current_setting('request.jwt.claims', true);
  c_sub := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);

  if p_on then
    begin
      if p_what = 'post' then
        insert into public.ul_post_likes (post_id, user_id) values (p_id, p_user) returning user_id into v_uid;
      else
        insert into public.ul_comment_likes (comment_id, user_id) values (p_id, p_user) returning user_id into v_uid;
      end if;
      v_rows := 1;
    exception when unique_violation then
      v_rows := 0;   -- 이미 눌렀어요
    end;

    -- 작성자를 auth.uid()로 덮어쓰는 트리거가 있으면 관리자 줄로 들어가요 → 데모 프로필 줄로 바로잡기
    if v_rows = 1 and v_uid is distinct from p_user then
      begin
        if p_what = 'post' then
          update public.ul_post_likes set user_id = p_user where post_id = p_id and user_id = v_uid;
        else
          update public.ul_comment_likes set user_id = p_user where comment_id = p_id and user_id = v_uid;
        end if;
      exception when unique_violation then
        -- 그 사이 이 사람 줄이 생겼으면, 관리자 줄은 지워요
        if p_what = 'post' then
          delete from public.ul_post_likes where post_id = p_id and user_id = v_uid;
        else
          delete from public.ul_comment_likes where comment_id = p_id and user_id = v_uid;
        end if;
      end;
      if p_what = 'post' then
        v_rows := case when exists (select 1 from public.ul_post_likes where post_id = p_id and user_id = p_user) then 1 else 0 end;
      else
        v_rows := case when exists (select 1 from public.ul_comment_likes where comment_id = p_id and user_id = p_user) then 1 else 0 end;
      end if;
    end if;
  else
    if p_what = 'post' then
      delete from public.ul_post_likes where post_id = p_id and user_id = p_user;
    else
      delete from public.ul_comment_likes where comment_id = p_id and user_id = p_user;
    end if;
    get diagnostics v_rows = row_count;
    v_rows := -v_rows;
  end if;

  perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);
  return v_rows;   -- 1: 새로 눌렀어요 · -1: 취소했어요 · 0: 달라진 게 없어요
end $$;
revoke execute on function public.ul_seed_like_toggle(text,bigint,uuid,boolean) from public, anon, authenticated;

-- ---------- 글·댓글의 공감 수를 실제 줄 수로 다시 맞추기 (내부용) ----------
create or replace function public.ul_seed_like_sync(p_what text, p_id bigint)
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_what = 'post' then
    select count(*) into v_n from public.ul_post_likes where post_id = p_id;
    -- 이미 맞으면 건드리지 않아요 (트리거의 "수정됨" 표시 같은 부작용을 피하려고)
    update public.ul_posts p set likes = v_n where p.id = p_id and p.likes is distinct from v_n;
  else
    select count(*) into v_n from public.ul_comment_likes where comment_id = p_id;
    update public.ul_comments c set likes = v_n where c.id = p_id and c.likes is distinct from v_n;
  end if;
  return v_n;
end $$;
revoke execute on function public.ul_seed_like_sync(text,bigint) from public, anon, authenticated;

-- ---------- 글 하나에 데모 프로필 한 명이 공감 (누르기/취소) ----------
-- p_like: null이면 지금 상태를 뒤집어요. true면 공감, false면 취소.
-- 돌려주는 값: {"liked": true/false, "likes": 지금 글의 공감 수}
create or replace function public.ul_seed_post_like(p_user uuid, p_post bigint, p_like boolean default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_author uuid; v_have boolean; v_on boolean; v_delta int := 0; v_likes int;
        v_hb int; v_ha int;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 고를 수 있어요' using errcode = 'P0001';
  end if;
  select user_id into v_author from public.ul_posts where id = p_post;
  if v_author is null then raise exception '공감할 글을 찾지 못했어요' using errcode = 'P0001'; end if;

  v_have := exists (select 1 from public.ul_post_likes where post_id = p_post and user_id = p_user);
  v_on := coalesce(p_like, not v_have);

  if v_on is distinct from v_have then
    select helpful into v_hb from public.ul_profiles where id = v_author;
    v_delta := public.ul_seed_like_toggle('post', p_post, p_user, v_on);
    if v_delta <> 0 then
      -- 받은 도움돼요: 트리거가 올려 줬으면 그대로 두고, 안 올렸으면 여기서 한 번만 올려요
      select helpful into v_ha from public.ul_profiles where id = v_author;
      if v_ha is distinct from greatest(0, coalesce(v_hb, 0) + v_delta) then
        update public.ul_profiles set helpful = greatest(0, coalesce(v_hb, 0) + v_delta) where id = v_author;
      end if;
    end if;
  end if;

  v_likes := public.ul_seed_like_sync('post', p_post);
  return jsonb_build_object(
    'liked', exists (select 1 from public.ul_post_likes where post_id = p_post and user_id = p_user),
    'likes', v_likes);
end $$;

-- ---------- 댓글 하나에 데모 프로필 한 명이 공감("도움돼요") ----------
create or replace function public.ul_seed_comment_like(p_user uuid, p_comment bigint, p_like boolean default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_author uuid; v_have boolean; v_on boolean; v_delta int := 0; v_likes int;
        v_hb int; v_ha int;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 고를 수 있어요' using errcode = 'P0001';
  end if;
  select user_id into v_author from public.ul_comments where id = p_comment;
  if v_author is null then raise exception '공감할 댓글을 찾지 못했어요' using errcode = 'P0001'; end if;

  v_have := exists (select 1 from public.ul_comment_likes where comment_id = p_comment and user_id = p_user);
  v_on := coalesce(p_like, not v_have);

  if v_on is distinct from v_have then
    select helpful into v_hb from public.ul_profiles where id = v_author;
    v_delta := public.ul_seed_like_toggle('comment', p_comment, p_user, v_on);
    if v_delta <> 0 then
      select helpful into v_ha from public.ul_profiles where id = v_author;
      if v_ha is distinct from greatest(0, coalesce(v_hb, 0) + v_delta) then
        update public.ul_profiles set helpful = greatest(0, coalesce(v_hb, 0) + v_delta) where id = v_author;
      end if;
    end if;
  end if;

  v_likes := public.ul_seed_like_sync('comment', p_comment);
  return jsonb_build_object(
    'liked', exists (select 1 from public.ul_comment_likes where comment_id = p_comment and user_id = p_user),
    'likes', v_likes);
end $$;

-- ---------- 글 하나에 데모 프로필 N명이 한 번에 공감 ----------
-- 아직 안 누른 데모 프로필 중에서 무작위로 골라요. (글쓴이 본인은 빼요)
-- 돌려주는 값: {"added": 새로 눌린 수, "likes": 지금 글의 공감 수, "nicks": 새로 누른 프로필 닉네임}
create or replace function public.ul_seed_post_like_many(p_post bigint, p_count int default 3, p_exclude uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_author uuid; v_n int; v_delta int := 0; v_likes int; v_hb int; v_ha int;
        v_nicks text[] := '{}'; r record;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  select user_id into v_author from public.ul_posts where id = p_post;
  if v_author is null then raise exception '공감할 글을 찾지 못했어요' using errcode = 'P0001'; end if;
  v_n := greatest(1, least(coalesce(p_count, 3), 50));

  select helpful into v_hb from public.ul_profiles where id = v_author;
  for r in
    select p.id, p.nick
      from public.ul_profiles p
     where p.is_demo and p.id <> v_author
       and (p_exclude is null or p.id <> p_exclude)
       and not exists (select 1 from public.ul_post_likes l where l.post_id = p_post and l.user_id = p.id)
     order by random()
     limit v_n
  loop
    if public.ul_seed_like_toggle('post', p_post, r.id, true) = 1 then
      v_delta := v_delta + 1;
      v_nicks := v_nicks || r.nick;
    end if;
  end loop;

  if v_delta <> 0 then
    select helpful into v_ha from public.ul_profiles where id = v_author;
    if v_ha is distinct from greatest(0, coalesce(v_hb, 0) + v_delta) then
      update public.ul_profiles set helpful = greatest(0, coalesce(v_hb, 0) + v_delta) where id = v_author;
    end if;
  end if;

  v_likes := public.ul_seed_like_sync('post', p_post);
  return jsonb_build_object('added', v_delta, 'likes', v_likes, 'nicks', to_jsonb(v_nicks));
end $$;

-- ---------- 댓글 하나에 데모 프로필 N명이 한 번에 공감 ----------
create or replace function public.ul_seed_comment_like_many(p_comment bigint, p_count int default 3, p_exclude uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_author uuid; v_n int; v_delta int := 0; v_likes int; v_hb int; v_ha int;
        v_nicks text[] := '{}'; r record;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  select user_id into v_author from public.ul_comments where id = p_comment;
  if v_author is null then raise exception '공감할 댓글을 찾지 못했어요' using errcode = 'P0001'; end if;
  v_n := greatest(1, least(coalesce(p_count, 3), 50));

  select helpful into v_hb from public.ul_profiles where id = v_author;
  for r in
    select p.id, p.nick
      from public.ul_profiles p
     where p.is_demo and p.id <> v_author
       and (p_exclude is null or p.id <> p_exclude)
       and not exists (select 1 from public.ul_comment_likes l where l.comment_id = p_comment and l.user_id = p.id)
     order by random()
     limit v_n
  loop
    if public.ul_seed_like_toggle('comment', p_comment, r.id, true) = 1 then
      v_delta := v_delta + 1;
      v_nicks := v_nicks || r.nick;
    end if;
  end loop;

  if v_delta <> 0 then
    select helpful into v_ha from public.ul_profiles where id = v_author;
    if v_ha is distinct from greatest(0, coalesce(v_hb, 0) + v_delta) then
      update public.ul_profiles set helpful = greatest(0, coalesce(v_hb, 0) + v_delta) where id = v_author;
    end if;
  end if;

  v_likes := public.ul_seed_like_sync('comment', p_comment);
  return jsonb_build_object('added', v_delta, 'likes', v_likes, 'nicks', to_jsonb(v_nicks));
end $$;

-- ---------- /admin/seed 화면이 지금 공감 상태를 한 번에 읽어 가기 ----------
-- 돌려주는 값: {"likes": 글 공감 수, "liked": 그 프로필이 눌렀는지,
--              "comments": {"댓글 id": {"likes": n, "liked": true/false}, ...}}
create or replace function public.ul_seed_talk_likes(p_post bigint, p_user uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_cmts jsonb;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  select id into v_id from public.ul_posts where id = p_post;
  if v_id is null then raise exception '글을 찾지 못했어요' using errcode = 'P0001'; end if;

  select coalesce(jsonb_object_agg(c.id::text, jsonb_build_object(
           'likes', (select count(*) from public.ul_comment_likes l where l.comment_id = c.id),
           'liked', coalesce(p_user is not null and exists (
                      select 1 from public.ul_comment_likes l where l.comment_id = c.id and l.user_id = p_user), false))), '{}'::jsonb)
    into v_cmts
    from public.ul_comments c where c.post_id = p_post;

  return jsonb_build_object(
    'likes', (select count(*) from public.ul_post_likes l where l.post_id = p_post),
    'liked', coalesce(p_user is not null and exists (
               select 1 from public.ul_post_likes l where l.post_id = p_post and l.user_id = p_user), false),
    'comments', v_cmts);
end $$;

revoke execute on function public.ul_seed_post_like(uuid,bigint,boolean),
  public.ul_seed_comment_like(uuid,bigint,boolean),
  public.ul_seed_post_like_many(bigint,int,uuid),
  public.ul_seed_comment_like_many(bigint,int,uuid),
  public.ul_seed_talk_likes(bigint,uuid) from public, anon;
grant execute on function public.ul_seed_post_like(uuid,bigint,boolean),
  public.ul_seed_comment_like(uuid,bigint,boolean),
  public.ul_seed_post_like_many(bigint,int,uuid),
  public.ul_seed_comment_like_many(bigint,int,uuid),
  public.ul_seed_talk_likes(bigint,uuid) to authenticated;

-- ---------- 데모 프로필을 지울 때: 그 프로필이 남긴 공감도 함께 정리 ----------
-- (공감 줄이 남아 있으면 글·댓글의 공감 수가 실제보다 많아 보여요)
-- ※ 가게 리뷰 도움돼요까지 포함한 최종판은 18단계(파일 맨 끝)에서 한 번 더 정의해요. 적용되는 건 맨 끝 판이에요.
create or replace function public.ul_seed_delete_profile(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_posts bigint[]; v_cmts bigint[];
        v_uids uuid[]; v_ns int[]; v_hbs int[]; v_ha int; i int;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 지울 수 있어요' using errcode = 'P0001';
  end if;

  v_posts := array(select distinct post_id from public.ul_post_likes where user_id = p_user);
  v_cmts  := array(select distinct comment_id from public.ul_comment_likes where user_id = p_user);

  -- 지운 공감만큼 글·댓글 쓴 사람의 받은 도움돼요도 줄여요 (지우기 전에 지금 값을 적어 둡니다)
  with got as (
    select p.user_id as uid, count(*)::int as n
      from public.ul_post_likes l join public.ul_posts p on p.id = l.post_id
     where l.user_id = p_user group by p.user_id
    union all
    select c.user_id, count(*)::int
      from public.ul_comment_likes l join public.ul_comments c on c.id = l.comment_id
     where l.user_id = p_user group by c.user_id
  ), per as (select uid, sum(n)::int as n from got group by uid)
  select array_agg(per.uid), array_agg(per.n), array_agg(coalesce(pr.helpful, 0))
    into v_uids, v_ns, v_hbs
    from per left join public.ul_profiles pr on pr.id = per.uid;

  delete from public.ul_post_likes where user_id = p_user;
  delete from public.ul_comment_likes where user_id = p_user;

  -- 트리거가 이미 도움돼요를 줄였으면 그대로 두고, 안 줄였으면 여기서 한 번만 줄여요
  if v_uids is not null then
    for i in 1 .. array_length(v_uids, 1) loop
      select helpful into v_ha from public.ul_profiles where id = v_uids[i];
      if v_ha is distinct from greatest(0, v_hbs[i] - v_ns[i]) then
        update public.ul_profiles set helpful = greatest(0, v_hbs[i] - v_ns[i]) where id = v_uids[i];
      end if;
    end loop;
  end if;

  update public.ul_posts p set likes = (select count(*) from public.ul_post_likes l where l.post_id = p.id)
   where p.id = any(v_posts) and p.likes is distinct from (select count(*) from public.ul_post_likes l where l.post_id = p.id);
  update public.ul_comments c set likes = (select count(*) from public.ul_comment_likes l where l.comment_id = c.id)
   where c.id = any(v_cmts) and c.likes is distinct from (select count(*) from public.ul_comment_likes l where l.comment_id = c.id);

  delete from auth.users where id = p_user;   -- 프로필·예시 리뷰·글·댓글도 함께 지워져요
end $$;

-- =====================================================================
-- 유니로그 18단계: 예시 데이터 — 가게 리뷰 "도움돼요" (관리자 전용)
-- Supabase > SQL Editor > + (새 칸) 에 이 파일 내용을 전부 붙여넣고 Run 하세요. 17번 다음에 실행해요.
-- 여러 번 실행해도 괜찮아요.
--
-- · 데모 프로필이 가게 리뷰에 "도움돼요"를 누른 것처럼 만들 수 있어요.
--   한 사람씩 누르고 취소하기, 데모 프로필 N명이 한 번에 누르기 둘 다 돼요.
-- · 실제 앱과 똑같은 테이블(ul_review_likes)에 넣어요. 그래서 리뷰의 도움돼요 수(ul_reviews.likes)와
--   리뷰를 쓴 사람의 받은 도움돼요(ul_profiles.helpful)가 실제와 똑같이 올라가요(리뷰어 랭킹에 그대로 반영).
-- · ul_review_likes에 "작성자를 auth.uid()로 정하는" 트리거가 있어도 되도록, 넣는 동안만 그 데모 프로필이
--   로그인한 것처럼 신분(request.jwt.claims)을 바꿔 두고 되돌려요. (17단계 글·댓글 공감과 같은 방식)
-- · 넣은 뒤에는 리뷰의 도움돼요 수를 실제 줄 수(count(*))로 다시 맞춰요.
--   트리거가 수를 더하는지와 상관없이 화면에 보이는 숫자가 실제와 똑같아져요.
-- · 내가 쓴 리뷰에는 누를 수 없어요 (실제 앱과 같은 규칙). 한 번에 누르기는 리뷰 쓴 사람을 빼요.
-- =====================================================================

-- ---------- 리뷰 도움돼요 한 줄 넣기 / 빼기 (다른 함수에서만 부르는 내부용) ----------
create or replace function public.ul_seed_review_like_toggle(p_review bigint, p_user uuid, p_on boolean)
returns int
language plpgsql security definer set search_path = public as $$
declare v_rows int := 0; v_uid uuid; c_claims text; c_sub text;
begin
  c_claims := current_setting('request.jwt.claims', true);
  c_sub := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);

  if p_on then
    begin
      insert into public.ul_review_likes (review_id, user_id) values (p_review, p_user) returning user_id into v_uid;
      v_rows := 1;
    exception when unique_violation then
      v_rows := 0;   -- 이미 눌렀어요
    end;

    -- 작성자를 auth.uid()로 덮어쓰는 트리거가 있으면 관리자 줄로 들어가요 → 데모 프로필 줄로 바로잡기
    if v_rows = 1 and v_uid is distinct from p_user then
      begin
        update public.ul_review_likes set user_id = p_user where review_id = p_review and user_id = v_uid;
      exception when unique_violation then
        -- 그 사이 이 사람 줄이 생겼으면, 엉뚱한 줄은 지워요
        delete from public.ul_review_likes where review_id = p_review and user_id = v_uid;
      end;
      v_rows := case when exists (select 1 from public.ul_review_likes where review_id = p_review and user_id = p_user) then 1 else 0 end;
    end if;
  else
    delete from public.ul_review_likes where review_id = p_review and user_id = p_user;
    get diagnostics v_rows = row_count;
    v_rows := -v_rows;
  end if;

  perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);
  return v_rows;   -- 1: 새로 눌렀어요 · -1: 취소했어요 · 0: 달라진 게 없어요
end $$;
revoke execute on function public.ul_seed_review_like_toggle(bigint,uuid,boolean) from public, anon, authenticated;

-- ---------- 리뷰의 도움돼요 수를 실제 줄 수로 다시 맞추기 (내부용) ----------
create or replace function public.ul_seed_review_like_sync(p_review bigint)
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  select count(*) into v_n from public.ul_review_likes where review_id = p_review;
  -- 이미 맞으면 건드리지 않아요 (트리거의 "수정됨" 표시 같은 부작용을 피하려고)
  update public.ul_reviews r set likes = v_n where r.id = p_review and r.likes is distinct from v_n;
  return v_n;
end $$;
revoke execute on function public.ul_seed_review_like_sync(bigint) from public, anon, authenticated;

-- ---------- 리뷰 하나에 데모 프로필 한 명이 도움돼요 (누르기/취소) ----------
-- p_like: null이면 지금 상태를 뒤집어요. true면 누르기, false면 취소.
-- 돌려주는 값: {"liked": true/false, "likes": 지금 리뷰의 도움돼요 수}
create or replace function public.ul_seed_review_like(p_user uuid, p_review bigint, p_like boolean default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_author uuid; v_have boolean; v_on boolean; v_delta int := 0; v_likes int;
        v_hb int; v_ha int;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 고를 수 있어요' using errcode = 'P0001';
  end if;
  select user_id into v_author from public.ul_reviews where id = p_review;
  if v_author is null then raise exception '도움돼요를 누를 리뷰를 찾지 못했어요' using errcode = 'P0001'; end if;
  if v_author = p_user then
    raise exception '내가 쓴 리뷰에는 도움돼요를 누를 수 없어요' using errcode = 'P0001';
  end if;

  v_have := exists (select 1 from public.ul_review_likes where review_id = p_review and user_id = p_user);
  v_on := coalesce(p_like, not v_have);

  if v_on is distinct from v_have then
    select helpful into v_hb from public.ul_profiles where id = v_author;
    v_delta := public.ul_seed_review_like_toggle(p_review, p_user, v_on);
    if v_delta <> 0 then
      -- 받은 도움돼요: 트리거가 올려 줬으면 그대로 두고, 안 올렸으면 여기서 한 번만 올려요
      select helpful into v_ha from public.ul_profiles where id = v_author;
      if v_ha is distinct from greatest(0, coalesce(v_hb, 0) + v_delta) then
        update public.ul_profiles set helpful = greatest(0, coalesce(v_hb, 0) + v_delta) where id = v_author;
      end if;
    end if;
  end if;

  v_likes := public.ul_seed_review_like_sync(p_review);
  return jsonb_build_object(
    'liked', exists (select 1 from public.ul_review_likes where review_id = p_review and user_id = p_user),
    'likes', v_likes);
end $$;

-- ---------- 리뷰 하나에 데모 프로필 N명이 한 번에 도움돼요 ----------
-- 아직 안 누른 데모 프로필 중에서 무작위로 골라요. (리뷰 쓴 사람과 지금 고른 프로필은 빼요)
-- 돌려주는 값: {"added": 새로 눌린 수, "likes": 지금 리뷰의 도움돼요 수, "nicks": 새로 누른 프로필 닉네임}
create or replace function public.ul_seed_review_like_many(p_review bigint, p_count int default 2, p_exclude uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_author uuid; v_n int; v_delta int := 0; v_likes int; v_hb int; v_ha int;
        v_nicks text[] := '{}'; r record;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  select user_id into v_author from public.ul_reviews where id = p_review;
  if v_author is null then raise exception '도움돼요를 누를 리뷰를 찾지 못했어요' using errcode = 'P0001'; end if;
  v_n := greatest(1, least(coalesce(p_count, 2), 50));

  select helpful into v_hb from public.ul_profiles where id = v_author;
  for r in
    select p.id, p.nick
      from public.ul_profiles p
     where p.is_demo and p.id <> v_author
       and (p_exclude is null or p.id <> p_exclude)
       and not exists (select 1 from public.ul_review_likes l where l.review_id = p_review and l.user_id = p.id)
     order by random()
     limit v_n
  loop
    if public.ul_seed_review_like_toggle(p_review, r.id, true) = 1 then
      v_delta := v_delta + 1;
      v_nicks := v_nicks || r.nick;
    end if;
  end loop;

  if v_delta <> 0 then
    select helpful into v_ha from public.ul_profiles where id = v_author;
    if v_ha is distinct from greatest(0, coalesce(v_hb, 0) + v_delta) then
      update public.ul_profiles set helpful = greatest(0, coalesce(v_hb, 0) + v_delta) where id = v_author;
    end if;
  end if;

  v_likes := public.ul_seed_review_like_sync(p_review);
  return jsonb_build_object('added', v_delta, 'likes', v_likes, 'nicks', to_jsonb(v_nicks));
end $$;

-- ---------- /admin/seed 화면이 리뷰들의 지금 도움돼요 상태를 한 번에 읽어 가기 ----------
-- 돌려주는 값: {"리뷰 id": {"likes": n, "liked": true/false}, ...}   (리뷰 id는 글자로 옵니다)
create or replace function public.ul_seed_review_likes(p_reviews bigint[], p_user uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  select coalesce(jsonb_object_agg(r.id::text, jsonb_build_object(
           'likes', (select count(*) from public.ul_review_likes l where l.review_id = r.id),
           'liked', coalesce(p_user is not null and exists (
                      select 1 from public.ul_review_likes l where l.review_id = r.id and l.user_id = p_user), false))), '{}'::jsonb)
    into v_out
    from public.ul_reviews r
   where r.id = any((coalesce(p_reviews, '{}'::bigint[]))[1:500]);
  return v_out;
end $$;

revoke execute on function public.ul_seed_review_like(uuid,bigint,boolean),
  public.ul_seed_review_like_many(bigint,int,uuid),
  public.ul_seed_review_likes(bigint[],uuid) from public, anon;
grant execute on function public.ul_seed_review_like(uuid,bigint,boolean),
  public.ul_seed_review_like_many(bigint,int,uuid),
  public.ul_seed_review_likes(bigint[],uuid) to authenticated;

-- ---------- 예시 리뷰를 지울 때: 그 리뷰가 받은 도움돼요까지 정리 (18단계 최종판) ----------
-- 리뷰를 지우면 도움돼요 줄(ul_review_likes)은 DB가 함께 지워요. 트리거가 받은 도움돼요를 줄여 주면
-- 그대로 두고, 안 줄였으면 여기서 한 번만 줄입니다. (방문 인증 기록 정리 + 18단계 도움돼요 정리)
create or replace function public.ul_seed_delete_review(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_place text; v_hb int; v_ha int; v_n int;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  select user_id, place_id into v_user, v_place from public.ul_reviews where id = p_id and is_demo;
  if v_user is not null then
    select helpful into v_hb from public.ul_profiles where id = v_user;
    select count(*) into v_n from public.ul_review_likes where review_id = p_id;
  end if;

  delete from public.ul_reviews where id = p_id and is_demo;

  -- 예시 리뷰와 함께 넣어 둔 방문 인증 기록도 같이 지워요 (데모 프로필 것만)
  if v_user is not null and v_place is not null then
    delete from public.ul_visits v
     where v.user_id = v_user and v.place_id = v_place
       and exists (select 1 from public.ul_profiles p where p.id = v_user and p.is_demo);
  end if;

  -- 그 리뷰가 받은 도움돼요만큼 리뷰 쓴 사람의 받은 도움돼요도 줄여요
  if v_user is not null and v_n > 0 then
    select helpful into v_ha from public.ul_profiles where id = v_user;
    if v_ha is distinct from greatest(0, coalesce(v_hb, 0) - v_n) then
      update public.ul_profiles set helpful = greatest(0, coalesce(v_hb, 0) - v_n) where id = v_user;
    end if;
  end if;
end $$;

-- ---------- 데모 프로필을 지울 때: 그 프로필이 남긴 리뷰 도움돼요까지 정리 (18단계 최종판) ----------
-- 글·댓글 공감(17단계)에 리뷰 도움돼요를 더해, 공감 줄·도움돼요 수·받은 도움돼요를 한 번에 맞춰요.
create or replace function public.ul_seed_delete_profile(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_posts bigint[]; v_cmts bigint[]; v_revs bigint[];
        v_uids uuid[]; v_ns int[]; v_hbs int[]; v_ha int; i int;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.ul_profiles where id = p_user and is_demo) then
    raise exception '데모 프로필만 지울 수 있어요' using errcode = 'P0001';
  end if;

  v_posts := array(select distinct post_id from public.ul_post_likes where user_id = p_user);
  v_cmts  := array(select distinct comment_id from public.ul_comment_likes where user_id = p_user);
  v_revs  := array(select distinct review_id from public.ul_review_likes where user_id = p_user);

  -- 지운 공감만큼 글·댓글·리뷰 쓴 사람의 받은 도움돼요도 줄여요 (지우기 전에 지금 값을 적어 둡니다)
  with got as (
    select p.user_id as uid, count(*)::int as n
      from public.ul_post_likes l join public.ul_posts p on p.id = l.post_id
     where l.user_id = p_user group by p.user_id
    union all
    select c.user_id, count(*)::int
      from public.ul_comment_likes l join public.ul_comments c on c.id = l.comment_id
     where l.user_id = p_user group by c.user_id
    union all
    select r.user_id, count(*)::int
      from public.ul_review_likes l join public.ul_reviews r on r.id = l.review_id
     where l.user_id = p_user group by r.user_id
  ), per as (select uid, sum(n)::int as n from got group by uid)
  select array_agg(per.uid), array_agg(per.n), array_agg(coalesce(pr.helpful, 0))
    into v_uids, v_ns, v_hbs
    from per left join public.ul_profiles pr on pr.id = per.uid;

  delete from public.ul_post_likes where user_id = p_user;
  delete from public.ul_comment_likes where user_id = p_user;
  delete from public.ul_review_likes where user_id = p_user;

  -- 트리거가 이미 도움돼요를 줄였으면 그대로 두고, 안 줄였으면 여기서 한 번만 줄여요
  if v_uids is not null then
    for i in 1 .. array_length(v_uids, 1) loop
      select helpful into v_ha from public.ul_profiles where id = v_uids[i];
      if v_ha is distinct from greatest(0, v_hbs[i] - v_ns[i]) then
        update public.ul_profiles set helpful = greatest(0, v_hbs[i] - v_ns[i]) where id = v_uids[i];
      end if;
    end loop;
  end if;

  update public.ul_posts p set likes = (select count(*) from public.ul_post_likes l where l.post_id = p.id)
   where p.id = any(v_posts) and p.likes is distinct from (select count(*) from public.ul_post_likes l where l.post_id = p.id);
  update public.ul_comments c set likes = (select count(*) from public.ul_comment_likes l where l.comment_id = c.id)
   where c.id = any(v_cmts) and c.likes is distinct from (select count(*) from public.ul_comment_likes l where l.comment_id = c.id);
  update public.ul_reviews r set likes = (select count(*) from public.ul_review_likes l where l.review_id = r.id)
   where r.id = any(v_revs) and r.likes is distinct from (select count(*) from public.ul_review_likes l where l.review_id = r.id);

  delete from auth.users where id = p_user;   -- 프로필·예시 리뷰·글·댓글도 함께 지워져요
end $$;

-- =====================================================================
-- 유니로그 19단계: 예시 리뷰 고치기 — /admin/seed 의 [수정]
-- Supabase > SQL Editor > + (새 칸) 에 전부 붙여넣고 Run 하세요. 18번 다음에 실행해요.
-- 여러 번 실행해도 괜찮아요.
--
-- · 15단계에서 올린 예시 리뷰를 관리자가 고칠 수 있어요
--   (별점 · 방문유형 · 방문 인증 횟수 · 먹은 메뉴 · 1인 가격대 · 태그 · 사진 · 리뷰 내용)
-- · 가게와 작성자(데모 프로필)는 그대로예요. 도움돼요·받은 도움돼요도 그대로 둬요.
-- · 고쳐도 리뷰에 "수정됨" 표시는 안 남아요. (예시 리뷰는 실제로 쓴 사람이 없어요)
--   → 리뷰 쓰기 규칙(15단계 ul_reviews_before)에 UPDATE 예외를 넣어서 처리해요.
-- · 방문 인증 횟수를 바꾸면, 함께 넣어 둔 방문 인증 기록도 그 횟수에 맞춰 정리해요.
--   (리뷰에 보이는 "📍 방문 인증 N회"와 단골왕 집계가 같은 값을 가리키게)
-- =====================================================================

-- ---------- 예시 리뷰 고치기 (관리자만) ----------
-- p_menu·p_visit_count·p_photos·p_price_level·p_tags는 올릴 때와 같은 규칙이에요.
-- p_photos를 비우면(null) 사진은 그대로 두고, 빈 배열('{}')을 넣으면 사진을 모두 지워요. (태그도 같아요)
drop function if exists public.ul_seed_update_review(bigint, numeric, text, text, text, int, text[], int, text[]);
create or replace function public.ul_seed_update_review(p_id bigint, p_rating numeric, p_kind text, p_body text,
                                                        p_menu text default null,
                                                        p_visit_count int default 0,
                                                        p_photos text[] default null,
                                                        p_price_level int default null,
                                                        p_tags text[] default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare r public.ul_reviews;
        v_kind text; v_vc int; v_price int; v_rating numeric;
        v_photos text[]; v_tags text[];
        v_ptype text; v_ttype text;
        v_ids bigint[] := '{}'; v_visit bigint; v_try int; v_miss int; v_have int;
        c_claims text; c_sub text;
begin
  if not public.ul_is_admin() then raise exception '관리자만 할 수 있어요' using errcode = 'P0001'; end if;
  select * into r from public.ul_reviews where id = p_id and is_demo;
  if not found then raise exception '예시 리뷰만 고칠 수 있어요' using errcode = 'P0001'; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception '리뷰 내용을 넣어 주세요' using errcode = 'P0001'; end if;

  v_kind := coalesce(nullif(btrim(coalesce(p_kind, '')), ''), r.kind, 'visit');
  v_vc := case when v_kind = 'visit' then greatest(0, least(coalesce(p_visit_count, 0), 999)) else 0 end;
  v_price := case when p_price_level between 0 and 4 then p_price_level else null end;
  -- 별점은 0.5점 단위 (0.5 ~ 5). 비워 두면 그대로 둬요
  v_rating := case when p_rating is null then r.rating
                   else round(least(5, greatest(0.5, p_rating)) * 2) / 2 end;

  -- 사진 주소 정리: http(s) 주소만, 앞에서 5장까지 / 태그: 빈 값·중복 빼고 8개까지
  if p_photos is not null then
    select coalesce(array_agg(t.u order by t.ord), '{}') into v_photos
      from unnest(p_photos) with ordinality as t(u, ord)
     where t.ord <= 5 and t.u ~* '^https?://';
  end if;
  if p_tags is not null then
    select coalesce(array_agg(distinct left(btrim(t.u), 20)), '{}') into v_tags
      from unnest(p_tags[1:8]) as t(u)
     where btrim(coalesce(t.u, '')) <> '';
  end if;

  -- 본문 컬럼들 (사진·태그는 컬럼 타입을 보고 따로 넣어요)
  -- ul.seed='on' 이면 15단계 ul_reviews_before 가 "수정됨"을 안 남기고 방문 인증 검사도 건너뛰어요
  perform set_config('ul.seed', 'on', true);
  update public.ul_reviews
     set rating = v_rating, body = btrim(p_body),
         menu = nullif(btrim(coalesce(p_menu, '')), ''),
         kind = v_kind, visit_count = v_vc, price_level = v_price,
         updated_at = now()
   where id = p_id and is_demo;
  perform set_config('ul.seed', 'off', true);

  if p_photos is not null then
    select data_type into v_ptype from information_schema.columns
     where table_schema = 'public' and table_name = 'ul_reviews' and column_name = 'photos';
    if v_ptype = 'ARRAY' then
      update public.ul_reviews set photos = coalesce(v_photos, '{}') where id = p_id;
    elsif v_ptype is not null then
      update public.ul_reviews set photos = coalesce(to_jsonb(v_photos), '[]'::jsonb) where id = p_id;
    end if;
  end if;
  if p_tags is not null then
    select data_type into v_ttype from information_schema.columns
     where table_schema = 'public' and table_name = 'ul_reviews' and column_name = 'tags';
    if v_ttype = 'ARRAY' then
      update public.ul_reviews set tags = coalesce(v_tags, '{}') where id = p_id;
    elsif v_ttype is not null then
      update public.ul_reviews set tags = coalesce(to_jsonb(v_tags), '[]'::jsonb) where id = p_id;
    end if;
  end if;

  -- 위 UPDATE들은 "내부에서 바뀌는 값"이라 edited 는 false 그대로 두고, 혹시 켜졌으면 한 번 더 꺼요
  if (select edited from public.ul_reviews where id = p_id) then
    update public.ul_reviews set edited = false where id = p_id;
  end if;

  -- 방문 인증 기록을 고친 횟수에 맞춰요 (예시 리뷰에 함께 넣어 둔 줄만)
  if exists (select 1 from public.ul_profiles p where p.id = r.user_id and p.is_demo) then
    c_claims := current_setting('request.jwt.claims', true);
    c_sub := current_setting('request.jwt.claim.sub', true);
    if v_vc > 0 then
      -- ul_visits 쪽 트리거가 auth.uid()로 작성자를 덮어쓸 수 있어, 잠깐 데모 프로필이 로그인한 것처럼 맞춰 둡니다
      perform set_config('request.jwt.claim.sub', r.user_id::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', r.user_id, 'role', 'authenticated')::text, true);
    end if;

    select count(*) into v_have from public.ul_visits where user_id = r.user_id and place_id = r.place_id;
    if v_vc > v_have then
      v_try := 0; v_miss := 0;
      while v_miss < 7 and v_try < 400 loop
        v_try := v_try + 1;
        begin
          insert into public.ul_visits (user_id, place_id, visit_day)
          values (r.user_id, r.place_id, (now() at time zone 'Asia/Seoul')::date - (v_try - 1))
          returning id into v_visit;
          v_ids := v_ids || v_visit;
          v_miss := 0;
        exception when others then
          v_miss := v_miss + 1;   -- 그 날짜가 이미 있거나 제약에 걸리면 그 줄만 건너뛰기
        end;
        exit when (select count(*) from public.ul_visits where user_id = r.user_id and place_id = r.place_id) >= v_vc;
      end loop;
      -- 작성자가 데모 프로필로 안 들어간 줄은 지워요 (관리자 계정에 가짜 방문이 남지 않게)
      if array_length(v_ids, 1) is not null then
        delete from public.ul_visits where id = any(v_ids) and user_id <> r.user_id;
      end if;
    elsif v_vc < v_have then
      delete from public.ul_visits where id in (
        select v.id from public.ul_visits v
         where v.user_id = r.user_id and v.place_id = r.place_id
         order by v.visit_day asc, v.id asc
         limit (v_have - v_vc));
    end if;

    perform set_config('request.jwt.claim.sub', coalesce(c_sub, ''), true);
    perform set_config('request.jwt.claims', coalesce(c_claims, ''), true);
  end if;

  return p_id;
end $$;

revoke execute on function public.ul_seed_update_review(bigint,numeric,text,text,text,int,text[],int,text[]) from public, anon;
grant execute on function public.ul_seed_update_review(bigint,numeric,text,text,text,int,text[],int,text[]) to authenticated;
