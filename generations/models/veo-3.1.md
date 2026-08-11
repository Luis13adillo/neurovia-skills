# Veo 3.1

Video generation via Google. Higher quality but slower than Kling.

| Field | Value |
|-------|-------|
| Model ID | `veo-3.1-generate-preview` |
| Provider | Google AI Studio |
| Method | Async (predictLongRunning → poll) |
| Type | Video generation |
| API Key | `.env` → `GOOGLE_AI_STUDIO_KEY` |
| Docs | https://ai.google.dev/api/generate-videos |

## Step 1: Start Job

```javascript
const body = {
  instances: [{
    image: { bytesBase64Encoded: '<base64>', mimeType: 'image/jpeg' },
    prompt: '<prompt>'
  }],
  parameters: {
    aspectRatio: '16:9',
    sampleCount: 1
  }
};
```

**Endpoint:**
```
POST https://generativelanguage.googleapis.com/v1beta/models/veo-3.1-generate-preview:predictLongRunning?key={API_KEY}
```

**Response:**
```json
{ "name": "models/veo-3.1-generate-preview/operations/{operation_id}" }
```

## Step 2: Poll for Result

```
GET https://generativelanguage.googleapis.com/v1beta/{operation_name}?key={API_KEY}
```

Poll every 10 seconds. When `json.done === true`:

```javascript
const samples = json.response.generateVideoResponse.generatedSamples;
const videoUri = samples[0].video.uri;
```

## Step 3: Download Video

The URI returns a 302 redirect. Use curl with `-L`:

```bash
curl -L -o "generations/veo_<shortid>_$(date +%s).mp4" "{videoUri}&key={API_KEY}"
```

## Notes

- Jobs typically take 1-2 minutes
- Poll up to 30 times (5 minutes) before timing out
- Video downloads as MP4
- Different request format from image gen (instances/parameters, not contents)
- Simple prompts work best (e.g. "animate this")
- `sampleCount`: 1-4 per request

## Dashboard

- Aspect: 16:9 | 9:16
- Resolution: 720p
- Mode: n/a
- Duration: 8s
- Features: Image to Video (start frame), Samples (1-4 per request)
