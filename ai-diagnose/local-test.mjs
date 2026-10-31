import { readFileSync } from "node:fs";
import { extname } from "node:path";

const API_KEY = process.env.GEMINI_API_KEY;
const MODEL = process.env.GEMINI_MODEL ?? "gemini-3.8-flash";

const MIME = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
  ".heic": "image/heic",
};

const PROMPT = (description) => `You are an assistant for a home-service marketplace. A customer submitted a photo and a description of a problem with an appliance or home system.

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

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

async function main() {
  const [imagePath, ...rest] = process.argv.slice(2);
  const userText = rest.join(" ") ||
    "Please look at this photo and help me describe the problem.";

  if (!API_KEY) {
    fail(`Missing GEMINI_API_KEY. Set it first, e.g. in PowerShell:
  $env:GEMINI_API_KEY="your-key"`);
    return;
  }

  if (!imagePath) {
    fail("Usage: node local-test.mjs <path-to-image> [description text]");
    return;
  }

  const mimeType = MIME[extname(imagePath).toLowerCase()];
  if (!mimeType) {
    fail(`Unsupported image type: ${imagePath}`);
    return;
  }

  let imageBase64;
  try {
    imageBase64 = readFileSync(imagePath).toString("base64");
  } catch {
    fail(`Could not read file: ${imagePath}`);
    return;
  }

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}`;

  console.log(`Calling ${MODEL} with ${imagePath} ...\n`);

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      contents: [{
        parts: [
          { text: PROMPT(userText) },
          { inline_data: { mime_type: mimeType, data: imageBase64 } },
        ],
      }],
      generationConfig: { responseMimeType: "application/json", temperature: 0.2 },
    }),
  });

  if (!res.ok) {
    fail(`API error ${res.status}: ${await res.text()}`);
    return;
  }

  const data = await res.json();
  const raw = data?.candidates?.[0]?.content?.parts?.[0]?.text;

  if (!raw) {
    fail(`No text in response: ${JSON.stringify(data, null, 2)}`);
    return;
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail(`Model did not return valid JSON:\n${raw}`);
    return;
  }

  for (const key of ["likely_category", "summary", "confidence"]) {
    if (parsed[key] === undefined) {
      fail(`Response missing required field: ${key}`);
      return;
    }
  }

  console.log(JSON.stringify(parsed, null, 2));
}

await main();
