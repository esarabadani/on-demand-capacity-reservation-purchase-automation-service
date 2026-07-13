# =============================================================================
# cr_config.py
#
# WHAT THIS FILE DOES
# -------------------
# Reads the 8 environment variables the Function App expects and turns them
# into a strongly typed `Config` object that the rest of the code uses.
#
# WHY A SEPARATE FILE?
# --------------------
# Every other module (state, manager, HTTP handlers) needs configuration.
# Centralising it here means:
#   - one place to fail fast if something is missing
#   - one place to change the environment variable names
#   - the manager/state code stays testable (you can construct a Config()
#     manually in a unit test)
#
# WHERE DO THE ENVIRONMENT VARIABLES COME FROM?
# ---------------------------------------------
# In Azure: Terraform sets them as Function App "app settings"
# (see infra/main.tf -> app_settings block).
# Locally:  local.settings.json.example shows you what to put in
#           src/local.settings.json when running `func start`.
# =============================================================================

from __future__ import annotations  # allows using new-style type hints on Python 3.9

import json
import os
from dataclasses import dataclass
from typing import List


# -----------------------------------------------------------------------------
# SkuTarget
#
# Represents one row from the CR_TARGETS JSON list, e.g.:
#   { "sku": "Standard_NV6ads_A10_v5", "quantity": 50 }
#
# `frozen=True` makes the object immutable, which prevents accidental mutation
# somewhere deep in the call stack.
# -----------------------------------------------------------------------------
@dataclass(frozen=True)
class SkuTarget:
    sku: str        # The exact Azure VM size name, e.g. "Standard_NV6ads_A10_v5".
    quantity: int   # How many of these VMs we want reserved (our goal).


# -----------------------------------------------------------------------------
# Config
#
# The complete typed configuration the whole app operates on.
# -----------------------------------------------------------------------------
@dataclass(frozen=True)
class Config:
    subscription_id: str    # Azure subscription that owns the reservations.
    resource_group: str     # RG in which the Capacity Reservation Group lives.
    location: str           # Azure region for reservations (e.g. "westeurope").
    group_name: str         # Name of the Capacity Reservation Group (CRG).
    targets: List[SkuTarget]  # List of SKU targets (VM sizes + quantities).
    state_table: str        # Name of the Table Storage table used for per-SKU state.
    attempts_table: str     # Name of the Table Storage table used for the audit log.
    storage_account: str    # Storage account NAME (not connection string) - used with MI.

    @property
    def storage_endpoint(self) -> str:
        """
        Build the Table Storage endpoint URL for this storage account.
        Example: "https://crbotst12345678.table.core.windows.net".
        We use this URL together with DefaultAzureCredential (managed identity)
        so no keys or connection strings are ever needed in code.
        """
        return f"https://{self.storage_account}.table.core.windows.net"


# -----------------------------------------------------------------------------
# load_config
#
# Reads every setting from os.environ, validates it, and returns a Config.
# Called at the top of every Function invocation (see _bootstrap in
# function_app.py).
# -----------------------------------------------------------------------------
def load_config() -> Config:
    # These four are REQUIRED - the app can't work without them.
    subscription_id = _require("CR_TARGET_SUBSCRIPTION_ID")
    resource_group  = _require("CR_TARGET_RESOURCE_GROUP")
    storage_account = _require("CR_STORAGE_ACCOUNT")
    targets_raw     = _require("CR_TARGETS")

    # These have safe defaults if not set.
    location   = os.environ.get("CR_LOCATION", "westeurope").strip()
    group_name = os.environ.get("CR_GROUP_NAME", "cr-group-we").strip()
    state_table    = os.environ.get("CR_STATE_TABLE", "crState").strip()
    attempts_table = os.environ.get("CR_ATTEMPTS_TABLE", "crAttempts").strip()

    # CR_TARGETS is stored as a JSON string in the app setting because Azure
    # Functions app settings can only be strings. We parse it here into
    # a proper list of SkuTarget dataclasses.
    # Example valid value:
    #   [{"sku":"Standard_NV6ads_A10_v5","quantity":50},
    #    {"sku":"Standard_NV18ads_A10_v5","quantity":9}]
    try:
        parsed = json.loads(targets_raw)
        targets = [SkuTarget(sku=t["sku"], quantity=int(t["quantity"])) for t in parsed]
    except (ValueError, KeyError, TypeError) as exc:
        raise RuntimeError(
            f"CR_TARGETS is not valid JSON of [{{sku, quantity}}]: {exc}"
        ) from exc

    if not targets:
        # Empty list would silently make the bot do nothing every hour.
        # Better to fail loudly at startup.
        raise RuntimeError("CR_TARGETS must contain at least one entry")

    return Config(
        subscription_id=subscription_id,
        resource_group=resource_group,
        location=location,
        group_name=group_name,
        targets=targets,
        state_table=state_table,
        attempts_table=attempts_table,
        storage_account=storage_account,
    )


# -----------------------------------------------------------------------------
# _require: small helper that reads an env var and raises if it's missing/empty.
# The double underscore prefix is Python convention for "internal / private".
# -----------------------------------------------------------------------------
def _require(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return val
