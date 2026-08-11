# GPT Image 2 (OpenAI direct)

Best image model available on this setup. **Use this as the default for images.**
Synchronous — no polling, no task IDs. Returns the image in the response.

| Field | Value |
|-------|-------|
| Model ID | `gpt-image-2` |
| Provider | OpenAI (direct — NOT via Kie) |
| Method | Sync `POST /v1/images/generations` |
| Type | Image generation |
| API Key | `.env` → `OPENAI_API_KEY` |
| Docs | https://platform.openai.com/docs/api-reference/images |

Verified working 2026-08-05: ~13s for a 1024x1024 low-quality image.

## Endpoint

```
POST https://api.openai.com/v1/images/generations
Authorization: Bearer {OPENAI_API_KEY}
Content-Type: application/json
```

## Request Format

```javascript
const body = {
  model: 'gpt-image-2',
  prompt: '<prompt>',
  size: '1024x1024',      // see size rules below
  quality: 'high',        // low | medium | high | auto
  output_format: 'png',   // png | webp | jpeg
  background: 'auto',     // transparent | opaque | auto
  n: 1
};
```

## Response Handling

Returns **base64**, not a URL. There is nothing to download and nothing to poll.

```javascript
const json = await res.json();
const b64 = json.data[0].b64_json;
fs.writeFileSync(filepath, Buffer.from(b64, 'base64'));
```

`json.usage` reports `{input_tokens, output_tokens, total_tokens}` — output tokens are the
image tokens and are what you are billed on. Log it when the user asks about cost.

## Parameters — all verified by probing the live API

- **size**: **arbitrary**, not a fixed list. Rules, all three enforced:
  - both width and height must be **divisible by 16**
  - **longest edge ≤ 3840**
  - must clear a minimum pixel budget (64x64 is rejected as too small)
  - `auto` also accepted
  - This is the big advantage over the 1.x models — real 16:9 like `1920x1088` works.
- **quality**: `low` | `medium` | `high` | `auto`
- **output_format**: `png` | `webp` | `jpeg`
- **background**: `transparent` | `opaque` | `auto` — use `transparent` + `png` for logos
  and overlays that sit on top of other artwork.
- **n**: number of images per request.

## Useful sizes (divisible by 16, under 3840)

| Use | Size |
|-----|------|
| Square / Instagram post | `1024x1024` |
| Instagram story, TikTok, phone wallpaper | `1088x1920` |
| 16:9 landscape, YouTube thumbnail, web hero | `1920x1088` |
| 4:5 Instagram portrait | `1024x1280` |
| Wide banner | `2560x1088` |

## Sibling models (same endpoint, same key)

| Model | Notes |
|-------|-------|
| `gpt-image-2` | Newest, arbitrary sizes. Default choice. |
| `gpt-image-1.5` | Older. **Fixed sizes only:** 1024x1024, 1024x1536, 1536x1024, auto. |
| `gpt-image-1` | Older still, same fixed sizes. |
| `gpt-image-1-mini` | Cheapest and fastest (~8.5s). Same fixed sizes. Good for drafts and bulk variations. |

Swap `model` to switch. Everything else about the call is identical, except the 1.x family
rejects any size outside its three presets.

## Note on the Kie "GPT Image 1.5"

The Kie-routed `gpt-image/1.5-text-to-image` entry is the **same OpenAI family resold through
Kie**, and it is async (submit + poll, ~90s). Going direct is faster, gives arbitrary sizes,
and skips a middleman. Prefer this file. Keep the Kie route only as a fallback if the OpenAI
account runs out of credit.

## Dashboard

- Aspect: any (w,h divisible by 16, longest edge <= 3840)
- Resolution: up to 3840 on the longest edge
- Mode: low | medium | high | auto
- Duration: n/a
- Features: Transparent BG, Arbitrary Size, Sync (no polling)
