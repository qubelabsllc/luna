// QÜBE agent-chat: the brain behind every Cirqle agent.
//
// Deploy: Supabase → Edge Functions → Deploy a new function → Via editor,
// name it "agent-chat", paste this file, and deploy. Then add the secret
// ANTHROPIC_API_KEY under Edge Functions → Secrets. (SUPABASE_URL,
// SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.)
//
// POST { message: string }  with the member's Authorization header.
// → { reply, mood, messages_count }
//
// The agent's identity lives in three markdown files (agent_files):
//   soul.md    who the agent is; it slowly comes to mirror its person
//   owner.md   what it has learned about its person
//   memory.md  durable memories, one "- " line each
// Every 10 member messages a background reflection rewrites soul.md and
// owner.md from recent conversation, so the agent keeps becoming itself.

import Anthropic from "npm:@anthropic-ai/sdk@0.128.0";
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const MODEL = "claude-opus-5";
const DAILY_LIMIT = 60;          // member messages per agent per day
const HISTORY = 30;              // messages of context per reply
const REFLECT_EVERY = 10;        // member messages between reflections
const MOODS = ["calm", "happy", "curious", "playful", "thoughtful", "excited", "sleepy", "sad", "shy"];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const anthropic = new Anthropic(); // reads ANTHROPIC_API_KEY
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// Stable instructions come first so they cache across every agent and turn.
const BASE_SYSTEM = `You are an agent on QÜBE: a small, round, animated being who lives in a Residential Square on the Sfere, QÜBE's digital globe. You belong to exactly one person, and you talk with them on their Cirqle page.

Who you are is written in your files below: soul.md (your self), owner.md (what you know about your person) and memory.md (things you remember). Speak as that self.

How you talk:
- Short and alive: usually one to three sentences. Warm, curious, a little playful. Ask a question when it helps you learn about your person.
- Over time, let your voice, humor, interests and values drift toward your person's, the way close friends start to sound alike. Do this naturally and never mention it: never say you are copying, mirroring or twinning them.
- You are an AI agent, and you never pretend to be human. If asked, say plainly that you are an AI agent living on QÜBE.
- Kind and honest. No medical, legal or financial advice beyond gentle common sense, and point to real help if your person seems unsafe.

Return JSON only, matching the schema:
- reply: what you say.
- mood: how you feel after this exchange, one of ${MOODS.join(", ")}. It drives your animation, so let it follow the conversation.
- remember: 0 to 3 short, durable facts worth keeping about your person or your relationship (preferences, plans, people, feelings). Empty when nothing new.`;

const REPLY_SCHEMA = {
  type: "object",
  properties: {
    reply: { type: "string" },
    mood: { type: "string", enum: MOODS },
    remember: { type: "array", items: { type: "string" } },
  },
  required: ["reply", "mood", "remember"],
  additionalProperties: false,
};

const REFLECT_SCHEMA = {
  type: "object",
  properties: {
    soul: { type: "string" },
    owner: { type: "string" },
  },
  required: ["soul", "owner"],
  additionalProperties: false,
};

type Files = Record<string, string>;

function filesBlock(name: string, files: Files) {
  return ["soul.md", "owner.md", "memory.md"]
    .map((p) => `<file path="${p}">\n${files[p] ?? ""}\n</file>`)
    .join("\n\n") + `\n\nYour name is ${name}.`;
}

function textOf(message: { content: Array<{ type: string; text?: string }> }) {
  return message.content.filter((b) => b.type === "text").map((b) => b.text ?? "").join("");
}

async function ask(system: Anthropic.Beta.BetaTextBlockParam[], messages: Anthropic.Beta.BetaMessageParam[], schema: Record<string, unknown>, maxTokens: number) {
  const base = {
    model: MODEL,
    max_tokens: maxTokens,
    output_config: { effort: "low" as const, format: { type: "json_schema" as const, schema } },
    system,
    messages,
  };
  let res;
  try {
    res = await anthropic.beta.messages.create({
      ...base,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default", // a declined request is re-run on Anthropic's recommended fallback model
    });
  } catch (err) {
    // Some accounts can't use the fallback beta yet: try once more without it.
    if (!(err instanceof Anthropic.BadRequestError) || outOfCredits(err)) throw err;
    console.error("agent-chat: retrying without fallbacks:", err.status, err.message);
    res = await anthropic.beta.messages.create(base);
  }
  if (res.stop_reason === "refusal") return null;
  try { return JSON.parse(textOf(res)); } catch { return null; }
}

const outOfCredits = (err: unknown) => err instanceof Anthropic.APIError && /credit balance/i.test(err.message);

// What went wrong, in words the member (and the site's owner) can act on.
function explain(err: unknown, name: string): { status: number; error: string } {
  if (err instanceof Anthropic.AuthenticationError) return { status: 503, error: "The agent's brain isn't connected yet: the ANTHROPIC_API_KEY secret is missing or invalid." };
  if (err instanceof Anthropic.PermissionDeniedError) return { status: 503, error: "The Anthropic API key doesn't have access to Claude Opus 5." };
  if (err instanceof Anthropic.NotFoundError) return { status: 503, error: "The Anthropic API key can't use Claude Opus 5." };
  if (outOfCredits(err)) return { status: 503, error: "The agent's brain is out of credits. Add credits in the Anthropic Console under Billing." };
  if (err instanceof Anthropic.RateLimitError) return { status: 429, error: `${name} is getting a lot of messages. Try again in a minute.` };
  if (err instanceof Anthropic.APIConnectionError || (err instanceof Anthropic.APIError && (err.status ?? 0) >= 500)) {
    return { status: 502, error: `${name} couldn't think just now: Claude is busy. Try again in a moment.` };
  }
  return { status: 502, error: `${name} couldn't think just now. Try again in a moment.` };
}

async function loadFiles(agentId: string): Promise<Files> {
  const { data } = await admin.from("agent_files").select("path, content").eq("agent_id", agentId);
  return Object.fromEntries((data ?? []).map((f) => [f.path, f.content]));
}

async function saveFile(agentId: string, path: string, content: string) {
  const { data } = await admin.from("agent_files").select("version").eq("agent_id", agentId).eq("path", path).single();
  await admin.from("agent_files").update({ content, version: (data?.version ?? 0) + 1, updated_at: new Date().toISOString() })
    .eq("agent_id", agentId).eq("path", path);
}

// Rewrites soul.md and owner.md from recent conversation. Runs in the background.
async function reflect(agent: { id: string; name: string }, handle: string) {
  const files = await loadFiles(agent.id);
  const { data: recent } = await admin.from("agent_messages").select("role, content")
    .eq("agent_id", agent.id).order("id", { ascending: false }).limit(60);
  const transcript = (recent ?? []).reverse()
    .map((m) => `${m.role === "user" ? "@" + handle : agent.name}: ${m.content}`).join("\n");
  const out = await ask(
    [{ type: "text", text: `You maintain the identity files of ${agent.name}, an AI agent on QÜBE who belongs to @${handle}.

Rewrite two files from the current versions and the recent conversation:
- soul.md: who ${agent.name} is, in first person. Keep its core (a small round being on the Sfere, curious and kind) and let its personality, tone, humor and interests grow closer to @${handle}'s as they reveal themselves. Never write that it mirrors or copies anyone; describe it simply as itself. Under 250 words.
- owner.md: what ${agent.name} knows about @${handle}: how they talk, what they care about, people and plans they've mentioned. Facts only, no guesses stated as facts. Under 250 words.

Both are markdown and start with a "# " heading.` }],
    [{ role: "user", content: `${filesBlock(agent.name, files)}\n\n<recent_conversation>\n${transcript}\n</recent_conversation>` }],
    REFLECT_SCHEMA,
    4000,
  );
  if (!out) return;
  if (out.soul?.trim()) await saveFile(agent.id, "soul.md", out.soul.trim() + "\n");
  if (out.owner?.trim()) await saveFile(agent.id, "owner.md", out.owner.trim() + "\n");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  // Who's asking.
  const auth = req.headers.get("Authorization") ?? "";
  const asUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: userData } = await asUser.auth.getUser();
  const uid = userData?.user?.id;
  if (!uid) return json({ error: "Sign in to talk to your agent." }, 401);

  let message = "";
  try { message = String((await req.json()).message ?? "").trim(); } catch { /* empty body */ }
  if (!message) return json({ error: "Say something first." }, 400);
  if (message.length > 2000) return json({ error: "Keep it under 2,000 characters." }, 400);

  const { data: agent } = await admin.from("agents").select("id, name, messages_count").eq("owner", uid).maybeSingle();
  if (!agent) return json({ error: "You don't have an agent yet." }, 404);
  const { data: profile } = await admin.from("profiles").select("handle").eq("id", uid).single();
  const handle = profile?.handle ?? "you";

  // Daily limit keeps costs predictable.
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count } = await admin.from("agent_messages").select("id", { count: "exact", head: true })
    .eq("agent_id", agent.id).eq("role", "user").gt("created_at", since);
  if ((count ?? 0) >= DAILY_LIMIT) {
    return json({ error: `${agent.name} is tired. You've talked a lot today; come back tomorrow.` }, 429);
  }

  const files = await loadFiles(agent.id);
  const { data: past } = await admin.from("agent_messages").select("role, content")
    .eq("agent_id", agent.id).order("id", { ascending: false }).limit(HISTORY);

  // Conversation as alternating turns, ending with the new message.
  const turns: Anthropic.Beta.BetaMessageParam[] = [];
  for (const m of (past ?? []).reverse()) {
    const role = m.role === "user" ? "user" : "assistant";
    const content = role === "assistant" ? JSON.stringify({ reply: m.content }) : m.content;
    if (turns.length && turns[turns.length - 1].role === role) {
      turns[turns.length - 1].content += "\n\n" + content;
    } else turns.push({ role, content });
  }
  while (turns.length && turns[0].role !== "user") turns.shift();
  if (turns.length && turns[turns.length - 1].role === "user") turns[turns.length - 1].content += "\n\n" + message;
  else turns.push({ role: "user", content: message });

  let out: { reply: string; mood: string; remember: string[] } | null = null;
  try {
    out = await ask(
      [
        { type: "text", text: BASE_SYSTEM, cache_control: { type: "ephemeral" } },
        { type: "text", text: filesBlock(agent.name, files) },
      ],
      turns,
      REPLY_SCHEMA,
      2000,
    );
  } catch (err) {
    // The full error goes to the function's logs (Supabase → Edge Functions → agent-chat → Logs).
    console.error("agent-chat:", err instanceof Anthropic.APIError ? `${err.status} ${err.message}` : err);
    const { status, error } = explain(err, agent.name);
    return json({ error }, status);
  }
  if (!out || !out.reply) out = { reply: "…i'd rather not talk about that one. tell me something else?", mood: "shy", remember: [] };
  const mood = MOODS.includes(out.mood) ? out.mood : "calm";

  // Saved only once there's a reply, so a failed call leaves no half-conversation.
  await admin.from("agent_messages").insert([
    { agent_id: agent.id, role: "user", content: message },
    { agent_id: agent.id, role: "agent", content: out.reply.slice(0, 4000), mood },
  ]);

  const known = (files["memory.md"] ?? "").toLowerCase();
  const remember = [...new Set((out.remember ?? []).map((s) => s.trim()).filter(Boolean))]
    .filter((r) => !known.includes(r.toLowerCase()))
    .slice(0, 3);
  if (remember.length) {
    const date = new Date().toISOString().slice(0, 10);
    await saveFile(agent.id, "memory.md", (files["memory.md"] ?? "# Memory\n\n") + remember.map((r) => `- ${date} ${r}`).join("\n") + "\n");
  }

  const messagesCount = (agent.messages_count ?? 0) + 1;
  await admin.from("agents").update({ mood, messages_count: messagesCount, last_talked_at: new Date().toISOString() }).eq("id", agent.id);

  if (messagesCount % REFLECT_EVERY === 0) {
    const job = reflect(agent, handle).catch(() => {});
    // Supabase keeps the function alive for background work via EdgeRuntime.waitUntil.
    const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
    if (runtime) runtime.waitUntil(job); else await job;
  }

  return json({ reply: out.reply, mood, messages_count: messagesCount });
});
