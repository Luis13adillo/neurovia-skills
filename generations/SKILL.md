---
name: generations
description: Media generation system - images and videos via AI model APIs, plus dashboard Generations tab management (styles, models panel, gallery). Covers generating media, adding new models, managing visual styles, and onboarding models from aggregator docs.
---

# Generations

Generate images and videos via AI model APIs. Manage the dashboard Generations tab (styles, models panel, gallery).

## Rules (read before every generation)

**1. Quote video cost and WAIT.** Video is the expensive lane. Before any paid video run,
state the model, duration, resolution, and expected dollars, then stop and wait for Luis's
explicit go. Quoting is not approval. **One approval covers exactly one run** — a retry,
a variation, or a second attempt each need a fresh go.

Current video pricing to quote from:

| Model | Rough cost | Note |
|-------|-----------|------|
| Kling 3.0 std (720p) | ~$0.20/sec → **~$2.00 for 10s** | default video model |
| Kling 3.0 pro (1080p) | ~$0.35/sec → **~$3.50 for 10s** | only when Luis asks for 1080p |

Images are cheap enough to run without asking (~$0.01–$0.15). No gate on images.

**2. Draft cheap, finish pretty.** Iterate on `gpt-image-1-mini` (~8.5s, cheap). Only rerun
the same prompt on `gpt-image-2` once Luis picks a favourite. Do not burn the quality model
on throwaway drafts.

**3. Real reference images, never described.** Never describe a logo, a face, or a brand mark
in words — it comes back wrong every time. Pass the real file from `generations/refs/`. If the
ref is missing, STOP and ask Luis for it. Do not improvise a description.

**4. One flat folder.** Every output lands directly in `generations/`. No subfolders. The only
exceptions are the two that already exist: `refs/` and `styles/`.

**5. Write a sidecar log after every save.** Same basename as the media file, `.json`
extension, sitting right next to it. This is how Luis recovers "what prompt made this" weeks
later. Format:

```json
{
  "model": "gpt-image-2",
  "provider": "OpenAI direct",
  "prompt": "the full text prompt exactly as sent to the API",
  "refs": ["refs/claude_app_icon.jpg"],
  "params": { "size": "1920x1088", "quality": "high", "format": "png" },
  "cost_estimate": "$0.07",
  "created": "2026-08-09T19:30:00Z"
}
```

For video, also record `duration_sec` and the approval: `"approved_by_luis": true`.

**6. One at a time.** Run multiple generations sequentially, not in parallel — it avoids rate
limits and keeps Kie's async polling readable.

**7. Never hide a provider swap.** If the primary route fails and you fall back, say which
route ran and why.

## Install location (Luis's setup)

This skill is installed globally, so the paths below are ABSOLUTE. Every relative path
mentioned later in this file (`generations/`, `.env`, `data/*.json`) resolves against
the install root.

| What | Absolute path |
|------|---------------|
| Install root | `/Users/luismiguel/Desktop/rubric/templates/generations/` |
| API keys | `/Users/luismiguel/Desktop/rubric/templates/generations/.env` |
| Generated media | `/Users/luismiguel/Desktop/rubric/templates/generations/generations/` |
| Reference images | `/Users/luismiguel/Desktop/rubric/templates/generations/generations/refs/` |
| Style previews | `/Users/luismiguel/Desktop/rubric/templates/generations/generations/styles/` |
| Styles config | `/Users/luismiguel/Desktop/rubric/templates/generations/data/generation-styles.json` |
| Models config | `/Users/luismiguel/Desktop/rubric/templates/generations/data/generation-models.json` |

**MERGED INTO THE CONSOLE (2026-08-06).** Generations is now a real tab at
**http://localhost:5050** — the same server as the rest of the RUBRIC console.
There is no separate address any more. Start it the normal way:
`node /Users/luismiguel/Desktop/rubric/templates/scaffold/server.js`

The merge added, in `scaffold/`:
- `generations` in `TEMPLATE_CHECKS` + `TAB_ORDER` (server.js)
- a `GENERATIONS` helper block and a `GENERATIONS ROUTES` block (server.js)
- `TAB_LABELS`/`TAB_ICONS` entries, `.gen-*` CSS, the `#tab-generations` panel,
  and `generationsInit()` behind `window.__onTabShow['generations']` (index.html)

Pre-merge copies are at `scaffold/.backup-before-generations-merge/`.

The standalone server at `generations/server.js` still exists and still works
(`npm start` → port 5051) but is redundant. Do not run both.

Save media for a client project into the media folder above (not into the client repo),
then reference it by path. Media is served at `http://localhost:5051/generations/<filename>`.

## Verified status (tested 2026-08-05, fal.ai added and tested 2026-08-09)

| Provider | Key valid? | Generation works? |
|----------|-----------|-------------------|
| **fal.ai** | YES | **YES — verified 2026-08-09.** `nano-banana-2-lite` returned a real image in **3.3s**, sync. Cheapest route. |
| **OpenAI (direct)** | YES | **YES — verified.** `gpt-image-2` ~13s, `gpt-image-1-mini` ~8.5s. |
| Kie AI | YES | **YES — verified end to end.** Credit balance was 1377. Slow (~90s, async). |
| Google AI Studio | YES (lists 50 models) | **NO — free tier quota is `limit: 0` for ALL image models.** Billing being enabled, retest pending. |

### Which model to use

**Draft images → `google/nano-banana-2-lite` via fal.ai** (`models/nano-banana-2-lite.md`).
~$0.034, 3.3 seconds, synchronous. This is the default for all iteration.

**Final images → `gpt-image-2` via OpenAI direct** (`models/gpt-image-2.md`). Synchronous,
and it takes arbitrary sizes — real `1920x1088` 16:9 and `1088x1920` vertical, which no
other image model here can do. It also does transparent backgrounds, which matters for
logos and overlays. Use it once Luis picks a draft he likes.
`fal-ai/nano-banana-2` at 2K/4K is the alternative finisher.

**Video → Kling 3.0 via Kie** (`models/kling-3.0.md`). Still the only video model with a
verified end-to-end run. **Quote the cost and wait** (see Rules).

**Animating reference stills → Seedance 2.0 Fast via fal**
(`models/seedance-2.0-fast.md`). Reachable and authenticated, but no paid run yet.

**Nano Banana 2 is NO LONGER BLOCKED.** fal.ai hosts it, so the Google quota problem
stops mattering for images. Only Veo 3.1 still depends on Google billing.

### fal.ai model ids (verified to exist 2026-08-09)

Checked by POSTing an empty body — 422 means the id is real and auth works, 404 means
wrong id. This costs nothing and is the right way to confirm an id before paying.

| Id | What |
|----|------|
| `google/nano-banana-2-lite` | cheap draft image — **tested, works** |
| `fal-ai/nano-banana-2` · `/edit` | quality image, 0.5K–4K |
| `fal-ai/nano-banana-pro` · `/edit` | top-tier image |
| `openai/gpt-image-2` · `/edit` | GPT Image 2 via fal (OpenAI direct is usually better) |
| `bytedance/seedance-2.0/fast/reference-to-video` | animate reference stills |
| `fal-ai/kling-video/v2/master/text-to-video` | Kling via fal, fallback for Kie |

Watch the prefixes — `bytedance/...` and `google/...` and `openai/...` have **no**
`fal-ai/` in front. Adding it returns 404.

**Google is blocked, and it is not a key problem.** The `GOOGLE_AI_STUDIO_KEY` in `.env` is
valid and lists 50 models fine. But every image model (gemini-3.1-flash-image,
gemini-2.5-flash-image, nano-banana-pro-preview) returns HTTP 429 `RESOURCE_EXHAUSTED`
with `generate_content_free_tier_requests, limit: 0`. Image generation on this API requires
**billing enabled** on the Google Cloud project.

**STATUS 2026-08-09 — Luis said he is enabling billing.** Not yet retested. Next time a
Google model comes up: run ONE test call against `gemini-3.1-flash-image`. If it returns an
image, update the table above and drop the BLOCKED flags. If it still 429s, billing has not
propagated yet — fall back to OpenAI and tell Luis, do not retry in a loop.

Until that retest passes, route image work to OpenAI direct.

**Kie quirks, both observed:**
- `data.state` returns **`generating`**, not the `waiting` this skill's model files claim.
  Poll until state is literally `success` or `fail`; treat anything else as in-progress.
- Kie returns transient `fail` + `"Internal Error, Please try again later."` The very
  first test failed this way and an identical retry succeeded. **Always retry once** before
  reporting a Kie failure to the user.
- Typical GPT Image 1.5 time to `success`: ~90 seconds. Poll every 5-6s, allow 3+ minutes.
- Credit balance: `GET https://api.kie.ai/api/v1/chat/credit` with `Authorization: Bearer $KIE_API_KEY`
  → `{"code":200,"data":<credits>}`. (`/common/credit` and `/user/credit` are 404s.)

## Structure

```
skill/
├── SKILL.md              ← this file (process + dashboard management)
└── models/               ← one file per model (API recipes)
    ├── gpt-image-2.md     ← GPT Image 2, OpenAI direct — DEFAULT IMAGE MODEL
    ├── nano-banana-2.md   ← NB2 (BLOCKED - Google quota)
    ├── nano-banana-pro.md ← NB Pro (BLOCKED - Google quota)
    ├── gpt-image-1.5.md   ← GPT Image 1.5 (async image via Kie, slow fallback)
    ├── kling-3.0.md       ← Kling 3.0 (default video model)
    └── veo-3.1.md         ← Veo 3.1 (Google video)
```

When generating media, read the relevant model file for the API recipe.

---

## Quick Reference

Ordered by what actually works on this setup.

| Task | Model | Model File | Status |
|------|-------|------------|--------|
| **Image — draft / iterate (default)** | **Nano Banana 2 Lite** (fal) | `models/nano-banana-2-lite.md` | **WORKS** 3.3s, ~$0.034 |
| **Image — final / hero** | **GPT Image 2** (OpenAI) | `models/gpt-image-2.md` | **WORKS** ~13s |
| Image — quality alt, 2K/4K | Nano Banana 2 (fal) | `models/nano-banana-2.md` | **WORKS** via fal |
| Image — cheap bulk | GPT Image 1 Mini | `models/gpt-image-2.md` (siblings) | **WORKS** ~8.5s |
| **Video generation** | **Kling 3.0** (Kie) | `models/kling-3.0.md` | **WORKS** async — quote first |
| Video — animate stills | Seedance 2.0 Fast (fal) | `models/seedance-2.0-fast.md` | reachable, no paid run yet |
| Image — slow fallback | GPT Image 1.5 via Kie | `models/gpt-image-1.5.md` | works, ~90s |
| Image | Nano Banana Pro | `models/nano-banana-pro.md` | reachable via fal (`fal-ai/nano-banana-pro`) |
| Video | Veo 3.1 | `models/veo-3.1.md` | BLOCKED — Google billing |

## API Keys

Store keys in `.env` at the install root. Never commit them.
`.env` is covered by `/Users/luismiguel/Desktop/rubric/.gitignore` (line 2) — verified.

```
fal.ai:            .env  →  FAL_KEY                 <- images primary (cheapest), added 2026-08-09
OpenAI (direct):   .env  →  OPENAI_API_KEY          <- image finisher
Kie AI (Kling):    .env  →  KIE_API_KEY             <- video, primary
Google AI Studio:  .env  →  GOOGLE_AI_STUDIO_KEY    <- valid but quota-blocked
```

**Auth header shape differs per provider. This is the most common cause of a 401:**

| Provider | Header |
|----------|--------|
| fal.ai | `Authorization: Key {FAL_KEY}` — the word is **Key** |
| Kie AI | `Authorization: Bearer {KIE_API_KEY}` — the word is **Bearer** |
| OpenAI | `Authorization: Bearer {OPENAI_API_KEY}` |
| Google AI Studio | key goes in the **URL**: `?key={GOOGLE_AI_STUDIO_KEY}` |

## Output Location

- **Generated media:** `generations/`
- **Reference images:** `generations/refs/`
- **Style references:** `generations/styles/`
- All display in the Generations tab automatically

## File Naming

Use descriptive names with version/attempt numbers:
`{project}_{variant}_{attempt}_{timestamp}.{ext}`

Example: `logo_phone_v3_2_1774328838061.jpg`

For video models, prefix with the model name:
- Kling: `kling3_{shortId}_{timestamp}.mp4`
- Veo: `veo_{shortId}_{timestamp}.mp4`

---

## Generating Media

### Images

1. Read the model file (e.g., `models/nano-banana-2.md`)
2. If using a reference/style image, read it and base64-encode it
3. Make the API call per the model file's request format
4. Save to `generations/` with a descriptive filename
5. The image appears automatically in the Generations tab

### Videos

1. Read the model file (e.g., `models/kling-3.0.md`)
2. If using image-to-video, prepare the source image (Kling needs a public URL - use litterbox)
3. Submit the async job per the model file
4. Poll for completion
5. Download to `generations/` with model-prefixed filename

### Reference Images

When a reference image is provided:
1. Save to `generations/refs/` with the specified name
2. Confirm the path back
3. Reference shows in Generations tab with REF badge
4. Use the path in subsequent generation requests

### Multiple Generations

Always run sequentially (not parallel) to avoid rate limits.

---

## Dashboard - Generations Tab

The Generations tab has three sections:

### 1. Filter Bar

Tabs: **All** | **Images** | **Videos** | **References**

Plus column count selector (2-6 columns) and Styles/Models toggle buttons.

### 2. Styles Panel

Data-driven from `data/generation-styles.json`. Click any style card to copy its path.

Each style needs:
- `id` - unique identifier (snake_case)
- `name` - display name
- `description` - one-line description shown on the card
- `image` - filename in `generations/styles/`
- `prompt` - the full prompt text to use this style

### 3. Models Panel

Data-driven from `data/generation-models.json`. Renders automatically - no HTML changes needed.

Card param order is fixed: **aspect → resolution → mode → duration**. Use `"n/a"` for any that don't apply.

---

## Adding a New Style

1. Save the style reference image to `generations/styles/{id}.jpg`
2. Add an entry to `data/generation-styles.json`:

```json
{
  "id": "new_style",
  "name": "New Style Name",
  "description": "One-line description of the visual style",
  "image": "new_style.jpg",
  "prompt": "Full prompt text that produces this style. Include any negative guidance."
}
```

3. The dashboard loads styles dynamically - no HTML changes needed

### Removing a Style

Delete the entry from `generation-styles.json`. Optionally remove the image from `generations/styles/`.

---

## Adding a New Model

### Step 1: Get the API documentation

Read the model's API docs from the aggregator. Key info needed:
- Endpoint URL
- Authentication method (API key header format)
- Request body format
- Response format (sync vs async, polling endpoint if async)
- Output format (base64, URL, file)
- Supported parameters

### Step 2: Store the API key

Add the key to your `.env` file:
```
NEW_MODEL_KEY=your_key_here
```

### Step 3: Create the model file

Create `skill/models/{model-name}.md` following the existing model files as a template.

### Step 4: Add to the Models panel

Add an entry to `data/generation-models.json`:

```json
{
  "id": "model-id",
  "name": "Model Name",
  "type": "video",
  "provider": "Provider Name",
  "docs": "https://docs.provider.com/model",
  "aspect": "16:9 | 9:16",
  "resolution": "n/a",
  "mode": "n/a",
  "duration": "5 - 10s",
  "features": [
    { "label": "Feature Name", "detail": "short description" }
  ]
}
```

---

## Recommended Aggregators

- **fal.ai** - Fast inference, wide model selection, pay-per-use
- **wavespeed.ai** - Competitive pricing, good for video models
- **kie.ai** - Primary provider for Kling 3.0 and Nano Banana Pro

When evaluating a new model, check:
1. Pricing per generation
2. Async (polling) or sync (immediate)?
3. Image-to-video support?
4. Available aspect ratios and resolutions

---

## Prompt Tips

- **Simple edits:** Keep prompts short. "center the icons vertically" beats a 200-word description.
- **Multiple attempts:** Always run 2-3 variations - results vary between runs.
- **Veo:** Goes dramatic by default. Keep prompts calm, add negative guidance.
- **Style references:** Paste the style path from the Styles panel to use as a reference.
