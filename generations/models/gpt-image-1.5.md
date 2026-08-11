# GPT Image 1.5

High-quality text-to-image generation via Kie AI. Async workflow - submit task, poll for result.

| Field | Value |
|-------|-------|
| Model ID | `gpt-image/1.5-text-to-image` |
| Provider | Kie AI |
| Method | Async (createTask → poll recordInfo) |
| Type | Image generation |
| API Key | `.env` → `KIE_API_KEY` |
| Docs | https://kie.ai |

## Request Format

```javascript
const body = {
  model: 'gpt-image/1.5-text-to-image',
  input: {
    prompt: '<prompt>',        // max 3000 chars
    aspect_ratio: '3:2',       // 1:1 | 2:3 | 3:2
    quality: 'medium'          // medium | high
  }
};
```

## Endpoints

### Create Task

```
POST https://api.kie.ai/api/v1/jobs/createTask
Authorization: Bearer {KIE_API_KEY}
Content-Type: application/json
```

### Poll Status

```
GET https://api.kie.ai/api/v1/jobs/recordInfo?taskId={taskId}
Authorization: Bearer {KIE_API_KEY}
```

## Response Handling

1. Submit task → get `data.taskId` from response
2. Poll `recordInfo` until `data.state` is `success` or `fail`
3. On success, parse `data.resultJson` (JSON string) → `resultUrls` array contains image URLs
4. Download the image URL and save to `generations/`

```javascript
const result = JSON.parse(data.resultJson);
const imageUrl = result.resultUrls[0];
```

## Parameters

- **prompt** (required): Text description, max 3000 characters
- **aspect_ratio** (required): `1:1` | `2:3` | `3:2`
- **quality** (required): `medium` (balanced) | `high` (slower, more detailed)

## Notes

- Async model - requires polling (unlike NB2/NB Pro which are sync)
- Poll interval: 3-5 seconds recommended
- States: `waiting` → `success` or `fail`
- No reference image support - text-to-image only

## Dashboard

- Aspect: 1:1 | 2:3 | 3:2
- Resolution: n/a
- Mode: medium | high
- Duration: n/a
- Features: Quality (medium=balanced, high=slow+detailed)
