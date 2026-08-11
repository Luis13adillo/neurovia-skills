# Kling 3.0

Default video model. Faster and cheaper than Veo.

| Field | Value |
|-------|-------|
| Model ID | `kling-3.0/video` |
| Provider | Kie AI |
| Method | Async (createTask → poll recordInfo) |
| Type | Video generation |
| API Key | `.env` → `KIE_API_KEY` |
| Docs | https://docs.kie.ai/market/kling/kling-3-0 |

## Step 1: Submit Task

```bash
curl -s -X POST https://api.kie.ai/api/v1/jobs/createTask \
  -H "Authorization: Bearer {KIE_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "kling-3.0/video",
    "input": {
      "mode": "std",
      "prompt": "<your prompt>",
      "duration": "5",
      "aspect_ratio": "16:9",
      "multi_shots": false,
      "sound": true
    }
  }'
```

**Response:** `{"code":200,"data":{"taskId":"<id>"}}`

### Required Fields (422 if any missing)

`mode`, `prompt`, `duration`, `aspect_ratio`, `multi_shots`, `sound`

### Parameter Options

- `mode`: `"std"` (720p) or `"pro"` (1080p, costs more)
- `duration`: `"3"` to `"15"` (seconds, as string)
- `aspect_ratio`: `"16:9"`, `"9:16"`, or `"1:1"`
- `multi_shots`: always `false` for single-shot
- `sound`: `true` for audio

## Step 2: Poll for Result

```bash
curl -s "https://api.kie.ai/api/v1/jobs/recordInfo?taskId=<id>" \
  -H "Authorization: Bearer {KIE_API_KEY}"
```

Poll every 15 seconds. States: `waiting` → `success` / `fail`. Takes ~2 min.

**Success response:**
```json
{
  "data": {
    "state": "success",
    "resultJson": "{\"resultUrls\":[\"https://tempfile.aiquickdraw.com/r/<id>.mp4\"]}"
  }
}
```

## Step 3: Download

```bash
curl -L -o "generations/kling3_<shortid>_$(date +%s).mp4" "<resultUrl>"
```

## Image-to-Video

Pass 1-2 URLs in `image_urls` (index 0 = first frame, index 1 = last frame).

**`image_urls` must be publicly accessible URLs** - Kie's servers fetch the image. Use litterbox for temporary hosting:

```bash
# Upload to litterbox (1h expiry, free, no account)
curl -s -F "reqtype=fileupload" -F "time=1h" -F "fileToUpload=@/path/to/image.jpg" https://litterbox.catbox.moe/resources/internals/api.php
# Returns: https://litter.catbox.moe/abc123.jpg
```

## Notes

- `tempfile.aiquickdraw.com` URLs expire - download immediately
- Multi-shot mode only supports first frame (no last frame)
- litterbox URLs expire after 1 hour

## Dashboard

- Aspect: 16:9 | 9:16 | 1:1
- Resolution: std=720p | pro=1080p
- Mode: std | pro
- Duration: 3-15s
- Features: Frame Control (first + last frame), Sound (multi-language, lip sync), Multi-shot (multiple angles), Elements (reference assets, max 3)
