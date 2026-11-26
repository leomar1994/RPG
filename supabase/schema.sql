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

-- ===== Mundo compartilhado: o jogador NÃO edita, só a história grava (funções que apenas acrescentam) =====
drop policy if exists "rpg_mundo: logado cria" on public.rpg_mundo_ents;
drop policy if exists "rpg_mundo: logado atualiza" on public.rpg_mundo_ents;
revoke insert, update, delete on public.rpg_mundo_ents from authenticated, anon;

create or replace function public.rpg_mundo_gravar(p_mundo text, p_ents jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare
  e jsonb; t text; i text; old public.rpg_mundo_ents; novo jsonb; n integer := 0; tms bigint; k text;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if p_mundo is null or char_length(p_mundo) not between 1 and 80 then raise exception 'mundo'; end if;
  if jsonb_typeof(p_ents) <> 'array' or jsonb_array_length(p_ents) > 60 then raise exception 'lote'; end if;
  for e in select * from jsonb_array_elements(p_ents) loop
    t := e->>'tipo'; i := e->>'id';
    if t is null or t not in ('local','npc','fato','caminho','morto','meta') then continue; end if;
    if i is null or char_length(i) not between 1 and 80 then continue; end if;
    if pg_column_size(e) > 20000 then continue; end if;
    tms := case when (e->>'ts') ~ '^[0-9]{1,15}$' then (e->>'ts')::bigint else 0 end;
    select * into old from public.rpg_mundo_ents where mundo = p_mundo and id = i for update;
    if not found then
      insert into public.rpg_mundo_ents (mundo, id, tipo, dados, ts) values (p_mundo, i, t, e, tms);
      n := n + 1; continue;
    end if;
    if old.tipo <> t then continue; end if;
    novo := old.dados;
    if t = 'local' then
      novo := novo || jsonb_build_object(
        'saidas', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from (select jsonb_array_elements_text(coalesce(old.dados->'saidas','[]'::jsonb)) x union select jsonb_array_elements_text(coalesce(e->'saidas','[]'::jsonb))) q),
        'visitas', greatest(coalesce((old.dados->>'visitas')::int, 0), case when (e->>'visitas') ~ '^[0-9]{1,6}$' then (e->>'visitas')::int else 0 end));
      if old.dados->>'estado' = 'citado' and e->>'estado' = 'conhecido' then novo := novo || jsonb_build_object('estado', 'conhecido'); end if;
      foreach k in array array['desc','perigos','mapa','categoria','pois'] loop
        if not (novo ? k) and (e ? k) then novo := novo || jsonb_build_object(k, e->k); end if;
      end loop;
    elsif t = 'npc' then
      novo := novo || jsonb_build_object(
        'conversas', greatest(coalesce((old.dados->>'conversas')::int, 0), case when (e->>'conversas') ~ '^[0-9]{1,6}$' then (e->>'conversas')::int else 0 end),
        'falas', (select coalesce(jsonb_agg(f order by tt), '[]'::jsonb) from (select f, case when (f->>'t') ~ '^[0-9]{1,15}$' then (f->>'t')::bigint else 0 end tt from (select jsonb_array_elements(coalesce(old.dados->'falas','[]'::jsonb)) f union select jsonb_array_elements(coalesce(e->'falas','[]'::jsonb))) u order by 2 desc limit 30) z));
      foreach k in array array['atitude','objetivo'] loop
        if e ? k then novo := novo || jsonb_build_object(k, e->k); end if;
      end loop;
      foreach k in array array['papel','aparencia','persona','localId','lugarTxt'] loop
        if not (novo ? k) and (e ? k) then novo := novo || jsonb_build_object(k, e->k); end if;
      end loop;
    elsif t = 'meta' then
      if not (novo ? 'nome') and (e ? 'nome') then novo := novo || jsonb_build_object('nome', e->'nome'); end if;
    elsif t = 'morto' then
      novo := novo || jsonb_build_object(
        'vasculhado', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from (select jsonb_array_elements_text(coalesce(old.dados->'vasculhado','[]'::jsonb)) x union select jsonb_array_elements_text(coalesce(e->'vasculhado','[]'::jsonb))) q),
        'liberado', coalesce(e->'liberado', old.dados->'liberado', '[]'::jsonb));
      if e ? 'pertences' then
        novo := novo || jsonb_build_object('pertences', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(old.dados->'pertences','[]'::jsonb)) p where exists (select 1 from jsonb_array_elements(coalesce(e->'pertences','[]'::jsonb)) q where q->>'n' = p->>'n')));
      end if;
      if e ? 'nota' then novo := novo || jsonb_build_object('nota', e->'nota'); end if;
      if not coalesce((old.dados->>'fim')::boolean, false) and e->>'estado' in ('cadaver','meio-vivo','morto-vivo','zumbi','esqueleto','fantasma') then
        novo := novo || jsonb_build_object('estado', e->>'estado');
      end if;
    else
      continue;
    end if;
    update public.rpg_mundo_ents set dados = novo, ts = greatest(old.ts, tms) where mundo = p_mundo and id = i;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.rpg_mundo_gravar(text, jsonb) from public, anon;
grant execute on function public.rpg_mundo_gravar(text, jsonb) to authenticated;

-- Descoberta de corpo: a 4ª conta diferente encontra o cadáver em decomposição; depois ele deixa de existir para as outras.
create or replace function public.rpg_mundo_corpo(p_mundo text, p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.rpg_mundo_ents; d jsonb; por jsonb; quem text := auth.uid()::text; n int; nova boolean := false;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  select * into r from public.rpg_mundo_ents where mundo = p_mundo and id = p_id and tipo = 'morto' for update;
  if not found then return jsonb_build_object('existe', false); end if;
  d := r.dados; por := coalesce(d->'descobertoPor', '[]'::jsonb);
  if coalesce((d->>'fim')::boolean, false) and not jsonb_exists(por, quem) then return jsonb_build_object('existe', false); end if;
  if not jsonb_exists(por, quem) then
    por := por || to_jsonb(quem); nova := true;
    if jsonb_array_length(por) >= 4 then d := d || jsonb_build_object('estado', 'decomposicao', 'fim', true); end if;
  end if;
  n := jsonb_array_length(por);
  d := d || jsonb_build_object('descobertoPor', por, 'vezes', n);
  if nova then update public.rpg_mundo_ents set dados = d, ts = greatest(ts, (extract(epoch from clock_timestamp()) * 1000)::bigint) where mundo = p_mundo and id = p_id; end if;
  return jsonb_build_object('existe', true, 'nova', nova, 'vezes', n, 'estado', d->>'estado', 'dados', d);
end $$;
revoke execute on function public.rpg_mundo_corpo(text, text) from public, anon;
grant execute on function public.rpg_mundo_corpo(text, text) to authenticated;
