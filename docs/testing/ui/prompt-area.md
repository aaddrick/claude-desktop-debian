# UI — Code Tab Prompt Area

The prompt input area is where users type messages, attach files, pick model and permission mode, and trigger send/stop. Related functional tests: [T18](../cases/code-tab-foundations.md#t18--drag-and-drop-files-into-prompt), [T32](../cases/code-tab-workflow.md#t32--slash-command-menu).

## Text input

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Input field | Bottom center of session pane | Single-line on focus, expands to multi-line as user types | — |
| Placeholder text | Empty state | Helpful hint ("Type to message Claude...") | — |
| Cursor caret | Inside input | Blinks; visible against any background | — |
| Multi-line autosize | Type a long message | Input grows up to a max height, then scrolls | — |
| Word wrap | Long text | Wraps at field width without horizontal scroll | — |
| Paste plain text | `Ctrl+V` after copying text | Inserts at cursor | — |
| Paste image | `Ctrl+V` after copying an image | Attaches as file (see attachments below) | — |
| `Enter` to send | Press Enter | Submits prompt | — |
| `Shift+Enter` for newline | Press Shift+Enter | Inserts newline, doesn't submit | — |
| `Esc` | Press Esc when prompt has content | DE-dependent; typically does nothing in input | — |
| IME composition | Compose a CJK character | Composition UI renders correctly above the input | Fcitx5/IBus integration |

## Attachments

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Attachment button | Left of input (paperclip icon) | Click opens native file chooser | Wayland: portal-backed |
| File-attached chip | Above or inside input | Shows filename + remove (X) button | — |
| Multiple attachments | Attach 3+ files | Each shows as a separate chip; stacked if needed | — |
| Image preview thumbnail | Image attachments | Shows small thumbnail | — |
| PDF preview | PDF attachments | Shows generic PDF icon + filename | — |
| Drag-drop overlay | Drag a file from file manager into the prompt | Overlay highlight indicates drop zone; release attaches ([T18](../cases/code-tab-foundations.md#t18--drag-and-drop-files-into-prompt)) | — |
| `@filename` autocomplete | Type `@` in prompt | Dropdown shows matching project files | Local and SSH only |

## `+` menu (skills, plugins, connectors)

| Element | Position in menu | Expected | Notes |
|---------|------------------|----------|-------|
| `+` button | Adjacent to attachment button | Click opens menu | — |
| **Slash commands** entry | Top of menu | Opens slash command picker (same as typing `/`) | Crosses with [T32](../cases/code-tab-workflow.md#t32--slash-command-menu) |
| **Skills** entry | Mid-menu | Opens skill browser | — |
| **Connectors** entry | Mid-menu | Opens connector picker / status | Crosses with [T34](../cases/code-tab-handoff.md#t34--connector-oauth-round-trip) |
| **Plugins** entry | Mid-menu | Opens installed plugin list | Crosses with [T11](../cases/extensibility.md#t11--plugin-install-anthropic--partners), [T33](../cases/extensibility.md#t33--plugin-browser) |
| **Add plugin** subentry | Under Plugins | Opens plugin browser | — |

## Slash menu (triggered by typing `/`)

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Menu container | Above prompt input | Modal-like overlay, scrollable | — |
| Built-in commands section | Top of list | Lists `/btw`, `/compact`, etc. | — |
| Project skills section | Mid-list | Lists skills from `.claude/skills/` | — |
| User skills section | Mid-list | Lists skills from `~/.claude/skills/` | — |
| Plugin skills section | Bottom-list | Lists skills from installed plugins | — |
| Filter by typing | Type after `/` | Narrows the list | — |
| Selected item insertion | `Enter` or click | Inserts highlighted token in prompt | — |
| `Esc` to dismiss | Press Esc | Closes menu, keeps `/` typed | — |

## Pickers next to send button

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Model picker | Right of input | Dropdown of Sonnet, Opus, Haiku (per current plan availability) | `Cmd+Shift+I` opens |
| Permission mode picker | Right of input | Dropdown of Ask, Auto accept, Plan, Auto, Bypass | `Cmd+Shift+M` opens |
| Effort picker (when applicable) | Right of input | Dropdown of effort levels for adaptive-reasoning models | `Cmd+Shift+E` opens |
| Send button | Far right | Click submits prompt | — |
| Stop button | Replaces Send while Claude responding | Click interrupts current response | `Esc` shortcut equivalent |
| Usage ring | Adjacent to model picker | Shows context window usage + plan usage | Click for details |

## Failure modes to watch for

| Symptom | Likely cause | Notes |
|---------|--------------|-------|
| Drag-drop overlay doesn't appear | Electron drag-drop event not firing on Wayland | Try X11 fallback to isolate |
| `@filename` autocomplete returns empty | Project-folder access not granted; folder picker [T17](../cases/code-tab-foundations.md#t17--folder-picker-opens) failed silently | Verify env pill shows the right folder |
| Slash menu shows wrong skills | Settings shared between desktop and CLI ([T36](../cases/extensibility.md#t36--hooks-fire), [T37](../cases/extensibility.md#t37--claudemd-memory-loads)) | Check `~/.claude/skills/` content vs what's listed |
| Send button greyed out unexpectedly | Permission mode or model not loaded | Refresh; check model dropdown |
| IME composition broken | Electron IME pipeline regression | Test with simpler Electron app |
