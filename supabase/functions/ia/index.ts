// Função "ia" (Supabase Edge Function): repassa o pedido do jogo para a IA usando as chaves do DONO,
// guardadas como segredos do servidor. As chaves nunca vão para o navegador.
// Só jogador logado (o Supabase confere o token) e com limite de pedidos por dia.
//   GET  ?info=1        -> { provedores: { groq: [modelos], ... }, limite }
//   POST ?p=groq        -> corpo no formato OpenAI (chat/completions); devolve a resposta do provedor
import { createClient } from "jsr:@supabase/supabase-js@2";

const PROV: Record<string, { url: string; env: string; modelos: string[] }> = {
  gemini:     { url: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", env: "GEMINI_KEY", modelos: ["gemini-2.5-flash", "gemini-2.5-flash-lite"] },
  groq:       { url: "https://api.groq.com/openai/v1/chat/completions", env: "GROQ_KEY", modelos: ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "qwen/qwen3-32b"] },
  cerebras:   { url: "https://api.cerebras.ai/v1/chat/completions", env: "CEREBRAS_KEY", modelos: ["gpt-oss-120b", "llama-3.3-70b"] },
  mistral:    { url: "https://api.mistral.ai/v1/chat/completions", env: "MISTRAL_KEY", modelos: ["mistral-medium-latest", "mistral-small-latest"] },
  sambanova:  { url: "https://api.sambanova.ai/v1/chat/completions", env: "SAMBANOVA_KEY", modelos: ["Meta-Llama-3.3-70B-Instruct", "gpt-oss-120b"] },
  openrouter: { url: "https://openrouter.ai/api/v1/chat/completions", env: "OPENROUTER_KEY", modelos: ["openrouter/free"] },
};
const LIMITE_DIA = Number(Deno.env.get("LIMITE_DIA") || "400");   // pedidos por jogador por dia
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-title", "Access-Control-Expose-Headers": "retry-after", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const disponiveis = Object.fromEntries(Object.entries(PROV).filter(([, p]) => Deno.env.get(p.env)).map(([k, p]) => [k, p.modelos]));
  if (url.searchParams.get("info")) return json({ provedores: disponiveis, limite: LIMITE_DIA });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await admin.auth.getUser(token);
  if (!u?.user) return json({ error: { code: 401, message: "Entre com a sua conta para usar a IA do jogo." } }, 401);

  const p = url.searchParams.get("p") || "", pv = PROV[p], chave = pv && Deno.env.get(pv.env);
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
