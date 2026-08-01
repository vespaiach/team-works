# Team Works — UI spec

_Interface spec for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md), [permissions.md](./permissions.md) and [data-model.md](./data-model.md). Status: approved 2026-07-31._

This document covers the screen inventory, the React Aria Components mapping, design tokens, breakpoints, board semantics, and the states the brief never covers: empty, loading, error, offline, and permission-disabled. It does not cover the roadmap's internal date/progress logic (owned by `roadmap-view.md`) or notification content and delivery (owned by `notifications.md`).

---

## 1. Layout & navigation

A persistent left sidebar, present on every authenticated screen:

- Workspace name at the top.
- Project list, sorted by `Project.sort_order`, each row showing its color swatch, key, and name. Clicking a project opens its Board.
- Below the project list: **Roadmap** and **Notifications** links (the latter with an unread-count badge).
- At the bottom: the current user's name/avatar, opening a menu with **Profile** and **Sign out**.

On mobile (below the `md` breakpoint, §2), the sidebar is hidden by default and opens as a full-height slide-out drawer via a menu button in a slim top bar. The top bar also carries the current screen's title.

There is no separate projects-index screen — the sidebar's project list is the only project switcher, so it is always visible on desktop and one tap away on mobile.

---

## 2. Design tokens

Single light theme for v1 (see §8 — dark mode is out of scope). System font stack throughout: `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif` — no web font loading.

**Color roles**

| Role | Value | Used for |
| --- | --- | --- |
| `background` | `#FFFFFF` | page background |
| `surface` | `#F7F8FA` | cards, panels, sidebar |
| `border` | `#E4E7EC` | dividers, input borders, card outlines |
| `text-primary` | `#1A1D21` | body text, titles |
| `text-secondary` | `#6B7280` | metadata, timestamps, placeholders |
| `accent` | `#5B5FEF` | primary buttons, links, focus rings, selected states |
| `danger` | `#E5484D` | destructive actions, error toasts, overdue due dates |
| `success` | `#12B76A` | done status, success toasts |
| `warning` | `#F5A524` | medium priority, warning banners |

**Status and priority colors** (issue `status`, `priority`, and project `status` all reuse this small set rather than each defining their own):

| Value | Color |
| --- | --- |
| `backlog` | `#9CA3AF` (gray) |
| `todo` | `#64748B` (slate) |
| `in_progress` | `#3B82F6` (blue) |
| `done` | `#12B76A` (green, = `success`) |
| `canceled` | `#EF4444` (red) — card/row title also renders with strikethrough |
| priority `none` | `#9CA3AF` |
| priority `low` | `#60A5FA` |
| priority `medium` | `#F5A524` (= `warning`) |
| priority `high` | `#FB923C` |
| priority `urgent` | `#E5484D` (= `danger`) — also gets a distinct icon, since color alone isn't a sufficient signal at this severity |

Project `status` (`planned`/`active`/`paused`/`completed`/`canceled`) uses the same five-color mapping by position (planned≈backlog, active≈in_progress, paused≈todo, completed≈done, canceled≈canceled), so a user learns the color language once.

**Type scale**

| Token | Size / line-height | Used for |
| --- | --- | --- |
| `text-xs` | 12px / 16px | timestamps, badges, meta labels |
| `text-sm` | 13px / 18px | secondary body text, table cells |
| `text-base` | 14px / 20px | primary body text, inputs, buttons |
| `text-md` | 16px / 24px | card titles, section headers |
| `text-lg` | 20px / 28px | page titles |

**Spacing scale (px):** 4, 8, 12, 16, 24, 32, 48 — Tailwind-compatible, since Tailwind is already the project's styling foundation.

**Breakpoints** — expressed as Tailwind's own default breakpoints rather than inventing new ones:

| Name | Range |
| --- | --- |
| mobile | below `md` (< 768px) |
| tablet | `md` to below `lg` (768–1023px) |
| desktop | `lg` and up (≥ 1024px) |

---

## 3. React Aria Components mapping

| UI need | Component(s) |
| --- | --- |
| Modals (confirm delete, invite user) | `DialogTrigger` + `Modal` + `Dialog` |
| Text input (issue title, project name, comment body) | `TextField`, `TextArea` |
| Status / priority quick-change (small fixed set, click the badge) | `MenuTrigger` + `Menu` + `Popover` |
| Assignee / milestone / project-lead pickers (searchable, larger sets) | `ComboBox` |
| Label multi-apply | `ListBox` (multiple selection) inside a `Popover` |
| Due date, milestone target date, project start/target date | `DatePicker` / `DateField` |
| Sidebar project list, notifications list | `GridList` (keyboard-navigable, supports a selected row) |
| Issue detail sections (Sub-issues / Attachments / Comments) | `Tabs` |
| Card / row overflow actions | `MenuTrigger` + `Menu` |
| Error and success notices | `Toast` / `ToastRegion` (or, if the pinned React Aria version predates these, a hand-rolled `aria-live` region following the same pattern) |
| Board drag-and-drop | **`dnd-kit`, not React Aria** — React Aria Components has no drag primitive suited to a multi-column board; this is the one interaction outside the RAC mapping |
| @mention autocomplete inside comments/description | Custom-built — no RAC primitive covers in-text autocomplete; a positioned `Popover` + `ListBox` anchored to the caret |

---

## 4. Screen inventory

### 4.1 Sign in / magic-link confirm
Email entry form → "check your email" confirmation. The magic link itself opens a confirmation page (`GET`, renders and consumes nothing) with an explicit "Sign in" button (`POST`, redeems) — per [auth.md](./auth.md), so a mail scanner prefetching the link can't burn it. On success, redirects to the last-viewed project's board, or the first project by `sort_order` if none is remembered.

**Expired or already-used link.** The confirmation page detects this server-side (the `POST` redemption fails) and replaces the "Sign in" button with a message ("This link has expired or was already used") and a link back to the sign-in form to request a new one. No separate route — it's a state of the same confirmation screen, not a distinct page.

### 4.2 Board (per project)
Detailed in §5. Route per project (`/projects/:key`).

### 4.3 Roadmap (workspace-wide)
Projects and milestones as bars/markers on a Frappe Gantt timeline, with Month/Quarter/Year zoom controls. Dragging a bar is enabled only for admins (disabled per §7's permission-disabled convention for everyone else). Date-gap handling, progress derivation, and mobile-specific behavior are owned by `roadmap-view.md` — this spec only fixes where the screen lives and that it's read-only for non-admins.

### 4.4 Issue detail
Dedicated route (`/projects/:key/issues/:number`, e.g. `/projects/WEB/issues/142`) rather than a modal overlay, so `WEB-142` deep-links directly — simpler than reconciling a modal-over-board state with direct navigation.

Two-pane on tablet/desktop: main column (title, description, sub-issues, comments, attachments) and a meta sidebar (status, priority, assignee, labels, milestone, due date). Single column on mobile, meta fields collapsed into a summary strip above the comments.

- **Title** — inline-editable text field.
- **Description** — plain text in a `TextArea`, preserved line breaks, no markdown rendering (no markdown dependency is in the current stack).
- **Status / priority** — click-to-change `Menu`.
- **Assignee** — `ComboBox`; project members listed first, then the rest of the workspace, deactivated users excluded (permissions.md §12).
- **Labels** — multi-select popover; admin-curated set, applied by anyone with write access.
- **Milestone** — `Select`, scoped to the issue's own project, plus a "no milestone" option.
- **Sub-issues** — a list embedded in the main column. "Add sub-issue" is only offered on a top-level issue — hidden on a sub-issue's own detail page, since nesting is one level deep. Each row shows status, assignee, title, and links to its own detail page.
- **Comments** — plain text, @mention autocomplete (§3), newest at the bottom.
- **Attachments** — drag-and-drop zone plus a file-picker button; list shows filename, size, uploader. Download triggers the authorized-download endpoint `attachments.md` owns; this spec only fixes the list/upload UI.
- **Assigned non-member state** (permissions.md §7): if the current user is assigned to the issue but not a member of its project, every editable control above renders disabled with the permission-disabled banner (§7) naming the project they'd need to be added to.

### 4.5 Project settings (admin)
Name, description, start/target date, status, color, lead — plus member management (add/remove via a searchable list of the workspace) and milestone management (create/edit/reschedule/delete). Delete-project control is disabled with an inline note unless the project's `status` is already `canceled`.

### 4.6 Workspace settings (admin)
Three tabs: **Members** (invite by email, set role, deactivate), **Pending invites** (every unaccepted `invite` row, with a resend/revoke action per row and its expiry shown — this is the pending-invite admin page auth.md §12 owes to this doc), **Labels** (create/edit/delete the workspace-wide set). Non-admins never see this screen in the sidebar at all — it's the one piece of navigation that's actually permission-gated, since there's nothing partial to show a member here.

### 4.7 Notifications
Reverse-chronological list, unread visually distinguished, each row linking to the relevant issue. Mark-as-read on open, plus a "mark all read" action. Empty state: "No notifications yet."

### 4.8 Profile
Name and avatar, editable by their owner. No password field — auth is magic-link only.

---

## 5. Board semantics

Five columns, always: Backlog · Todo · In Progress · Done · Canceled, left to right — nothing hidden by default, consistent with the "nothing disappears" read model.

**Grouping.** A control in the board header switches what defines a column: **Status** (default), **Assignee**, or **Priority**. Regrouping changes what a column *is* — e.g. under Assignee grouping, each column is a person and status renders as a small colored badge on the card instead. There is one underlying `sort_order` per issue, project-wide, so reordering under any grouping shifts relative position under the others too (data-model.md §5).

**What a drag changes.**
- Reordering within a column: a single `moveIssue` call recomputing `sort_order` between the two neighbors at the drop point. The grouping field (status/assignee/priority) is unchanged.
- Dragging to a different column: the same `moveIssue` call also sets whichever field the current grouping represents (status, assignee, or priority) to match the target column, in addition to the new `sort_order`.

**Cards** show title, `WEB-142` id, a priority icon, assignee avatar, label chips, and due date (rendered in `danger` if overdue).

**Mobile** keeps the same column layout at reduced width; the board scrolls horizontally, roughly snapping to one column per screen, so the drag-and-drop model doesn't need a separate mobile-only interaction.

**Non-member of the project.** The whole board renders read-only: cards are not draggable (no grab affordance), and the permission-disabled banner (§7) appears once, at the top of the board, rather than on every card.

---

## 6. Roadmap

Layout only — the internal mapping of projects/milestones to Gantt bars, undated-record handling, `progress` derivation, and mobile-specific behavior all belong to `roadmap-view.md` (concept-brief.md §5 already names these as open). What this spec fixes: the screen lives at `/roadmap` in the sidebar, offers Month/Quarter/Year zoom, and is read-only for non-admins per §4.3.

---

## 7. Cross-cutting states

**Empty.** Each screen with a list defines its own one-line empty message (e.g. a board column with no cards just looks empty — no message needed there; Notifications says "No notifications yet"; a project with no milestones says so in Project Settings).

**Loading.** A single full-screen loading state while Zero performs its first-ever sync after sign-in, when the local store is empty. After that, every screen renders instantly from the local store — no per-screen or per-query spinners anywhere else.

**Error.** A rejected write surfaces as a toast naming what failed and why (e.g. "Only project members can edit issues in Website Redesign") — per permissions.md §9. The optimistic UI reverts on its own; no separate error screen.

**Offline.** Reads keep working against the local store. Every write-capable input renders in the permission-disabled state below, with the reason "Changes need a connection."

**Permission-disabled.** Any control the current user cannot use (non-member write attempts, offline writes, an admin-only Gantt drag) renders disabled with a persistent inline note explaining why, placed next to the control or, for a whole read-only screen, once at the top. Never a tooltip-only or hover-only explanation, since it must work identically on touch and desktop. This is the general form of the assigned-non-member treatment in §4.4.

**Two-phase cascading delete.** A project or issue delete cascades in Postgres; the client's optimistic mutator can't reproduce that, so dependent rows settle a moment later than the target ([data-model.md](./data-model.md) §4). This is expected behavior, not a bug, and each case already has a UI treatment that hides the gap rather than exposing it:
- **Project delete** — the UI navigates away from the project (to the sidebar's next project, or the roadmap if none remain) the instant the delete is confirmed. Nothing that would flicker is still on screen.
- **Issue delete** — sub-issues are promoted to top-level, not cascaded; the client-side mutator performs that promotion locally, so the board/list already shows the correct result before the server round-trip lands.
- **Comment or label delete** — cascaded rows (attachments, notifications, join rows) are few and not rendered next to the thing being deleted. No special handling — they're simply gone a moment later.

---

## 8. Out of scope for v1

Noted so the gaps above aren't mistaken for oversights.

- Dark mode or user-selectable themes — single light theme only.
- A keyboard command palette (already excluded, concept-brief.md §2).
- Search or filtering beyond the board's grouping control.
- Markdown or rich-text rendering in descriptions and comments — plain text only, since no markdown library is in the current stack.
- An activity log / audit trail on issues — consistent with permissions.md §11 excluding an audit log of permission changes.

---

## 9. Changes this spec requires elsewhere

This document discharges every item other specs deferred to "ui-spec.md, when written":

**From permissions.md §12:**

- A convention for controls disabled by permission, with the reason surfaced rather than a dead button — §7.
- The assigned-non-member state on issue detail — §4.4.
- An assignee picker and mention autocomplete that list project members first and the rest of the workspace below, excluding deactivated users — §4.4, §3.

**From auth.md's deferred-items table:**

- The sign-in, verify-confirmation and expired-link screens — §4.1.
- The pending-invite admin page — §4.6.

**From data-model.md's deferred-items table:**

- The two-phase settle after a cascading delete, as a UI state — §7.

No edits to permissions.md, data-model.md, auth.md, or team-works-concept-brief.md are required — each already anticipated this doc rather than asserting something it now contradicts.
