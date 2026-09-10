-- Migration date: 2026-09-05
-- Add scoped app and project memory directly in its final inline-Markdown
-- form. This intentionally avoids the superseded object-storage/version model,
-- so an upgrade never creates memory bodies that a later migration must erase.

alter table public.user_profiles
  add column if not exists memory_curator_model text,
  add column if not exists project_memory_default boolean not null default true;

alter table public.chat_messages
  add column if not exists author_user_id uuid references auth.users(id) on delete set null,
  add column if not exists memory_input_message_id uuid,
  add column if not exists memory_eligible_at timestamptz,
  add column if not exists memory_app_eligible_at timestamptz;
alter table public.word_chat_messages
  add column if not exists author_user_id uuid references auth.users(id) on delete set null,
  add column if not exists memory_input_message_id uuid,
  add column if not exists memory_eligible_at timestamptz,
  add column if not exists memory_app_eligible_at timestamptz;
alter table public.tabular_review_chat_messages
  add column if not exists author_user_id uuid references auth.users(id) on delete set null,
  add column if not exists memory_input_message_id uuid,
  add column if not exists memory_eligible_at timestamptz,
  add column if not exists memory_app_eligible_at timestamptz;

create index if not exists chat_messages_chat_created_id_idx
  on public.chat_messages(chat_id, created_at, id);
-- (chat_id) is a strict prefix of the index above; keeping both taxes every
-- chat message insert for nothing.
drop index if exists public.idx_chat_messages_chat;
create index if not exists chat_messages_author_idx
  on public.chat_messages(author_user_id) where author_user_id is not null;
create index if not exists word_chat_messages_author_idx
  on public.word_chat_messages(author_user_id) where author_user_id is not null;
create index if not exists tabular_review_chat_messages_author_idx
  on public.tabular_review_chat_messages(author_user_id) where author_user_id is not null;

-- Scoped memory files
-- ---------------------------------------------------------------------------
-- One row per memory file holds the Markdown body itself. Saves from the
-- editor and the curator are direct compare-and-swap updates of that row;
-- there is no version history and no separate object to keep in step.
create table if not exists public.memory_files (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('user', 'project')),
  user_id uuid references auth.users(id) on delete cascade,
  project_id uuid references public.projects(id) on delete cascade,
  enabled boolean not null default true,
  epoch bigint not null default 0 check (epoch >= 0),
  -- Monotonic change token for compare-and-swap. Nothing is retained per
  -- value: it exists only to answer "has this row moved since you read it?".
  revision bigint not null default 0 check (revision >= 0),
  learning_cutoff_at timestamptz not null default now(),
  content text not null default '',
  content_sha256 text check (
    content_sha256 is null or content_sha256 ~ '^[0-9a-f]{64}$'
  ),
  size_bytes integer not null default 0
    check (size_bytes >= 0 and size_bytes <= 16384),
  -- The curator job that last applied a write, so a retried job is a no-op.
  last_source_job_id uuid,
  status text not null default 'idle'
    check (status in ('idle', 'scheduled', 'processing', 'failed')),
  last_error_code text,
  last_source text check (
    last_source is null or last_source in ('manual', 'curator', 'wipe', 'settings')
  ),
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint memory_files_scope_owner_check check (
    (scope = 'user' and user_id is not null and project_id is null)
    or (scope = 'project' and project_id is not null and user_id is null)
  )
);
create unique index if not exists memory_files_user_unique
  on public.memory_files(user_id);
create unique index if not exists memory_files_project_unique
  on public.memory_files(project_id);

create table if not exists public.memory_consolidation_states (
  id uuid primary key default gen_random_uuid(),
  surface text not null check (surface in ('chat', 'word', 'tabular')),
  conversation_id uuid not null,
  actor_user_id uuid not null references auth.users(id) on delete cascade,
  project_id uuid references public.projects(id) on delete cascade,
  generation bigint not null default 0 check (generation >= 0),
  processed_generation bigint not null default 0 check (processed_generation >= 0),
  latest_activity_id uuid,
  conversation_generation bigint not null default 0
    check (conversation_generation >= 0),
  source_epoch bigint not null default 0 check (source_epoch >= 0),
  latest_turn_id uuid,
  latest_terminal_at timestamptz,
  latest_terminal_message_at timestamptz,
  run_after timestamptz,
  status text not null default 'idle'
    check (status in ('idle', 'scheduled', 'processing', 'failed', 'disabled')),
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(surface, conversation_id, actor_user_id)
);
create index if not exists memory_consolidation_states_project_idx
  on public.memory_consolidation_states(project_id) where project_id is not null;

alter table public.memory_consolidation_states
  add column if not exists latest_activity_id uuid,
  add column if not exists conversation_generation bigint not null default 0,
  add column if not exists source_epoch bigint not null default 0,
  add column if not exists latest_terminal_at timestamptz,
  add column if not exists latest_terminal_message_at timestamptz;

alter table public.memory_consolidation_states
  alter column actor_user_id set not null;
alter table public.memory_consolidation_states
  drop constraint if exists memory_consolidation_states_actor_user_id_fkey;
alter table public.memory_consolidation_states
  add constraint memory_consolidation_states_actor_user_id_fkey
  foreign key (actor_user_id) references auth.users(id) on delete cascade;

create table if not exists public.memory_conversation_activity (
  surface text not null check (surface in ('chat', 'word', 'tabular')),
  conversation_id uuid not null,
  generation bigint not null default 0 check (generation >= 0),
  source_epoch bigint not null default 0 check (source_epoch >= 0),
  latest_activity_id uuid,
  latest_turn_id uuid,
  latest_turn_message_at timestamptz,
  latest_turn_completed_at timestamptz,
  latest_turn_actor_user_id uuid references auth.users(id) on delete set null,
  project_id uuid,
  project_curator_actor_user_id uuid references auth.users(id) on delete set null,
  quiet_until timestamptz,
  actor_user_id uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(surface, conversation_id)
);

alter table public.memory_conversation_activity
  add column if not exists source_epoch bigint not null default 0,
  add column if not exists latest_activity_id uuid,
  add column if not exists latest_turn_message_at timestamptz,
  add column if not exists latest_turn_completed_at timestamptz,
  add column if not exists latest_turn_actor_user_id uuid references auth.users(id) on delete set null,
  add column if not exists project_id uuid,
  add column if not exists project_curator_actor_user_id uuid references auth.users(id) on delete set null,
  add column if not exists quiet_until timestamptz,
  add column if not exists deleted_at timestamptz;

alter table public.memory_conversation_activity
  drop column if exists active_turn_id,
  drop column if exists active_until;

alter table public.memory_conversation_activity
  alter column actor_user_id drop not null;
alter table public.memory_conversation_activity
  drop constraint if exists memory_conversation_activity_actor_user_id_fkey;
alter table public.memory_conversation_activity
  add constraint memory_conversation_activity_actor_user_id_fkey
  foreign key (actor_user_id) references auth.users(id) on delete set null;

create table if not exists public.memory_conversation_turn_leases (
  surface text not null check (surface in ('chat', 'word', 'tabular')),
  conversation_id uuid not null,
  activity_id uuid not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  primary key(surface, conversation_id, activity_id)
);

create index if not exists memory_conversation_turn_leases_expiry_idx
  on public.memory_conversation_turn_leases(expires_at);

create table if not exists public.memory_consolidation_results (
  job_id uuid not null,
  memory_file_id uuid not null references public.memory_files(id) on delete cascade,
  scope text not null check (scope in ('user', 'project')),
  outcome text not null check (
    outcome in ('updated', 'no_change', 'skipped', 'superseded')
  ),
  revision bigint,
  created_at timestamptz not null default now(),
  primary key(job_id, memory_file_id)
);
-- The composite primary key cannot serve the ON DELETE CASCADE lookup from
-- memory_files, and the retention sweep deletes by age.
create index if not exists memory_consolidation_results_file_idx
  on public.memory_consolidation_results(memory_file_id);
create index if not exists memory_consolidation_results_created_idx
  on public.memory_consolidation_results(created_at);
-- User-referencing columns whose parent rows are deleted (account deletion)
-- need an index or the cascade scans every memory table.
create index if not exists memory_files_updated_by_idx
  on public.memory_files(updated_by) where updated_by is not null;
create index if not exists memory_consolidation_states_actor_idx
  on public.memory_consolidation_states(actor_user_id);
create index if not exists memory_conversation_activity_actor_idx
  on public.memory_conversation_activity(actor_user_id)
  where actor_user_id is not null;
create index if not exists memory_conversation_activity_turn_actor_idx
  on public.memory_conversation_activity(latest_turn_actor_user_id)
  where latest_turn_actor_user_id is not null;
create index if not exists memory_conversation_activity_project_actor_idx
  on public.memory_conversation_activity(project_curator_actor_user_id)
  where project_curator_actor_user_id is not null;
create index if not exists memory_conversation_turn_leases_actor_idx
  on public.memory_conversation_turn_leases(actor_user_id);

alter table public.memory_files enable row level security;
alter table public.memory_consolidation_states enable row level security;
alter table public.memory_conversation_activity enable row level security;
alter table public.memory_conversation_turn_leases enable row level security;
alter table public.memory_consolidation_results enable row level security;

-- Existing accounts are opted out during upgrade. Project memory is on by
-- default; project creation writes its explicit setting in the same
-- application transaction so a creator's opt-out remains authoritative.
insert into public.memory_files(scope, user_id, enabled)
select 'user', id, false from auth.users
on conflict do nothing;
insert into public.memory_files(scope, project_id, enabled)
select 'project', id, true from public.projects
on conflict do nothing;

create or replace function public.initialize_new_user_memory()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.memory_files(scope, user_id, enabled)
  values ('user', new.id, true)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_memory on auth.users;
create trigger on_auth_user_created_memory
  after insert on auth.users
  for each row execute function public.initialize_new_user_memory();

create or replace function public.create_project_with_memory(
  p_user_id uuid,
  p_name text,
  p_cm_number text,
  p_practice text,
  p_org_id uuid,
  p_memory_enabled boolean
)
returns public.projects
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  created public.projects%rowtype;
begin
  insert into public.projects(user_id, name, cm_number, practice, org_id)
  values (p_user_id, p_name, p_cm_number, p_practice, p_org_id)
  returning * into created;
  insert into public.memory_files(scope, project_id, enabled)
  values ('project', created.id, p_memory_enabled);
  return created;
end;
$$;

-- Remove the superseded pre-stream activity API so it cannot be called out of band.
drop function if exists public.invalidate_memory_conversation(
  text, uuid, uuid, uuid, uuid
);

-- Conflicts raise P0001, never 40001: PostgREST treats a serialization
-- failure as retryable and never answers the request, which hung every
-- manual write that lost a compare-and-swap race and every curator job that
-- hit a superseded generation.
create or replace function public.lock_memory_conversation_source(
  p_surface text,
  p_conversation_id uuid,
  p_actor_user_id uuid
)
returns table(locked_project_id uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  owner_user_id uuid;
  resolved_project_id uuid;
  verified_owner_user_id uuid;
  verified_project_id uuid;
  review_id uuid;
  verified_review_id uuid;
  review_owner_user_id uuid;
  verified_review_owner_user_id uuid;
  word_document_id uuid;
  verified_word_document_id uuid;
begin
  if p_surface = 'chat' then
    select source.user_id, source.project_id
    into owner_user_id, resolved_project_id
    from public.chats source where source.id = p_conversation_id;
    if not found then return; end if;
    perform actor.id from auth.users actor
    where actor.id in (p_actor_user_id, owner_user_id)
    order by actor.id for key share;
    if resolved_project_id is not null then
      perform project.id from public.projects project
      where project.id = resolved_project_id for key share;
      if not found then return; end if;
    end if;
    select source.user_id, source.project_id
    into verified_owner_user_id, verified_project_id
    from public.chats source
    where source.id = p_conversation_id for key share;
    if not found
      or verified_owner_user_id is distinct from owner_user_id
      or verified_project_id is distinct from resolved_project_id
    then
      raise exception using errcode = 'P0001', message = 'memory_source_changed';
    end if;
  elsif p_surface = 'word' then
    select source.user_id, source.word_document_id
    into owner_user_id, word_document_id
    from public.word_chats source where source.id = p_conversation_id;
    if not found then return; end if;
    perform actor.id from auth.users actor
    where actor.id in (p_actor_user_id, owner_user_id)
    order by actor.id for key share;
    perform document.id from public.word_documents document
    where document.id = word_document_id for key share;
    if not found then return; end if;
    select source.user_id, source.word_document_id
    into verified_owner_user_id, verified_word_document_id
    from public.word_chats source
    where source.id = p_conversation_id for key share;
    if not found
      or verified_owner_user_id is distinct from owner_user_id
      or verified_word_document_id is distinct from word_document_id
    then
      raise exception using errcode = 'P0001', message = 'memory_source_changed';
    end if;
    resolved_project_id := null;
  elsif p_surface = 'tabular' then
    select source.user_id, source.review_id, review.user_id, review.project_id
    into owner_user_id, review_id, review_owner_user_id, resolved_project_id
    from public.tabular_review_chats source
    join public.tabular_reviews review on review.id = source.review_id
    where source.id = p_conversation_id;
    if not found then return; end if;
    perform actor.id from auth.users actor
    where actor.id in (p_actor_user_id, owner_user_id, review_owner_user_id)
    order by actor.id for key share;
    if resolved_project_id is not null then
      perform project.id from public.projects project
      where project.id = resolved_project_id for key share;
      if not found then return; end if;
    end if;
    perform review.id from public.tabular_reviews review
    where review.id = review_id for key share;
    if not found then return; end if;
    select source.user_id, source.review_id, review.user_id, review.project_id
    into verified_owner_user_id, verified_review_id,
      verified_review_owner_user_id, verified_project_id
    from public.tabular_review_chats source
    join public.tabular_reviews review on review.id = source.review_id
    where source.id = p_conversation_id for key share of source, review;
    if not found
      or verified_owner_user_id is distinct from owner_user_id
      or verified_review_id is distinct from review_id
      or verified_review_owner_user_id is distinct from review_owner_user_id
      or verified_project_id is distinct from resolved_project_id
    then
      raise exception using errcode = 'P0001', message = 'memory_source_changed';
    end if;
  else
    raise exception using errcode = '22023', message = 'invalid_memory_surface';
  end if;
  return query select resolved_project_id;
end;
$$;

drop function if exists public.begin_memory_conversation_turn(
  text, uuid, uuid, uuid, timestamptz
);
create or replace function public.begin_memory_conversation_turn(
  p_surface text,
  p_conversation_id uuid,
  p_actor_user_id uuid,
  p_activity_id uuid,
  p_lease_seconds integer,
  p_quiet_seconds integer
)
returns table(conversation_generation bigint, source_epoch bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  activity public.memory_conversation_activity%rowtype;
  lease_until timestamptz;
  minimum_quiet_until timestamptz;
begin
  if p_surface not in ('chat', 'word', 'tabular')
    or p_activity_id is null
    or p_lease_seconds < 60 or p_lease_seconds > 14400
    or p_quiet_seconds < 1 or p_quiet_seconds > 3600
  then
    raise exception using errcode = '22023', message = 'invalid_memory_activity';
  end if;
  lease_until := now() + make_interval(secs => p_lease_seconds);
  minimum_quiet_until := now() + make_interval(secs => p_quiet_seconds);

  -- Every mutation that can race source deletion starts with the canonical
  -- source row. The DELETE trigger therefore either fences this transaction
  -- before it creates scheduler metadata or runs after this transaction ends.
  perform locked.locked_project_id
  from public.lock_memory_conversation_source(
    p_surface, p_conversation_id, p_actor_user_id
  ) locked;
  if not found then
    raise exception using errcode = 'P0001', message = 'memory_conversation_deleted';
  end if;

  insert into public.memory_conversation_activity(
    surface, conversation_id, actor_user_id, quiet_until
  ) values (
    p_surface, p_conversation_id, p_actor_user_id, minimum_quiet_until
  ) on conflict (surface, conversation_id) do nothing;
  select * into activity from public.memory_conversation_activity
  where surface = p_surface and conversation_id = p_conversation_id for update;
  if activity.deleted_at is not null then
    raise exception using errcode = 'P0001', message = 'memory_conversation_deleted';
  end if;

  -- Only garbage is reaped here. An expired lease is already ignored by every
  -- gate, but the successful-turn scheduler proves its activity id by deleting
  -- its own lease row: reaping a row the moment it expired made a turn that
  -- outlived its lease (a long tool loop) silently unlearnable as soon as
  -- anyone else spoke in the conversation.
  delete from public.memory_conversation_turn_leases
  where surface = p_surface and conversation_id = p_conversation_id
    and expires_at <= now() - interval '1 day';
  insert into public.memory_conversation_turn_leases(
    surface, conversation_id, activity_id, actor_user_id, expires_at
  ) values (
    p_surface, p_conversation_id, p_activity_id, p_actor_user_id, lease_until
  ) on conflict (surface, conversation_id, activity_id) do update
    set actor_user_id = excluded.actor_user_id,
        expires_at = greatest(
          public.memory_conversation_turn_leases.expires_at,
          excluded.expires_at
        );

  update public.memory_conversation_activity
  set quiet_until = greatest(
        coalesce(quiet_until, '-infinity'::timestamptz),
        minimum_quiet_until
      ),
      actor_user_id = p_actor_user_id,
      updated_at = now()
  where surface = p_surface and conversation_id = p_conversation_id;

  -- A claimed worker is fenced again during promotion. Pending work is moved
  -- one quiet window: a turn that completes or is released retimes it
  -- itself, so only a crashed stream ever waits this long, and it is retried
  -- until its lease dies.
  update public.db_jobs
  set run_at = greatest(
        run_at,
        least(lease_until, now() + make_interval(secs => p_quiet_seconds))
      )
  where kind = 'memory.consolidate' and status = 'pending'
    and payload->>'surface' = p_surface
    and payload->>'conversationId' = p_conversation_id::text;
  update public.memory_consolidation_states
  set run_after = greatest(
        coalesce(run_after, '-infinity'::timestamptz),
        least(lease_until, now() + make_interval(secs => p_quiet_seconds))
      ),
      updated_at = now()
  where surface = p_surface and conversation_id = p_conversation_id
    and processed_generation < generation;

  return query select activity.generation, activity.source_epoch;
end;
$$;

drop function if exists public.release_memory_conversation_turn(
  text, uuid, uuid, timestamptz
);
create or replace function public.release_memory_conversation_turn(
  p_surface text,
  p_conversation_id uuid,
  p_activity_id uuid,
  p_quiet_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  activity public.memory_conversation_activity%rowtype;
  next_quiet_until timestamptz;
begin
  if p_surface not in ('chat', 'word', 'tabular')
    or p_activity_id is null
    or p_quiet_seconds < 1 or p_quiet_seconds > 3600
  then
    raise exception using errcode = '22023', message = 'invalid_memory_activity';
  end if;
  next_quiet_until := now() + make_interval(secs => p_quiet_seconds);
  select * into activity from public.memory_conversation_activity
  where surface = p_surface and conversation_id = p_conversation_id for update;
  if not found or activity.deleted_at is not null then return false; end if;
  delete from public.memory_conversation_turn_leases
  where surface = p_surface and conversation_id = p_conversation_id
    and activity_id = p_activity_id;
  if not found then return false; end if;

  update public.memory_conversation_activity
  set quiet_until = greatest(
        coalesce(quiet_until, '-infinity'::timestamptz),
        next_quiet_until
      ),
      updated_at = now()
  where surface = p_surface and conversation_id = p_conversation_id;
  -- A released turn is the earliest this conversation can be quiet again.
  -- Pending work moves there in both directions: later when the turn had
  -- interrupted a nearly-due job, earlier when a worker had deferred the job
  -- behind this turn's lease.
  update public.db_jobs
  set run_at = next_quiet_until
  where kind = 'memory.consolidate' and status = 'pending'
    and payload->>'surface' = p_surface
    and payload->>'conversationId' = p_conversation_id::text;
  update public.memory_consolidation_states as pending
  set run_after = greatest(
        coalesce(pending.run_after, '-infinity'::timestamptz),
        next_quiet_until
      ),
      status = case
        when pending.processed_generation < pending.generation
          then 'scheduled'
        else pending.status
      end,
      updated_at = now()
  where pending.surface = p_surface
    and pending.conversation_id = p_conversation_id;
  return true;
end;
$$;

create or replace function public.fence_memory_conversation_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fence_surface text := tg_argv[0];
begin
  if fence_surface not in ('chat', 'word', 'tabular') then
    raise exception using errcode = '22023', message = 'invalid_memory_surface';
  end if;

  -- DELETE already owns the canonical source row. Follow the global
  -- source -> activity -> lease -> state order used by scheduling/promotion.
  update public.memory_conversation_activity
  set source_epoch = source_epoch + 1,
      generation = generation + 1,
      latest_activity_id = null,
      latest_turn_id = null,
      quiet_until = null,
      deleted_at = now(),
      updated_at = now()
  where surface = fence_surface and conversation_id = old.id;
  delete from public.memory_conversation_turn_leases
  where surface = fence_surface and conversation_id = old.id;
  update public.memory_consolidation_states as rearmed
  set generation = rearmed.generation + 1,
      latest_activity_id = null,
      latest_turn_id = null,
      status = 'idle',
      updated_at = now()
  where surface = fence_surface and conversation_id = old.id;
  update public.db_jobs
  set run_at = least(run_at, now())
  where kind = 'memory.consolidate'
    and status = 'pending'
    and payload->>'surface' = fence_surface
    and payload->>'conversationId' = old.id::text;
  delete from public.memory_consolidation_states
  where surface = fence_surface and conversation_id = old.id;
  delete from public.memory_conversation_activity
  where surface = fence_surface and conversation_id = old.id;
  return old;
end;
$$;

drop trigger if exists chats_memory_delete_fence on public.chats;
create trigger chats_memory_delete_fence
before delete on public.chats
for each row execute function public.fence_memory_conversation_delete('chat');
drop trigger if exists word_chats_memory_delete_fence on public.word_chats;
create trigger word_chats_memory_delete_fence
before delete on public.word_chats
for each row execute function public.fence_memory_conversation_delete('word');
drop trigger if exists tabular_review_chats_memory_delete_fence
  on public.tabular_review_chats;
create trigger tabular_review_chats_memory_delete_fence
before delete on public.tabular_review_chats
for each row execute function public.fence_memory_conversation_delete('tabular');

create index if not exists db_jobs_memory_conversation_pending_idx
  on public.db_jobs((payload->>'surface'), (payload->>'conversationId'))
  where kind = 'memory.consolidate' and status = 'pending';
-- refresh_memory_file_status probes live jobs by actor/app epoch and by
-- project/project epoch on every status transition.
create index if not exists db_jobs_memory_app_epoch_idx
  on public.db_jobs((payload->>'actorUserId'), (payload->>'appEpoch'))
  where kind = 'memory.consolidate' and status in ('pending', 'running');
create index if not exists db_jobs_memory_project_epoch_idx
  on public.db_jobs((payload->>'projectId'), (payload->>'projectEpoch'))
  where kind = 'memory.consolidate' and status in ('pending', 'running');

-- Atomic batch claim with built-in stale-running recovery (crash resume).
-- Storage cleanup kinds carry the only durable pointer to objects whose
-- metadata has been wiped. They are retried until successful, including after
-- a worker crash; all other kinds retain the ordinary finite attempt budget.
create or replace function public.claim_db_jobs(
  p_limit integer default 5,
  p_stale_seconds integer default 600
)
returns setof public.db_jobs
language sql
as $$
  with abandoned as (
    update public.db_jobs
       set status = 'failed',
           finished_at = now(),
           last_error = coalesce(
             last_error,
             'abandoned: worker died mid-run and attempts are exhausted'
           )
     where status = 'running'
       and claimed_at < now() - make_interval(secs => p_stale_seconds)
       and attempts >= max_attempts
       and kind <> 'storage.cleanup'
    returning id
  ), candidates as (
    select id
      from public.db_jobs
     where (status = 'pending' and run_at <= now())
        or (status = 'failed'
            and kind = 'storage.cleanup')
        or (status = 'running'
            and claimed_at < now() - make_interval(secs => p_stale_seconds)
            and (
              attempts < max_attempts
              or kind = 'storage.cleanup'
            ))
     order by run_at
     limit p_limit
       for update skip locked
  )
  update public.db_jobs j
     set status = 'running',
         claimed_at = now(),
         finished_at = null,
         attempts = case
           when j.kind = 'storage.cleanup'
             then least(j.attempts::bigint + 1, 2147483647)::integer
           else j.attempts + 1
         end,
         max_attempts = case
           when j.kind = 'storage.cleanup'
             then 2147483647
           else j.max_attempts
         end,
         dedupe_key = case
           when j.status = 'failed'
             and j.kind = 'storage.cleanup'
             then null
           else j.dedupe_key
         end
    from candidates c
   where j.id = c.id
  returning j.*;
$$;

-- Claim ONE job by id — the Redis-delivery path (transactional-outbox
-- pattern). When Redis is configured, enqueue also adds a BullMQ "delivery"
-- job carrying this row's id so pickup is instant; the worker still claims
-- through Postgres via this function, so a duplicate delivery (BullMQ retry,
-- poller backstop racing the delivery) can never double-run the job: the
-- second claimer matches zero rows. Same stale-running recovery as the batch
-- claim, including its attempt budget: a job that kills its worker must not be
-- redelivered forever. Terminally failing a spent stale row is left to the
-- batch claim above, which every deployment runs (as the delivery mechanism
-- without Redis, as the lost-delivery backstop with it).
create or replace function public.claim_db_job(
  p_id uuid,
  p_stale_seconds integer default 600
)
returns setof public.db_jobs
language sql
as $$
  update public.db_jobs j
     set status = 'running',
         claimed_at = now(),
         finished_at = null,
         attempts = case
           when j.kind = 'storage.cleanup'
             then least(j.attempts::bigint + 1, 2147483647)::integer
           else j.attempts + 1
         end,
         max_attempts = case
           when j.kind = 'storage.cleanup'
             then 2147483647
           else j.max_attempts
         end,
         dedupe_key = case
           when j.status = 'failed'
             and j.kind = 'storage.cleanup'
             then null
           else j.dedupe_key
         end
   where j.id = p_id
     and ((j.status = 'pending' and j.run_at <= now())
       or (j.status = 'failed'
           and j.kind = 'storage.cleanup')
       or (j.status = 'running'
           and j.claimed_at < now() - make_interval(secs => p_stale_seconds)
           and (
             j.attempts < j.max_attempts
             or j.kind = 'storage.cleanup'
           )))
  returning j.*;
$$;

create index if not exists db_jobs_failed_cleanup_run_at_idx
  on public.db_jobs(run_at)
  where status = 'failed'
    and kind = 'storage.cleanup';

drop function if exists public.memory_source_allows_app_memory(text, uuid);
create or replace function public.memory_project_is_private(
  p_project_id uuid
)
returns boolean
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.projects project
    where project.id = p_project_id
      and project.org_id is null
      and not exists (
        select 1
        from public.project_access_grants grant_row
        where grant_row.project_id = project.id
      )
  );
$$;

create or replace function public.memory_source_allows_app_memory(
  p_surface text,
  p_conversation_id uuid,
  p_actor_user_id uuid,
  p_project_id uuid
)
returns boolean
language sql
-- Re-read grants after the caller's project-row lock wait. A stable function
-- could retain the statement's older snapshot while a concurrent share wins.
volatile
security definer
set search_path = public, pg_temp
as $$
  -- App memory is private to one user, so it may only learn from a
  -- conversation nobody else can read. That is a property of the
  -- conversation itself (its owner, organization, and direct grants) and,
  -- when it lives in a project, of the project too. The read path in the
  -- routes applies the same three tests before showing app memory.
  select case
    when p_surface = 'word' then p_project_id is null
    when p_surface = 'chat' then
      exists (
        select 1
        from public.chats chat
        where chat.id = p_conversation_id
          and chat.user_id = p_actor_user_id
          and chat.org_id is null
          and not exists (
            select 1
            from public.chat_access_grants grant_row
            where grant_row.chat_id = chat.id
          )
      )
      and (
        p_project_id is null
        or public.memory_project_is_private(p_project_id)
      )
    when p_surface = 'tabular' then
      p_project_id is not null
      and exists (
        select 1
        from public.tabular_review_chats chat
        join public.tabular_reviews review on review.id = chat.review_id
        where chat.id = p_conversation_id
          and review.user_id = p_actor_user_id
          and review.org_id is null
          and not exists (
            select 1
            from public.tabular_review_access_grants grant_row
            where grant_row.tabular_review_id = review.id
          )
      )
      and public.memory_project_is_private(p_project_id)
    else false
  end;
$$;

drop function if exists public.write_memory_file(
  uuid, bigint, bigint, text, text, integer, text, uuid, text, uuid, uuid, uuid, bigint, bigint, bigint
);
create or replace function public.write_memory_file(
  p_memory_file_id uuid,
  p_expected_revision bigint,
  p_expected_epoch bigint,
  p_content text,
  p_content_sha256 text,
  p_size_bytes integer,
  p_source text,
  p_updated_by uuid default null,
  p_source_surface text default null,
  p_source_chat_id uuid default null,
  p_source_job_id uuid default null,
  p_consolidation_state_id uuid default null,
  p_consolidation_generation bigint default null,
  p_conversation_generation bigint default null,
  p_source_epoch bigint default null
)
returns table(applied boolean, new_revision bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  target public.memory_files%rowtype;
  consolidation public.memory_consolidation_states%rowtype;
  activity public.memory_conversation_activity%rowtype;
begin
  if p_source not in ('manual', 'curator') then
    raise exception using errcode = '22023', message = 'invalid_memory_source';
  end if;
  if p_size_bytes < 0 or p_size_bytes > 16384 then
    raise exception using errcode = '22023', message = 'memory_content_too_large';
  end if;
  -- Match canonical DELETE's source -> scheduler-state lock order. Holding
  -- this key-share lock through the write makes deletion and learning
  -- serialize without a check/write gap.
  if p_source = 'curator' then
    if p_consolidation_state_id is null
      or p_consolidation_generation is null
      or p_conversation_generation is null
      or p_source_surface is null
      or p_source_chat_id is null
      or p_source_epoch is null
    then
      raise exception using errcode = '22023', message = 'memory_curator_fence_required';
    end if;
    perform locked.locked_project_id
    from public.lock_memory_conversation_source(
      p_source_surface, p_source_chat_id, p_updated_by
    ) locked;
    if not found then
      raise exception using errcode = 'P0001', message = 'memory_job_superseded';
    end if;
    select * into activity from public.memory_conversation_activity
    where surface = p_source_surface and conversation_id = p_source_chat_id
    for update;
    if not found
      or activity.deleted_at is not null
      or activity.source_epoch <> p_source_epoch
      or activity.generation <> p_conversation_generation
    then
      raise exception using errcode = 'P0001', message = 'memory_job_superseded';
    end if;
    if activity.quiet_until is null
      or activity.quiet_until > now()
      or exists (
        select 1 from public.memory_conversation_turn_leases lease
        where lease.surface = p_source_surface
          and lease.conversation_id = p_source_chat_id
          and lease.expires_at > now()
      )
    then
      raise exception using errcode = '55000', message = 'memory_conversation_not_quiet';
    end if;
    select * into consolidation from public.memory_consolidation_states
    where id = p_consolidation_state_id for update;
    if not found
      or consolidation.generation <> p_consolidation_generation
      or consolidation.conversation_generation <> p_conversation_generation
      or consolidation.surface <> p_source_surface
      or consolidation.conversation_id <> p_source_chat_id
      or consolidation.source_epoch <> p_source_epoch
      or consolidation.actor_user_id is distinct from p_updated_by
    then
      raise exception using errcode = 'P0001', message = 'memory_job_superseded';
    end if;
  end if;

  select * into target from public.memory_files
  where id = p_memory_file_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'memory_file_not_found';
  end if;

  -- A curator job that is retried after its transaction already committed
  -- must not apply the same replacement twice.
  if p_source_job_id is not null
    and target.last_source_job_id = p_source_job_id
  then
    return query select false, target.revision;
    return;
  end if;

  if p_source = 'curator' then
    if (target.scope = 'user' and target.user_id <> consolidation.actor_user_id)
      or (target.scope = 'project' and target.project_id is distinct from consolidation.project_id)
    then
      raise exception using errcode = 'P0001', message = 'memory_job_superseded';
    end if;
    if target.scope = 'user'
      and not public.memory_source_allows_app_memory(
        p_source_surface, p_source_chat_id, p_updated_by, activity.project_id
      )
    then
      raise exception using errcode = 'P0001', message = 'memory_scope_ineligible';
    end if;
  end if;

  if not target.enabled then
    raise exception using errcode = 'P0001', message = 'memory_disabled';
  end if;
  if target.epoch <> p_expected_epoch then
    raise exception using errcode = 'P0001', message = 'memory_epoch_conflict';
  end if;
  if target.revision <> p_expected_revision then
    raise exception using errcode = 'P0001', message = 'memory_revision_conflict';
  end if;

  -- An unchanged body is not a write: it would burn a revision and, for the
  -- curator, look like new learning in the audit trail. The job receipt is
  -- still stamped so a retried job is recognised above and applied once.
  if target.content_sha256 is not distinct from p_content_sha256 then
    if p_source_job_id is not null then
      update public.memory_files
      set last_source_job_id = p_source_job_id
      where id = p_memory_file_id;
      insert into public.memory_consolidation_results(
        job_id, memory_file_id, scope, outcome, revision
      ) values (
        p_source_job_id, target.id, target.scope, 'no_change', target.revision
      ) on conflict (job_id, memory_file_id) do update
        set outcome = excluded.outcome,
            revision = excluded.revision,
            created_at = now();
    end if;
    return query select false, target.revision;
    return;
  end if;

  update public.memory_files
  set content = p_content,
      content_sha256 = p_content_sha256,
      size_bytes = p_size_bytes,
      revision = target.revision + 1,
      status = case
        when p_source = 'manual' and target.status = 'failed' then 'idle'
        else target.status
      end,
      last_error_code = null,
      last_source = p_source,
      last_source_job_id = p_source_job_id,
      updated_by = p_updated_by,
      updated_at = now()
  where id = p_memory_file_id;

  if p_source_job_id is not null then
    insert into public.memory_consolidation_results(
      job_id, memory_file_id, scope, outcome, revision
    ) values (
      p_source_job_id, target.id, target.scope, 'updated', target.revision + 1
    ) on conflict (job_id, memory_file_id) do update
      set outcome = excluded.outcome,
          revision = excluded.revision,
          created_at = now();
  end if;

  return query select true, target.revision + 1;
end;
$$;

drop function if exists public.wipe_memory_file(uuid, boolean);
drop function if exists public.wipe_memory_file(uuid, boolean, uuid, text);
drop function if exists public.wipe_memory_file(uuid, boolean, uuid, text, boolean);
drop function if exists public.wipe_memory_file(
  uuid, boolean, uuid, text, boolean
);

create or replace function public.wipe_memory_file(
  p_memory_file_id uuid,
  p_enabled boolean,
  p_updated_by uuid default null,
  p_source text default 'wipe'
)
returns table(
  new_epoch bigint,
  new_revision bigint,
  effective_enabled boolean,
  mutation_at timestamptz,
  mutation_by uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  target public.memory_files%rowtype;
  changed_at timestamptz := now();
begin
  if p_source not in ('wipe', 'settings') then
    raise exception using errcode = '22023', message = 'invalid_memory_source';
  end if;
  select * into target from public.memory_files
  where id = p_memory_file_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'memory_file_not_found';
  end if;

  -- The body lives on this row, so erasure is the same UPDATE that fences
  -- in-flight curator work: the epoch bump supersedes any job that read the
  -- old content, and the revision bump invalidates loaded editor drafts.
  update public.memory_files
  set enabled = coalesce(p_enabled, target.enabled),
      epoch = target.epoch + 1,
      revision = target.revision + 1,
      learning_cutoff_at = changed_at,
      content = '',
      content_sha256 = null,
      size_bytes = 0,
      status = 'idle',
      last_error_code = null,
      last_source = p_source,
      last_source_job_id = null,
      updated_by = p_updated_by,
      updated_at = changed_at
  where id = target.id;

  return query select
    target.epoch + 1,
    target.revision + 1,
    coalesce(p_enabled, target.enabled),
    changed_at,
    p_updated_by;
end;
$$;

drop function if exists public.enable_memory_file(uuid, uuid);
create or replace function public.enable_memory_file(
  p_memory_file_id uuid,
  p_updated_by uuid
)
returns table(
  effective_enabled boolean,
  new_epoch bigint,
  new_revision bigint,
  mutation_at timestamptz,
  mutation_by uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  target public.memory_files%rowtype;
  changed_at timestamptz := now();
begin
  select * into target from public.memory_files
  where id = p_memory_file_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'memory_file_not_found';
  end if;
  if target.enabled then
    return query select true, target.epoch, target.revision,
      target.updated_at, target.updated_by;
    return;
  end if;
  update public.memory_files memory_file
  set enabled = true,
      epoch = target.epoch + 1,
      revision = target.revision + 1,
      learning_cutoff_at = changed_at,
      content = '',
      content_sha256 = null,
      size_bytes = 0,
      last_source_job_id = null,
      status = 'idle',
      last_error_code = null,
      last_source = 'settings',
      updated_by = p_updated_by,
      updated_at = changed_at
  where memory_file.id = target.id;
  return query select true, target.epoch + 1, target.revision + 1,
    changed_at, p_updated_by;
end;
$$;

-- Remove superseded scheduler overloads before installing the final API.
drop function if exists public.schedule_memory_consolidation(
  text, uuid, uuid, uuid, uuid, timestamptz
);
drop function if exists public.schedule_memory_consolidation(
  text, uuid, uuid, uuid, uuid, uuid, timestamptz
);
create or replace function public.schedule_memory_consolidation(
  p_surface text,
  p_conversation_id uuid,
  p_actor_user_id uuid,
  p_project_id uuid,
  p_turn_id uuid,
  p_activity_id uuid,
  p_quiet_seconds integer
)
returns table(job_id uuid, generation bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  state public.memory_consolidation_states%rowtype;
  activity public.memory_conversation_activity%rowtype;
  queued_state public.memory_consolidation_states%rowtype;
  app_file public.memory_files%rowtype;
  project_file public.memory_files%rowtype;
  canonical_project_id uuid;
  terminal_message_at timestamptz;
  terminal_at timestamptz := now();
  next_quiet_until timestamptz;
  next_conversation_generation bigint;
  actor_generation bigint;
  actor_job_id uuid;
  queued_job_id uuid;
  cursor_advances boolean;
  actor_cursor_advances boolean;
  app_turn_eligible boolean;
  app_enabled boolean;
  project_enabled boolean;
  pending_actor_ids uuid[];
begin
  if p_surface not in ('chat', 'word', 'tabular')
    or p_turn_id is null or p_activity_id is null
    or p_quiet_seconds < 1 or p_quiet_seconds > 3600
  then
    raise exception using errcode = '22023', message = 'invalid_memory_turn';
  end if;
  next_quiet_until := terminal_at + make_interval(secs => p_quiet_seconds);

  -- Lock the canonical source before activity/state/files. The terminal row is
  -- also verified here so a forged or failed assistant id is never scheduled.
  select locked.locked_project_id into canonical_project_id
  from public.lock_memory_conversation_source(
    p_surface, p_conversation_id, p_actor_user_id
  ) locked;
  if not found then return; end if;
  if p_surface = 'chat' then
    select message.created_at into terminal_message_at
    from public.chat_messages message
    where message.id = p_turn_id and message.chat_id = p_conversation_id
      and message.role = 'assistant' and message.content is not null
      and message.memory_input_message_id is not null
      and (
        message.author_user_id is null
        or message.author_user_id = p_actor_user_id
        or message.content @> jsonb_build_array(jsonb_build_object(
          'type', 'ask_inputs_response', 'author_user_id', p_actor_user_id
        ))
      )
    for key share;
  elsif p_surface = 'word' then
    select message.created_at into terminal_message_at
    from public.word_chat_messages message
    where message.id = p_turn_id and message.chat_id = p_conversation_id
      and message.role = 'assistant' and message.content is not null
      and message.memory_input_message_id is not null
      and (
        message.author_user_id is null
        or message.author_user_id = p_actor_user_id
        or message.content @> jsonb_build_array(jsonb_build_object(
          'type', 'ask_inputs_response', 'author_user_id', p_actor_user_id
        ))
      )
    for key share;
  else
    select message.created_at into terminal_message_at
    from public.tabular_review_chat_messages message
    where message.id = p_turn_id and message.chat_id = p_conversation_id
      and message.role = 'assistant' and message.content is not null
      and message.memory_input_message_id is not null
      and (
        message.author_user_id is null
        or message.author_user_id = p_actor_user_id
        or message.content @> jsonb_build_array(jsonb_build_object(
          'type', 'ask_inputs_response', 'author_user_id', p_actor_user_id
        ))
      )
    for key share;
  end if;
  if terminal_message_at is null then return; end if;
  if p_project_id is not null and p_project_id is distinct from canonical_project_id then
    raise exception using errcode = '22023', message = 'invalid_memory_project';
  end if;
  app_turn_eligible := public.memory_source_allows_app_memory(
    p_surface, p_conversation_id, p_actor_user_id, canonical_project_id
  );

  insert into public.memory_conversation_activity(
    surface, conversation_id, actor_user_id, quiet_until
  ) values (
    p_surface, p_conversation_id, p_actor_user_id, next_quiet_until
  ) on conflict (surface, conversation_id) do nothing;
  select * into activity from public.memory_conversation_activity current_activity
  where current_activity.surface = p_surface
    and current_activity.conversation_id = p_conversation_id
  for update;
  if not found or activity.deleted_at is not null then return; end if;

  delete from public.memory_conversation_turn_leases lease
  where lease.surface = p_surface
    and lease.conversation_id = p_conversation_id
    and lease.activity_id = p_activity_id
    and lease.actor_user_id is not distinct from p_actor_user_id;
  if not found then return; end if;
  if p_surface = 'chat' then
    update public.chat_messages message
    set memory_eligible_at = terminal_at,
        memory_app_eligible_at = case
          when app_turn_eligible then terminal_at else null end
    where message.id = p_turn_id and message.chat_id = p_conversation_id;
  elsif p_surface = 'word' then
    update public.word_chat_messages message
    set memory_eligible_at = terminal_at,
        memory_app_eligible_at = case
          when app_turn_eligible then terminal_at else null end
    where message.id = p_turn_id and message.chat_id = p_conversation_id;
  else
    update public.tabular_review_chat_messages message
    set memory_eligible_at = terminal_at,
        memory_app_eligible_at = case
          when app_turn_eligible then terminal_at else null end
    where message.id = p_turn_id and message.chat_id = p_conversation_id;
  end if;
  delete from public.memory_conversation_turn_leases lease
  where lease.surface = p_surface
    and lease.conversation_id = p_conversation_id
    and lease.expires_at <= terminal_at;

  cursor_advances := activity.latest_turn_message_at is null
    or (terminal_message_at, p_turn_id) >
       (activity.latest_turn_message_at, activity.latest_turn_id);
  next_conversation_generation := activity.generation + 1;
  update public.memory_conversation_activity current_activity
  set generation = next_conversation_generation,
      latest_turn_id = case when cursor_advances
        then p_turn_id else current_activity.latest_turn_id end,
      latest_turn_message_at = case when cursor_advances
        then terminal_message_at else current_activity.latest_turn_message_at end,
      latest_turn_completed_at = terminal_at,
      latest_turn_actor_user_id = case when cursor_advances
        then p_actor_user_id else current_activity.latest_turn_actor_user_id end,
      project_id = case
        when current_activity.project_id is distinct from canonical_project_id
          then canonical_project_id
        else current_activity.project_id
      end,
      project_curator_actor_user_id = case
        when canonical_project_id is null then null
        when p_project_id is not null then p_actor_user_id
        when current_activity.project_id is distinct from canonical_project_id then null
        else current_activity.project_curator_actor_user_id
      end,
      quiet_until = next_quiet_until,
      actor_user_id = p_actor_user_id,
      updated_at = terminal_at
  where current_activity.surface = p_surface
    and current_activity.conversation_id = p_conversation_id
  returning current_activity.* into activity;

  insert into public.memory_consolidation_states(
    surface, conversation_id, actor_user_id, project_id, source_epoch
  ) values (
    p_surface, p_conversation_id, p_actor_user_id, p_project_id,
    activity.source_epoch
  ) on conflict (surface, conversation_id, actor_user_id) do nothing;
  select * into state from public.memory_consolidation_states current_state
  where current_state.surface = p_surface
    and current_state.conversation_id = p_conversation_id
    and current_state.actor_user_id = p_actor_user_id
  for update;
  if not found then
    -- The upsert above guarantees the row; a miss means it was deleted under
    -- us. Every later statement keys on state.id, so continuing would be a
    -- silent no-op that looks exactly like "nothing to schedule".
    raise exception using errcode = 'P0001', message = 'memory_state_missing';
  end if;

  actor_cursor_advances := state.latest_terminal_message_at is null
    or (terminal_message_at, p_turn_id) >
       (state.latest_terminal_message_at, state.latest_turn_id);
  actor_generation := state.generation + 1;
  update public.memory_consolidation_states current_state
  set generation = actor_generation,
      conversation_generation = next_conversation_generation,
      source_epoch = activity.source_epoch,
      latest_turn_id = case when actor_cursor_advances
        then p_turn_id else current_state.latest_turn_id end,
      latest_terminal_message_at = case when actor_cursor_advances
        then terminal_message_at else current_state.latest_terminal_message_at end,
      latest_terminal_at = terminal_at,
      project_id = case when p_project_id is not null
        then p_project_id else current_state.project_id end,
      run_after = next_quiet_until,
      status = 'idle',
      last_error_code = null,
      updated_at = terminal_at
  where current_state.id = state.id;

  -- Extend the global quiet generation without losing any actor's most recent
  -- successful cursor. The retained project curator is also rearmed even when
  -- their app cursor was already processed, so a viewer's later project turn
  -- can still be learned by a currently-authorized editor.
  update public.memory_consolidation_states rearmed
  set generation = rearmed.generation + 1,
      conversation_generation = next_conversation_generation,
      source_epoch = activity.source_epoch,
      run_after = next_quiet_until,
      status = 'idle',
      last_error_code = null,
      updated_at = terminal_at
  where rearmed.surface = p_surface
    and rearmed.conversation_id = p_conversation_id
    and rearmed.id <> state.id
    and rearmed.latest_turn_id is not null
    and (
      rearmed.processed_generation < rearmed.generation
      or rearmed.actor_user_id = activity.project_curator_actor_user_id
    );

  insert into public.memory_files(scope, user_id, enabled)
  select distinct 'user', pending.actor_user_id, true
  from public.memory_consolidation_states pending
  where pending.surface = p_surface
    and pending.conversation_id = p_conversation_id
    and pending.latest_turn_id is not null
    and pending.processed_generation < pending.generation
  on conflict do nothing;
  if activity.project_id is not null then
    insert into public.memory_files(scope, project_id, enabled)
    values ('project', activity.project_id, true)
    on conflict do nothing;
  end if;

  -- Lock every file this turn may touch, in id order, through the unique
  -- indexes. The obvious "user_id in (subquery) or project_id = ..." shape
  -- cannot use either index under a top-level OR and scanned (and row
  -- locked) the whole table on every assistant turn.
  select coalesce(array_agg(distinct pending.actor_user_id), '{}')
  into pending_actor_ids
  from public.memory_consolidation_states pending
  where pending.surface = p_surface
    and pending.conversation_id = p_conversation_id
    and pending.latest_turn_id is not null
    and pending.processed_generation < pending.generation;
  perform memory_file.id
  from public.memory_files memory_file
  where memory_file.id in (
      select locked_user_file.id from public.memory_files locked_user_file
      where locked_user_file.scope = 'user'
        and locked_user_file.user_id = any(pending_actor_ids)
      union all
      select locked_project_file.id
      from public.memory_files locked_project_file
      where locked_project_file.scope = 'project'
        and locked_project_file.project_id = activity.project_id
    )
  order by memory_file.id
  for update;

  for queued_state in
    select pending.* from public.memory_consolidation_states pending
    where pending.surface = p_surface
      and pending.conversation_id = p_conversation_id
      and pending.latest_turn_id is not null
      and pending.processed_generation < pending.generation
    order by pending.actor_user_id, pending.id
    for update
  loop
    select * into app_file from public.memory_files memory_file
    where memory_file.scope = 'user'
      and memory_file.user_id = queued_state.actor_user_id;
    app_enabled := coalesce(app_file.enabled, false)
      and public.memory_source_allows_app_memory(
        p_surface, p_conversation_id, queued_state.actor_user_id,
        activity.project_id
      );
    project_enabled := false;
    if activity.project_id is not null
      and queued_state.actor_user_id = activity.project_curator_actor_user_id
      and queued_state.project_id = activity.project_id
    then
      select * into project_file from public.memory_files memory_file
      where memory_file.scope = 'project'
        and memory_file.project_id = activity.project_id;
      project_enabled := coalesce(project_file.enabled, false);
    end if;

    if not app_enabled and not project_enabled then
      update public.memory_consolidation_states finished_state
      set processed_generation = queued_state.generation,
          status = 'idle', updated_at = terminal_at
      where finished_state.id = queued_state.id;
      continue;
    end if;

    queued_job_id := gen_random_uuid();
    insert into public.db_jobs(
      id, kind, payload, max_attempts, run_at, dedupe_key
    ) values (
      queued_job_id,
      'memory.consolidate',
      jsonb_build_object(
        'stateId', queued_state.id,
        'generation', queued_state.generation,
        'surface', queued_state.surface,
        'conversationId', queued_state.conversation_id,
        'actorUserId', queued_state.actor_user_id,
        'projectId', queued_state.project_id,
        'turnId', queued_state.latest_turn_id,
        'terminalAt', queued_state.latest_terminal_at,
        'projectTurnId', activity.latest_turn_id,
        'projectTerminalAt', activity.latest_turn_completed_at,
        'conversationGeneration', next_conversation_generation,
        'sourceEpoch', queued_state.source_epoch,
        'appEpoch', case when app_enabled then app_file.epoch else null end,
        'projectEpoch', case when project_enabled then project_file.epoch else null end
      ),
      5,
      next_quiet_until,
      'memory:' || queued_state.id::text || ':' ||
        queued_state.generation::text || ':' || next_conversation_generation::text
    );
    update public.memory_consolidation_states scheduled_state
    set status = 'scheduled', updated_at = terminal_at
    where scheduled_state.id = queued_state.id;
    if app_enabled then
      update public.memory_files memory_file
      set status = case when memory_file.status = 'processing'
        then memory_file.status else 'scheduled' end
      where memory_file.id = app_file.id;
    end if;
    if project_enabled then
      update public.memory_files memory_file
      set status = case when memory_file.status = 'processing'
        then memory_file.status else 'scheduled' end
      where memory_file.id = project_file.id;
    end if;
    if queued_state.id = state.id then actor_job_id := queued_job_id; end if;
  end loop;

  if actor_job_id is not null then
    return query select actor_job_id, actor_generation;
  end if;
end;
$$;

create or replace function public.set_memory_consolidation_status(
  p_state_id uuid,
  p_generation bigint,
  p_status text,
  p_error_code text default null,
  p_mark_processed boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  state public.memory_consolidation_states%rowtype;
begin
  if p_status not in ('idle', 'processing', 'failed') then
    raise exception using errcode = '22023', message = 'invalid_memory_status';
  end if;
  select * into state from public.memory_consolidation_states
  where id = p_state_id for update;
  if not found or state.generation <> p_generation then
    return false;
  end if;
  update public.memory_consolidation_states
  set status = p_status,
      processed_generation = case
        when p_mark_processed then greatest(processed_generation, p_generation)
        else processed_generation
      end,
      last_error_code = p_error_code,
      updated_at = now()
  where id = state.id;
  return true;
end;
$$;

create or replace function public.refresh_memory_file_status(
  p_memory_file_id uuid,
  p_expected_epoch bigint,
  p_current_job_id uuid,
  p_requested_status text,
  p_error_code text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  target public.memory_files%rowtype;
  next_status text := p_requested_status;
begin
  if p_requested_status not in ('idle', 'scheduled', 'processing', 'failed') then
    raise exception using errcode = '22023', message = 'invalid_memory_status';
  end if;
  select * into target from public.memory_files
  where id = p_memory_file_id for update;
  if not found or not target.enabled or target.epoch <> p_expected_epoch then
    return false;
  end if;
  if p_requested_status <> 'processing' then
    if exists (
      select 1 from public.db_jobs job
      where job.kind = 'memory.consolidate'
        and job.id <> p_current_job_id
        and job.status = 'running'
        and (
          (target.scope = 'user'
            and job.payload->>'actorUserId' = target.user_id::text
            and job.payload->>'appEpoch' = target.epoch::text)
          or
          (target.scope = 'project'
            and job.payload->>'projectId' = target.project_id::text
            and job.payload->>'projectEpoch' = target.epoch::text)
        )
    ) then
      next_status := 'processing';
    elsif exists (
      select 1 from public.db_jobs job
      where job.kind = 'memory.consolidate'
        and job.id <> p_current_job_id
        and job.status = 'pending'
        and (
          (target.scope = 'user'
            and job.payload->>'actorUserId' = target.user_id::text
            and job.payload->>'appEpoch' = target.epoch::text)
          or
          (target.scope = 'project'
            and job.payload->>'projectId' = target.project_id::text
            and job.payload->>'projectEpoch' = target.epoch::text)
        )
    ) then
      next_status := 'scheduled';
    end if;
  end if;
  update public.memory_files
  set status = next_status,
      last_error_code = case
        when next_status = 'failed' then p_error_code
        else null
      end,
      updated_at = now()
  where id = target.id;
  return true;
end;
$$;

revoke all on public.memory_files from anon, authenticated;
revoke all on public.memory_consolidation_states from anon, authenticated;
revoke all on public.memory_conversation_activity from anon, authenticated;
revoke all on public.memory_conversation_turn_leases from anon, authenticated;
revoke all on public.memory_consolidation_results from anon, authenticated;

revoke all on function public.create_project_with_memory(uuid, text, text, text, uuid, boolean)
  from public, anon, authenticated;
revoke all on function public.initialize_new_user_memory()
  from public, anon, authenticated;
revoke all on function public.lock_memory_conversation_source(text, uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.memory_project_is_private(uuid)
  from public, anon, authenticated;
revoke all on function public.memory_source_allows_app_memory(text, uuid, uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.fence_memory_conversation_delete()
  from public, anon, authenticated;
revoke all on function public.write_memory_file(uuid, bigint, bigint, text, text, integer, text, uuid, text, uuid, uuid, uuid, bigint, bigint, bigint)
  from public, anon, authenticated;
revoke all on function public.wipe_memory_file(uuid, boolean, uuid, text)
  from public, anon, authenticated;
revoke all on function public.enable_memory_file(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.begin_memory_conversation_turn(text, uuid, uuid, uuid, integer, integer)
  from public, anon, authenticated;
revoke all on function public.release_memory_conversation_turn(text, uuid, uuid, integer)
  from public, anon, authenticated;
revoke all on function public.schedule_memory_consolidation(text, uuid, uuid, uuid, uuid, uuid, integer)
  from public, anon, authenticated;
revoke all on function public.set_memory_consolidation_status(uuid, bigint, text, text, boolean)
  from public, anon, authenticated;
revoke all on function public.refresh_memory_file_status(uuid, bigint, uuid, text, text)
  from public, anon, authenticated;

grant select, insert, update, delete
  on public.memory_files,
     public.memory_consolidation_states,
     public.memory_conversation_activity,
     public.memory_conversation_turn_leases,
     public.memory_consolidation_results
  to service_role;
grant execute on function public.create_project_with_memory(uuid, text, text, text, uuid, boolean)
  to service_role;
grant execute on function public.initialize_new_user_memory()
  to service_role;
grant execute on function public.lock_memory_conversation_source(text, uuid, uuid)
  to service_role;
grant execute on function public.memory_project_is_private(uuid)
  to service_role;
grant execute
  on function public.memory_source_allows_app_memory(text, uuid, uuid, uuid)
  to service_role;
grant execute on function public.fence_memory_conversation_delete()
  to service_role;
grant execute
  on function public.write_memory_file(uuid, bigint, bigint, text, text, integer, text, uuid, text, uuid, uuid, uuid, bigint, bigint, bigint)
  to service_role;
grant execute on function public.wipe_memory_file(uuid, boolean, uuid, text)
  to service_role;
grant execute on function public.enable_memory_file(uuid, uuid)
  to service_role;
grant execute
  on function public.begin_memory_conversation_turn(text, uuid, uuid, uuid, integer, integer)
  to service_role;
grant execute
  on function public.release_memory_conversation_turn(text, uuid, uuid, integer)
  to service_role;
grant execute
  on function public.schedule_memory_consolidation(text, uuid, uuid, uuid, uuid, uuid, integer)
  to service_role;
grant execute
  on function public.set_memory_consolidation_status(uuid, bigint, text, text, boolean)
  to service_role;
grant execute on function public.refresh_memory_file_status(uuid, bigint, uuid, text, text)
  to service_role;
