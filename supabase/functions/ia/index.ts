// Função "ia" (Supabase Edge Function): repassa o pedido do jogo para a IA usando as chaves do DONO.
// As chaves ficam no servidor (segredos *_KEY ou a tabela rpg_chaves_dono) e nunca vão para o navegador.
// Só jogador logado (o Supabase confere o token) e com limite de pedidos por dia.
//   GET  ?info=1          -> { provedores: { groq: [modelos], ... }, limite, dono }
//   POST ?p=groq          -> corpo no formato OpenAI (chat/completions); devolve a resposta do provedor
//   POST ?salvar_chaves=1 -> só o dono: { chaves: { gemini_key: "...", groq_key: "" (apaga), ... } }
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
const LIMITE_DIA = Number(Deno.env.get("LIMITE_DIA") || "400");   // pedidos por jogador por dia
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-title", "Access-Control-Expose-Headers": "retry-after", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

let cache: { t: number; k: Record<string, string> } = { t: 0, k: {} };
async function chaves(forcar = false): Promise<Record<string, string>> {
  if (!forcar && Date.now() - cache.t < 60000) return cache.k;
  const k: Record<string, string> = {};
  try { const { data } = await admin.from("rpg_chaves_dono").select("prov, chave"); for (const r of data || []) if (r.chave) k[r.prov] = r.chave; } catch { /* tabela indisponível: só os segredos */ }
  for (const [p, pv] of Object.entries(PROV)) { const e = Deno.env.get(pv.env); if (e) k[p] = e; }      // segredo do servidor tem prioridade
  cache = { t: Date.now(), k }; return k;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await admin.auth.getUser(token);
  const ehDono = !!u?.user?.email && u.user.email.toLowerCase() === DONO;

  if (url.searchParams.get("info")) {
    const k = await chaves();
    return json({ provedores: Object.fromEntries(Object.entries(PROV).filter(([p]) => k[p]).map(([p, pv]) => [p, pv.modelos])), limite: LIMITE_DIA, dono: ehDono });
  }
  if (!u?.user) return json({ error: { code: 401, message: "Entre com a sua conta para usar a IA do jogo." } }, 401);

  if (url.searchParams.get("salvar_chaves")) {                         // o dono cola as chaves no jogo e elas viram a IA do jogo
    if (!ehDono) return json({ error: { code: 403, message: "Só o dono do jogo pode definir as chaves do servidor." } }, 403);
    let corpo: { chaves?: Record<string, string> } = {};
    try { corpo = await req.json(); } catch { return json({ error: { code: 400, message: "Pedido inválido." } }, 400); }
    const salvos: string[] = [], apagados: string[] = [];
    for (const [p, pv] of Object.entries(PROV)) {
      if (!corpo.chaves || !(pv.ls in corpo.chaves)) continue;
      const v = String(corpo.chaves[pv.ls] || "").trim();
      if (v) { await admin.from("rpg_chaves_dono").upsert({ prov: p, chave: v.slice(0, 400), atualizado: new Date().toISOString() }); salvos.push(p); }
      else { await admin.from("rpg_chaves_dono").delete().eq("prov", p); apagados.push(p); }
    }
    await chaves(true);
    return json({ ok: true, salvos, apagados });
  }

  const p = url.searchParams.get("p") || "", pv = PROV[p], chave = pv && (await chaves())[p];
  if (!pv || !chave) return json({ error: { code: 404, message: `Provedor ${p} indisponível no servidor.` } }, 404);

  const { data: n } = await admin.rpc("rpg_conta_uso", { uid: u.user.id });
  if (Number(n) > LIMITE_DIA) return json({ error: { code: 429, message: `Limite diário da IA do jogo atingido (${LIMITE_DIA} pedidos). Use a sua própria chave ou volte amanhã.` } }, 429);

  let corpo: Record<string, unknown>;
  try { corpo = await req.json(); } catch { return json({ error: { code: 400, message: "Pedido inválido." } }, 400); }
  if (!pv.modelos.includes(String(corpo.model))) corpo.model = pv.modelos[0];        // só os modelos liberados pelo dono
  corpo.max_tokens = Math.min(Number(corpo.max_tokens) || 1300, 1800);
  delete corpo.stream;

  const cab: Record<string, string> = { "Content-Type": "application/json", Authorization: "Bearer " + chave };
  if (p === "openrouter") cab["X-Title"] = "RPG Mestre IA";
  const r = await fetch(pv.url, { method: "POST", headers: cab, body: JSON.stringify(corpo) });
  return new Response(await r.text(), { status: r.status, headers: { ...CORS, "Content-Type": "application/json", ...(r.headers.get("retry-after") ? { "retry-after": r.headers.get("retry-after")! } : {}) } });
});
