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

-- Permissões das tabelas (projetos novos do Supabase não dão sozinhos). As políticas RLS acima limitam cada jogador ao próprio save.
grant select, insert, update on public.rpg_saves to authenticated;
grant select, insert, update, delete on public.rpg_saves, public.rpg_uso_ia, public.rpg_chaves_dono, public.rpg_banco_chaves to service_role;
grant execute on function public.rpg_conta_uso(uuid) to service_role;

-- ===== Mundo compartilhado e biblioteca de campanhas offline =====
-- Um mundo por campanha do catálogo (ex.: "e5:0"), lido e expandido por todos os jogadores logados.
create sequence if not exists public.rpg_mundo_v;
create table if not exists public.rpg_mundo_ents (
  mundo text not null check (char_length(mundo) between 1 and 80),
  id    text not null check (char_length(id) between 1 and 80),
  tipo  text not null default '',
  dados jsonb not null check (pg_column_size(dados) < 24000),
  ts    bigint not null default 0,
  v     bigint not null default 0,
  autor uuid default auth.uid(),
  primary key (mundo, id)
);
create index if not exists rpg_mundo_ents_v on public.rpg_mundo_ents (mundo, v);
alter table public.rpg_mundo_ents enable row level security;
create or replace function public.rpg_mundo_ents_tg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.ts < old.ts then return null; end if;   -- o mais novo vence
  new.v := nextval('public.rpg_mundo_v');
  new.autor := coalesce(old.autor, auth.uid());
  return new;
end $$;
revoke execute on function public.rpg_mundo_ents_tg() from public, anon, authenticated;
drop trigger if exists rpg_mundo_ents_tg on public.rpg_mundo_ents;
create trigger rpg_mundo_ents_tg before insert or update on public.rpg_mundo_ents for each row execute function public.rpg_mundo_ents_tg();
drop policy if exists "rpg_mundo: logado le" on public.rpg_mundo_ents;
create policy "rpg_mundo: logado le" on public.rpg_mundo_ents for select to authenticated using (true);
drop policy if exists "rpg_mundo: logado cria" on public.rpg_mundo_ents;
create policy "rpg_mundo: logado cria" on public.rpg_mundo_ents for insert to authenticated with check (true);
drop policy if exists "rpg_mundo: logado atualiza" on public.rpg_mundo_ents;
create policy "rpg_mundo: logado atualiza" on public.rpg_mundo_ents for update to authenticated using (true) with check (true);
grant select, insert, update on public.rpg_mundo_ents to authenticated;

-- Campanhas offline (jogar sem IA): qualquer um lê; só quem enviou altera ou apaga.
create table if not exists public.rpg_campanhas_off (
  id     text primary key check (char_length(id) between 1 and 80),
  titulo text not null default '',
  dados  jsonb not null check (pg_column_size(dados) < 4000000),
  autor  uuid not null default auth.uid(),
  criado timestamptz not null default now(),
  atualizado timestamptz not null default now()
);
alter table public.rpg_campanhas_off enable row level security;
drop policy if exists "rpg_off: todos leem" on public.rpg_campanhas_off;
create policy "rpg_off: todos leem" on public.rpg_campanhas_off for select to anon, authenticated using (true);
drop policy if exists "rpg_off: dono cria" on public.rpg_campanhas_off;
create policy "rpg_off: dono cria" on public.rpg_campanhas_off for insert to authenticated with check (autor = auth.uid());
drop policy if exists "rpg_off: dono atualiza" on public.rpg_campanhas_off;
create policy "rpg_off: dono atualiza" on public.rpg_campanhas_off for update to authenticated using (autor = auth.uid()) with check (autor = auth.uid());
drop policy if exists "rpg_off: dono apaga" on public.rpg_campanhas_off;
create policy "rpg_off: dono apaga" on public.rpg_campanhas_off for delete to authenticated using (autor = auth.uid());
grant select on public.rpg_campanhas_off to anon;
grant select, insert, update, delete on public.rpg_campanhas_off to authenticated;
