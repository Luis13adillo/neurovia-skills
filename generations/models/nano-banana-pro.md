# Nano Banana Pro (NB Pro)

Higher quality image generation via Kie AI.

| Field | Value |
|-------|-------|
| Model ID | `nano-banana-pro-preview` |
| Provider | **Google AI Studio** (the shipped template said "Kie AI" — that is wrong) |
| Method | `generateContent` |
| Type | Image generation |
| API Key | `.env` → **`GOOGLE_AI_STUDIO_KEY`** (NOT `KIE_API_KEY`) |

> **Corrected 2026-08-05, verified by testing both keys against this endpoint.**
> The template shipped saying Provider = Kie AI / key = `KIE_API_KEY`, but the endpoint
> below is `generativelanguage.googleapis.com` — Google's. Passing the Kie key returns
> `INVALID_ARGUMENT: API key not valid`. Passing the Google key authenticates correctly.
>
> **Currently unusable on this setup:** with the Google key it returns 429
> `RESOURCE_EXHAUSTED` (`free_tier_requests, limit: 0`). Needs billing enabled on the
> Google account. Use GPT Image 1.5 via Kie until then.

## Request Format

Same as NB2 - uses the `generateContent` method with `contents` array.

```javascript
const body = {
  contents: [{
    parts: [
      { inlineData: { mimeType: 'image/jpeg', data: '<base64>' } },
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
POST https://generativelanguage.googleapis.com/v1beta/models/nano-banana-pro-preview:generateContent?key={API_KEY}
```

## Parameters

- **Aspect ratio:** 9:16, 16:9, 1:1
- **Resolution:** 1K, 2K, 4K
- Reference images supported (style + composition guide)

## Dashboard

- Aspect: 9:16 | 16:9 | 1:1
- Resolution: 1K | 2K | 4K
- Mode: n/a
- Duration: n/a
- Features: Ref Images (style + composition guide)
