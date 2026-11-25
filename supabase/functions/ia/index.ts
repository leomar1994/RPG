// Função "ia" (Supabase Edge Function): repassa o pedido do jogo para a IA usando as chaves do DONO e o BANCO DE CHAVES.
// As chaves ficam no servidor (segredos *_KEY, tabela rpg_chaves_dono e tabela rpg_banco_chaves) e nunca vão para o navegador.
// Só o DONO usa as chaves do servidor (no solo dele e nas mesas em que ele é o Mestre/anfitrião: os pedidos saem do navegador dele).
//   GET  ?info=1               -> { provedores: { groq: [modelos], ... }, limite, dono }   (provedores só para o dono)
//   POST ?p=groq               -> corpo no formato OpenAI (chat/completions); devolve a resposta do provedor
//   POST ?salvar_chaves=1      -> só o dono: { chaves: { gemini_key: "...", ... } }
//   GET  ?banco=1              -> o que o jogador emprestou ao banco: { provs: [...], aceitou }
//   POST ?banco=emprestar      -> { chaves: { groq_key: "..." }, aceito: true }  (aceitar os termos é obrigatório)
//   POST ?banco=retirar        -> retira todas as chaves do jogador do banco
//   POST ?excluir_conta=1      -> apaga saves, uso e chaves do RPG; apaga o login se a conta não tiver dados no Técnico
import { createClient } from "jsr:@supabase/supabase-js@2";

const PROV: Record<string, { url: string; env: string; ls: string; modelos: string[] }> = {
  gemini:     { url: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", env: "GEMINI_KEY", ls: "gemini_key", modelos: ["gemini-2.5-flash", "gemini-2.5-flash-lite"] },
  groq:       { url: "https://api.groq.com/openai/v1/chat/completions", env: "GROQ_KEY", ls: "groq_key", modelos: ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "qwen/qwen3-32b"] },
  cerebras:   { url: "https://api.cerebras.ai/v1/chat/completions", env: "CEREBRAS_KEY", ls: "cerebras_key", modelos: ["gpt-oss-120b", "llama-3.3-70b"] },
  mistral:    { url: "https://api.mistral.ai/v1/chat/completions", env: "MISTRAL_KEY", ls: "mistral_key", modelos: ["mistral-medium-latest", "mistral-small-latest"] },
  sambanova:  { url: "https://api.sambanova.ai/v1/chat/completions", env: "SAMBANOVA_KEY", ls: "sambanova_key", modelos: ["Meta-Llama-3.3-70B-Instruct", "gpt-oss-120b"] },
  openrouter: { url: "https://openrouter.ai/api/v1/chat/completions", env: "OPENROUTER_KEY", ls: "openrouter_key", modelos: ["openrouter/free"] },
};
const DONO = (Deno.env.get("DONO_EMAIL") || "leomarbaseggio@gmail.com").toLowerCase();
const LIMITE_DIA = Number(Deno.env.get("LIMITE_DIA") || "400");   // pedidos por dia
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-title", "Access-Control-Expose-Headers": "retry-after", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// chaves por provedor: as do dono primeiro, depois as do banco (em rodízio)
let cache: { t: number; k: Record<string, string[]> } = { t: 0, k: {} };
let giro = 0;
async function chaves(forcar = false): Promise<Record<string, string[]>> {
  if (!forcar && Date.now() - cache.t < 60000) return cache.k;
  const k: Record<string, string[]> = {};
  const add = (p: string, v: string) => { if (v && PROV[p]) (k[p] ||= []).includes(v) || k[p].push(v); };
  for (const [p, pv] of Object.entries(PROV)) { const e = Deno.env.get(pv.env); if (e) add(p, e); }
  try { const { data } = await admin.from("rpg_chaves_dono").select("prov, chave"); for (const r of data || []) add(r.prov, r.chave); } catch { /* sem tabela */ }
  try { const { data } = await admin.from("rpg_banco_chaves").select("prov, chave"); for (const r of data || []) add(r.prov, r.chave); } catch { /* sem tabela */ }
  cache = { t: Date.now(), k }; return k;
}
const lerCorpo = async (req: Request) => { try { return await req.json(); } catch { return null; } };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await admin.auth.getUser(token);
  const uid = u?.user?.id || "";
  const ehDono = !!u?.user?.email && u.user.email.toLowerCase() === DONO;

  if (url.searchParams.get("info")) {
    const k = await chaves();
    return json({ provedores: ehDono ? Object.fromEntries(Object.entries(PROV).filter(([p]) => k[p]?.length).map(([p, pv]) => [p, pv.modelos])) : {}, limite: LIMITE_DIA, dono: ehDono });
  }
  if (!uid) return json({ error: { code: 401, message: "Entre com a sua conta para usar a IA do jogo." } }, 401);

  // ---------- banco de chaves (qualquer jogador logado) ----------
  const banco = url.searchParams.get("banco");
  if (banco) {
    if (banco === "1" || req.method === "GET") {
      const { data } = await admin.from("rpg_banco_chaves").select("prov, aceitou_termos").eq("user_id", uid);
      return json({ provs: (data || []).map(r => r.prov), aceitou: data?.[0]?.aceitou_termos || null });
    }
    if (banco === "retirar") { await admin.from("rpg_banco_chaves").delete().eq("user_id", uid); await chaves(true); return json({ ok: true, provs: [] }); }
    if (banco === "emprestar") {
      const corpo = await lerCorpo(req);
      if (corpo?.aceito !== true) return json({ error: { code: 400, message: "Para emprestar, aceite os termos de uso." } }, 400);
      const linhas = Object.entries(PROV).map(([p, pv]) => ({ p, v: String(corpo?.chaves?.[pv.ls] || "").trim() })).filter(x => x.v);
      if (!linhas.length) return json({ error: { code: 400, message: "Nenhuma chave para emprestar." } }, 400);
      const agora = new Date().toISOString();
      await admin.from("rpg_banco_chaves").upsert(linhas.map(x => ({ user_id: uid, prov: x.p, chave: x.v.slice(0, 400), aceitou_termos: agora })));
      await chaves(true);
      return json({ ok: true, provs: linhas.map(x => x.p) });
    }
    return json({ error: { code: 400, message: "Pedido inválido." } }, 400);
  }

  // ---------- excluir a conta do jogo ----------
  if (url.searchParams.get("excluir_conta")) {
    for (const t of ["rpg_banco_chaves", "rpg_saves", "rpg_uso_ia"]) await admin.from(t).delete().eq("user_id", uid);
    if (ehDono) await admin.from("rpg_chaves_dono").delete().neq("prov", "");
    let temFutebol = false;
    for (const t of ["liga_tecnicos", "liga_taticas"]) { const { count } = await admin.from(t).select("user_id", { count: "exact", head: true }).eq("user_id", uid); if ((count || 0) > 0) temFutebol = true; }
    let loginApagado = false;
    if (!temFutebol) { const { error } = await admin.auth.admin.deleteUser(uid); loginApagado = !error; }
    await chaves(true);
    return json({ ok: true, loginApagado, temFutebol });
  }

  if (url.searchParams.get("salvar_chaves")) {                         // o dono cola as chaves no jogo e elas viram a IA do jogo
    if (!ehDono) return json({ error: { code: 403, message: "Só o dono do jogo pode definir as chaves do servidor." } }, 403);
    const corpo = await lerCorpo(req); if (!corpo) return json({ error: { code: 400, message: "Pedido inválido." } }, 400);
    const salvos: string[] = [];
    for (const [p, pv] of Object.entries(PROV)) {
      const v = String(corpo.chaves?.[pv.ls] || "").trim();
      if (v) { await admin.from("rpg_chaves_dono").upsert({ prov: p, chave: v.slice(0, 400), atualizado: new Date().toISOString() }); salvos.push(p); }
    }
    await chaves(true);
    return json({ ok: true, salvos, apagados: [] });
  }

  // ---------- pedido de IA: só o dono ----------
  if (!ehDono) return json({ error: { code: 403, message: "A IA do jogo é só do dono e das mesas dele. Use a sua própria chave de IA." } }, 403);
  const p = url.searchParams.get("p") || "", pv = PROV[p], lista = pv ? (await chaves())[p] || [] : [];
  if (!pv || !lista.length) return json({ error: { code: 404, message: `Provedor ${p} indisponível no servidor.` } }, 404);

  const { data: n } = await admin.rpc("rpg_conta_uso", { uid });
  if (Number(n) > LIMITE_DIA) return json({ error: { code: 429, message: `Limite diário da IA do jogo atingido (${LIMITE_DIA} pedidos).` } }, 429);

  const corpo = await lerCorpo(req); if (!corpo) return json({ error: { code: 400, message: "Pedido inválido." } }, 400);
  if (!pv.modelos.includes(String(corpo.model))) corpo.model = pv.modelos[0];        // só os modelos liberados
  corpo.max_tokens = Math.min(Number(corpo.max_tokens) || 1300, 1800);
  delete corpo.stream;

  // a 1ª chave do dono sempre primeiro; as do banco em rodízio; chave sem cota ou recusada: tenta a próxima (até 4)
  const ordem = [lista[0], ...lista.slice(1).map((_, i, a) => a[(i + giro) % a.length])].slice(0, 4); giro++;
  let r: Response | null = null;
  for (const chave of ordem) {
    const cab: Record<string, string> = { "Content-Type": "application/json", Authorization: "Bearer " + chave };
    if (p === "openrouter") cab["X-Title"] = "RPG Mestre IA";
    r = await fetch(pv.url, { method: "POST", headers: cab, body: JSON.stringify(corpo) });
    if (![401, 402, 403, 429].includes(r.status)) break;
  }
  return new Response(await r!.text(), { status: r!.status, headers: { ...CORS, "Content-Type": "application/json", ...(r!.headers.get("retry-after") ? { "retry-after": r!.headers.get("retry-after")! } : {}) } });
});
