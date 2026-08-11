# Nano Banana 2 (NB2)

Default image model. Fast and good quality for most use cases.

## TWO ROUTES — prefer fal.ai

Google AI Studio is quota-blocked (see SKILL.md). **fal.ai hosts the same model and
works today**, so NB2 is no longer blocked. Use route A unless Google billing has been
confirmed working.

### Route A — fal.ai (WORKING, verified 2026-08-09)

| Field | Value |
|-------|-------|
| Model ID | `fal-ai/nano-banana-2` (quality) · `google/nano-banana-2-lite` (cheap draft) |
| Endpoint | `POST https://fal.run/fal-ai/nano-banana-2` |
| Auth | header `Authorization: Key {FAL_KEY}` — the word is **Key**, not Bearer |
| Method | **Sync**, no polling |
| Cost | ~$0.034/image (lite) |

```json
{
  "prompt": "<required>",
  "resolution": "1K",
  "aspect_ratio": "auto",
  "output_format": "png",
  "num_images": 1
}
```
`resolution` enum: `0.5K` | `1K` | `2K` | `4K`. Response: `json.images[0].url` —
download it immediately, fal.media URLs expire.

Editing / reference images: `fal-ai/nano-banana-2/edit`, which takes an `image_urls`
array of **public** URLs. Also available: `fal-ai/nano-banana-pro` and
`fal-ai/nano-banana-pro/edit`.

See `nano-banana-2-lite.md` for the full fal recipe.

### Route B — Google AI Studio (BLOCKED unless billing is on)

| Field | Value |
|-------|-------|
| Model ID | `gemini-3.1-flash-image-preview` |
| Provider | Google AI Studio |
| Method | `generateContent` |
| Type | Image generation |
| API Key | `.env` → `GOOGLE_AI_STUDIO_KEY` |

## Request Format

```javascript
const body = {
  contents: [{
    parts: [
      // Reference images (optional, as many as needed)
      { inlineData: { mimeType: 'image/jpeg', data: '<base64>' } },
      // Prompt (always last part)
      { text: '<prompt>' }
    ]
  }],
  generationConfig: {
    responseModalities: ['TEXT', 'IMAGE']
  }
};
```

## Endpoint

```
POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image-preview:generateContent?key={API_KEY}
```

## Response Handling

```javascript
const parts = json.candidates?.[0]?.content?.parts || [];
for (const part of parts) {
  if (part.inlineData) {
    const ext = part.inlineData.mimeType.includes('png') ? 'png' : 'jpg';
    fs.writeFileSync(filepath, Buffer.from(part.inlineData.data, 'base64'));
  }
}
```

## Parameters

- **Aspect ratio:** `generationConfig.imageConfig.aspectRatio` - "1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9"
- **Image size:** `generationConfig.imageConfig.imageSize` - "512", "1K", "2K", "4K" (uppercase K required)
- Reference images go as `inlineData` parts BEFORE the text prompt
- One image per response - to get multiple, make sequential requests
- Keep prompts simple for edits. Over-engineering often makes results worse

## Multiple Generations

Run sequentially (not parallel) to avoid rate limits.

## Dashboard

- Aspect: 1:1 | 2:3 | 3:2 | 3:4 | 4:3 | 4:5 | 5:4 | 9:16 | 16:9 | 21:9
- Resolution: 512 | 1K | 2K | 4K
- Mode: n/a
- Duration: n/a
- Features: Ref Images (style + composition guide)
