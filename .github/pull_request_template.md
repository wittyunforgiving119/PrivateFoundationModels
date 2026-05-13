## Summary

<!--
1-3 sentences. What does this change? Why?
-->

## Backend impact

<!--
Check all that apply. Leave them all blank for docs-only PRs.
-->

- [ ] PrivateFoundationModels (core API)
- [ ] PrivateFoundationModelsApple
- [ ] PrivateFoundationModelsCoreML
- [ ] PrivateFoundationModelsMLX

## Verification

<!--
Paste the relevant test / deep-harness output. Reviewers shouldn't
have to re-run; the result is the proof.
-->

```
swift test                          → 91/91
pfm-deep --model lfm2.5-350m        → PASS X / MODEL Y / FAIL 0
pfm-mlx-deep                        → PASS X / MODEL Y / FAIL 0
pfm-apple-deep                      → PASS X / MODEL Y / FAIL 0
```

## Hardware / OS used for verification

- Hardware:
- OS + Xcode:

## Notes for the reviewer
