# GitHub Bootstrap Service

This is the small control-plane backend that powers Sidekick's secure one-repo setup flow.

It does four things:

1. Start GitHub OAuth for the Sidekick user.
2. Create or reuse the user's private `sidekick-workspace` repository.
3. Apply branch protection to the default branch.
4. Redirect the user to the ChatGPT Codex Connector install page with that repository preselected.

## Why it exists

The iPhone app should not hold your GitHub OAuth client secret and should not create private GitHub repositories directly. The bootstrap service handles those GitHub API calls on your behalf.

## Deploy

The repo includes `render.yaml` for a simple Render deployment.

Required environment variables:

- `GITHUB_CLIENT_ID`
- `GITHUB_CLIENT_SECRET`
- `GITHUB_BOOTSTRAP_REDIRECT_BASE_URL`

Optional:

- `GITHUB_BOOTSTRAP_TEMPLATE_OWNER`
- `GITHUB_BOOTSTRAP_TEMPLATE_REPO`

## GitHub OAuth app settings

Set the GitHub OAuth app callback URL to:

```text
https://<your-bootstrap-service>/browser/github-bootstrap/callback
```

## iPhone app configuration

Set the app's bootstrap base URL to the same deployed service:

```text
SIDEKICK_GITHUB_BOOTSTRAP_BASE_URL = https://<your-bootstrap-service>
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
