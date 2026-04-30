# UI — Connectors & Plugins

Connector picker, connectors list, plugin browser, plugin manager. Related functional tests: [T11](../cases/extensibility.md#t11--plugin-install-anthropic--partners), [T33](../cases/extensibility.md#t33--plugin-browser), [T34](../cases/code-tab-handoff.md#t34--connector-oauth-round-trip), [S27](../cases/extensibility.md#s27--plugins-install-per-user-not-into-system-paths).

## Connector picker (in-session)

Triggered by `+` → **Connectors** in the prompt area.

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Connectors menu | Opened from `+` button | Lists configured connectors + "Manage connectors" entry | — |
| Per-connector row | Menu item | Name, status indicator (connected / not configured), action button | — |
| **Manage connectors** entry | Bottom of menu | Opens Settings → Connectors | Crosses with [`settings.md`](./settings.md#connectors) |
| Empty state | When no connectors configured | Helpful prompt with "Add connector" call to action | — |

## Connectors list (Settings → Connectors)

See [`settings.md`](./settings.md#connectors) for the surface.

## Add-connector flow

Triggered from the connector picker or Settings.

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Connector catalog | Modal body | Searchable list (Slack, GitHub, Linear, Notion, Google Calendar, etc.) | — |
| Per-connector tile | Catalog entry | Logo, name, short description | — |
| **Connect** button | Per tile | Initiates OAuth flow ([T34](../cases/code-tab-handoff.md#t34--connector-oauth-round-trip)) | Click → `xdg-open` to provider |
| OAuth in-app overlay (if used) | Replaces system browser handoff in some flows | Embedded login pane | — |
| Permission consent screen | OAuth provider side | Provider's UI; not under our control | — |
| Callback completion | After OAuth completes | Returns to Claude Desktop, connector now in list | If the URL scheme handler is broken, user is stranded in browser |
| Custom connector entry point | Catalog bottom | "Add custom connector via remote MCP" link | — |

## Plugin browser

Triggered by `+` → **Plugins** → **Add plugin**, or from sidebar **Customize** → **Plugins**.

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Plugin browser modal | Opened from menu | Searchable marketplace catalog | — |
| Marketplace selector | Top of modal | Default: Anthropic official; user-configured marketplaces also visible | — |
| Per-plugin tile | Catalog body | Name, author, description, install count | — |
| **Install** button | Per tile | Click installs to `~/.claude/plugins/` ([T11](../cases/extensibility.md#t11--plugin-install-anthropic--partners), [S27](../cases/extensibility.md#s27--plugins-install-per-user-not-into-system-paths)) | — |
| Plugin scope selector | Per install | User / Project / Local-only | — |
| Install progress indicator | During install | Spinner + "Installing X..." text | — |
| Install success state | After install | Confirmation; plugin now in **Manage plugins** | — |
| Install error state | On failure | Error message identifying the cause (network, signature, conflict) | — |

## Manage plugins

Triggered by `+` → **Plugins** → **Manage plugins**.

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Installed plugins list | Modal body | One row per installed plugin | — |
| Per-plugin row | List item | Name, version, scope (User / Project / Local), enable toggle, uninstall button | — |
| Enable toggle | Per row | Toggles plugin on/off without uninstall | — |
| **Uninstall** button | Per row | Removes plugin files from `~/.claude/plugins/` | Confirmation expected |
| Plugin skills sub-list | Expand row | Lists skills, agents, hooks, MCP servers, LSP configs the plugin contributes | — |

## Failure modes to watch for

| Symptom | Likely cause | Notes |
|---------|--------------|-------|
| Connect OAuth doesn't return to app | Custom URI scheme not registered ([T34](../cases/code-tab-handoff.md#t34--connector-oauth-round-trip)) | `xdg-mime query default x-scheme-handler/claude` |
| Plugin browser empty | Marketplace fetch failed; offline | DevTools network panel |
| Install progress stalls | Network / signature verification | Launcher log; check `~/.claude/plugins/.partial/` for incomplete downloads |
| Plugin installed but skills don't appear | Slash menu cache stale; restart session | — |
| Uninstall leaves files | Filesystem permissions; some plugin files owned by root | `find ~/.claude/plugins/ -not -user $USER` |
| Connector "Connected" but tools fail | Token expired; backend refuses; needs reconnect | Disconnect → reconnect |
