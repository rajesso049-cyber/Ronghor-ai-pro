# Ronghor AI

A Flutter Android chat app plus a small FastAPI backend. The backend talks to **Claude** (default) or OpenAI, so the app behaves like a normal AI assistant: chat, optional live web search, voice input, read-aloud, and local chat history.

Not included yet: accounts, cloud sync, long-term memory, image generation, file uploads, autonomous agents.

## Setup (about 15 minutes, all doable from a phone browser)

### 1. Get an API key
Create a key at console.anthropic.com (API usage is billed separately from a Claude chat subscription; add a few dollars of credit). Web search must be enabled for your organization in the Console.

### 2. Put this project in your GitHub repo
Upload everything, keeping the folders, including `.github/workflows/`, `backend/`, `lib/`, `tool/` and `render.yaml`.

### 3. Deploy the backend on Render (free plan)
1. render.com > **New** > **Blueprint** > pick your repo.
2. When asked, paste your `ANTHROPIC_API_KEY`. Render creates `APP_ACCESS_KEY` for you.
3. When it finishes, copy the service URL (`https://ronghor-ai-api.onrender.com` or similar).
4. Open the service > **Environment** > reveal and copy `APP_ACCESS_KEY`.

Free Render services sleep after 15 minutes idle, so the first message after a break can take up to a minute. Paid plans stay awake.

### 4. Build the APK
GitHub > **Actions** > **Build Ronghor AI Android APK** > **Run workflow**, then download the `ronghor-ai-release-apk` artifact.

Optional: add a repository variable `BACKEND_URL` (Settings > Secrets and variables > Actions > Variables) to bake your server address into the app.

### 5. Install and connect
Uninstall any older Ronghor AI first (each CI build is signed with a fresh key, so Android refuses to update in place). Install the new APK, tap the sliders icon, enter the backend URL and access key, tap **Test connection**, then Save.

## Backend settings (environment variables)

| Name | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Your Claude API key |
| `ANTHROPIC_MODEL` | Optional, default `claude-sonnet-5-5` (use `claude-haiku-5-5` for cheaper and faster) |
| `APP_ACCESS_KEY` | Required. The app must send it, so nobody else can spend your credits |
| `OPENAI_API_KEY` + `OPENAI_MODEL` | Use OpenAI instead (set `AI_PROVIDER=openai` if both keys exist) |
| `SYSTEM_PROMPT_EXTRA` | Optional extra instructions, e.g. your name and preferred style |
| `MAX_OUTPUT_TOKENS` | Optional, default 2048 |

Local test: `cd backend && pip install -r requirements.txt && cp .env.example .env`, edit `.env`, then `uvicorn main:app --port 8000`. Run `python -m unittest test_ai` for the offline tests.
A phone cannot reach `localhost`; use an HTTPS tunnel (ngrok, Cloudflare Tunnel) or deploy.
To allow plain `http://` for LAN testing, run the workflow manually with **allow_http** ticked.

## Troubleshooting
- **Operation not permitted / cannot connect:** the APK was built without the internet permission. Use this version's workflow; it patches the manifest correctly.
- **Wrong or missing access key:** re-copy `APP_ACCESS_KEY` from Render into Settings.
- **Server has no AI key / credit balance too low:** check the API key and credit in the Anthropic Console.
- **Slow first reply:** the free Render server was asleep.

## Layout
`lib/main.dart` app, `backend/` API (`ai.py` logic, `main.py` routes), `tool/patch_android.py` manifest patcher, `render.yaml` deployment blueprint, `.github/workflows/android-apk.yml` APK build.
