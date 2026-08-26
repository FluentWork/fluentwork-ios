# OpenCodeReview local review archives

OpenCodeReview **pre-commit gate is paused**. Prefer **gstack `/review`** before PR merge
(see `fluentwork-meta/agents/shared/review-gate.md`).

## Optional manual OCR

```bash
FORCE_OCR=1 ./Scripts/ocr-local-review.sh
./Scripts/ocr-export-review.sh
```

Exports land under `.opencodereview/reviews/` when OCR is run manually.
