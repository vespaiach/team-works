# ADR-0004: Fractional indexing for issue ordering

Status: Accepted — 2026-07-31

## Context

The board is `dnd-kit` over Zero. A drop must compute its new position on the client immediately, with no server round-trip, and every changed row replicates through logical replication to every connected client — so a reorder scheme that touches more than one row per drop turns a single gesture into a burst of replicated updates and races other users' in-flight drags (data-model.md §5).

## Decision

`sort_order` is a base-62 fractional index — a `text COLLATE "C"` string key generated with the `fractional-indexing` package — one key per issue, **project-wide** rather than per board column. Ties are possible and are not an error; every ordered query sorts by `(sort_order, id)`.

## Consequences

- A drop writes exactly one row, regardless of how the board is grouped.
- Because there is only one order, reordering within one grouping (e.g. the status board) also changes relative position in every other grouping (e.g. by assignee) — an explicit, accepted cost rather than a bug (data-model.md §5).
- Keys can tie under concurrent drags; the `(sort_order, id)` tie-break resolves to creation order because ids are UUIDv7 ([ADR-0005](./0005-client-generated-uuidv7-primary-keys.md)), which is a defensible answer rather than an arbitrary one.
- No rebalancing job in v1 — keys just grow longer; a one-off maintenance script is the only planned repair, and reaching a length that matters requires thousands of drops into an identical position, unlikely for a team under twenty.
- Postgres needs `COLLATE "C"` stated explicitly, since its default locale collation folds case and would disagree with `zero-cache`'s SQLite (`BINARY` by default) and JavaScript's UTF-16 string comparison.

## Alternatives considered

- **Integer positions with renumbering.** A drop that renumbers a column turns one gesture into N replicated row updates and races other users' in-flight optimistic drags.
- **Float/double positions.** Update one row too, but a `double` exhausts its precision after roughly fifty successive halvings of the same gap, after which the column needs renumbering anyway.
- **Per-column sort key.** Leaves other groupings (assignee, priority) with no defined order, forcing drag-to-reorder to be disabled in them.
