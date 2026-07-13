# =============================================================================
# cr_manager.py
#
# WHAT THIS FILE DOES
# -------------------
# This is the brain of the bot. It talks to Azure Compute (via the
# ComputeManagementClient) and drives the halving-degrade strategy.
#
# THE STRATEGY (each hourly run)
# ------------------------------
#   1. Make sure the Capacity Reservation Group exists (create it if missing).
#      The CRG is a container - no capacity, no cost, just a bucket that holds
#      reservations. We create it regionally (no zones), so Azure will pick
#      whichever zone has capacity.
#
#   2. For each SKU target (e.g. NV6 x 50, NV18 x 9):
#
#      a) If Azure left the reservation in a "Failed" state (rare, but happens
#         when a capacity increase fails), we first restore it to the number
#         Azure actually has. This makes the reservation usable again.
#
#      b) If the reservation doesn't exist yet, try to CREATE it, with the
#         halving-degrade sequence: try N, N/2, N/4, ..., 1. First success wins.
#
#      c) If the reservation exists but is smaller than the target, try to
#         PATCH it upward (also halving the delta). First success wins.
#
#      d) After ANY success we loop again in the same hourly run to keep
#         chipping toward the target - because a partial success doesn't mean
#         the datacenter is out, it just means Azure won't hand out that big
#         a chunk right now. Maybe a smaller chunk still works.
#
#      e) When the whole degrade sequence fails end-to-end, or we hit the
#         target, we stop for this hour and wait for the next timer tick.
#
#   3. After every API call (success OR failure) we write two things:
#        - update the crState row for this SKU (single source of truth for
#          "where are we now?")
#        - append a row to crAttempts for the audit log / dashboard history
#
# HOW IT AUTHENTICATES
# --------------------
# DefaultAzureCredential -> in Azure this becomes the Function App's
# system-assigned managed identity (SAMI). Terraform gave that identity
# "Contributor" on the reservations resource group, which is enough to
# create/update/read capacity reservations.
# =============================================================================

from __future__ import annotations

import datetime as dt
import logging
from dataclasses import dataclass
from typing import Dict, List, Tuple

# Base Azure SDK exceptions used to distinguish "not found" from other errors.
from azure.core.exceptions import HttpResponseError, ResourceNotFoundError

# Managed-identity-aware credential.
from azure.identity import DefaultAzureCredential

# Compute management SDK - the thing that lets us CRUD reservations.
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.compute.models import (
    CapacityReservation,          # payload for CREATE
    CapacityReservationGroup,     # payload for CRG CREATE
    CapacityReservationUpdate,    # payload for PATCH
    Sku,                          # nested {"name": <vmSize>, "capacity": N}
)

from cr_config import Config, SkuTarget
from cr_state import AttemptRecord, SkuState, StateStore

logger = logging.getLogger(__name__)


# -----------------------------------------------------------------------------
# _degrade_sequence
#
# Build the halving degrade list, e.g.:
#     50 -> [50, 25, 12, 6, 3, 1]
#      9 -> [9, 4, 2, 1]
#      1 -> [1]
# Duplicates removed while preserving order (important for small N).
# The final "1" is always appended so we always try at least one VM.
# -----------------------------------------------------------------------------
def _degrade_sequence(n: int) -> List[int]:
    if n <= 0:
        return []
    seq, cur = [], n
    while cur > 1:
        seq.append(cur)
        cur //= 2      # integer division - halves and rounds down
    seq.append(1)      # always try 1 as the last resort
    # De-duplicate while preserving order (e.g. n=2 -> [2, 1], n=3 -> [3, 1, 1] -> [3, 1]).
    seen, out = set(), []
    for v in seq:
        if v not in seen:
            seen.add(v)
            out.append(v)
    return out


# -----------------------------------------------------------------------------
# ReservationSnapshot
#
# A small internal struct describing what a capacity reservation looks like
# right now on Azure. We build one of these from a GET call.
# -----------------------------------------------------------------------------
@dataclass
class ReservationSnapshot:
    exists: bool                # False if the reservation doesn't exist yet
    capacity: int               # what we asked Azure for (sku.capacity)
    current_capacity: int       # what Azure actually reserved (instanceView.currentCapacity)
    provisioning_state: str     # e.g. Succeeded / Failed / Updating / Creating


# =============================================================================
# ReservationManager - all Azure Compute interactions live here.
# =============================================================================
class ReservationManager:
    def __init__(self, cfg: Config, store: StateStore, credential=None):
        self._cfg = cfg
        self._store = store
        cred = credential or DefaultAzureCredential(
            exclude_interactive_browser_credential=True
        )
        # ComputeManagementClient is our gateway to Microsoft.Compute REST APIs.
        self._client = ComputeManagementClient(
            credential=cred,
            subscription_id=cfg.subscription_id,
        )

    # -------------------------------------------------------------------------
    # Naming helper
    #
    # Azure resource names have restrictions (alphanumeric + hyphens, max 80
    # chars). VM SKUs contain underscores which aren't allowed in some
    # resource names, so we translate underscores to hyphens and lowercase
    # the whole thing.
    # e.g. "Standard_NV6ads_A10_v5" -> "cr-standard-nv6ads-a10-v5"
    # -------------------------------------------------------------------------
    def _res_name(self, sku: str) -> str:
        return f"cr-{sku.replace('_', '-').lower()}"

    # -------------------------------------------------------------------------
    # ensure_group
    #
    # Create the Capacity Reservation Group (CRG) if it doesn't exist yet.
    # Idempotent - safe to call every hour. The CRG itself has no cost, it's
    # just a labelled shelf that will hold our reservations.
    #
    # We deliberately do NOT pass a `zones` array here, which makes the group
    # REGIONAL - Azure can then satisfy each reservation from whichever zone
    # currently has capacity (better odds when the region is tight).
    # -------------------------------------------------------------------------
    def ensure_group(self) -> None:
        try:
            self._client.capacity_reservation_groups.get(
                resource_group_name=self._cfg.resource_group,
                capacity_reservation_group_name=self._cfg.group_name,
            )
            # If we got here, the group already exists - nothing to do.
        except ResourceNotFoundError:
            logger.info("Creating regional CRG %s in %s",
                        self._cfg.group_name, self._cfg.location)
            self._client.capacity_reservation_groups.create_or_update(
                resource_group_name=self._cfg.resource_group,
                capacity_reservation_group_name=self._cfg.group_name,
                parameters=CapacityReservationGroup(location=self._cfg.location),
            )

    # -------------------------------------------------------------------------
    # get_snapshot
    #
    # Read the current state of a reservation from Azure and normalise it into
    # our ReservationSnapshot dataclass.
    #
    # The important thing here is `expand="instanceView"` - without this,
    # Azure only returns what we ASKED for (sku.capacity). WITH it, we also
    # get `instanceView.currentCapacity`, which is what Azure ACTUALLY reserved
    # - those two numbers can differ if a resize is pending or failed.
    # -------------------------------------------------------------------------
    def get_snapshot(self, sku: str) -> ReservationSnapshot:
        try:
            res = self._client.capacity_reservations.get(
                resource_group_name=self._cfg.resource_group,
                capacity_reservation_group_name=self._cfg.group_name,
                capacity_reservation_name=self._res_name(sku),
                expand="instanceView",
            )
        except ResourceNotFoundError:
            # No reservation yet - return an "empty" snapshot.
            return ReservationSnapshot(False, 0, 0, "None")

        # Extract requested capacity from sku.capacity.
        capacity = int(res.sku.capacity) if res.sku and res.sku.capacity else 0

        # Extract actual capacity from instanceView.currentCapacity. Different
        # SDK versions expose this differently, so we try both names.
        current = capacity
        iv = getattr(res, "instance_view", None)
        if iv is not None:
            for attr in ("current_capacity", "currentCapacity"):
                v = getattr(iv, attr, None)
                if isinstance(v, int):
                    current = v
                    break
                if isinstance(v, str) and v.isdigit():
                    current = int(v)
                    break

        return ReservationSnapshot(
            exists=True,
            capacity=capacity,
            current_capacity=current,
            provisioning_state=res.provisioning_state or "Unknown",
        )

    # -------------------------------------------------------------------------
    # _create : do the actual PUT to create a reservation.
    #
    # `begin_create_or_update` returns a "long-running operation" (LRO)
    # poller. Calling .result() blocks until the operation finishes and raises
    # if it failed. This is intentional - our whole degrade loop depends on
    # knowing success/failure synchronously.
    # -------------------------------------------------------------------------
    def _create(self, sku: str, quantity: int) -> ReservationSnapshot:
        poller = self._client.capacity_reservations.begin_create_or_update(
            resource_group_name=self._cfg.resource_group,
            capacity_reservation_group_name=self._cfg.group_name,
            capacity_reservation_name=self._res_name(sku),
            parameters=CapacityReservation(
                location=self._cfg.location,
                sku=Sku(name=sku, capacity=quantity),
            ),
        )
        poller.result()          # blocks; raises HttpResponseError on failure
        return self.get_snapshot(sku)

    # -------------------------------------------------------------------------
    # _update : do the actual PATCH to change the capacity of an existing
    # reservation. Same synchronous pattern as _create.
    # -------------------------------------------------------------------------
    def _update(self, sku: str, new_capacity: int) -> ReservationSnapshot:
        poller = self._client.capacity_reservations.begin_update(
            resource_group_name=self._cfg.resource_group,
            capacity_reservation_group_name=self._cfg.group_name,
            capacity_reservation_name=self._res_name(sku),
            parameters=CapacityReservationUpdate(sku=Sku(name=sku, capacity=new_capacity)),
        )
        poller.result()
        return self.get_snapshot(sku)

    # -------------------------------------------------------------------------
    # run_cycle : PUBLIC entry point called by the Timer trigger every hour.
    # Ensures the group exists and then processes each SKU in turn.
    # Returns a summary dict for logging / manual-trigger response body.
    # -------------------------------------------------------------------------
    def run_cycle(self) -> Dict:
        self.ensure_group()
        return {"skus": [self._advance_sku(t) for t in self._cfg.targets]}

    # -------------------------------------------------------------------------
    # _advance_sku
    #
    # The core loop for one SKU. Runs the halving strategy repeatedly until:
    #   a) we hit the target (remaining == 0),
    #   b) an entire degrade sequence fails end-to-end, or
    #   c) the safety cap of 32 iterations is hit (protection against a
    #      buggy Azure API that keeps returning "success" forever).
    # -------------------------------------------------------------------------
    def _advance_sku(self, target: SkuTarget) -> Dict:
        sku = target.sku

        # Start by reading what Azure currently has for this SKU.
        snap = self.get_snapshot(sku)

        # Special case: if the reservation is stuck in "Failed" state, we can't
        # do anything useful with it. Restore it to the actual capacity Azure
        # holds. See "Restore instance quantity" in the Azure docs.
        if snap.exists and snap.provisioning_state.lower() == "failed":
            self._restore_failed(sku, snap)
            snap = self.get_snapshot(sku)

        confirmed_start = snap.current_capacity if snap.exists else 0
        actions: List[Dict] = []      # accumulates one dict per attempt-batch
        max_iterations = 32           # safety cap

        for _ in range(max_iterations):
            confirmed = snap.current_capacity if snap.exists else 0
            remaining = max(target.quantity - confirmed, 0)

            # Target reached? Nothing more to do this hour.
            if remaining <= 0:
                break

            logger.info("[%s] target=%d confirmed=%d remaining=%d",
                        sku, target.quantity, confirmed, remaining)

            # Decide whether to CREATE (if the reservation doesn't exist yet)
            # or PATCH (if it exists and we want to grow it).
            if snap.exists:
                snap, action = self._grow(sku, snap, remaining)
            else:
                snap, action = self._create_with_degrade(sku, remaining)

            actions.append(action)

            # If the whole degrade sequence failed, don't burn more API calls
            # this hour - break out and wait for the next timer.
            if action.get("result") != "success":
                break

        confirmed_after = snap.current_capacity if snap.exists else 0

        # If we didn't do anything at all (already at target on entry),
        # still refresh the state row so the dashboard shows a fresh timestamp.
        if not actions:
            self._persist(sku, snap, "no-op", "")

        return {
            "sku": sku,
            "target": target.quantity,
            "confirmed_before": confirmed_start,
            "confirmed": confirmed_after,
            "remaining": max(target.quantity - confirmed_after, 0),
            "actions": actions,
        }

    # -------------------------------------------------------------------------
    # _restore_failed
    #
    # When a PATCH fails, Azure sometimes leaves the reservation in a "Failed"
    # state where sku.capacity != instanceView.currentCapacity. To get it
    # working again, we send another PATCH that lowers capacity back down to
    # currentCapacity (or at least 1). After this succeeds, the reservation
    # is usable again.
    # -------------------------------------------------------------------------
    def _restore_failed(self, sku: str, snap: ReservationSnapshot) -> None:
        target = max(snap.current_capacity, 1)
        logger.warning("[%s] Failed state; restoring to currentCapacity=%d", sku, target)
        try:
            new = self._update(sku, target)
            self._record(sku, "restore", 0, target, "success", new.current_capacity, "")
            self._persist(sku, new, "restored", "")
        except Exception as exc:
            err = _short_error(exc)
            logger.error("Restore failed for %s: %s", sku, err)
            self._record(sku, "restore", 0, target, "failure", snap.current_capacity, err)
            self._persist(sku, snap, "restore-failed", err)

    # -------------------------------------------------------------------------
    # _create_with_degrade
    #
    # First-time creation with halving-degrade. Called when no reservation
    # exists yet for this SKU. We try [want, want/2, ..., 1] and stop at the
    # first quantity Azure accepts. Every attempt is recorded in the audit
    # log so you can see exactly what happened.
    # -------------------------------------------------------------------------
    def _create_with_degrade(self, sku: str, want: int) -> Tuple[ReservationSnapshot, Dict]:
        last_err = ""
        for qty in _degrade_sequence(want):
            try:
                logger.info("CREATE %s qty=%d", sku, qty)
                snap = self._create(sku, qty)
                # Success - record it and return immediately.
                self._record(sku, "create", want, qty, "success", snap.current_capacity, "")
                self._persist(sku, snap, "created", "")
                return snap, {"action": "create", "qty": qty, "result": "success"}
            except Exception as exc:
                # Failure - log, record, and try the next smaller quantity.
                last_err = _short_error(exc)
                logger.warning("CREATE %s qty=%d failed: %s", sku, qty, last_err)
                self._record(sku, "create", want, qty, "failure", 0, last_err)

        # Whole sequence failed. Return an "empty" snapshot.
        empty = ReservationSnapshot(False, 0, 0, "None")
        self._persist(sku, empty, "failed", last_err)
        return empty, {"action": "create", "qty": 0, "result": "failure", "error": last_err}

    # -------------------------------------------------------------------------
    # _grow
    #
    # Grow an existing reservation using halving-degrade on the DELTA (not
    # the total). Example: current=5, want=45 more, tries +45, +22, +11, ...
    #
    # Special handling: if a PATCH pushes the reservation into "Failed" state
    # (Azure couldn't fulfil the increase), we restore before trying smaller
    # increments so subsequent attempts start from a healthy baseline.
    # -------------------------------------------------------------------------
    def _grow(self, sku: str, snap: ReservationSnapshot, want: int
              ) -> Tuple[ReservationSnapshot, Dict]:
        base = snap.current_capacity
        last_err = ""
        for delta in _degrade_sequence(want):
            new_cap = base + delta
            try:
                logger.info("GROW %s base=%d +%d -> %d", sku, base, delta, new_cap)
                new = self._update(sku, new_cap)

                # The SDK sometimes returns "Failed" instead of raising.
                # Treat that as an exception so our catch handles it uniformly.
                if new.provisioning_state.lower() == "failed":
                    raise RuntimeError(
                        f"Update returned Failed, currentCapacity={new.current_capacity}"
                    )

                # Success - record and return.
                self._record(sku, "update", want, new_cap, "success", new.current_capacity, "")
                self._persist(sku, new, "increased", "")
                return new, {"action": "update", "delta": delta, "result": "success"}

            except Exception as exc:
                last_err = _short_error(exc)
                logger.warning("GROW %s +%d failed: %s", sku, delta, last_err)
                self._record(sku, "update", want, new_cap, "failure", base, last_err)

                # If the update flipped the reservation into Failed, restore it
                # before continuing with smaller increments.
                refresh = self.get_snapshot(sku)
                if refresh.provisioning_state.lower() == "failed":
                    self._restore_failed(sku, refresh)
                    snap = self.get_snapshot(sku)
                    base = snap.current_capacity

        # Whole sequence failed.
        self._persist(sku, snap, "failed", last_err)
        return snap, {"action": "update", "delta": 0, "result": "failure", "error": last_err}

    # -------------------------------------------------------------------------
    # _persist : upsert one row into crState for this SKU
    # -------------------------------------------------------------------------
    def _persist(self, sku: str, snap: ReservationSnapshot,
                 outcome: str, error: str) -> None:
        self._store.upsert_state(SkuState(
            sku=sku,
            current_capacity=snap.current_capacity if snap.exists else 0,
            provisioning_state=snap.provisioning_state,
            last_attempt_utc=_now(),
            last_outcome=outcome,
            last_error=error,
        ))

    # -------------------------------------------------------------------------
    # _record : append one row to crAttempts (audit log).
    # Never allowed to break the outer flow - if the audit write fails we
    # log a warning and move on.
    # -------------------------------------------------------------------------
    def _record(self, sku: str, action: str, requested: int, attempted: int,
                result: str, resulting: int, error: str) -> None:
        try:
            self._store.append_attempt(AttemptRecord(
                timestamp_utc=_now(),
                sku=sku,
                action=action,
                requested_delta=requested,
                attempted_quantity=attempted,
                result=result,
                resulting_capacity=resulting,
                error=error,
            ))
        except Exception as exc:
            logger.warning("Failed to persist attempt for %s: %s", sku, exc)


# =============================================================================
# Module-level helpers
# =============================================================================

def _now() -> str:
    """Return the current UTC time as ISO-8601."""
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _short_error(exc: BaseException) -> str:
    """
    Reduce an Azure SDK exception to a compact "Code: Message" string.
    We store this in the audit log and the state row so the dashboard can
    show it in one line without dumping a full stack trace.
    """
    if isinstance(exc, HttpResponseError):
        code = msg = ""
        try:
            body = exc.error
            if body is not None:
                code = getattr(body, "code", "") or ""
                msg = getattr(body, "message", "") or ""
        except Exception:
            pass
        return f"{code}: {msg}".strip(": ") or str(exc)
    return f"{type(exc).__name__}: {exc}"
