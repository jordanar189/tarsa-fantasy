# Requests Archive

Completed requests, appended over time. Most recent at the bottom.

## REQ-001 — Allow entry to draft room before draft begins — Archived 2026-05-17
- **Request Date:** 2026-05-17
- **Details:**
  allow users to enter draft room before draft begins
- **Conversation:**
  - [2026-05-17 23:09] Claude: Completed. Removed the `startsAt <= now` guard from `canEnter` in `LeagueDetailView.swift` so the "Open draft room" button appears as soon as a draft is scheduled, regardless of how far away the start time is. When entering early, the banner still shows the "Starts in X" countdown above the button so users know when it goes live. Inside the room, the existing scheduled-status header already renders the full countdown and commissioner start controls. Also updated the schedule-section footer in `DraftSetupView.swift` to tell owners they can enter any time after scheduling.
