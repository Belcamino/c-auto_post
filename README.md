# c-auto_post

Automated publishing daemon for Facebook and Instagram. Reads a Markdown schedule file (`plan.md`) and publishes posts at their scheduled times, updating each post's status in-place.

---

## Overview

The system is built around a single PowerShell orchestrator (`publisher.ps1`) that runs in a continuous loop. Every hour (configurable) it reads `plan.md`, finds posts whose scheduled time has passed within a configurable tolerance window, and calls the appropriate Python publisher script via the Facebook/Instagram Graph API v25.0.

```
plan.md  ──►  publisher.ps1  ──►  fb_publisher.py   ──►  Facebook Graph API
                                  ig_publisher.py   ──►  Instagram Graph API
```

After each successful publish, the post's `**Status:**` line in `plan.md` is updated from `⏳ pending` to `✅ published` (or `❌ failed`). The file is never pushed to GitHub — it stays local.

---

## Files

| File | Description |
|---|---|
| `publisher.ps1` | Main orchestrator — loop daemon + git helpers |
| `fb_publisher.py` | Posts a text message to a Facebook page |
| `ig_publisher.py` | Posts an image+caption to an Instagram account |
| `test.ps1` | Manual one-shot test: calls both Python scripts directly |
| `modello.md` | Template showing the expected `plan.md` format |
| `.env` | Credentials and configuration (not tracked by git) |
| `plan.md` | The active publishing schedule (not tracked by git) |
| `immagini.md` | Local image URL registry (not tracked by git) |
| `testi/` | Source PDF files used to generate content (not tracked by git) |

---

## Requirements

- PowerShell 5+ (Windows)
- Python 3.x with `requests` installed (`pip install requests`)
- A Facebook Page with a valid Page Access Token
- An Instagram Professional account linked to a Facebook app, with a valid access token
- Git (only needed for the `-GitStart` / `-GitPush` options)

---

## Setup

1. Copy `.env.example` to `.env` (or create `.env` from scratch) and fill in all values:

```env
# Facebook
FB_PAGE_TOKEN=<your_facebook_page_access_token>
FB_PAGE_ID=<your_facebook_page_id>

# Instagram
IG_ACCESS_TOKEN=<your_instagram_access_token>
IG_USER_ID=<your_instagram_user_id>
IG_DEFAULT_IMAGE_URL=<fallback_image_url_for_posts_without_an_explicit_image>

# GitHub (only needed for -GitStart / -GitPush)
GITHUB_USER=<your_github_username>
GITHUB_REPO=<repository_name>
GITHUB_TOKEN=<personal_access_token>
```

2. Create `plan.md` following the format described in `modello.md` (see [Plan format](#plan-format) below).

3. Run the daemon from the project directory:

```powershell
cd C:\path\to\c-auto_post
.\publisher.ps1
```

---

## publisher.ps1 — Usage

```
.\publisher.ps1 [options]
```

### Options

| Option | Default | Description |
|---|---|---|
| `-IntervalMinutes N` | `60` | Wait time between cycles |
| `-ToleranceMinutes N` | `30` | How many minutes past schedule a post is still published |
| `-MaxLogSizeMB N` | `5` | Log file size limit before rotation |
| `-DryRun` | off | Simulate publishing without calling any API |
| `-Debug` | off | Print verbose parsing details to log and screen |
| `-GitStart` | — | Init local git repo, stage all files, create initial commit, then exit |
| `-GitPush` | — | Push current branch to GitHub and exit |

### Examples

```powershell
# Normal daemon mode
.\publisher.ps1

# Simulate without publishing
.\publisher.ps1 -DryRun

# Faster cycle for testing (every 5 minutes, 10-minute tolerance)
.\publisher.ps1 -IntervalMinutes 5 -ToleranceMinutes 10 -Debug

# First-time git setup
.\publisher.ps1 -GitStart

# Push to GitHub
.\publisher.ps1 -GitPush
```

Stop the daemon with **Ctrl+C**.

---

## Plan format

`plan.md` is a Markdown file structured as date sections containing post blocks.

```markdown
## YYYY-MM-DD

### 🔵 Facebook — HH:mm
**Topic:** Short description
**Status:** ⏳ pending

Post body text here.
Can span multiple paragraphs.

---

### 📸 Instagram — HH:mm
**Topic:** Short description
**Image:** https://example.com/image.jpg
**Image note:** Description of the image
**Status:** ⏳ pending

Caption text here.

---
```

**Rules:**
- Each date section starts with `## YYYY-MM-DD`.
- Each post header is `### 🔵 Facebook — HH:mm` or `### 📸 Instagram — HH:mm`.
- `**Status:** ⏳ pending` marks a post as ready to publish.
- The body text is everything between the metadata lines and the closing `---`.
- Instagram posts require an image URL (`**Image:**`). If absent, `IG_DEFAULT_IMAGE_URL` from `.env` is used.
- Markdown bold (`**text**`) and italic (`*text*`) are stripped before sending to the APIs.

See `modello.md` for a complete working example.

---

## Python publishers

Both scripts receive their input exclusively via environment variables to avoid command-line quoting issues on Windows.

### fb_publisher.py

| Env var | Required | Description |
|---|---|---|
| `POST_MESSAGE` | yes | Text to post |
| `FB_PAGE_TOKEN` | yes | Facebook Page Access Token |
| `FB_PAGE_ID` | yes | Target Facebook Page ID |

Prints `SUCCESS:<post_id>` on success, `ERROR:<code>:<message>` on failure.

### ig_publisher.py

| Env var | Required | Description |
|---|---|---|
| `POST_MESSAGE` | yes | Caption text |
| `POST_IMAGE_URL` | no | Image URL (overrides default) |
| `IG_ACCESS_TOKEN` | yes | Instagram access token |
| `IG_USER_ID` | yes | Instagram Professional account ID |
| `IG_DEFAULT_IMAGE_URL` | no | Fallback image if `POST_IMAGE_URL` is empty |

Prints a JSON object: `{"success": true, "post_id": "..."}` or `{"success": false, "error": {...}}`.

Publishing to Instagram is a two-step process: first a media container is created, then it is published. Both steps call the Facebook Graph API v25.0.

---

## Git workflow

The repo tracks only source files. `plan.md`, `immagini.md`, `.env`, logs, and `testi/` are excluded via `.gitignore`.

```powershell
# First time: initialize local repo and create first commit
.\publisher.ps1 -GitStart

# Push to GitHub
.\publisher.ps1 -GitPush
```

`-GitStart` will configure the `origin` remote using `GITHUB_USER`, `GITHUB_REPO`, and `GITHUB_TOKEN` from `.env`, so no manual `git remote add` is needed.

---

## Logging

The daemon writes to `publisher.log` in the project directory. Log entries are prefixed with timestamp and level (`INFO`, `SUCCESS`, `WARN`, `ERROR`, `DEBUG`). The log is automatically rotated when it exceeds `MaxLogSizeMB` (default 5 MB), keeping up to 3 rotated files (`publisher.log.1`, `.2`, `.3`).

---

## Manual testing

Use `test.ps1` to fire a single publish without going through the scheduler:

```powershell
.\test.ps1 "Your message here"
.\test.ps1 "Your message here" "https://example.com/image.jpg"
```

This calls both `fb_publisher.py` and `ig_publisher.py` directly and prints their raw output.
