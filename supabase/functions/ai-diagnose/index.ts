// Supabase Edge Function: ai-diagnose
// Deploy with: supabase functions deploy ai-diagnose
// Secret:      supabase secrets set GEMINI_API_KEY=your-key
//
// Request body: { "image_base64": "...", "mime_type": "image/jpeg", "description": "..." }
// The API key never leaves this function.

const API_KEY = Deno.env.get("GEMINI_API_KEY");
const MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-3.8-flash";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PROMPT = (description: string) => `You are an assistant for a home-service marketplace. A customer submitted a photo and a description of a problem with an appliance or home system.

Your job is NOT to give a confirmed diagnosis. A photo alone cannot reliably establish the exact cause of a fault.

Customer description: "${description}"

Return ONLY valid JSON matching this shape:
{
  "likely_category": string,
  "summary": string,
  "confidence": "low" | "medium" | "high",
  "follow_up_questions": string[],
  "info_needed": string[],
  "uncertainty_notes": string,
  "safety_notice": string | null
}

Rules:
- Never present suggestions as a confirmed diagnosis.
- Use "low" confidence when the photo is unclear or insufficient.
- Do not recommend dangerous DIY electrical or appliance repairs.
- Keep it short and practical.`;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  if (!API_KEY) return json({ error: "Server is not configured" }, 500);

  let image_base64: string, mime_type: string, description: string;
  try {
    ({ image_base64, mime_type, description } = await req.json());
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  if (!image_base64 || !mime_type) {
    return json({ error: "image_base64 and mime_type are required" }, 400);
  }

  const allowed = ["image/jpeg", "image/png", "image/webp", "image/heic"];
  if (!allowed.includes(mime_type)) {
    return json({ error: "Unsupported image type" }, 400);
  }

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}`;

  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{
          parts: [
            { text: PROMPT(description ?? "") },
            { inline_data: { mime_type, data: image_base64 } },
          ],
        }],
        generationConfig: { responseMimeType: "application/json", temperature: 0.2 },
      }),
      signal: AbortSignal.timeout(30000),
    });
  } catch {
    return json({ error: "AI provider unreachable or timed out" }, 504);
  }

  if (res.status === 429) return json({ error: "AI is busy, please retry shortly" }, 429);
  if (!res.ok) return json({ error: "AI provider error" }, 502);

  const data = await res.json();
  const raw = data?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!raw) return json({ error: "Empty AI response" }, 502);

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return json({ error: "AI returned malformed output" }, 502);
  }

  for (const key of ["likely_category", "summary", "confidence"]) {
    if (parsed[key] === undefined) {
      return json({ error: `AI output missing field: ${key}` }, 502);
    }
  }

  return json(parsed);
});
