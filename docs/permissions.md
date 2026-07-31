# Team Works — permissions

_Authorization spec for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md). Status: approved 2026-07-31._

This document is the source of truth for `src/lib/permissions.ts`. Every rule below should map to a named predicate in that module, and every predicate should trace back to a row here.

---

## 1. Roles

There are exactly two roles, and one membership relation.

**Workspace role** — `User.role`, either `admin` or `member`. Assigned at invite time. Only an admin can change it.

- `admin` — runs the workspace: invites people, sets roles, creates projects, manages project membership, curates labels, owns project and milestone structure. Sees everything.
- `member` — does the work: reads and writes issues, comments, and attachments inside the projects they belong to. Sees nothing else.

**Membership** — `ProjectMember(project_id, user_id)`. No role column. You are in a project or you are not.

> **Change from the brief:** the brief's `ProjectMember.role` (`lead` | `member`) is dropped. `Project.lead` remains as an informational field naming who is driving the project; it grants no permissions.

---

## 2. The two predicates

Every rule in this document reduces to these:

```ts
isAdmin(user)           = user.role === 'admin'
isMember(user, project) = isAdmin(user) || hasProjectMemberRow(project.id, user.id)
```

`isMember` returning true for admins is deliberate: admins are implicitly members of every project, so no downstream rule needs its own `|| isAdmin` branch. Admin access falls out of the membership predicate rather than being bolted onto each rule.

Only one further check exists anywhere in the system: authorship, which applies to comments and attachments and nothing else (§3).

---

## 3. Permission matrix

`✓` allowed · `—` not allowed (admin only) · "invisible" means the row is absent from the client entirely, not merely hidden.

| Action | Admin | Member of the project | Non-member |
| --- | :---: | :---: | :---: |
| See project, its milestones, issues, comments, attachments | ✓ | ✓ | invisible |
| Create project | ✓ | — | — |
| Edit project name, description, dates, status, color, lead | ✓ | — | — |
| Delete project | ✓ | — | — |
| Add or remove project members | ✓ | — | — |
| Create, edit, reschedule, delete milestones | ✓ | — | — |
| Create issue in the project | ✓ | ✓ | — |
| Edit **any** issue in the project — all fields, including status, assignee, priority, due date, sort order, parent | ✓ | ✓ | — |
| Delete issue | ✓ | — (set status `canceled`) | — |
| Post comment | ✓ | ✓ | — |
| Edit or delete **own** comment | ✓ | ✓ | — |
| Edit **another user's** comment | — | — | — |
| Delete **another user's** comment | ✓ | — | — |
| Upload attachment | ✓ | ✓ | — |
| Delete **own** attachment | ✓ | ✓ | — |
| Delete **another user's** attachment | ✓ | — | — |
| Create, edit, delete labels (the workspace-wide set) | ✓ | — | — |
| Apply or remove labels on an issue | ✓ | ✓ | — |
| Invite users, deactivate users, set workspace roles | ✓ | — | — |
| Read own notifications, mark read | ✓ | ✓ | ✓ |
| Edit own profile (name, avatar) | ✓ | ✓ | ✓ |

Two choices worth naming:

- **Members can edit any issue in their project, not only their own.** Editing an issue *is* the work — dragging a card between board columns is an update, and a rule scoped to authorship would break the board's primary gesture for most cards. Authorship survives in exactly one place, comments, where "don't rewrite my words" is the actual concern.
- **Labels are curated by admins but applied by anyone.** An admin owns the label set so it stays coherent; members apply them freely.

---

## 4. Read rules — what Zero syncs to a client

Read authorization is expressed once, as the sync scope. A client holds only what these rules admit; everything else never reaches the browser.

| Table | Synced to a client when |
| --- | --- |
| `Project` | `isMember(user, project)` |
| `ProjectMember` | its `project_id` is a visible project |
| `Milestone` | its `project_id` is a visible project |
| `Issue` | its `project_id` is a visible project |
| `IssueLabel` | its `issue_id` is a visible issue |
| `Comment` | its `issue_id` is a visible issue |
| `Attachment` | its issue (directly, or via its comment) is a visible issue |
| `Label` | always — small workspace-wide set |
| `User` | always — see below |
| `Notification` | `notification.user_id === user.id` |

**On syncing all users:** the full workspace roster reaches every client, because assignee pickers, avatars, comment bylines, and @mention autocomplete all need it. Synced columns are `id`, `name`, `email`, `avatar`, `role` only. Authentication material — sessions, tokens, magic-link state — lives in tables outside the syncable subset and is never part of Zero's replica.

The JWT that authenticates the sync connection carries the user's `id` and workspace `role`. Project membership is **not** in the token; it is resolved server-side by `zero-cache` against `ProjectMember`, so adding or removing a member takes effect on the next sync rather than at the next token refresh.

---

## 5. Write rules — per mutator

Every mutator listed here calls the policy module before writing. Grouped by the check they perform.

**Requires `isAdmin`**

`createProject`, `updateProject`, `deleteProject`, `addProjectMember`, `removeProjectMember`, `createMilestone`, `updateMilestone`, `deleteMilestone`, `deleteIssue`, `createLabel`, `updateLabel`, `deleteLabel`, `inviteUser`, `setUserRole`, `deactivateUser`

**Requires `isMember` of the affected project**

`createIssue`, `updateIssue`, `moveIssue` (status + sort order), `addIssueLabel`, `removeIssueLabel`, `createComment`, `createAttachment`

**Requires `isMember` **and** authorship**

`updateComment`, `deleteComment`, `deleteAttachment` — author only, except an admin may delete any comment or attachment (but may not edit another user's comment; editing someone's words is never permitted).

**Requires only self**

`updateOwnProfile`, `markNotificationRead`

For any mutator taking an issue or comment id, the project used for the `isMember` check is derived server-side from the stored row — never from a client-supplied `project_id`.

---

## 6. Invariants

These are not permissions, but the read rules leak without them. Each is enforced in the mutators that could violate it.

1. **Every issue belongs to a project.** `Issue.project_id` is `NOT NULL`. This is a change from the brief, which had it nullable; with membership as the visibility boundary, a project-less issue has nothing to key a rule off. Teams that want a landing spot for unsorted work create an "Inbox" project. (Enforced by: schema.)
2. **A sub-issue lives in the same project as its parent.** Otherwise a child issue leaks into a project the viewer cannot see. (Enforced by: `createIssue`, `updateIssue`.)
3. **An issue can only be assigned to a member of its project.** Assigning to a non-member produces an issue its own assignee cannot see. The assignee picker lists project members only; the mutator re-checks. (Enforced by: `createIssue`, `updateIssue`.)
4. **@mentions resolve to project members only.** Same reasoning — a mention notification would otherwise link a user to an invisible issue. Non-members are absent from mention autocomplete, and the mutator drops any that slip through. (Enforced by: `createComment`, `updateComment`.)
5. **An issue cannot change project.** Moving an issue between projects would move it across a visibility boundary and strand its assignee, sub-issues, and mention notifications. Not supported in v1. (Enforced by: `updateIssue`.)

---

## 7. Edge cases and decisions

**Removing a member who has issues assigned to them.** The removal is blocked. The admin is shown which issues are still assigned and must reassign them first. Silently unassigning would quietly lose information about who was doing what; leaving the assignment in place would point at a user who can no longer see the issue.

**The last admin.** The last remaining admin cannot be demoted to member or deactivated. The first user in a fresh workspace is created as an admin during setup; every subsequent user arrives by invitation.

**Content authored by removed or deactivated users.** Comments, attachments, and `created_by` references survive. The name still renders. Removing someone from a project or deactivating them revokes their access; it does not rewrite history.

**Losing access while the app is open.** When an admin removes a member, the affected rows leave that user's sync set and disappear from the local store. Any route rendering removed data must handle it — route to a "you no longer have access to this project" state rather than crashing on a null. This is a UI requirement, tracked in the UI spec.

**Promotion to admin.** Takes effect on the next JWT issuance, since the workspace role is a token claim. The session's token is refreshed on role change so the user does not have to sign out and back in.

**Deactivated users.** Cannot sign in and receive no notifications. Their `ProjectMember` rows are retained, so reactivation restores prior access.

---

## 8. Enforcement

One module, two consumers.

```ts
// src/lib/permissions.ts — pure, no I/O, no framework imports

type Actor = { id: string; role: 'admin' | 'member' }
type Membership = ReadonlySet<string>   // project ids the actor belongs to

export function isAdmin(actor: Actor): boolean
export function isMember(actor: Actor, m: Membership, projectId: string): boolean

export function canCreateIssue(actor: Actor, m: Membership, projectId: string): boolean
export function canEditIssue(actor: Actor, m: Membership, issue: IssueRow): boolean
export function canDeleteIssue(actor: Actor): boolean
export function canEditComment(actor: Actor, m: Membership, comment: CommentRow): boolean
export function canDeleteComment(actor: Actor, m: Membership, comment: CommentRow): boolean
export function canAssignTo(m: Membership, projectId: string, assigneeMembership: Membership): boolean
export function canManageProject(actor: Actor): boolean
export function canManageMilestones(actor: Actor): boolean
export function canManageLabels(actor: Actor): boolean
export function canManageUsers(actor: Actor): boolean
```

The predicates are pure functions over already-loaded data. They perform no queries, which is what lets the same code run in three places:

1. **Zero read rules** are built from `isMember`, so the sync scope and the matrix cannot drift apart.
2. **Server mutators** call the relevant predicate before writing. This is the authoritative check.
3. **The client** calls the same predicates — to disable controls the user cannot use, and because Zero runs custom mutators optimistically on the client, which keeps the UI from flashing a state the server will reject.

The client check is a courtesy; the server check is the enforcement. Never the reverse.

---

## 9. Failure behavior

- **Rejected write.** The server mutator throws, Zero rolls back the optimistic write, and the UI shows a toast naming what failed and why ("Only admins can edit project details"). The local store returns to its pre-write state on its own.
- **Disconnected.** Writes are rejected before they are attempted, per the read-only-when-offline decision in the brief. Inputs render in a clearly disabled state explaining that changes need a connection.
- **Absent data.** A request for something outside the sync scope has nothing to reject — the row simply is not there. Routes handle "not found" and "no access" identically, and say "no access" only where the user could plausibly have had it.
- **Expired token.** The sync connection drops and the client behaves as disconnected until the token refreshes.

---

## 10. Testing

- **Predicate tests.** `permissions.ts` is pure, so it gets table-driven unit tests: every cell of the §3 matrix is one case. This is the bulk of the coverage and it is cheap.
- **Sync scope tests.** With a seeded workspace — two projects, an admin, a member of project A only — assert that the member's sync set contains project A's issues and comments and contains nothing from project B, for each table in §4.
- **Mutator authorization tests.** For each mutator in §5, one allowed case and one denied case, asserting the denial happens server-side even when the client-side check is bypassed.
- **Invariant tests.** One per §6 rule, each attempting the violation directly through a mutator.

---

## 11. Out of scope for v1

Not needed now; noted so the model above is not mistaken for a limitation that was overlooked.

- Guest or read-only roles
- Per-issue privacy inside a project
- Custom roles or granular permission grants
- Multiple workspaces or tenants
- Audit log of permission changes

The `isMember` predicate is the extension point. The future team chat (brief §8) reuses it directly: channel membership is the same shape as project membership, and channel visibility becomes the same rule against a different table.

---

## 12. Changes this spec requires elsewhere

- `Issue.project_id` becomes `NOT NULL` (§6.1) — the brief has it nullable.
- `ProjectMember.role` is removed (§1) — the brief has `lead` | `member`.
- The UI spec needs: a disabled-control convention for actions the actor lacks, a "no longer have access" route state (§7), and a members-only assignee picker (§6.3).
