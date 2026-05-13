# Wiring up X + Reddit API credentials

One-time setup. Take ~10 minutes. Future PFM launches go from "click 4 browser tabs" to `./bin/post-x.py && ./bin/post-reddit.py` — one shell command per channel.

`bin/post-x.py` and `bin/post-reddit.py` already exist and **dry-run safely** when no credentials are set, so you can test the workflow first.

---

## X (Twitter) v2 API

The X v2 "Free" tier allows ~500 posts per month with OAuth 1.0a user context. That's enough for many launches.

### 1. Create / open your developer account

- Open <https://developer.x.com/en/portal/dashboard>
- Sign in with the account you want to post from (@JackdeS11).
- If first time, click "Sign up for the Free tier."

### 2. Create a "Project + App"

- Inside the portal, **Projects** → **+ New Project** (any name, e.g. "PFM Launch").
- Inside the project, **+ Add App** (any name, e.g. "pfm-cli-poster").

### 3. Enable **OAuth 1.0a User authentication**

This is the part that lets you post.

- App settings → **User authentication settings** → **Set up**
- App permissions: **Read and write**
- Type of App: **Web App, Automated App or Bot** (just need any "confidential" setting)
- Callback URL: `http://localhost` is fine (we're not using OAuth flow)
- Website URL: `https://github.com/john-rocky/PrivateFoundationModels` is fine
- Save.

### 4. Generate **Consumer Keys** and **Access Token & Secret**

- App **Keys and tokens** tab.
- "Consumer Keys" → **Regenerate** → copy "API Key" and "API Key Secret"
- "Access Token and Secret" → **Generate** (under "OAuth 1.0a")
  - Make sure permission says **Read and write** (re-generate if it says Read-only).
- Copy the access token + access token secret.

### 5. Export the four env vars

```bash
# Add to ~/.zshrc or a per-project .envrc, then `source` it.
export X_CONSUMER_KEY="..."
export X_CONSUMER_SECRET="..."
export X_ACCESS_TOKEN="..."
export X_ACCESS_TOKEN_SECRET="..."
```

### 6. Install tweepy and run

```bash
pip install tweepy
./bin/post-x.py
# → Posted: https://twitter.com/i/web/status/12345...
```

If you see "401 Unauthorized," your token doesn't have write permission — re-do step 3 with "Read and write" and re-generate in step 4.

---

## Reddit script-app

Reddit's password-grant flow takes about 2 minutes.

### 1. Create a "script" app

- Open <https://www.reddit.com/prefs/apps>
- Scroll down → **create another app...**
- name: `pfm-launch` (or anything)
- type: **script**
- description: leave blank
- about url: `https://github.com/john-rocky/PrivateFoundationModels`
- redirect uri: `http://localhost:8080` (required but unused for script apps)
- Click **create app**.

### 2. Copy the credentials

After creation, the app card shows:
- A short **client_id** under the app name (looks like `aB1Cd2Ef...`).
- A longer **secret** further down.

### 3. Export the env vars

```bash
export REDDIT_CLIENT_ID="..."
export REDDIT_CLIENT_SECRET="..."
export REDDIT_USERNAME="your_reddit_handle"
export REDDIT_PASSWORD="your_reddit_password"   # account password
export REDDIT_USER_AGENT="pfm-launch/0.10 by <your_reddit_handle>"
```

> **Note:** If your account uses Reddit's official 2FA app, you'll need to append the 6-digit code to the password (`abc123:987654`) per [Reddit's docs](https://github.com/reddit-archive/reddit/wiki/OAuth2#authorization). The 2FA code rotates every 30 s, so one-shot only. Easier to disable 2FA on the posting account or use a dedicated launch account.

### 4. Install praw and run

```bash
pip install praw
./bin/post-reddit.py
# → r/swift: https://www.reddit.com/r/swift/comments/...
# → r/iOSProgramming: https://www.reddit.com/r/iOSProgramming/comments/...
```

If a subreddit requires a **flair**, the post will still create but show "Flair required" until you assign one via the web UI. (Reddit's API doesn't auto-pick flair without the subreddit-specific flair_id which isn't easily discoverable.)

---

## Hacker News

HN has no submit API. The `post-tabs.sh` script opens the pre-filled HN submit form in your browser; you click Submit there.

There are unofficial libraries that automate HN posting via Puppeteer / Playwright, but they break Y Combinator's ToS and routinely get accounts shadow-banned. Don't bother.

---

## Apple Developer Forums

Same: no submit API. Open `https://developer.apple.com/forums/create-content?tags=foundation-models` and paste the body from [`docs/apple-developer-forums-post.md`](../docs/apple-developer-forums-post.md).

---

## Verifying without posting

Both `post-x.py` and `post-reddit.py` print "DRY RUN" and exit 0 when env vars are missing, so you can wire them into CI as a "would this post correctly?" smoke test without actually posting:

```bash
./bin/post-x.py
# DRY RUN — X env vars not set: ['consumer_key', ...]
# Would have posted:
# ...
```
