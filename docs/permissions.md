# Team Works — permissions

_Authorization spec for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md). Status: approved 2026-07-31._

This document is the source of truth for `src/lib/permissions.ts`. Every rule below should map to a named predicate in that module, and every predicate should trace back to a row here.

---

## 1. The shape of it

**The workspace is transparent. Membership decides who can change things.**

Every user reads every project. Project membership is a **write** boundary, not a visibility one: you can see all the work, and you can act on the work in the projects you belong to.

This is a deliberate reversal of the concept brief, which made membership a visibility wall. Transparency is what makes the rest of the model simple — a member removed from a project keeps seeing their assigned issues, an @mention can name anyone, and no row ever disappears from a client mid-session. Those three problems were each solved separately under a visibility wall; here they do not arise.

**What it costs:** there is no confidential project. Every standard user can read every project, including one about a reorganization, a departure, a compensation review, or a legal matter. This is an accepted limitation for a team of fewer than twenty, not an oversight. If such a project ever needs to exist, the read model has to change — the `isMember` predicate below is already the right hook for it, but the sync scope in §4 would need revisiting.

---

## 2. Roles and membership

**Workspace role** — `User.role`, either `admin` or `member`. Assigned at invite time. Only an admin can change it.

- `admin` — runs the workspace: invites people, sets roles, creates projects, manages project membership, curates labels, owns project and milestone structure. Can write anywhere.
- `member` — does the work: creates and edits issues, comments, and attachments in the projects they belong to. Reads everything.

**Membership** — `ProjectMember(project_id, user_id)`. No role column. You are in a project or you are not.

> **Change from the brief:** the brief's `ProjectMember.role` (`lead` | `member`) is dropped. `Project.lead` remains as an informational field naming who is driving the project; it grants no permissions.

Every rule in this document reduces to these two predicates:

```ts
isAdmin(user)           = user.role === 'admin'
isMember(user, project) = isAdmin(user) || hasProjectMemberRow(project.id, user.id)
```

`isMember` returning true for admins is deliberate: admins are implicitly members of every project, so no downstream rule needs its own `|| isAdmin` branch. Admin access falls out of the membership predicate rather than being bolted onto each rule.

One further check exists anywhere in the system: authorship, which applies to comments and attachments and nothing else.

---

## 3. Permission matrix

`✓` allowed · `—` not allowed. "Non-member" means a standard user who is not in the project in question.

| Action | Admin | Member of the project | Non-member |
| --- | :---: | :---: | :---: |
| **Read** any project, milestone, issue, comment, attachment | ✓ | ✓ | ✓ |
| Create project | ✓ | — | — |
| Edit project name, description, dates, status, color, lead | ✓ | — | — |
| Delete project | ✓ | — | — |
| Add or remove project members | ✓ | — | — |
| Create, edit, reschedule, delete milestones | ✓ | — | — |
| Create issue in the project | ✓ | ✓ | — |
| Edit **any** issue in the project — all fields, including status, assignee, priority, due date, sort order, parent | ✓ | ✓ | — |
| Delete issue | ✓ | — (set status `canceled`) | — |
| Post comment | ✓ | ✓ | — |
| Edit or delete **own** comment | ✓ | ✓ | n/a |
| Edit **another user's** comment | — | — | — |
| Delete **another user's** comment | ✓ | — | — |
| Upload attachment | ✓ | ✓ | — |
| Delete **own** attachment | ✓ | ✓ | n/a |
| Delete **another user's** attachment | ✓ | — | — |
| Create, edit, delete labels (the workspace-wide set) | ✓ | — | — |
| Apply or remove labels on an issue | ✓ | ✓ | — |
| Invite users, deactivate users, set workspace roles | ✓ | — | — |
| Read own notifications, mark read | ✓ | ✓ | ✓ |
| Edit own profile (name, avatar) | ✓ | ✓ | ✓ |

Four choices worth naming:

- **Members can edit any issue in their project, not only their own.** Editing an issue *is* the work — dragging a card between board columns is an update, and a rule scoped to authorship would break the board's primary gesture for most cards. Authorship survives only on comments and attachments, where "don't rewrite my words" is the actual concern.
- **Comments follow the membership rule.** A non-member reads the discussion but does not join it. This keeps the model stateable in one sentence: membership gates every write, without exception.
- **Members cancel; admins delete.** `status = 'canceled'` is reversible and keeps history. Hard deletion is an admin action.
- **Labels are curated by admins but applied by anyone.** An admin owns the label set so it stays coherent; members apply them freely.

---

## 4. Read model — what Zero syncs

Every syncable table syncs in full to every authenticated client, with one exception:

| Table | Synced to a client when |
| --- | --- |
| `Project`, `ProjectMember`, `Milestone`, `Issue`, `Label`, `IssueLabel`, `Comment`, `Attachment` | always |
| `User` | always — `id`, `name`, `email`, `avatar`, `role` only |
| `Notification` | `notification.user_id === user.id` |

Notifications are the only per-user read rule in the system.

Authentication material — sessions, tokens, magic-link state — lives in tables outside the syncable subset and never enters Zero's replica. The `User` columns listed above are the only ones that sync; anything added to that table later is outside the sync set unless explicitly included.

The JWT authenticating the sync connection carries the user's `id` and workspace `role`. Project membership is **not** in the token and does not need to be — membership is only consulted server-side during writes (§5), so adding or removing a member takes effect on the very next mutation rather than at the next token refresh.

A client therefore holds the entire workspace. At fewer than twenty users this is a small dataset, well inside Zero's comfortable range, and it means every read in the app is local and instant.

---

## 5. Write rules — per mutator

Every mutator calls the policy module before writing. Grouped by the check performed.

**Requires `isAdmin`**

`createProject`, `updateProject`, `deleteProject`, `addProjectMember`, `removeProjectMember`, `createMilestone`, `updateMilestone`, `deleteMilestone`, `deleteIssue`, `createLabel`, `updateLabel`, `deleteLabel`, `inviteUser`, `setUserRole`, `deactivateUser`

**Requires `isMember` of the affected project**

`createIssue`, `updateIssue`, `moveIssue` (status + sort order), `addIssueLabel`, `removeIssueLabel`, `createComment`, `createAttachment`

**Requires `isMember` **and** authorship**

`updateComment`, `deleteComment`, `deleteAttachment` — author only, except an admin may delete any comment or attachment. No one may edit another user's comment, admins included.

**Requires only self**

`updateOwnProfile`, `markNotificationRead`

For any mutator taking an issue or comment id, the project used for the `isMember` check is derived server-side from the stored row — never from a client-supplied `project_id`.

---

## 6. Invariants

Not permissions, but the write rules become incoherent without them. Each is enforced in the mutators that could violate it.

1. **Every issue belongs to a project.** `Issue.project_id` is `NOT NULL`. This is a change from the brief, which had it nullable. The `isMember` check needs a project to resolve against; a project-less issue has no membership and therefore no answer to "who may edit this". Teams wanting a landing spot for unsorted work create an "Inbox" project. (Enforced by: schema.)
2. **A sub-issue lives in the same project as its parent.** Otherwise an issue hierarchy spans two write boundaries, and a user can edit a parent but not its children. (Enforced by: `createIssue`, `updateIssue`.)
3. **An issue cannot change project.** Moving an issue would move it across the write boundary mid-flight, silently changing who can act on it. Not supported in v1. (Enforced by: `updateIssue`.)

**Not invariants, deliberately:** an issue may be assigned to a non-member, and an @mention may name anyone. Both are legal because everyone can read everything. The assignee picker and mention autocomplete list project members first, with the rest of the workspace below — a UI preference, not an enforced rule. This is what makes member removal a free action (§7).

---

## 7. Edge cases and decisions

**Removing a member from a project.** Nothing special happens. Issues assigned to them stay assigned and stay visible to them; they simply lose the ability to edit anything in that project. Whoever remains reassigns the work when convenient. No blocking, no cleanup, no cascade.

**An assigned non-member.** They can see their issue but cannot update it — not even to move it on the board. The issue detail view explains why and names the project they would need to be added to. This is a real state, reachable by removing a member, and the UI must handle it rather than rendering dead controls.

**The last admin.** The last remaining admin cannot be demoted to member or deactivated. The first user in a fresh workspace is created as an admin during setup; every subsequent user arrives by invitation.

**Content authored by removed or deactivated users.** Comments, attachments, and `created_by` references survive. The name still renders. Removing someone from a project or deactivating them revokes write access; it does not rewrite history.

**Losing write access while the app is open.** No rows leave the client's sync set, so nothing disappears and no route breaks. Controls that were enabled become disabled on the next render. This is the main practical benefit of a transparent read model.

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
export function canComment(actor: Actor, m: Membership, projectId: string): boolean
export function canEditComment(actor: Actor, m: Membership, comment: CommentRow): boolean
export function canDeleteComment(actor: Actor, m: Membership, comment: CommentRow): boolean
export function canDeleteAttachment(actor: Actor, m: Membership, att: AttachmentRow): boolean
export function canManageProject(actor: Actor): boolean
export function canManageMilestones(actor: Actor): boolean
export function canManageLabels(actor: Actor): boolean
export function canManageUsers(actor: Actor): boolean
```

The predicates are pure functions over already-loaded data. They perform no queries, which is what lets the same code run in two places:

1. **Server mutators** call the relevant predicate before writing. This is the authoritative check.
2. **The client** calls the same predicates — to disable controls the user cannot use, and because Zero runs custom mutators optimistically on the client, which keeps the UI from flashing a state the server will reject.

The client check is a courtesy; the server check is the enforcement. Never the reverse.

Zero's read rules do **not** consume this module. With a transparent read model there is only one read rule — notifications scoped to their owner — and it is expressed directly in the Zero schema. The sync scope and the permission matrix are independent by design, so there is nothing to keep in step.

The client's `Membership` set is derived from the synced `ProjectMember` rows for the current user. The server derives its own from the database and never trusts the client's.

---

## 9. Failure behavior

- **Rejected write.** The server mutator throws, Zero rolls back the optimistic write, and the UI shows a toast naming what failed and why ("Only project members can edit issues in Website Redesign"). The local store returns to its pre-write state on its own.
- **Disconnected.** Writes are rejected before they are attempted, per the read-only-when-offline decision in the brief. Inputs render in a clearly disabled state explaining that changes need a connection. Reads continue to work against the local store.
- **Not found.** Since every user can read every project, a missing row means the row genuinely does not exist — deleted, or a bad link. There is no "you don't have access" read state, and the UI should not imply one.
- **Expired token.** The sync connection drops and the client behaves as disconnected until the token refreshes.

---

## 10. Testing

- **Predicate tests.** `permissions.ts` is pure, so it gets table-driven unit tests: every cell of the §3 matrix is one case. This is the bulk of the coverage and it is cheap.
- **Sync scope tests.** With a seeded workspace, assert that a client receives all projects and issues regardless of membership, and that it receives its own notifications and no one else's.
- **Mutator authorization tests.** For each mutator in §5, one allowed case and one denied case, asserting the denial happens server-side even when the client-side check is bypassed.
- **Invariant tests.** One per §6 rule, each attempting the violation directly through a mutator.
- **Removal test.** Remove a member from a project while an issue is assigned to them; assert the issue is unchanged, still visible to them, and no longer editable by them.

---

## 11. Out of scope for v1

Noted so the model above is not mistaken for an oversight.

- **Confidential or private projects** — the accepted cost of the transparent read model (§1). The largest known limitation.
- Guest or read-only roles
- Per-issue privacy inside a project
- Custom roles or granular permission grants
- Multiple workspaces or tenants
- Audit log of permission changes
- Moving an issue between projects (§6.3)

The `isMember` predicate is the extension point. The future team chat (brief §8) reuses it directly: channel membership is the same shape as project membership. Chat is also where a genuine read boundary first becomes necessary — direct messages cannot be world-readable — so the read rules will grow a second case then, keyed off the same predicate.

---

## 12. Changes this spec requires elsewhere

**To the concept brief:**

- §3 — `Issue.project_id` becomes `NOT NULL` (§6.1); the brief has it nullable.
- §3 — `ProjectMember.role` is removed (§2); the brief has `lead` | `member`.
- §5 — the brief states Zero's read rules key off ProjectMembership and that "a client only syncs projects the user is a member of". They no longer do; membership governs writes only (§4).
- §7 decision 4 — "Access: per-project (membership-based; drives Zero read rules)" should read "drives write rules".

**To the UI spec, when written:**

- A convention for controls disabled by permission, with the reason surfaced rather than a dead button.
- The assigned-non-member state on issue detail (§7).
- An assignee picker and mention autocomplete that list project members first and the rest of the workspace below (§6).
