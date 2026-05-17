---
name: upload
description: >
  Ship Tarsa Fantasy: commit any pending changes and push to GitHub. The
  GitHub Actions workflow at .github/workflows/testflight.yml then builds and
  uploads to TestFlight automatically. Trigger when the user invokes `/upload`
  or says things like "ship it", "upload to testflight", "push and upload",
  "release a new build", or otherwise asks to publish the current state.
  Do NOT trigger for ad-hoc git pushes with no shipping intent.
---

# Upload

Commit + push. GitHub Actions takes it from there.

The build no longer happens locally — `.github/workflows/testflight.yml` runs on every push to `main` that touches `Tarsa Fantasy/**` or `Tarsa Fantasy.xcodeproj/**`, archives, and uploads to TestFlight on a macOS runner. The local `scripts/upload-testflight.sh` is still there as an escape hatch but you don't run it from this skill.

## Step 1 — Inspect the working tree

Run `git status --short` and `git diff --stat`.

If the tree is clean AND `git log origin/main..HEAD` is empty (nothing to push), there is nothing to ship — tell the user and stop.

If the tree is clean but there are unpushed commits, skip to Step 3 (push only).

## Step 2 — Commit

1. Run `git diff --stat` and `git diff --cached --stat`. If untracked files exist, also run `git status` to see them.
2. **Watch for things that shouldn't be committed.** Repo gitignore covers `.env`, `.DS_Store`, `.claude/`, `build/`, `*.xcarchive`, `*.ipa`, `xcuserdata/`, `supabase/.temp/`. If something suspicious surfaces (a new `.env*`, a `.p8`, `*.p12`, `*.mobileprovision`, anything in `~/.appstoreconnect/`, a credentials file), STOP and ask before proceeding.
3. Draft a short commit message (1–2 sentences) reflecting the actual changes. Lead with the change type (`add`, `fix`, `refactor`, `tweak`).
4. Stage and commit with the standard footer:
   ```
   git add -A
   git commit -m "$(cat <<'EOF'
   <your message>

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
   EOF
   )"
   ```

## Step 3 — Push

```
git push origin main
```

If push fails because the remote moved: `git pull --rebase origin main` and retry once. If still failing, STOP — there's a conflict the user needs to resolve.

## Step 4 — Report

Tell the user:
- The commit SHA (short) that was pushed
- That GitHub Actions will pick it up and upload to TestFlight in ~10–15 minutes
- The workflow run URL: `https://github.com/jordanar189/tarsa-fantasy/actions`

If the change touched only files outside the workflow's `paths` filter (only `*.md`, `supabase/**`, `README`, etc.), tell the user the workflow will NOT trigger and they have nothing to wait for.

## Rules

- Do not run `scripts/upload-testflight.sh` from this skill — that's the local-only fallback.
- Do not change `MARKETING_VERSION` — the user controls that in Xcode.
- Do not modify `.env`, `.github/workflows/testflight.yml`, or anything in `~/.appstoreconnect/`.
- One-shot workflow. Do not retry if a step fails — let the user decide.
