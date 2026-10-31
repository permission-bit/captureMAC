# Manual recording checklist

These checks require an interactive macOS session and the user's permission. Automated tests never grant permissions or capture the desktop.

1. Launch `build/Still.app`. Without screen permission, the app shows an explanation without automatically requesting access. Click **Allow access**, grant access in System Settings, and restart if requested.
2. Select a display, then a window. Refresh each: the preview and source title must match. Still's own windows must not appear as capture sources.
3. Record five seconds with H.264 at 1080p/30 fps and audio off. Verify the countdown and optional app hiding. Stop with ⇧⌘R from another app. The resulting MP4 must play, have approximately the expected duration, and exclude Still's interface.
4. Stop through the menu bar, then record again. Late callbacks from the first session must not affect the second.
5. Enable system audio and play a local audio file. Verify sound in the result. Also enable the microphone, allow access, and speak; verify both sources in QuickTime. Disable the microphone and confirm that it is no longer captured.
6. Set a ten-second countdown and cancel before it ends. No recording should be created. Start again, including with the countdown disabled.
7. Enable a one-minute time limit. Verify automatic stop and playable output after approximately 60 seconds. Reset the limit to **Never**.
8. Test HEVC and 60 fps. Verify codec and frame rate in QuickTime's Movie Inspector. Also test window capture and Retina resolution.
9. Test cursor visibility and click highlighting. Move the selected window during capture. Close it: the app should finish or show an actionable error, then allow selection of a new source.
10. Save a screenshot. Check source resolution and exclusion of Still for display captures. Preview, share, copy, and reveal it in Finder. Move it to Trash and restore it with Finder.
11. Press ⌘Q while recording. **Keep recording** must leave the recording running. **Save & Quit** must wait for output finalization; the result must remain available after relaunch.
12. Close the main window and reopen it from the menu bar. ⇧⌘R must toggle once per press, including when Still is frontmost.
13. Deny or revoke screen permission. Verify an actionable error and no stuck recording state. A non-writable output folder must also report a failure without a success notice.
14. Test light/dark mode and minimum window size. Use VoiceOver and keyboard navigation to reach the source selector, recording controls, and settings.

## Languages

1. With **System language** selected, launch under supported macOS languages, including regional variants such as French (Canada), Chinese (Taiwan), and English (US). Check matching and English fallback for unsupported languages.
2. Select each language in **Settings → Language**. Recording controls, custom app menus, menu bar actions, library labels, and settings should update immediately without restarting.
3. Relaunch Still and verify that the chosen language persists. Switch back to **System language** and verify that it follows macOS again.
4. Select Arabic. Verify a right-to-left sidebar, navigation, and settings layout. Check that shortcuts, filenames, window titles, and technical paths remain readable.
5. Inspect long French, Russian, Hindi, and German labels at minimum window size. Verify that text wraps and all actions remain accessible.
6. Check countdown values, durations, media dates, library counts, notices, and error messages for missing keys or visible format placeholders.
7. Change language, open a media preview, and inspect its context menu and share action. macOS-owned dialogs are expected to retain the system's app language.
8. During a recording or countdown, the language picker must be disabled. The recording and saved settings must remain unaffected.
9. Verify localized permission descriptions with macOS app languages. Never reset a user's existing permissions automatically as part of a test.

## Conversion and discard

- Use **Convert…** in the library context menu and preview. Export GIF, PNG/JPEG frames, HEIC/TIFF/BMP images and MP4/MOV/M4V videos. Confirm results open, originals stay unchanged, and exported files saved to the library folder appear in the library.
- Choose a nonzero GIF start time and inspect its first frame, duration, loop, size and speed. Test cancel during export, an invalid start time, unsupported encoders and an existing filename. No staging file should remain after an error or cancellation.
- While recording, use the menu bar icon → **Delete current recording**. The recording stops, the output disappears after finalization, and it never appears as a saved library item. Start another recording and verify that it saves normally. Also test cancelling the countdown through the same menu action.

## Recording folders

Before recording, choose Save location and use the native dialog to create a nested folder inside Aufnahmen. Record and take a screenshot; both must appear there. Relaunch and verify the destination persists. In Library, create folders, navigate into them and back, and set the current folder as the recording destination. Verify Finder opens the browsed folder. Switching destinations during recording must be disabled; outside folders and symlinks leading outside Aufnahmen must be rejected.
