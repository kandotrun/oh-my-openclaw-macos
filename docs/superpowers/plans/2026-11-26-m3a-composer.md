# Milestone 3a: Composer and Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shell interactive. It needs an IME-safe composer with attachments, a model and thinking-level menu, send and stop, inline approval and question cards, retry for uncertain sends, and a running-turn indicator.

**Architecture:**

- Pure decisions live in `App/Platform` and are tested with `swift test`: `ComposerKeyRouting` and `AttachmentImport`.
- AppKit stays in a thin `NSTextView` adapter. SwiftUI views call the existing `AppModel` API (`draftText`, `addAttachment`, `send`, `stop`, `setModel`, `setThinking`, `resolvePrompt`, `retryPending`).
- Milestone 3 is split in two. This PR (3a) makes the app usable. 3b adds the work log projection and timeline.

**Tech Stack:** SwiftUI and AppKit (`NSTextView`, `NSPasteboard`), ImageIO, UniformTypeIdentifiers, Swift Testing, XCTest UI tests.

## Tasks

### Task 1: Key routing (TDD)

`ComposerKeyRouting.action(keyCode:modifiers:hasMarkedText:)` returns `.send`, `.insertNewline`, or `.passThrough`:

- Marked text always passes through, so the input method commits a conversion.
- Return or Enter with no modifiers, or with Command, sends.
- Shift or Option inserts a newline.
- Control passes through.
- Other keys pass through.

### Task 2: Attachment import (TDD)

- `AttachmentImport.image(data:fileName:limit:)` keeps PNG and JPEG bytes within the limit. It re-encodes other formats, or oversized images, as JPEG at 2048 px at most, and fails when the result still exceeds the limit.
- `AttachmentImport.file(url:limit:)` reads a security-scoped file. It rejects anything over 25 MB, derives the MIME type from `UTType`, and routes images through `image`.

### Task 3: Composer view

- `ComposerTextView` (`NSViewRepresentable` over an `NSTextView` subclass) does the following:
  - routes keys through `ComposerKeyRouting` using `hasMarkedText()`
  - never replaces text while marked text exists
  - grows from 1 to 8 lines
  - routes pasted or dropped files and images to attachments
- `ComposerView` holds:
  - the attachment tray (thumbnails or chips, with remove)
  - the attach button (`fileImporter`)
  - the `<model> <level>` menu
  - send, or a red stop while a run is active (Command-.)
  - the placeholder "メッセージを入力（Return で送信、Shift-Return で改行）"

### Task 4: Timeline interaction

- Approval cards show:
  - the title and detail (exec commands in monospace)
  - Allow once, Allow always, and Deny, mapped from `allowedDecisions`
- Question cards show options, or a text or secure field.
- Uncertain or failed user messages get a retry button.
- A running turn shows "Working for N s" with a thinking indicator.
- Command-N creates a new side thread (`newSideChat`) until projects land in milestone 4.

### Task 5: Proof

- `just test`, `just lint`, `just build`, `just uitest`.
- A UI test types into the composer in the demo, presses Return, and sees the user message and the streamed reply.
- A manual IME check selects the Japanese input source, types romaji, and presses Return. The first Return commits the conversion and does not send; the second Return sends.
