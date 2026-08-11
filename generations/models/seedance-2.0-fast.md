# Seedance 2.0 Fast — Reference to Video (via fal.ai)

**Animates reference images.** Feed it stills and it turns them into motion.
Use when the job is "make this image move", not "make a video from a description".

**PAID VIDEO — quote the cost and wait for Luis's explicit go before running.**

| Field | Value |
|-------|-------|
| Model ID | `bytedance/seedance-2.0/fast/reference-to-video` |
| Provider | fal.ai |
| Method | Submit + poll (use the queue endpoint for anything over a few seconds) |
| Type | Video |
| API Key | `.env` → `FAL_KEY` |
| Docs | https://fal.ai/models/bytedance/seedance-2.0/fast/reference-to-video |
| Cost | ~$0.24 per second at 720p → **a 5s clip is ~$1.20, an 8s clip is ~$1.92** |

Endpoint verified reachable 2026-08-09 (422 on empty body = exists + auth ok).
No paid run has been made yet — the first real generation is still unproven.

## Cost quote template

> Seedance 2.0 Fast, 5 seconds, 720p, from 2 reference images — about **$1.20**. Run it?

## Endpoint

```
POST https://fal.run/bytedance/seedance-2.0/fast/reference-to-video
Authorization: Key {FAL_KEY}
```

For the polling version, swap the host to `https://queue.fal.run/` — the reply
gives `request_id` plus `status_url` and `response_url`, then poll `status_url`
until `status` is `COMPLETED`.

## Request Format

```json
{
  "prompt": "<required>",
  "image_urls": ["https://...", "https://..."],
  "duration": "5",
  "resolution": "720p",
  "aspect_ratio": "16:9",
  "generate_audio": true,
  "bitrate_mode": "standard"
}
```

Verified enums:
- `duration` — `auto` | `4` | `5` | `6` | `7` | `8` (**strings, not numbers**)
- `resolution` — `480p` | `720p` (720p default). 480p is the cheaper draft.
- `aspect_ratio` — `auto` | `21:9` | `16:9` | `4:3` | `1:1` | `3:4`
- `bitrate_mode` — `standard` | `high`
- also accepts `video_urls` and `audio_urls` arrays

`generate_audio` defaults to **true**. Set it false if Luis wants a silent clip.

## Reference Images Must Be Public URLs

`image_urls` takes URLs, not local paths. Files in `generations/refs/` have to be
uploaded first. Options: fal's own upload endpoint, or Kie AI's file upload (the
Kie account already exists and its uploader returns a public URL).

## Response Handling

```javascript
const json = await r.json();
const videoUrl = json.video.url;   // output is { video, seed }
// Download IMMEDIATELY — result URLs expire in hours.
```

## Notes

- Sibling variants exist and are all real ids: `seedance-2.0/fast/text-to-video`,
  `/fast/image-to-video`, `seedance-2.0/mini/*` (cheaper), `seedance-2.5/*` (newer).
- Note the id has **no `fal-ai/` prefix** — it is `bytedance/...`. Prefixing it
  with `fal-ai/` returns 404.
