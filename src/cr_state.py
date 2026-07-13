# =============================================================================
# cr_state.py
#
# WHAT THIS FILE DOES
# -------------------
# Persists the bot's memory in two Azure Storage Tables:
#
#   1. crState    - one row per SKU. Answers "how many did I actually reserve
#                   so far, and what happened last time I tried?"
#   2. crAttempts - append-only audit log. One row per API call the bot made
#                   (create/update/restore, success/failure, and the error).
#
# WHY TABLE STORAGE?
# ------------------
# It's cheap (fractions of a cent per month), schemaless, and the Function's
# managed identity can talk to it with RBAC (no keys).
#
# TABLE STORAGE MODEL (quick refresher)
# -------------------------------------
# Each row has:
#   - PartitionKey (str)  : rows with the same PK live together (fast queries).
#   - RowKey (str)        : unique within a partition.
#   - Any number of other columns (any primitive type).
# Sorting is ascending by (PartitionKey, RowKey).
# =============================================================================

from __future__ import annotations

import datetime as dt
import logging
import uuid
from dataclasses import dataclass
from typing import List, Optional

# azure-core exposes the base exception classes (like "not found", "conflict").
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
# azure-data-tables is the Table Storage client library.
from azure.data.tables import TableClient, TableServiceClient, UpdateMode
# DefaultAzureCredential picks whatever auth is available: managed identity in
# Azure, developer credentials locally (VS Code, az login, env vars, etc.).
from azure.identity import DefaultAzureCredential

logger = logging.getLogger(__name__)


# =============================================================================
# In-memory data shapes
# =============================================================================

# -----------------------------------------------------------------------------
# SkuState = one row in the `crState` table.
# One SkuState per VM SKU. Overwritten every hour with the fresh status.
# -----------------------------------------------------------------------------
@dataclass
class SkuState:
    sku: str                                    # RowKey
    current_capacity: int = 0                   # what Azure actually reserved
    provisioning_state: str = "None"            # None|Creating|Succeeded|Failed
    last_attempt_utc: Optional[str] = None      # ISO-8601 UTC timestamp of last try
    last_outcome: str = ""                      # created|increased|no-op|failed|restored
    last_error: str = ""                        # last error message (empty on success)
    updated_utc: str = ""                       # when this row was last written


# -----------------------------------------------------------------------------
# AttemptRecord = one row in the `crAttempts` table.
# One row per individual API call, i.e. one row per (SKU, attempted_quantity).
# -----------------------------------------------------------------------------
@dataclass
class AttemptRecord:
    timestamp_utc: str          # when this attempt happened
    sku: str                    # which VM size
    action: str                 # create | update | restore
    requested_delta: int        # how many *more* VMs we wanted this run
    attempted_quantity: int     # what we asked Azure for on this specific call
    result: str                 # "success" or "failure"
    resulting_capacity: int     # what capacity is now (after this call)
    error: str = ""             # error message if it failed


# =============================================================================
# StateStore = thin wrapper around Table Storage. All I/O goes through here.
# =============================================================================
class StateStore:
    def __init__(self, endpoint: str, state_table: str, attempts_table: str, credential=None):
        """
        endpoint       : full table endpoint URL, e.g.
                         https://crbotst123.table.core.windows.net
        state_table    : name of the crState table (default "crState")
        attempts_table : name of the crAttempts table (default "crAttempts")
        credential     : optional; DefaultAzureCredential by default.
                         In Azure this becomes the Function App's managed identity.
        """
        self._state_name = state_table
        self._attempts_name = attempts_table

        # exclude_interactive_browser_credential=True stops the SDK from popping
        # a browser window when running non-interactively (e.g. in Azure).
        cred = credential or DefaultAzureCredential(
            exclude_interactive_browser_credential=True
        )
        self._svc = TableServiceClient(endpoint=endpoint, credential=cred)

        # Create tables if they don't exist yet. Terraform already creates them,
        # but this guard makes the code work in local dev with a fresh account.
        for name in (state_table, attempts_table):
            try:
                self._svc.create_table(name)
            except ResourceExistsError:
                pass  # already there - fine

    # Small helpers so we don't type get_table_client(...) all over the place.
    def _state(self) -> TableClient:
        return self._svc.get_table_client(self._state_name)

    def _attempts(self) -> TableClient:
        return self._svc.get_table_client(self._attempts_name)

    # -------------------------------------------------------------------------
    # crState - read/write current state per SKU
    # -------------------------------------------------------------------------
    def get_state(self, sku: str) -> SkuState:
        """
        Fetch the state row for one SKU. Returns a fresh SkuState (all zeros)
        if the row doesn't exist yet (first run).

        We use PartitionKey="sku" (a fixed literal) so ALL SKU rows live in the
        same partition. That's fine because we only have a handful of SKUs; a
        single partition is the fastest thing you can query.
        """
        try:
            e = self._state().get_entity(partition_key="sku", row_key=sku)
        except ResourceNotFoundError:
            return SkuState(sku=sku)  # sensible defaults
        return SkuState(
            sku=sku,
            current_capacity=int(e.get("current_capacity", 0)),
            provisioning_state=e.get("provisioning_state", "None"),
            last_attempt_utc=e.get("last_attempt_utc"),
            last_outcome=e.get("last_outcome", ""),
            last_error=e.get("last_error", ""),
            updated_utc=e.get("updated_utc", ""),
        )

    def upsert_state(self, s: SkuState) -> None:
        """
        Overwrite (or create) the row for this SKU with the given state.
        `upsert` = update if exists, insert if not. UpdateMode.REPLACE means
        we replace ALL columns (any missing field would be dropped).
        """
        s.updated_utc = _now()  # stamp the write time so the dashboard can show it
        self._state().upsert_entity(entity={
            "PartitionKey": "sku",
            "RowKey": s.sku,
            "current_capacity": s.current_capacity,
            "provisioning_state": s.provisioning_state,
            "last_attempt_utc": s.last_attempt_utc or "",
            "last_outcome": s.last_outcome,
            # Table Storage caps a single string property at 64 KB. We slice to
            # a safe size to avoid an error if a giant error message comes back.
            "last_error": s.last_error[:32000],
            "updated_utc": s.updated_utc,
        }, mode=UpdateMode.REPLACE)

    def list_state(self) -> List[SkuState]:
        """
        Return every row from crState. Used by the dashboard, which wants to
        show one card per SKU. With <10 SKUs this is trivially fast.
        """
        out: List[SkuState] = []
        for e in self._state().list_entities():
            out.append(SkuState(
                sku=e["RowKey"],
                current_capacity=int(e.get("current_capacity", 0)),
                provisioning_state=e.get("provisioning_state", "None"),
                last_attempt_utc=e.get("last_attempt_utc"),
                last_outcome=e.get("last_outcome", ""),
                last_error=e.get("last_error", ""),
                updated_utc=e.get("updated_utc", ""),
            ))
        return out

    # -------------------------------------------------------------------------
    # crAttempts - append-only audit log
    # -------------------------------------------------------------------------
    def append_attempt(self, a: AttemptRecord) -> None:
        """
        Insert one new row into the audit table.

        PartitionKey  = date bucket "YYYY-MM-DD" so partitions stay small.
                        Table Storage queries within a single partition are the
                        cheapest kind, so bucketing by day is a good trade-off:
                        each day's data lives together, but old days don't slow
                        down today's queries.
        RowKey        = <reverse-ticks>-<random uuid8>. Reverse-ticks makes the
                        newest attempts sort FIRST inside the partition, which
                        makes "recent attempts" queries dirt cheap. The random
                        uuid8 avoids collisions if two attempts have the same
                        second-level timestamp.
        """
        ts = a.timestamp_utc
        self._attempts().create_entity(entity={
            "PartitionKey": ts[:10],  # "2026-07-14"
            "RowKey": f"{_reverse_ticks(ts)}-{uuid.uuid4().hex[:8]}",
            "timestamp_utc": ts,
            "sku": a.sku,
            "action": a.action,
            "requested_delta": a.requested_delta,
            "attempted_quantity": a.attempted_quantity,
            "result": a.result,
            "resulting_capacity": a.resulting_capacity,
            "error": a.error[:32000],
        })

    def recent_attempts(self, limit: int = 100) -> List[AttemptRecord]:
        """
        Return the most recent N attempts across the last 7 days.

        We loop over day-partitions from today backwards. As soon as we've
        collected `limit` records we stop. In practice today's partition is
        almost always enough - the loop is just insurance for quiet periods.
        """
        out: List[AttemptRecord] = []
        today = dt.datetime.now(dt.timezone.utc).date()

        for offset in range(0, 7):
            day = (today - dt.timedelta(days=offset)).isoformat()  # e.g. "2026-07-14"
            try:
                # Query all rows in this day-partition. RowKey ordering is
                # already newest-first thanks to _reverse_ticks.
                for e in self._attempts().query_entities(
                        query_filter=f"PartitionKey eq '{day}'",
                        results_per_page=limit):
                    out.append(AttemptRecord(
                        timestamp_utc=e.get("timestamp_utc", ""),
                        sku=e.get("sku", ""),
                        action=e.get("action", ""),
                        requested_delta=int(e.get("requested_delta", 0)),
                        attempted_quantity=int(e.get("attempted_quantity", 0)),
                        result=e.get("result", ""),
                        resulting_capacity=int(e.get("resulting_capacity", 0)),
                        error=e.get("error", ""),
                    ))
                    if len(out) >= limit:
                        break
                if len(out) >= limit:
                    break
            except Exception as exc:  # pragma: no cover
                # Don't let a bad partition break the dashboard.
                logger.warning("Failed to query attempts for %s: %s", day, exc)

        # Cross-partition results aren't guaranteed to be sorted by time, so we
        # sort again here in Python. This is fine because `limit` is small.
        out.sort(key=lambda r: r.timestamp_utc, reverse=True)
        return out[:limit]


# =============================================================================
# Module-level helper functions
# =============================================================================
def _now() -> str:
    """Return the current UTC time as ISO-8601 to the second, e.g. 2026-07-14T13:00:00Z."""
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _reverse_ticks(iso: str) -> str:
    """
    Build a 10-digit string that sorts DESCENDING by time.

    Table Storage sorts RowKeys ascending. We want newest-first, so we subtract
    the timestamp (seconds since epoch) from a big constant (9,999,999,999).
    That makes newer times produce SMALLER numbers, which come first in an
    ascending sort. This is a well-known Table Storage idiom.
    """
    try:
        t = dt.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        # Fallback if the input is malformed - use "now" and move on.
        t = dt.datetime.now(dt.timezone.utc)
    return f"{9_999_999_999 - int(t.timestamp()):010d}"
