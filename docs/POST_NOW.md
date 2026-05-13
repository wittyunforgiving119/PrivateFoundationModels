# Post now — one-click launchers

Each link below opens the target platform's compose form **with the title, body, and URL already filled in**. You click → review → press the Post / Submit button. No copy-paste.

> If your browser blocks the link click because it's coming from a `file://` markdown viewer, view this file on GitHub: <https://github.com/john-rocky/PrivateFoundationModels/blob/main/docs/POST_NOW.md>

## 1. X (recommended first move)

[**→ Post the v0.5 launch tweet on X**](https://twitter.com/intent/tweet?text=PrivateFoundationModels%20v0.5%20%E2%80%94%20three%20Swift%20backends%2C%20same%20LanguageModelSession.respond%28to%3A%29%20call%20site%3A%0A%0A%C2%B7%20iOS%2026%2B%3A%20Apple%E2%80%99s%20native%20FoundationModels%20%28Apple%20Intelligence%29%0A%C2%B7%20iOS%2018%2B%3A%20CoreML%20%2F%20Apple%20Neural%20Engine%0A%C2%B7%20iOS%2017%2B%3A%20MLX%20%2F%20GPU%20%28any%20mlx-community%2F%2A%20model%29%0A%0A%40Generable%20%2B%20Tools%20work%20on%20all%20three.%20Verified.%0A%0Ahttps%3A%2F%2Fgithub.com%2Fjohn-rocky%2FPrivateFoundationModels)

Attach a 6-second screen recording of `pfm-apple-deep` finishing with `PASS 14 / MODEL 0 / FAIL 0` before posting. That visual is the single biggest credibility signal we have.

For a multi-tweet thread (more detail per tweet), copy the body from [`docs/x-post-v0.5.md`](x-post-v0.5.md) and paste into a new thread after this initial tweet.

## 2. Hacker News (early-morning Pacific is the sweet spot)

[**→ Submit to HN**](https://news.ycombinator.com/submitlink?u=https%3A%2F%2Fgithub.com%2Fjohn-rocky%2FPrivateFoundationModels&t=PrivateFoundationModels%3A%20one%20Apple-FM%20API%2C%20three%20on-device%20Swift%20backends)

Title pre-filled: *PrivateFoundationModels: one Apple-FM API, three on-device Swift backends*

HN scoring window is the first hour. The README does the rest — no body needed.

## 3. Reddit r/swift (text post)

[**→ Submit to r/swift**](https://www.reddit.com/r/swift/submit?title=PrivateFoundationModels%20v0.5%20%E2%80%94%20Apple%20FoundationModels%20API%20on%20iOS%2018%2C%20native%20passthrough%20on%20iOS%2026%2C%20CoreML%20%2F%20MLX%20backends%20in%20between&text=The%20same%20LanguageModelSession.respond%28to%3A%29%20call%20site%20routes%20to%20three%20different%20runtimes%20depending%20on%20what%20is%20available%20on%20the%20device.%0A%0A-%20iOS%2026%2B%20%E2%86%92%20Apple%27s%20actual%20native%20FoundationModels%20%28Apple%20Intelligence%29%0A-%20iOS%2018%2B%20%E2%86%92%20CoreML%20on%20the%20Apple%20Neural%20Engine%0A-%20iOS%2017%2B%20%E2%86%92%20ml-explore%2Fmlx-swift-lm%20on%20the%20GPU%20%28any%20mlx-community%2F%2A%20model%29%0A%0A%40Generable%20structured%20output%20and%20Tool%20calling%20work%20on%20all%20three%20backends.%20Verified%20end-to-end%20on%20Apple%20M4%20Max%20with%20PASS%2014%20%2F%20FAIL%200%20on%20the%20Apple-native%20path.%0A%0AMIT%2C%20SPM%20only.%20Repo%3A%20https%3A%2F%2Fgithub.com%2Fjohn-rocky%2FPrivateFoundationModels&kind=self)

Title + body both pre-filled.

## 4. Reddit r/iOSProgramming (text post)

[**→ Submit to r/iOSProgramming**](https://www.reddit.com/r/iOSProgramming/submit?title=PrivateFoundationModels%20v0.5%20%E2%80%94%20Apple%20FoundationModels%20API%20on%20iOS%2018%2C%20native%20passthrough%20on%20iOS%2026%2C%20CoreML%20%2F%20MLX%20backends%20in%20between&text=The%20same%20LanguageModelSession.respond%28to%3A%29%20call%20site%20routes%20to%20three%20different%20runtimes%20depending%20on%20what%20is%20available%20on%20the%20device.%0A%0A-%20iOS%2026%2B%20%E2%86%92%20Apple%27s%20actual%20native%20FoundationModels%20%28Apple%20Intelligence%29%0A-%20iOS%2018%2B%20%E2%86%92%20CoreML%20on%20the%20Apple%20Neural%20Engine%0A-%20iOS%2017%2B%20%E2%86%92%20ml-explore%2Fmlx-swift-lm%20on%20the%20GPU%20%28any%20mlx-community%2F%2A%20model%29%0A%0A%40Generable%20structured%20output%20and%20Tool%20calling%20work%20on%20all%20three%20backends.%20Verified%20end-to-end%20on%20Apple%20M4%20Max%20with%20PASS%2014%20%2F%20FAIL%200%20on%20the%20Apple-native%20path.%0A%0AMIT%2C%20SPM%20only.%20Repo%3A%20https%3A%2F%2Fgithub.com%2Fjohn-rocky%2FPrivateFoundationModels&kind=self)

## 5. Apple Developer Forums

Apple's forum doesn't expose a pre-fillable submit URL, so this one is a manual paste:

- Open: <https://developer.apple.com/forums/create-content?tags=foundation-models>
- Title + body in [`docs/apple-developer-forums-post.md`](apple-developer-forums-post.md)

---

## Why I can't post these myself

This Claude Code session doesn't have a Playwright MCP / X API / Reddit API / HN client wired in. ToolSearch over the deferred-tool list returns only WebFetch (read-only) and Google Drive auth. The pre-fill-and-click pattern above is the closest one-click hand-off I can produce from here.

If you want me to actually post end-to-end in a future session, add one of these to your Claude Code MCP config:

- `@playwright/mcp` (browser automation — fully scripted post)
- A custom Twitter MCP using your OAuth token
- `mcp-reddit` for Reddit / `mcp-hn` for HN

Then I can drive the form fills + submit clicks without you ever touching a keyboard.
