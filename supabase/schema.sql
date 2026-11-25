-- RPG Mestre IA: contas e saves na nuvem (rode no SQL Editor do Supabase)

-- Um registro por jogador: todo o save (personagens, diários, mundo, campanhas offline) e as chaves de IA dele.
create table if not exists public.rpg_saves (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  dados      jsonb not null default '{}'::jsonb,
  chaves     jsonb not null default '{}'::jsonb,
  atualizado timestamptz not null default now()
);
alter table public.rpg_saves enable row level security;

-- Cada jogador só lê e grava o próprio save.
drop policy if exists "rpg_saves: dono le" on public.rpg_saves;
create policy "rpg_saves: dono le" on public.rpg_saves for select using (auth.uid() = user_id);
drop policy if exists "rpg_saves: dono cria" on public.rpg_saves;
create policy "rpg_saves: dono cria" on public.rpg_saves for insert with check (auth.uid() = user_id);
drop policy if exists "rpg_saves: dono atualiza" on public.rpg_saves;
create policy "rpg_saves: dono atualiza" on public.rpg_saves for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Contador de uso da IA do jogo (as chaves do dono). Sem políticas: só a função "ia" (service role) mexe.
create table if not exists public.rpg_uso_ia (
  user_id uuid not null references auth.users (id) on delete cascade,
  dia     date not null default current_date,
  n       integer not null default 0,
  primary key (user_id, dia)
);
alter table public.rpg_uso_ia enable row level security;

-- Soma 1 pedido no dia e devolve o total (chamada pela função "ia").
create or replace function public.rpg_conta_uso(uid uuid) returns integer
language sql security definer set search_path = public as $$
  insert into public.rpg_uso_ia (user_id, dia, n) values (uid, current_date, 1)
  on conflict (user_id, dia) do update set n = public.rpg_uso_ia.n + 1
  returning n;
$$;
revoke all on function public.rpg_conta_uso(uuid) from public, anon, authenticated;

-- Chaves de IA do dono do jogo (usadas pela função "ia"). Sem políticas: só a função lê.
create table if not exists public.rpg_chaves_dono (
  prov       text primary key,
  chave      text not null,
  atualizado timestamptz not null default now()
);
alter table public.rpg_chaves_dono enable row level security;
revoke all on public.rpg_chaves_dono from anon, authenticated;

-- Banco de chaves: jogadores emprestam as próprias chaves (opcional, com aceite dos termos).
-- Usadas só nas mesas do dono. Apagar a conta apaga as chaves (cascade).
create table if not exists public.rpg_banco_chaves (
  user_id        uuid not null references auth.users (id) on delete cascade,
  prov           text not null,
  chave          text not null,
  aceitou_termos timestamptz not null,
  criado         timestamptz not null default now(),
  primary key (user_id, prov)
);
alter table public.rpg_banco_chaves enable row level security;
revoke all on public.rpg_banco_chaves from anon, authenticated;
