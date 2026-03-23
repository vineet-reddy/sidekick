# Sidekick Backend

This service now acts as the Sidekick backend. It handles anonymous device sessions, GitHub connection, hosted paper jobs, and GitHub publication.

It does these things:

1. Start GitHub OAuth for the Sidekick user.
2. Create or reuse the user's public `sidekick` repository.
3. Run hosted paper jobs against the OpenAI API.
4. Publish reproducibility bundles back into the user's repo.

## Why it exists

The iPhone app should not hold your GitHub OAuth client secret or your OpenAI API key. The backend handles those calls on the user's behalf and keeps only small durable metadata.

## Deploy

The repo includes `render.yaml` for a simple Render deployment.

Required environment variables:

- `GITHUB_CLIENT_ID`
- `GITHUB_CLIENT_SECRET`
- `SIDEKICK_BACKEND_BASE_URL`
- `OPENAI_API_KEY`
- `SIDEKICK_ENCRYPTION_SECRET`

## GitHub OAuth app settings

Set the GitHub OAuth app callback URL to:

```text
https://<your-render-service>.onrender.com/browser/github-connect/callback
```

## iPhone app configuration

Set the app's backend base URL to the same deployed service:

```text
SIDEKICK_GITHUB_BOOTSTRAP_BASE_URL = https://<your-render-service>.onrender.com
```

The app reads this from:

- process environment in development
- `SidekickGitHubBootstrapBaseURL` in `Info.plist` for app builds

## Local development

For simulator-only local development:

```bash
cd /Users/vineetreddy/Documents/GitHub/sidekick
cp github_bootstrap_service/.env.example github_bootstrap_service/.env
export $(grep -v '^#' github_bootstrap_service/.env | xargs)
./scripts/run_github_bootstrap_service.sh
```
