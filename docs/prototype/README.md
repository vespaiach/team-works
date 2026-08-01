# Handoff: Team Works — project & roadmap tracker (v1 UI)

## Overview

**Team Works** is a small, self-hosted, Linear-inspired work tracker for a single team of fewer than 20 people. Work lives as **issues**; issues roll up into **projects**; projects carry **milestones**; everything is visible on a **roadmap**. It is milestone/roadmap-driven (not sprint-driven), local-first, and invite-only with per-project write access.

This package contains a **high-fidelity HTML prototype** of the v1 UI plus the **seven approved product specs** that are the source of truth for data, auth, permissions, roadmap logic, and state machines. The prototype covers: the app shell, per-project Kanban board, full-page issue detail, workspace roadmap, notifications, sign-in / magic-link, and project & workspace settings.

## About the Design Files

The file `Team Works.dc.html` is a **design reference created in HTML** — a working prototype showing intended look and behavior. **It is not production code to copy.** It is authored as a self-contained "Design Component" (custom `<x-dc>` runtime + inline styles + a single logic class); that authoring format is an artifact of the design tool, **not** a prescription for the target stack.

Your task is to **recreate this UI in the real Team Works codebase**, whose stack is already decided by the specs (see `team-works-concept-brief.md §5`):

- **Next.js (App Router) + React**, built on **Adobe React Aria Components**, responsive (mobile + desktop from one codebase), **Tailwind** for styling.
- **`dnd-kit`** for board drag-and-drop; **Frappe Gantt** (core `frappe-gantt`) for the roadmap.
- **Zero (Rocicorp)** as the data/sync layer (reactive `useQuery` + optimistic custom mutators); **Drizzle** + **PostgreSQL 15+** on the server.
- **Hand-written** auth (magic-link, `jose` + `nodemailer`) — **not** Auth.js.

Treat the HTML as the spec for **pixels, layout, and interaction**; treat the seven `.md` specs as the authority for **everything behind the UI**. Where the prototype and a spec disagree, the spec wins (the prototype takes documented liberties — see "Known deviations" below).

The prototype's `ui-spec.md` §2 defines a **neutral light theme** (white bg, indigo `#5B5FEF` accent, system fonts). The team chose instead to **keep a warm "Cream & Sugar" brand mapped onto the spec's token roles** — that mapping is documented in "Design Tokens" below and is the intended visual direction. Everything structural still follows `ui-spec.md`.

## Fidelity

**High-fidelity.** Colors, spacing, radii, type sizes, and interactions are all intentional. Recreate pixel-accurately with the codebase's React Aria + Tailwind primitives, using the token table below. Two caveats:
- **Desktop-first.** The prototype implements the desktop layout only. The mobile/responsive behavior is specified in `ui-spec.md §1/§2/§5` and `roadmap-view.md §6` and must be built from those (drawer sidebar below `md`, horizontally-scrolling board, read-only roadmap on touch).
- **Drag is visual-only** in the prototype. Real board DnD (`dnd-kit`) and roadmap reschedule (Frappe Gantt `onDateChange`) must be wired to Zero mutators per the specs.

---

## Screens / Views

All screens live inside a persistent **app shell** (sidebar + main), except **Sign in**, which is full-screen. The prototype switches screens via a `view` state field; in the real app these are **routes** (`ui-spec.md §4` fixes each route).

### App shell — sidebar
- **Width** 262px, `flex:none`. **Background** `#EFE6D4`, right border `1px #E1D3B9`, padding `14px 12px 12px`.
- **Workspace switcher** (top): 30×30 rounded-9px accent tile with a 4-square glyph, "Team Works" (14px/600) + "Team workspace" (11.5px `#9A8974`), chevron.
- **New issue** button: full-width, accent bg, cream text `#FBF3E7`, plus icon, radius 9px, shadow `0 1px 2px rgba(80,45,15,.18)`.
- **Projects** group (label 11px/600 uppercase, `.06em` tracking, `#A6957E`; a "+" new-project button visible to admins only). Each project row = 9px color swatch + **KEY** (10.5px/600 tabular `#B2A188`, 30px wide) + name (13px) + right-aligned issue count. Active project: `${accent}1e` bg, accent text, 600.
- **Divider**, then workspace links: **Roadmap**, **Notifications** (right-aligned unread count pill in accent), and **Settings** (admins only). Active link: `${accent}1e` bg + accent text.
- **User chip** (bottom, border-top `1px #E1D3B9`): 28px round accent avatar "MA", "Mara Ellison" / role label, sign-out icon button.

### App shell — header
- `flex:none`, padding `13px 22px`, bg `#F6EEDF`, bottom border `1px #E7DAC4`, min-height 58px.
- Left: **title block** (`flex:1;min-width:96px`) — optional color dot + title (17px/700, `-.02em`, ellipsized) with subtitle below (12px `#9A8974`, ellipsized). **This block must flex and ellipsize; siblings are `flex:none`** (a prior version collided here — see the header note).
- Board only: **Group-by** segmented control (Status / Assignee / Priority). Roadmap only: **zoom** control (Month / Quarter / Year). Notifications only: "Mark all read".
- Right (auto-margin): search field (190px, decorative in prototype), overlapping team avatars (28px, `-8px` overlap, 2px `#F6EEDF` ring).

### 1. Sign in / magic-link  — route `/signin`, `/auth/verify`
Full-screen, centered card (`min(420px,94vw)`, `#FFFDF9`, radius 18px, shadow `0 24px 60px rgba(60,38,15,.16)`) on a warm radial background. Four states (`ui-spec.md §4.1`, `auth.md §4`):
- **form** — email input + "Send magic link".
- **sent** — "Check your email" confirmation (mail icon, resend link).
- **verify** — the page the magic link opens: avatar + "Sign in as …" + **Sign in** button. Per `auth.md §4.3` the `GET` **consumes nothing**; only the button's `POST` redeems.
- **expired** — "Link expired or already used" + back-to-sign-in (`ui-spec.md §4.1`).

### 2. Board (per project) — route `/projects/:key`
`ui-spec.md §5`. Horizontally scrolling row of columns (300px wide comfortable / 272 compact, gap 18/12), padding `18px 22px 22px`.
- **Five fixed columns, always**: Backlog · Todo · In Progress · Done · Canceled. Column header = color dot (or avatar when grouped by assignee) + name (13.5px/600) + count + "+".
- **Grouping control** (header) redefines columns: **Status** (default) / **Assignee** (columns are people + Unassigned; card shows a status badge) / **Priority** (columns are Urgent→None; card shows a status badge). There is **one project-wide `sort_order`** per issue; reordering under any grouping shifts the others (`data-model.md §5`).
- **Card**: bg `#FFFDF9`, border `1px #ECE1CF`, radius 11px, padding `14px 15px` (compact `11px 12px`), shadow `0 1px 2px rgba(90,60,25,.05)`; hover → border `#D9C7A9`, shadow `0 4px 12px rgba(90,60,25,.10)`. Contents: priority glyph + `WEB-142` id (11.5px tabular `#B2A188`) + optional status badge; title (13.5px/500, `text-wrap:pretty`); label chips; footer with 24px assignee avatar, due chip (color shifts warm→accent→`#C2492E` as it nears/passes), sub-issue & comment counts. **Canceled issues**: title `#A6957E` + strikethrough, card `opacity:.72`.
- **Priority glyph**: `urgent` = 15px rounded square filled `#C2492E` with a white "!"; others = three ascending bars (7/10/13px), filled bars colored by the priority color, empty `#DBCFB9` (`low`=1, `medium`=2, `high`=3 filled).
- **Permission-disabled**: a non-member of the project, or an offline user, sees a **banner** at the top of the board (`#FBEEE6` bg, `#F0D8C8` border, `#B4552E` text, warning icon) and the board is read-only — no card drag affordance (`ui-spec.md §5/§7`, `permissions.md §7`).
- **Empty column**: just "No issues" muted text.

### 3. Issue detail — route `/projects/:key/issues/:number` (e.g. `/projects/WEB/issues/142`)
`ui-spec.md §4.4`. A **dedicated full page** (not a modal), so `WEB-142` deep-links. Sticky breadcrumb bar (project dot+name / `WEB-31`, copy-link + close/back). Two-pane below (`max-width:1080px`):
- **Main** (`flex:1`, padding `26px 30px 40px`): status + priority pill badges; title (22px/700, strikethrough if canceled); description (14px/1.68 plain text, no markdown); **Sub-issues** (progress bar + list, each row = status dot + id + title + assignee, links to its own detail; "add sub-issue" only on a top-level issue — nesting is one level, `data-model.md §9`); **Comments** (newest at bottom, 28px avatar + name + time + body); **comment composer** (disabled + reason when read-only; "@ to mention, plain text no markdown" hint).
- **Meta rail** (262px, left border `1px #EDE2CF`): Status, Priority, Assignee, Milestone, Due date, Project — each a labelled row (uppercase 10.5px label + value with swatch/avatar). Then an **Attachments** drop zone and a **Created … by …** line. When the viewer can't write, meta rows lose their hover/cursor affordance and the banner appears (`permissions.md §7` assigned-non-member; offline).

### 4. Roadmap — route `/roadmap`
`roadmap-view.md`. Single card (`min-width:860px`, `#FFFDF9`, radius 14px). Header row: 230px "Project" gutter + evenly-divided time columns. **Zoom** (Month = 4 months / **Quarter** = 6 months, default / Year = 4 quarters) — `roadmap-view.md §5`.
- Each **project with both dates** = a bar (`left/width` %, bg `${color}30`, `1px` color border, radius 7px) with a **progress fill** overlay (`opacity:.34`, width = derived %), a label, and the % (`roadmap-view.md §3`: `done / (total − canceled)`, canceled excluded, `0` not `NaN`). **Milestones** with a position render as nested diamond markers beneath their project.
- **Today** = vertical `#C2492E` line spanning the chart. Legend: Progress / Milestone / Today + a drag note.
- **Undated panel** (below chart, `roadmap-view.md §2`): projects/milestones missing a required date, grouped, each naming **what's missing** ("No dates set", "Target date only — needs a start date", "No target date"). Admins get a "Set dates" action.
- **Reschedule** (drag) is **admin-only and desktop-only** (`roadmap-view.md §4/§6`); the prototype shows a resize affordance only when `isAdmin && online`, and the legend note states the read-only reason otherwise. Canceled projects render dimmed, not hidden.

### 5. Notifications — route `/notifications`
`ui-spec.md §4.7`. Single-column reverse-chron list (`max-width:760px`). Each row: unread dot (accent) + actor avatar + "**Actor** action **WEB-31**" line + issue title + project chip + time. Unread rows have `#FBF3E4` bg and heavier weight. Clicking a row **navigates to that issue** and marks it read. "Mark all read" in the header. Empty state: bell icon + "No notifications yet."

### 6. Project settings (admin) — `ui-spec.md §4.5`
`max-width:720px` stack of cards: **Details** (name, description, start/target date, lead, status, color swatches), **Members** (add/remove searchable), **Milestones** (create/edit list), and a **Delete project** card that is **disabled with an inline note unless `status === 'canceled'`** (`data-model.md §4`, `permissions.md §5`). Admin-only screen.

### 7. Workspace settings (admin) — `ui-spec.md §4.6`
Tabbed (`Members` / `Pending invites` / `Labels`), `max-width:760px`. Members: avatar + name + email + role pill + Deactivate (last admin protected, `auth.md §8`). Pending invites: email + role + expiry + Resend/Revoke. Labels: the workspace-wide curated set with color dot + Edit/Delete. Non-admins never see this in nav.

### Modals
**New issue** (accent-scoped to current project; title/description; cycle Status & Priority; assignee chips) and **New project** (name + KEY input + description + color swatches). Both are lightweight in the prototype; the real create flows are Zero mutators (`data-model.md §6` for the issue-number counter).

### Cross-cutting states (`ui-spec.md §7`)
- **Loading** — a single full-screen first-sync spinner ("Syncing your workspace…") while Zero does its first sync; no per-screen spinners after (`appState` prop demonstrates it).
- **Empty / Error / Offline / Permission-disabled** — see per-screen notes; error is a toast naming what failed (`permissions.md §9`), offline disables every write-capable input with "Changes need a connection."

---

## Interactions & Behavior

- **Navigation**: sidebar project → that project's board; Roadmap/Notifications/Settings links; card → issue detail; notification row → issue; breadcrumb → back to board; sign-out → sign-in.
- **Board grouping** and **roadmap zoom** are segmented toggles (state only in prototype).
- **Real behavior to build** (from specs): board DnD via `dnd-kit` calling a single `moveIssue` mutator that sets `sort_order` (fractional index) and, on a cross-column drop, the grouped field (status/assignee/priority) — `data-model.md §5`, `ui-spec.md §5`, `state-machines.md §1`. Roadmap drag → `updateProject`/`updateMilestone` (admin-only) — `roadmap-view.md §4`. Optimistic mutations reconcile on the server; a rejected write rolls back + toasts (`permissions.md §9`). Two-phase cascading delete is expected, not a bug (`data-model.md §4`, `ui-spec.md §7`).
- **State machines** (`state-machines.md`): all 5×5 issue-status and project-status transitions are legal; **nothing cascades** (closing a parent doesn't touch sub-issues; milestone completion is derived at read time; canceling a project doesn't cancel its issues; status changes fire no notification).

## State Management

Prototype-local `view`, `projectKey`, `issueId`, `groupBy`, `zoom`, `notifRead`, `wsTab`, `authState`, plus the tweak props below. **In the real app**, all app data is **Zero live queries** over the local replica (`useQuery` in ZQL) — no per-screen fetching; UI state (current route, grouping, zoom) is router/local. Permission predicates (`permissions.ts`, pure) gate control-disabled state on the client and are the authoritative check server-side.

**Tweak props on the prototype (map to real concepts):**
- `accent` (color) — brand accent; `density` (comfortable/compact).
- `viewerRole` (admin/member) — demonstrates admin-gated nav + permission-disabled banners. Real role comes from `loadActor()` server-side (`auth.md §6`).
- `connection` (online/offline) — demonstrates the offline write-disabled state.
- `appState` (ready/loading) — demonstrates the first-sync loader.

---

## Design Tokens

Warm "Cream & Sugar" brand **mapped onto `ui-spec.md §2`'s role tokens**. Use these hexes; keep the *roles* so the mapping stays coherent.

**Surfaces & text**
| Role (ui-spec) | Prototype hex |
| --- | --- |
| background (page) | `#FBF6EC` |
| surface — sidebar | `#EFE6D4` |
| surface — header/footer bars | `#F6EEDF` |
| surface — cards/panels | `#FFFDF9` |
| border | `#E7DAC4` (soft `#F1E7D5`, sidebar `#E1D3B9`) |
| text-primary | `#33261C` |
| text-body | `#5F503F` |
| text-secondary | `#9A8974` |
| text-muted label | `#A6957E` / `#B2A188` |
| accent | `#B26B32` (prop; swatches `#B26B32 #A9803F #8C5A3B #C08748`) · accent-tint `${accent}1e` |
| danger | `#C2492E` · banner bg `#FBEEE6`, border `#F0D8C8`, text `#B4552E` |
| success | `#6E8B6A` · warning `#C08A3E` |
| on-accent text | `#FBF3E7` |

**Status colors** (issue & project status share these): `backlog #B0A08B` · `todo #808A98` · `in_progress #4E6E8C` · `done #6E8B6A` · `canceled #C2492E`. Project status maps by position (planned≈backlog, active≈in_progress, paused≈todo, completed≈done, canceled≈canceled) per `ui-spec.md §2`.

**Priority colors**: `none #B0A08B` · `low #7E9BB5` · `medium #C08A3E` · `high #C4763C` · `urgent #C2492E` (urgent also gets the "!" icon — color alone is insufficient at that severity, `ui-spec.md §2`).

**Label colors** (workspace set): design `#B26B32`, bug `#A65E4E`, content `#6E8B6A`, research `#7A6E58`, infra `#4E6E8C`, a11y `#8C6BB0`.

**Team avatar colors**: MA `${accent}`, DP `#6E8B6A`, PR `#8C5A3B`, LN `#4E6E8C`, SF `#A65E4E`.

**Type scale** (`ui-spec.md §2`; system font stack — `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif`, **no web fonts**): xs 12/16, sm 13/18, base 14/20, md 16/24, lg 20/28. Prototype specifics: page title 17px/700 `-.02em`; card title 13.5px/500; issue title 22px/700; ids 11.5px tabular; uppercase meta labels 10.5–11px/600 `.05–.06em`.

**Spacing scale** (Tailwind-compatible): 4, 8, 12, 16, 24, 32, 48. **Radii**: chips/pills 7–9px & 20px, cards 11–14px, avatars 50%. **Shadows**: card `0 1px 2px rgba(90,60,25,.05)`, card-hover `0 4px 12px rgba(90,60,25,.10)`, button `0 1px 2px rgba(80,45,15,.18)`, modal `0 24px 64px rgba(60,38,15,.30)`.

**Breakpoints** (Tailwind defaults): mobile < `md` (768), tablet `md`–`lg`, desktop ≥ `lg` (1024).

## Assets

No image/icon assets — all icons are **inline SVG** (stroke-based, ~1.5–1.7 stroke width) drawn in the prototype; substitute your icon set (e.g. Lucide) matching that weight. No web fonts. Product name/logo is a 4-square glyph (inline SVG) — replace with the real mark if one exists.

## Known deviations (prototype vs spec)

- **Theme**: prototype uses the warm brand, not `ui-spec.md §2`'s neutral indigo/system default — intentional (documented above).
- **Responsive/mobile**: not implemented — build from `ui-spec.md` + `roadmap-view.md §6`.
- **Drag/DnD & real dates**: visual only — wire per specs.
- **Issue-detail sub-sections**: prototype stacks Sub-issues + Comments + Attachments; `ui-spec.md §3` maps them to React Aria `Tabs` — either is acceptable, §4.4 describes the stacked layout.
- Sample data (issues, people, dates) is illustrative.

## Files

- `Team Works.dc.html` — the hi-fi prototype (open directly in a browser).
- `specs/team-works-concept-brief.md` — product scope, stack, build order, decisions (**start here**).
- `specs/ui-spec.md` — screen inventory, React Aria mapping, tokens, breakpoints, board semantics, cross-cutting states (**the UI authority**).
- `specs/data-model.md` — Drizzle schema, sync publication, ordering, ids, cascades, indexes, invariants.
- `specs/permissions.md` — roles, permission matrix, read model, per-mutator write rules.
- `specs/auth.md` — invites, magic links, sessions/rotation, the JWT `zero-cache` verifies, env contract.
- `specs/roadmap-view.md` — Gantt mapping, undated handling, progress derivation, reschedule & mobile rules.
- `specs/state-machines.md` — legal status transitions and the "nothing cascades" rules.

**Suggested reading order for implementation:** concept-brief → ui-spec → data-model → permissions → auth → roadmap-view → state-machines, then build in the concept-brief §6 order (foundation → issues+board → projects+milestones+roadmap → collaboration+notifications → issue depth → mobile polish).
