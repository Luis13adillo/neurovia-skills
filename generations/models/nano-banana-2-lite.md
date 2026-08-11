# Nano Banana 2 Lite (via fal.ai)

**Cheapest capable image model. Use this for ALL drafts and iteration.**
Verified working 2026-08-09 — 3.3 seconds, no polling.

| Field | Value |
|-------|-------|
| Model ID | `google/nano-banana-2-lite` |
| Provider | fal.ai |
| Method | **Sync** — finished image comes back in the first response |
| Type | Image |
| API Key | `.env` → `FAL_KEY` |
| Docs | https://fal.ai/models/google/nano-banana-2-lite |
| Cost | ~$0.034 per image |

## Endpoint

```
POST https://fal.run/google/nano-banana-2-lite
Authorization: Key {FAL_KEY}
Content-Type: application/json
```

Note the auth word is **`Key`**, not `Bearer`. Kie uses `Bearer`, fal uses `Key`.
Getting this wrong returns 401.

## Request Format

```json
{
  "prompt": "<required — the only mandatory field>",
  "num_images": 1,
  "aspect_ratio": "auto",
  "output_format": "png",
  "resolution": "1K",
  "seed": null,
  "safety_tolerance": "4",
  "system_prompt": ""
}
```

Verified defaults: `output_format` png, `num_images` 1, `aspect_ratio` auto,
`safety_tolerance` "4" (string, not int). With `aspect_ratio: auto` a landscape
prompt returned 1408x768.

## Response Handling

```javascript
const r = await fetch(url, { method:'POST', headers, body });
const json = await r.json();
const imageUrl = json.images[0].url;        // fal-hosted URL
// json.images[0] also has: content_type, file_name, width, height
// Download IMMEDIATELY — fal.media URLs expire.
const buf = Buffer.from(await (await fetch(imageUrl)).arrayBuffer());
fs.writeFileSync(filepath, buf);
```

There is no polling. If you find yourself writing a poll loop for this model,
you have the wrong recipe.

## Reference Images

This endpoint takes a text prompt only. For reference-image work use
`fal-ai/nano-banana-2/edit` or `fal-ai/nano-banana-pro/edit`, which accept an
`image_urls` array of PUBLIC urls — local file paths will not work, the file has
to be uploaded first.

## Notes

- A bad model id returns 404; a valid id with a bad body returns 422. That 422 is
  the free way to check a model exists without paying for a generation.
- `limit_generations` defaults to true — leave it on.
- Cheapest route in the whole setup. Draft here, then rerun the winner on
  `gpt-image-2` (OpenAI direct) or `fal-ai/nano-banana-2` at 2K/4K.
