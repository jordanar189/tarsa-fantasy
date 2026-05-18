# Requests Archive

Completed requests, appended over time. Most recent at the bottom.

## REQ-002 — Fix images not sending in chat — Archived 2026-05-18
- **Request Date:** 2026-05-18
- **Details:**
  pictures dont send in chat. i can add them to my message but when i tap send, it just loads for a second and then nothing sends
- **Conversation:**
  - [2026-05-18 12:15] Claude: Completed. Two bugs fixed in `DMChatView.swift` and `LeagueChatView.swift`: (1) Both views had an `error` state variable that was populated in catch blocks but no `.alert` modifier to surface it — upload failures were silently swallowed, leaving the user with no feedback and no message sent. Added a "Couldn't send" alert to both views. (2) iOS photos are typically HEIC format, which can fail to upload or render correctly through some CDN configurations. `loadPickedImage` now converts the raw photo data to JPEG (85% quality) before setting `pendingImage`, ensuring the uploaded file is universally compatible with Supabase storage and `AsyncImage` rendering.

## REQ-001 — Allow entry to draft room before draft begins — Archived 2026-05-17
- **Request Date:** 2026-05-17
- **Details:**
  allow users to enter draft room before draft begins
- **Conversation:**
  - [2026-05-17 23:09] Claude: Completed. Removed the `startsAt <= now` guard from `canEnter` in `LeagueDetailView.swift` so the "Open draft room" button appears as soon as a draft is scheduled, regardless of how far away the start time is. When entering early, the banner still shows the "Starts in X" countdown above the button so users know when it goes live. Inside the room, the existing scheduled-status header already renders the full countdown and commissioner start controls. Also updated the schedule-section footer in `DraftSetupView.swift` to tell owners they can enter any time after scheduling.
