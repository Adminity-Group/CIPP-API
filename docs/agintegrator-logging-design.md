# agintegrator event logging — design specification

Ported from CIPP-API's logging architecture, adapted to agintegrator's domain.

**Status:** design spec, ready to implement.
**Companion document:** `agintegrator-logging-implementation-prompt.md` — the same design re-shaped as
an implementation brief. This document is the *reference*; that one is the *instruction*.

---

## Table of contents

1. [Purpose and scope](#1-purpose-and-scope)
2. [Before you implement: review what already exists](#2-before-you-implement-review-what-already-exists)
3. [Architecture at a glance](#3-architecture-at-a-glance)
4. [Design principles](#4-design-principles)
5. [Storage schema](#5-storage-schema)
6. [Reference implementations](#6-reference-implementations)
7. [Call-site conventions](#7-call-site-conventions)
8. [Severity semantics](#8-severity-semantics)
9. [Worked examples](#9-worked-examples)
10. [Query cookbook](#10-query-cookbook)
11. [Operational concerns](#11-operational-concerns)
12. [Deviations from CIPP, and why](#12-deviations-from-cipp-and-why)
13. [Implementation checklist](#13-implementation-checklist)
14. [Appendix: CIPP source references](#appendix-cipp-source-references)

---

## 1. Purpose and scope

### What this gives you

A single, uniform way for every part of agintegrator — HTTP endpoints, queue workers, durable
activities, timers — to record what happened, in a form the SWA frontend can filter and a human can
read six weeks later when a customer asks why their July invoice was wrong.

Concretely:

- One function, `Write-LogMessage`, called from everywhere. One row per event.
- One Azure Table, `AgLogs`, partitioned by day.
- One HTTP endpoint, `Invoke-ListLogs`, that serves the log to the frontend with filtering.
- One timer, `Start-LogRetentionCleanup`, that keeps the table from growing forever.
- Ambient correlation, so a log line written five call frames deep inside a billing import
  automatically carries the id of the run it belongs to — without any function in between having to
  know about it.

### Deliberately out of scope

| Excluded | Why |
|---|---|
| Application Insights / console-log mirroring | Azure Functions already ships `Write-Information` / `Write-Warning` to the host log. CIPP adds a layer that monkey-patches the `Write-*` cmdlets to tee them into App Insights; useful, orthogonal, and easy to add later without touching this design. |
| Alert / notification dispatch (email, webhook, PSA ticket) | A separate concern that *reads* the log. The schema reserves a `sentAsAlert` column so it can be added later with no migration. |
| Run-progress tracking (parent-run + child-task tables with % complete) | Different problem — that's a job-status store, not a log. `RunId` here is a correlation stamp only. |
| Log archival to blob / cold storage | Retention is delete-only. Add archival later if audit requirements demand it. |

### Terminology

The word "log" in this document always means **the application event log** — a record of things
agintegrator did, written by agintegrator, for humans and the frontend to read. It is not the Azure
Functions host log, not App Insights traces, and not a vendor's own audit log.

---

## 2. Before you implement: review what already exists

**agintegrator already has Azure Table and table-entity functions. Do not write new ones.**

Step one of this implementation is a review, not a build. Find the existing helpers in `AgCore`, check
them against the table below, and extend only where a requirement is unmet. Record the actual function
names you find — every code sample in section 6 uses placeholder names (`Get-AgTable`,
`Add-AgTableEntity`, `Get-AgTableEntity`) that you must substitute with the real ones.

> **Assumption to confirm:** this document assumes the core module is named **`AgCore`**. If it is
> named something else, substitute throughout. The module identity matters for one specific reason —
> see the `$script:` scope warning in [§6.2](#62-set-agruncontext--the-ambient-correlation-holder).

| Requirement | Why the log path needs it | If unmet |
|---|---|---|
| Builds a table context from `$env:AzureWebJobsStorage`, creating the table if it does not exist | `AgLogs` must materialise on first write in a fresh environment (new deployment, new dev machine, CI) without a manual provisioning step | Add create-if-not-exists to the existing factory. Do **not** add a second context factory. |
| Reuses / caches the context per table name | `Write-LogMessage` is on every hot path. CIPP rebuilds *two* contexts on every single log write, which is measurable overhead at thousands of calls per import | Add a script-scope cache keyed by table name |
| Write path splits oversized data: properties >30 KB into `<Prop>_Part<N>` (recording the map in `SplitOverProps`), entities >~500 KB into `-part<N>` rows carrying `OriginalEntityId` + `PartIndex` | Azure Table caps a single property at 64 KB and an entity at 1 MB. `LogData` from a failed billing batch — a rejected payload plus a stack trace — routinely exceeds the property cap. Without splitting, the write throws and the failure that caused it goes unrecorded | Port CIPP's splitting logic (see [appendix](#appendix-cipp-source-references)) into the existing writer |
| Read path reassembles both kinds of split back into the original entity | Otherwise the log viewer shows a row with `LogData_Part0`, `LogData_Part1` and no `LogData`. **This is a live bug in CIPP** — its log-read endpoint bypasses its own reassembling wrapper | Port CIPP's merge logic into the existing reader |
| Batched writes with per-entity fallback | Not needed by the logger (one row per call), but the retention cleanup deletes in batches of 5 000 | Optional for this feature |

An OData filter-value sanitiser is **expected to be absent** — `ConvertTo-AgODataFilterValue` is
specified as a new function in [§6.5](#65-convertto-agodatafiltervalue--the-injection-guard). Confirm
nothing equivalent exists under another name before adding it.

Output of this step: a short note recording (a) the real helper names, (b) which requirements were
already met, (c) what you had to add.

---

## 3. Architecture at a glance

```
                       ┌──────────────────────────────────────────┐
  HTTP endpoint   ─────┤                                          │
  Queue worker    ─────┤   Write-LogMessage                       │
  Durable activity─────┤   · resolves caller identity             │──▶  Azure Table
  Timer function  ─────┤   · reads ambient RunId (AsyncLocal)     │      AgLogs
                       │   · builds one row, conditional columns  │      PK = yyyyMMdd
                       │   · one write, never throws              │      RK = guid
                       └──────────────────────────────────────────┘         │
                                                                            │
  Set-AgRunContext ──▶ AsyncLocal[string] ──▶ (read by the logger)          │
       ▲                                                                    │
       │ set once at job start, cleared in finally                          │
                                                                            │
                       ┌──────────────────────────────────────────┐         │
  SWA frontend    ◀────┤  Invoke-ListLogs                         │◀────────┤
                       │  · OData $filter: PK range + exact refs  │         │
                       │  · client-side: severity, user, API      │         │
                       │  · { Results, Metadata } envelope        │         │
                       └──────────────────────────────────────────┘         │
                                                                            │
                       ┌──────────────────────────────────────────┐         │
  Daily 02:30     ─────┤  Start-LogRetentionCleanup               │────────▶┤ (deletes)
                       │  · reads Config/LogRetention/Settings    │         │
                       │  · PartitionKey lt cutoff, 5k batches    │         │
                       └──────────────────────────────────────────┘         │
                                                                            │
  Settings page   ◀───▶  Invoke-ExecLogRetentionConfig ────────────▶ Config table
```

Three tables in total: `AgLogs` (the events), and two rows in your existing `Config` table
(`LogRetention`/`Settings` for the retention window, `LogRetention`/`LastRun` for the rerun guard).

---

## 4. Design principles

Each of these is a choice CIPP made deliberately, and the rationale is worth understanding before you
change any of them.

### 4.1 One row per event, written synchronously

No buffering, no batching, no async fire-and-forget. A log call is a single Azure Table insert that
completes before the calling code continues.

*Why:* the failure mode of buffered logging is losing exactly the records you need — the ones written
just before the process died. Azure Table inserts are ~10–20 ms; at the volumes agintegrator generates
(hundreds to low thousands of rows per import run) that is acceptable, and it means a log line written
immediately before a crash is on disk.

*Consequence:* do not log per-item at `Info` inside a loop over 50 000 billing lines. See
[§11.2](#112-partition-throughput).

### 4.2 Partition by day, in local time

`PartitionKey` is `yyyyMMdd` in the configured timezone. `RowKey` is a fresh GUID.

*Why the day:* every real query starts with "when". Azure Table's only indexed columns are
`PartitionKey` and `RowKey`; a query that specifies `PartitionKey` is a partition scan, and one that
does not is a full table scan. Day granularity makes "today's errors" and "this week for customer X"
efficient, and makes retention a partition-range delete.

*Why local time:* the frontend's date picker shows the operator's dates. If partitions were UTC, a log
written at 00:30 Copenhagen time in summer would land in the previous day's partition and vanish from
"today".

*Why a GUID row key, not a timestamp:* within a day partition you always sort in memory anyway (Azure
Table sorts by `RowKey` ascending, which is not what a log viewer wants), and a monotonic row key would
serialise writes onto one range. A GUID guarantees no collision between concurrent workers. The cost is
that you cannot do "the 100 most recent rows" as a server-side query — you filter the partition and
sort by the auto-populated `Timestamp` client-side.

### 4.3 Schemaless, conditional columns

Azure Table does not enforce a schema. Columns that have no value for a given event are **not written
at all** rather than written empty.

*Why:* a `HaloInvoiceId` column on a product-sync row is noise. Absent means "not applicable", which is
information. It also keeps rows small, and Azure Table bills on stored bytes.

*Consequence:* readers must tolerate missing properties. Never do `$Row.HaloInvoiceId.Trim()` without a
null check. In OData, `HaloInvoiceId eq '4471'` correctly matches only rows that have the property.

### 4.4 Short human message, structured `LogData`

`Message` is one sentence a human reads in a table row. Everything else — the rejected payload, the
stack trace, the vendor's raw error, the 40 fields of the record being processed — goes into `LogData`
as compressed JSON.

CIPP's convention, worth copying verbatim: when the detail is large, the message ends with **"see Log
Data for details"**.

*Why:* the log list view is a table. A message containing a 4 KB JSON blob makes it unusable. Splitting
them lets the list stay scannable and the detail stay complete.

### 4.5 Ambient correlation, not parameter threading

A billing import calls a vendor client, which calls a mapper, which calls a Halo client. All four layers
log. All four rows must carry the same `RunId`. Threading a `-RunId` parameter through every function
signature in the call graph is invasive, easy to forget, and pollutes the API of functions that have no
business knowing about runs.

Instead: the job sets the RunId once, into a module-scoped
`[System.Threading.AsyncLocal[string]]` holder, and `Write-LogMessage` reads it. No function in between
is aware.

CIPP does exactly this for its scheduled-task and standards-template ids, and its own source comments
record the hard-won detail: *"Module script scope is used instead of global scope, which is not reliable
in Azure Functions."* `AsyncLocal` (rather than a plain `$script:` variable) is what makes it correct
under the concurrent, async-continuation execution model the Functions PowerShell worker uses.

### 4.6 Logging must never break the caller

A failed log write must not fail a billing import. The logger wraps its own storage call and degrades
to `Write-Warning` on failure.

*Why:* the alternative is an outage caused by the observability layer. This is a genuine deviation from
CIPP, where `Write-LogMessage` can and does throw.

*But not silently:* the fallback `Write-Warning` reaches the Functions host log, so a broken log path is
still visible to anyone looking. Do **not** use an empty catch block.

### 4.7 Identity is resolved inside the logger

Call sites pass raw request headers (`-Headers $Request.Headers`). Decoding the Static Web Apps
principal, or resolving a machine-to-machine client id to a friendly name, happens once inside
`Write-LogMessage`.

*Why:* 4 000 call sites in CIPP pass headers; none of them contain base64/JSON decoding. One
implementation, one place to fix.

### 4.8 `Debug` costs nothing in production

`Debug`-severity calls return immediately unless a debug flag is set, **before** any storage work. This
lets you leave dense tracing in the code permanently and switch it on when investigating.

*Why the gate goes first:* CIPP's gate runs *after* it has already built two table contexts and issued
a lookup query, so its ~400 debug call sites pay real cost even when discarded. Do not copy that.

---

## 5. Storage schema

### 5.1 Table `AgLogs`

`PartitionKey` = `yyyyMMdd` in `$env:AG_TIMEZONE` (default `UTC`). `RowKey` = new GUID.

| Column | Type | Always written? | Content |
|---|---|---|---|
| `PartitionKey` | String | yes | `yyyyMMdd`, local date |
| `RowKey` | String | yes | `[guid]::NewGuid().ToString()` |
| `Timestamp` | DateTime | auto | Azure Table populates it. Surfaced to the frontend as `DateTime` — this, not `PartitionKey`, is the precise event time |
| `API` | String | yes | The coarse channel. For HTTP endpoints, the endpoint name. Otherwise a feature name: `BillingImport`, `Provisioning`, `ProductSync`, `LogRetentionCleanup`. Default `'None'` |
| `Message` | String | yes | One sentence for a human |
| `Severity` | String | yes | Exactly one of `Debug`, `Info`, `Warning`, `Error`, `Critical`, `Alert` — canonically cased |
| `Username` | String | yes | Resolved caller. `'AG'` when nothing is resolvable (background work) |
| `FunctionNode` | String | yes | `$env:WEBSITE_SITE_NAME` — which Function App instance wrote the row |
| `LogData` | String | yes | Compressed JSON at depth 10, or `''` |
| `sentAsAlert` | Boolean | yes | Always `$false`. **Reserved** — an alert dispatcher added later flips it to `$true` after delivering a row, giving at-most-once semantics without a schema change |
| `Source` | String | yes | Where the data or action came from: a vendor name (`Sherweb`, `Dropsuite`, …), `HaloPSA`, `BusinessCentral`, or `Internal` for work agintegrator initiated itself. Default `'None'` |
| `Target` | String | yes | Where it was written to — same vocabulary. Default `'None'` |
| `Customer` | String | yes | HaloPSA client display name, or `'None'` for events that are not about one customer |
| `RunId` | String | conditional | Correlation id for one import / provisioning / sync run. Supplied by ambient context, never by the caller |
| `CustomerId` | String | conditional | HaloPSA client id |
| `HaloTicketId` | String | conditional | |
| `HaloInvoiceId` | String | conditional | |
| `BcDocumentNo` | String | conditional | Business Central document number |
| `VendorRef` | String | conditional | Vendor-side identity: subscription id, order id, billing line id |
| `ProductId` | String | conditional | Product / SKU identity. Used by provisioning and by product sync |
| `IP` | String | conditional | First entry of `x-forwarded-for`, port stripped, IPv6 brackets removed |
| `AppId` | String | conditional | Client app id, for machine-to-machine callers |
| `SplitOverProps`, `<Prop>_Part<N>`, `OriginalEntityId`, `PartIndex` | String / Int | conditional | Written by the oversize-splitting layer in the storage helper. Reassembled on read. Never set these yourself |

#### `Source` + `Target` replace CIPP's `Tenant`

CIPP scopes every row to one M365 tenant. agintegrator has no tenant, but it does have a **direction**,
and that direction is the thing you filter on. `Source` and `Target` together answer "which integration
leg is this?" and make internal events expressible:

| Event | `Source` | `Target` | `Customer` |
|---|---|---|---|
| Import Sherweb billing into Halo | `Sherweb` | `HaloPSA` | the Halo client |
| Provision a vendor service, requested from Halo | `HaloPSA` | `Sherweb` | the Halo client |
| Sync a product definition Halo → BC | `HaloPSA` | `BusinessCentral` | `None` |
| Push an invoice Halo → BC | `HaloPSA` | `BusinessCentral` | the Halo client |
| Retention cleanup, version check, startup | `Internal` | `None` | `None` |

`Customer` keeps CIPP's `'None'` sentinel exactly — it is the direct analogue of `Tenant`, and the
`'None'` convention is what lets platform-level events sit in the same table as customer-scoped ones
without a nullable column.

#### Why discrete ref columns instead of one JSON bag

`HaloInvoiceId`, `BcDocumentNo`, `VendorRef` and friends could all live inside `LogData`. They do not,
because the primary forensic question is *"show me everything that touched Halo invoice 4471"*, and that
has to be a server-side OData `$filter`. Values buried in a JSON string can only be found by pulling
every row and scanning client-side.

CIPP does the same thing for the same reason — `StandardTemplateId`, `IntuneTemplateId` and
`ConditionalAccessTemplateId` are discrete, named, conditional columns precisely so its UI can filter
on them.

### 5.2 Configuration rows

Both live in agintegrator's existing `Config` table.

| PartitionKey | RowKey | Columns | Purpose |
|---|---|---|---|
| `LogRetention` | `Settings` | `RetentionDays` (Int32) | The retention window. Absent ⇒ default 90. Clamped 7–365 on both read and write |
| `LogRetention` | `LastRun` | `LastRunUtc` (String, ISO 8601) | Rerun guard for the cleanup timer |
| `TimeSettings` | `TimeSettings` | `Timezone` (String) | Windows timezone id, loaded into `$env:AG_TIMEZONE` at startup. Optional — omit and everything uses UTC |

### 5.3 Environment variables

| Variable | Default | Effect |
|---|---|---|
| `AzureWebJobsStorage` | — | Storage connection string. Already required by the Function App |
| `AG_TIMEZONE` | `UTC` | Windows timezone id used for `PartitionKey`. Set from the `TimeSettings` config row at startup, or directly as an app setting |
| `AG_DEBUG_MODE` | unset | `true` or `1` ⇒ `Debug`-severity rows are written. Anything else ⇒ discarded |
| `WEBSITE_SITE_NAME` | — | Set by Azure automatically; recorded as `FunctionNode` |

---

## 6. Reference implementations

All samples use placeholder storage-helper names — **`Get-AgTable`, `Add-AgTableEntity`,
`Get-AgTableEntity`** — which you replace with the real names recorded in
[§2](#2-before-you-implement-review-what-already-exists).

### 6.1 `Write-LogMessage` — the logger

Place in `AgCore`, alongside `Set-AgRunContext`.

```powershell
function Write-LogMessage {
    <#
    .SYNOPSIS
        Write one event to the AgLogs table.
    .DESCRIPTION
        The single logging entrypoint for agintegrator. Resolves the calling identity from request
        headers when present, picks up the ambient RunId set by Set-AgRunContext, and writes exactly
        one row. Never throws: a storage failure degrades to Write-Warning so that the observability
        layer cannot take down a billing import.
    .PARAMETER Message
        One sentence for a human. Keep it short; put detail in -LogData.
    .PARAMETER API
        The coarse channel: an HTTP endpoint name, or a feature name such as 'BillingImport'.
    .PARAMETER Sev
        Severity. See the severity semantics section of the design doc for which to pick.
    .PARAMETER Source
        Where the data or action came from: a vendor name, 'HaloPSA', 'BusinessCentral', 'Internal'.
    .PARAMETER Target
        Where it was written to. Same vocabulary as -Source.
    .PARAMETER Customer
        HaloPSA client display name, or 'None' for events not scoped to one customer.
    .PARAMETER Headers
        $Request.Headers from an HTTP trigger. Used to resolve the calling user and client IP.
    .PARAMETER User
        Explicit username, for paths that know the identity but have no headers.
    .PARAMETER LogData
        Any object. Serialised to compressed JSON at depth 10.
    .EXAMPLE
        Write-LogMessage -API 'BillingImport' -Source 'Sherweb' -Target 'HaloPSA' `
            -Customer 'Acme A/S' -Message 'Imported 42 billing lines' -Sev Info
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [string]$API = 'None',

        [ValidateSet('Debug', 'Info', 'Warning', 'Error', 'Critical', 'Alert')]
        [string]$Sev = 'Info',

        [string]$Source = 'None',
        [string]$Target = 'None',
        [string]$Customer = 'None',
        [string]$CustomerId,

        $Headers,
        $User,

        $LogData = '',

        [string]$HaloTicketId,
        [string]$HaloInvoiceId,
        [string]$BcDocumentNo,
        [string]$VendorRef,
        [string]$ProductId
    )

    # --- Debug gate FIRST, before any storage work is done. -------------------------------------
    # ValidateSet is case-insensitive but does not rewrite the value, so compare case-insensitively.
    if ($Sev -eq 'Debug' -and $env:AG_DEBUG_MODE -notin @('true', '1')) {
        return
    }

    try {
        # --- Canonicalise severity casing. -----------------------------------------------------
        # ValidateSet accepts 'error' and 'ERROR'; both must be stored as 'Error' or the frontend's
        # severity filter silently misses rows.
        $SeverityMap = @{
            debug = 'Debug'; info = 'Info'; warning = 'Warning'
            error = 'Error'; critical = 'Critical'; alert = 'Alert'
        }
        $Severity = $SeverityMap[$Sev.ToLowerInvariant()]

        # --- Resolve the calling identity. -----------------------------------------------------
        # Every branch is guarded: a malformed principal header must not throw. CIPP's equivalent
        # leaves its first branch unguarded and throws on bad input.
        $Username = $null
        $AppId = $null
        $IPAddress = $null

        if ($Headers) {
            $Idp = $Headers.'x-ms-client-principal-idp'

            if ($Idp -eq 'aad') {
                # Machine-to-machine caller: the principal name is the client app id.
                $AppId = [string]$Headers.'x-ms-client-principal-name'
                $Username = $AppId
                # If you keep a registry of API clients, resolve a friendly name here instead:
                #   $Client = Get-AgApiClient -AppId $AppId
                #   $Username = $Client.AppName ?? $AppId
            } else {
                # Static Web Apps: base64 JSON, userDetails holds the sign-in name.
                try {
                    $Principal = [System.Text.Encoding]::UTF8.GetString(
                        [System.Convert]::FromBase64String($Headers.'x-ms-client-principal')
                    ) | ConvertFrom-Json
                    $Username = $Principal.userDetails
                } catch {
                    $Username = $Headers.'x-ms-client-principal-name'
                }
            }

            if ($Headers.'x-forwarded-for') {
                $ForwardedFor = ($Headers.'x-forwarded-for' -split ',' | Select-Object -First 1).Trim()
                # Strip the ':port' suffix Azure appends, and IPv6 brackets.
                $IPRegex = '^(?<IP>(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:]+\]|[0-9a-fA-F:]+))(?::\d+)?$'
                $IPAddress = $ForwardedFor -replace $IPRegex, '${IP}' -replace '[\[\]]', ''
            }
        }

        if (-not $Username -and $User) {
            # Explicit -User: accept either a plain name or a base64 SWA principal.
            try {
                $Principal = [System.Text.Encoding]::UTF8.GetString(
                    [System.Convert]::FromBase64String($User)
                ) | ConvertFrom-Json
                $Username = $Principal.userDetails
            } catch {
                $Username = [string]$User
            }
        }

        if ([string]::IsNullOrWhiteSpace($Username)) { $Username = 'AG' }

        # --- Serialise LogData. -----------------------------------------------------------------
        $LogDataString = ''
        if ($LogData) {
            $LogDataString = if ($LogData -is [string]) {
                $LogData
            } else {
                ConvertTo-Json -InputObject $LogData -Depth 10 -Compress
            }
        }

        # --- Day partition, in local time. ------------------------------------------------------
        $TzId = if ($env:AG_TIMEZONE) { $env:AG_TIMEZONE } else { 'UTC' }
        try {
            $LocalNow = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, $TzId)
        } catch {
            # Bad timezone id: fall back to UTC rather than losing the log line.
            $LocalNow = [DateTime]::UtcNow
        }

        # --- Build the row. Conditional columns are added only when they have a value. ----------
        $Row = @{
            PartitionKey = [string]$LocalNow.ToString('yyyyMMdd')
            RowKey       = [string][guid]::NewGuid().ToString()
            API          = [string]$API
            Message      = [string]$Message
            Severity     = [string]$Severity
            Username     = [string]$Username
            Source       = [string]$Source
            Target       = [string]$Target
            Customer     = [string]$Customer
            FunctionNode = [string]$env:WEBSITE_SITE_NAME
            LogData      = [string]$LogDataString
            sentAsAlert  = $false
        }

        # Ambient RunId: set by Set-AgRunContext, invisible to the caller.
        if ($script:AgRunIdStorage -and $script:AgRunIdStorage.Value) {
            $Row.RunId = [string]$script:AgRunIdStorage.Value
        }

        foreach ($Optional in @(
                @{ Name = 'CustomerId'; Value = $CustomerId }
                @{ Name = 'HaloTicketId'; Value = $HaloTicketId }
                @{ Name = 'HaloInvoiceId'; Value = $HaloInvoiceId }
                @{ Name = 'BcDocumentNo'; Value = $BcDocumentNo }
                @{ Name = 'VendorRef'; Value = $VendorRef }
                @{ Name = 'ProductId'; Value = $ProductId }
                @{ Name = 'IP'; Value = $IPAddress }
                @{ Name = 'AppId'; Value = $AppId }
            )) {
            if (-not [string]::IsNullOrWhiteSpace($Optional.Value)) {
                $Row[$Optional.Name] = [string]$Optional.Value
            }
        }

        # --- Write. Substitute your real storage helper names here. -----------------------------
        $Table = Get-AgTable -TableName 'AgLogs'
        Add-AgTableEntity @Table -Entity $Row | Out-Null

    } catch {
        # Principle 4.6: logging must never break the caller. Degrade loudly, not silently -
        # Write-Warning reaches the Functions host log so a broken log path stays visible.
        Write-Warning "Write-LogMessage failed to record an event: $($_.Exception.Message)"
        Write-Warning "  Unrecorded [$Sev] $API - $Message"
    }
}
```

Notes on specific choices:

- **`$Sev` has a `ValidateSet`.** CIPP does not, and the result is 1 696 `Error` rows alongside stray
  `Warn` and `Information` typos that no filter will ever match. The set plus canonicalisation makes
  severity a reliable dimension.
- **`-LogData` accepts a string unchanged.** Callers occasionally pass pre-serialised JSON;
  re-serialising it would produce a JSON string containing an escaped JSON string.
- **The `foreach` over a list of name/value pairs** rather than eight `if` statements is purely
  readability; behaviour is identical.
- **No lookup query.** CIPP resolves its `Tenant` parameter against a `Tenants` table on every single
  log write — one extra round trip per log line. agintegrator's `Customer` is a passed string, so there
  is nothing to resolve. If you later want `CustomerId` auto-filled from `Customer`, cache the mapping
  in memory; do not query per write.

### 6.2 `Set-AgRunContext` — the ambient correlation holder

```powershell
function Set-AgRunContext {
    <#
    .SYNOPSIS
        Store the current run id in module-scoped AsyncLocal storage.
    .DESCRIPTION
        Write-LogMessage reads this holder and stamps RunId onto every row, so a log line written any
        number of call frames deep inside a run is correlated without any intermediate function
        knowing about runs.

        Module script scope is used deliberately: global scope is not reliable in the Azure Functions
        PowerShell worker. AsyncLocal (rather than a plain $script: variable) is what makes the value
        correct under concurrent invocations and async continuations.

        MUST live in the same module as Write-LogMessage - $script: scope is per-module, so a setter
        in one module and a reader in another will never see each other's value.
    .PARAMETER RunId
        The run identifier. Pass $null or an empty string to clear.
    .EXAMPLE
        $RunId = (New-Guid).Guid
        Set-AgRunContext -RunId $RunId
        try   { Invoke-AgBillingImport -Vendor 'Sherweb' }
        finally { Set-AgRunContext -RunId $null }
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId
    )

    if (-not $script:AgRunIdStorage) {
        $script:AgRunIdStorage = [System.Threading.AsyncLocal[string]]::new()
    }
    $script:AgRunIdStorage.Value = $RunId
}
```

```powershell
function Get-AgRunContext {
    <#
    .SYNOPSIS
        Return the current ambient run id, or $null.
    .DESCRIPTION
        Convenience reader for code that needs the run id as a value - for example to write it onto a
        Halo ticket note or a Business Central document, so an external record points back at the run
        that created it. Write-LogMessage does not use this; it reads the holder directly.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:AgRunIdStorage) { return $script:AgRunIdStorage.Value }
    return $null
}
```

> **Always clear in a `finally`.** The Functions PowerShell worker reuses runspaces. A RunId left set
> after a job finishes will leak onto unrelated log rows written by the next invocation on that
> runspace. CIPP clears its equivalent holder in a `finally` block for exactly this reason.

### 6.3 `Get-AgException` — the `-LogData` payload

```powershell
function Get-AgException {
    <#
    .SYNOPSIS
        Turn an ErrorRecord into a structured object suitable for -LogData.
    .DESCRIPTION
        Produces both a human-readable NormalizedError (for the log Message) and the full diagnostic
        context (for LogData). This pairing is the standard catch-block idiom - see the call-site
        conventions section.
    .PARAMETER Exception
        The ErrorRecord, i.e. $_ inside a catch block.
    .EXAMPLE
        catch {
            $ErrorMessage = Get-AgException -Exception $_
            Write-LogMessage -API 'BillingImport' -Sev Error -LogData $ErrorMessage `
                -Message "Failed to post invoice: $($ErrorMessage.NormalizedError)"
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        $Exception
    )

    process {
        [PSCustomObject]@{
            Message         = $Exception.Exception.Message
            NormalizedError = Get-NormalizedError -Message $Exception.Exception.Message
            Position        = $Exception.InvocationInfo.PositionMessage
            StackTrace      = ($Exception.ScriptStackTrace | Out-String)
            ScriptName      = $Exception.InvocationInfo.ScriptName
            LineNumber      = $Exception.InvocationInfo.ScriptLineNumber
            Category        = $Exception.CategoryInfo.ToString()
        }
    }
}
```

### 6.4 `Get-NormalizedError` — vendor error → human sentence

Two jobs: dig the real message out of a nested JSON error body, then translate known-cryptic messages
into something an operator can act on.

```powershell
function Get-NormalizedError {
    <#
    .SYNOPSIS
        Extract and humanise an error message from a vendor, HaloPSA or Business Central response.
    .DESCRIPTION
        REST APIs bury the useful text at varying depths inside a JSON error envelope. This function
        unwraps the common shapes, then runs the result through a translation table that turns known
        opaque errors into an actionable sentence. Unknown messages pass through unchanged.

        The translation table below is a STARTING POINT. Replace these entries with the real error
        strings your integrations actually emit - grep your existing log rows and error handling for
        recurring messages, and add an entry each time an operator has to ask what one means.
    .PARAMETER Message
        The raw error message, typically $_.Exception.Message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Message
    )

    # --- Unwrap a JSON error envelope, if the message is one. ----------------------------------
    $Json = $null
    try { $Json = $Message | ConvertFrom-Json -ErrorAction Stop } catch { $Json = $null }

    if ($Json) {
        # Ordered most-specific first. Extend with the shapes your vendors actually return.
        $Candidates = @(
            $Json.error.innererror.message
            $Json.error.message
            $Json.error.details.message
            $Json.message
            $Json.Message
            $Json.detail
            $Json.error_description
        )
        foreach ($Candidate in $Candidates) {
            if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
                $Message = $Candidate
                break
            }
        }
    }

    # --- Translate known-opaque messages. -----------------------------------------------------
    # REPLACE these with your real observed strings. They are illustrative placeholders.
    switch -Wildcard ($Message) {
        '*401*Unauthorized*' {
            'Authentication failed. The stored credentials for this system are invalid or expired.'
        }
        '*invalid_grant*' {
            'The refresh token for this integration has expired. Re-authorise the connection.'
        }
        '*429*' {
            'Rate limited by the remote system. The operation will be retried.'
        }
        '*The remote name could not be resolved*' {
            'Could not reach the remote system - DNS resolution failed. Check the configured base URL.'
        }
        '*The property value exceeds the maximum allowed size (64KB)*' {
            'A value was too large to store. One of the logged fields exceeds the 64KB property limit.'
        }
        default { $Message }
    }
}
```

*Why a translation table at all:* CIPP's version has grown to ~30 entries, each one added because an
operator could not act on the raw message. It is the cheapest possible improvement to support quality —
every entry turns a support question into a self-service fix.

### 6.5 `ConvertTo-AgODataFilterValue` — the injection guard

Every user-supplied value that reaches an OData `$filter` string goes through this first.

```powershell
function ConvertTo-AgODataFilterValue {
    <#
    .SYNOPSIS
        Sanitise a value for safe interpolation into an OData filter string.
    .DESCRIPTION
        Prevents OData injection by escaping (String) or strictly validating (Guid, Date, Integer)
        before the value is embedded in an Azure Table $filter expression. Use for every
        user-supplied or externally-sourced value that flows into a filter.
    .PARAMETER Value
        The input value.
    .PARAMETER Type
        String  - escapes single quotes by doubling them, per the OData spec. Safe for any text field.
        Guid    - validates UUID format, throws otherwise.
        Date    - validates ISO 8601 date or yyyyMMdd, throws otherwise.
        Integer - validates all-digits, throws otherwise.
    .EXAMPLE
        $SafeCustomer = ConvertTo-AgODataFilterValue -Value $Request.Query.Customer -Type String
        $Filter = "PartitionKey eq '$SafeDate' and Customer eq '$SafeCustomer'"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [ValidateSet('String', 'Guid', 'Date', 'Integer')]
        [string]$Type = 'String'
    )

    switch ($Type) {
        'Guid' {
            if ($Value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                throw "Invalid GUID format for OData filter: '$Value'"
            }
            return $Value
        }
        'Date' {
            if ($Value -notmatch '^\d{4}-?\d{2}-?\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?)?$') {
                throw "Invalid date for OData filter. Expected ISO 8601 or yyyyMMdd, got: '$Value'"
            }
            return $Value
        }
        'Integer' {
            if ($Value -notmatch '^\d+$') {
                throw "Invalid integer for OData filter: '$Value'"
            }
            return $Value
        }
        default {
            return $Value -replace "'", "''"
        }
    }
}
```

### 6.6 `Invoke-ListLogs` — the read endpoint

Three modes, one row shape.

**Query parameters**

| Parameter | Mode | Filtering | Notes |
|---|---|---|---|
| `ListLogs=true` | partition list | — | Returns the distinct day partitions, for the date dropdown |
| `logentryid=<guid>` | single entry | server-side | Optionally with `DateFilter` to target the partition directly |
| `DateFilter=yyyyMMdd` | list | server-side `PartitionKey eq` | Single day |
| `StartDate` / `EndDate` | list | server-side `PartitionKey ge/le` | Day range. Both absent ⇒ today |
| `Severity` | list | **client-side** | CSV. Default: everything except `Debug` |
| `User` | list | client-side | Supports `*` wildcards |
| `API` | list | client-side | Regex match |
| `Source`, `Target`, `Customer` | list | server-side `eq` | Exact match; values come from frontend dropdowns |
| `RunId`, `CustomerId`, `HaloTicketId`, `HaloInvoiceId`, `BcDocumentNo`, `VendorRef`, `ProductId` | list | server-side `eq` | Exact, high-selectivity |
| `Top` | list | result cap | Default 5 000, max 50 000 |

**Why severity is filtered client-side:** it needs an OR chain (`Severity eq 'Error' or Severity eq
'Critical' or …`). CIPP's source carries the finding verbatim — *"Azurite/Azure Table OData has been
unreliable on long OR chains"* — and since the partition is already narrowed by date, the client-side
pass is over a bounded set. `User` and `API` are client-side because they support wildcard and regex
matching, which OData cannot express.

```powershell
function Invoke-ListLogs {
    <#
    .SYNOPSIS
        HTTP endpoint. Lists agintegrator event log entries with filtering.
    .DESCRIPTION
        Three modes:
          ?ListLogs=true        - the distinct day partitions, for a date picker
          ?logentryid=<guid>    - one entry by RowKey
          (default)             - a filtered list for the given day or day range

        Reads through the reassembling table helper so that rows whose LogData was split across
        properties or entities come back whole. CIPP's equivalent endpoint bypasses its own
        reassembling wrapper and returns broken rows for large payloads - do not repeat that.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $TzId = if ($env:AG_TIMEZONE) { $env:AG_TIMEZONE } else { 'UTC' }
    try {
        $LocalNow = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, $TzId)
    } catch {
        $LocalNow = [DateTime]::UtcNow
    }
    $Today = $LocalNow.ToString('yyyyMMdd')

    $Table = Get-AgTable -TableName 'AgLogs'

    # Shared projection: ONE row shape for every mode, so the frontend needs one renderer.
    $Project = {
        param($Row)

        $LogData = if ($Row.LogData) {
            try { $Row.LogData | ConvertFrom-Json -ErrorAction Stop } catch { $Row.LogData }
        } else {
            $null
        }

        [PSCustomObject]@{
            DateTime      = $Row.Timestamp
            DateFilter    = $Row.PartitionKey
            RowKey        = $Row.RowKey
            API           = $Row.API
            Message       = $Row.Message
            Severity      = $Row.Severity
            User          = $Row.Username
            Source        = $Row.Source
            Target        = $Row.Target
            Customer      = $Row.Customer
            CustomerId    = $Row.CustomerId
            RunId         = $Row.RunId
            HaloTicketId  = $Row.HaloTicketId
            HaloInvoiceId = $Row.HaloInvoiceId
            BcDocumentNo  = $Row.BcDocumentNo
            VendorRef     = $Row.VendorRef
            ProductId     = $Row.ProductId
            IP            = $Row.IP
            AppId         = $Row.AppId
            FunctionNode  = $Row.FunctionNode
            LogData       = $LogData
        }
    }

    try {
        # =====================================================================================
        # Mode 1: the list of available day partitions.
        # =====================================================================================
        if ($Request.Query.ListLogs) {
            $Partitions = Get-AgTableEntity @Table -Property 'PartitionKey' |
                Select-Object -ExpandProperty PartitionKey -Unique |
                Sort-Object -Descending |
                ForEach-Object { @{ value = $_; label = $_ } }

            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::OK
                    Body       = @{
                        Results  = @($Partitions)
                        Metadata = @{ Count = @($Partitions).Count; Mode = 'PartitionList' }
                    }
                })
        }

        # =====================================================================================
        # Mode 2: a single entry by RowKey.
        # =====================================================================================
        if ($Request.Query.logentryid) {
            $SafeId = ConvertTo-AgODataFilterValue -Value $Request.Query.logentryid -Type Guid

            $Filter = if ($Request.Query.DateFilter) {
                $SafeDate = ConvertTo-AgODataFilterValue -Value $Request.Query.DateFilter -Type Date
                "PartitionKey eq '$SafeDate' and RowKey eq '$SafeId'"
            } else {
                # No partition given: this is a full table scan. The frontend should always send
                # DateFilter, which it has from the list view's DateFilter column.
                "RowKey eq '$SafeId'"
            }

            $Row = Get-AgTableEntity @Table -Filter $Filter | Select-Object -First 1
            $Result = if ($Row) { & $Project $Row } else { $null }

            return ([HttpResponseContext]@{
                    StatusCode = if ($Row) { [HttpStatusCode]::OK } else { [HttpStatusCode]::NotFound }
                    Body       = @{
                        Results  = @($Result)
                        Metadata = @{ Count = @($Result).Count; Mode = 'SingleEntry'; Filter = $Filter }
                    }
                })
        }

        # =====================================================================================
        # Mode 3: the filtered list.
        # =====================================================================================

        # --- Server-side: the day partition. -----------------------------------------------
        $StartDate = $Request.Query.StartDate ?? $Request.Query.DateFilter
        $EndDate = $Request.Query.EndDate ?? $Request.Query.DateFilter

        $Conditions = [System.Collections.Generic.List[string]]::new()

        if ($StartDate -and $EndDate) {
            $SafeStart = ConvertTo-AgODataFilterValue -Value $StartDate -Type Date
            $SafeEnd = ConvertTo-AgODataFilterValue -Value $EndDate -Type Date
            if ($SafeStart -eq $SafeEnd) {
                $Conditions.Add("PartitionKey eq '$SafeStart'")
            } else {
                $Conditions.Add("PartitionKey ge '$SafeStart' and PartitionKey le '$SafeEnd'")
            }
        } elseif ($StartDate) {
            $SafeStart = ConvertTo-AgODataFilterValue -Value $StartDate -Type Date
            $Conditions.Add("PartitionKey ge '$SafeStart'")
        } else {
            $Conditions.Add("PartitionKey eq '$Today'")
        }

        # --- Server-side: exact-match dimensions and record references. ---------------------
        $ExactFilters = [ordered]@{
            Source        = $Request.Query.Source
            Target        = $Request.Query.Target
            Customer      = $Request.Query.Customer
            CustomerId    = $Request.Query.CustomerId
            RunId         = $Request.Query.RunId
            HaloTicketId  = $Request.Query.HaloTicketId
            HaloInvoiceId = $Request.Query.HaloInvoiceId
            BcDocumentNo  = $Request.Query.BcDocumentNo
            VendorRef     = $Request.Query.VendorRef
            ProductId     = $Request.Query.ProductId
        }
        foreach ($Column in $ExactFilters.Keys) {
            $Value = $ExactFilters[$Column]
            if (-not [string]::IsNullOrWhiteSpace($Value)) {
                $Safe = ConvertTo-AgODataFilterValue -Value $Value -Type String
                $Conditions.Add("$Column eq '$Safe'")
            }
        }

        $Filter = $Conditions -join ' and '

        # --- Client-side criteria. ----------------------------------------------------------
        # Severity: needs an OR chain, which Azure Table / Azurite handle unreliably.
        # User and API: wildcard and regex, which OData cannot express.
        $Severities = if ($Request.Query.Severity) {
            @(($Request.Query.Severity -split ',').Trim() | Where-Object { $_ })
        } else {
            @('Info', 'Warning', 'Error', 'Critical', 'Alert')   # Debug excluded by default
        }
        $UserFilter = $Request.Query.User ?? '*'
        $ApiFilter = $Request.Query.API

        $Top = 5000
        if ($Request.Query.Top) {
            $Top = [int](ConvertTo-AgODataFilterValue -Value $Request.Query.Top -Type Integer)
            if ($Top -lt 1) { $Top = 1 }
            if ($Top -gt 50000) { $Top = 50000 }
        }

        Write-Information "ListLogs filter: $Filter | Severity: $($Severities -join ',') | Top: $Top"

        $Matched = Get-AgTableEntity @Table -Filter $Filter | Where-Object {
            $_.Severity -in $Severities -and
            ($UserFilter -eq '*' -or $_.Username -like $UserFilter) -and
            ([string]::IsNullOrEmpty($ApiFilter) -or $_.API -match $ApiFilter)
        }

        $Sorted = @($Matched | Sort-Object -Property Timestamp -Descending)
        $Truncated = $Sorted.Count -gt $Top
        $Page = if ($Truncated) { $Sorted[0..($Top - 1)] } else { $Sorted }

        $Results = @(foreach ($Row in $Page) { & $Project $Row })

        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK
                Body       = @{
                    Results  = $Results
                    Metadata = @{
                        Count     = $Results.Count
                        Total     = $Sorted.Count
                        Truncated = $Truncated
                        Top       = $Top
                        Filter    = $Filter
                        Mode      = 'List'
                    }
                }
            })

    } catch {
        $ErrorMessage = Get-AgException -Exception $_
        Write-Warning "ListLogs failed: $($ErrorMessage.NormalizedError)"
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = @{
                    Results  = @()
                    Metadata = @{ Count = 0; Error = $ErrorMessage.NormalizedError }
                }
            })
    }
}
```

> **Note on the response envelope.** Every mode returns `{ Results, Metadata }`. CIPP's log endpoint
> returns a bare array for the list and no metadata at all, which is why it has no way to tell the
> frontend "there were more rows than I sent you". If you are porting a CIPP frontend table component,
> point it at `.Results`.

> **This endpoint deliberately does not log its own invocation at `Info`.** Read endpoints that log
> every call fill the log with records of people looking at the log. Trace it at `Debug` if you want it.

### 6.7 `Start-LogRetentionCleanup` — the retention timer

```powershell
function Start-LogRetentionCleanup {
    <#
    .SYNOPSIS
        Delete AgLogs rows older than the configured retention window.
    .DESCRIPTION
        Runs daily. Reads the window from Config/LogRetention/Settings (default 90 days, clamped to
        7-365), then deletes whole day partitions older than the cutoff, in batches.

        Deletion is by PartitionKey, not by Timestamp. This matters twice over:
          1. PartitionKey is indexed; Timestamp is not, so a Timestamp filter scans every row.
          2. Rows are partitioned by LOCAL date. Deleting on UTC Timestamp uses a different clock
             from the writer, so the two disagree at day boundaries. CIPP has this exact skew.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $ConfigTable = Get-AgTable -TableName 'Config'

    try {
        # --- Rerun guard: at most once per 24h, however often the timer fires. ---------------
        $LastRun = Get-AgTableEntity @ConfigTable `
            -Filter "PartitionKey eq 'LogRetention' and RowKey eq 'LastRun'" |
            Select-Object -First 1

        if ($LastRun.LastRunUtc) {
            $Elapsed = [DateTime]::UtcNow - [DateTime]::Parse(
                $LastRun.LastRunUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            if ($Elapsed.TotalHours -lt 24) {
                Write-Information "Log cleanup ran $([int]$Elapsed.TotalHours)h ago. Skipping."
                return
            }
        }

        # --- Retention window. ----------------------------------------------------------------
        $Settings = Get-AgTableEntity @ConfigTable `
            -Filter "PartitionKey eq 'LogRetention' and RowKey eq 'Settings'" |
            Select-Object -First 1

        $RetentionDays = if ($Settings.RetentionDays) { [int]$Settings.RetentionDays } else { 90 }
        if ($RetentionDays -lt 7) { $RetentionDays = 7 }
        if ($RetentionDays -gt 365) { $RetentionDays = 365 }

        # --- Cutoff, on the same clock the writer uses. ---------------------------------------
        $TzId = if ($env:AG_TIMEZONE) { $env:AG_TIMEZONE } else { 'UTC' }
        try {
            $LocalNow = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, $TzId)
        } catch {
            $LocalNow = [DateTime]::UtcNow
        }
        $Cutoff = $LocalNow.AddDays(-$RetentionDays).ToString('yyyyMMdd')

        Write-Information "Log cleanup: retention $RetentionDays days, deleting partitions < $Cutoff"

        $LogTable = Get-AgTable -TableName 'AgLogs'
        $CutoffFilter = "PartitionKey lt '$Cutoff'"
        $BatchSize = 5000
        $TotalDeleted = 0
        $BatchNumber = 0

        if ($PSCmdlet.ShouldProcess('AgLogs', "Delete rows in partitions older than $Cutoff")) {
            while ($true) {
                $BatchNumber++

                # Project only the keys - that is all Remove needs, and it keeps the read cheap.
                $Old = @(Get-AgTableEntity @LogTable -Filter $CutoffFilter `
                        -Property @('PartitionKey', 'RowKey') -First $BatchSize)

                if ($Old.Count -eq 0) { break }

                Remove-AzDataTableEntity @LogTable -Entity $Old -Force
                $TotalDeleted += $Old.Count
                Write-Information "  batch $BatchNumber - deleted $($Old.Count)"

                if ($Old.Count -lt $BatchSize) { break }
            }
        }

        # --- Stamp the guard. -----------------------------------------------------------------
        Add-AgTableEntity @ConfigTable -Entity @{
            PartitionKey = 'LogRetention'
            RowKey       = 'LastRun'
            LastRunUtc   = [DateTime]::UtcNow.ToString('o')
        } -Force | Out-Null

        Write-LogMessage -API 'LogRetentionCleanup' -Source 'Internal' `
            -Message "Log cleanup completed. Deleted $TotalDeleted rows in $BatchNumber batch(es), retention $RetentionDays days." `
            -Sev Info

    } catch {
        $ErrorMessage = Get-AgException -Exception $_
        Write-LogMessage -API 'LogRetentionCleanup' -Source 'Internal' `
            -Message "Log cleanup failed: $($ErrorMessage.NormalizedError)" `
            -Sev Error -LogData $ErrorMessage
        throw
    }
}
```

Register it on a daily timer. If agintegrator uses plain Azure Functions timer triggers:

```json
{
  "bindings": [
    {
      "name": "Timer",
      "type": "timerTrigger",
      "direction": "in",
      "schedule": "0 30 2 * * *"
    }
  ]
}
```

`0 30 2 * * *` is 02:30 daily — CIPP's schedule, chosen to be well clear of business-hours load. If
agintegrator has a CIPP-style timer registry (a JSON file of commands and cron expressions dispatched
by one timer function), register `Start-LogRetentionCleanup` there instead of adding a function folder.

### 6.8 `Invoke-ExecLogRetentionConfig` — the settings endpoint

```powershell
function Invoke-ExecLogRetentionConfig {
    <#
    .SYNOPSIS
        HTTP endpoint. Read or set the log retention window.
    .DESCRIPTION
        GET  ?List=true  - returns { RetentionDays }
        POST { RetentionDays } - validates 7-365 and stores it
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = 'ExecLogRetentionConfig'
    $Headers = $Request.Headers
    $Table = Get-AgTable -TableName 'Config'
    $Filter = "PartitionKey eq 'LogRetention' and RowKey eq 'Settings'"

    $Results = try {
        if ($Request.Query.List) {
            $Settings = Get-AgTableEntity @Table -Filter $Filter | Select-Object -First 1
            @{ RetentionDays = if ($Settings.RetentionDays) { [int]$Settings.RetentionDays } else { 90 } }
        } else {
            $RetentionDays = [int]$Request.Body.RetentionDays
            if ($RetentionDays -lt 7) { throw 'Retention must be at least 7 days.' }
            if ($RetentionDays -gt 365) { throw 'Retention must be at most 365 days.' }

            Add-AgTableEntity @Table -Entity @{
                PartitionKey  = 'LogRetention'
                RowKey        = 'Settings'
                RetentionDays = $RetentionDays
            } -Force | Out-Null

            Write-LogMessage -Headers $Headers -API $APIName -Source 'Internal' `
                -Message "Set log retention to $RetentionDays days" -Sev Info

            "Successfully set log retention to $RetentionDays days"
        }
    } catch {
        $ErrorMessage = Get-AgException -Exception $_
        Write-LogMessage -Headers $Headers -API $APIName -Source 'Internal' `
            -Message "Failed to set log retention: $($ErrorMessage.NormalizedError)" `
            -Sev Error -LogData $ErrorMessage
        "Failed: $($ErrorMessage.NormalizedError)"
    }

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = @{ Results = $Results }
        })
}
```

---

## 7. Call-site conventions

Consistency here is what makes the log queryable. CIPP has 4 026 `Write-LogMessage` call sites and its
conventions are documented in-repo precisely because inconsistency at the call site is what degrades a
log into noise.

### 7.1 HTTP endpoints

```powershell
function Invoke-ExecProvisionService {
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = 'ExecProvisionService'      # or $Request.Params.<your route param>
    $Headers = $Request.Headers

    Write-LogMessage -Headers $Headers -API $APIName -Message 'Accessed this API' -Sev Debug

    try {
        # ... do the work ...
        Write-LogMessage -Headers $Headers -API $APIName `
            -Source 'HaloPSA' -Target 'Sherweb' `
            -Customer $Customer -CustomerId $CustomerId `
            -HaloTicketId $TicketId -ProductId $ProductId `
            -Message "Provisioned $($Product.Name) for $Customer" -Sev Info

        $StatusCode = [HttpStatusCode]::OK
        $Body = @{ Results = 'Provisioned successfully' }
    } catch {
        $ErrorMessage = Get-AgException -Exception $_
        Write-LogMessage -Headers $Headers -API $APIName `
            -Source 'HaloPSA' -Target 'Sherweb' `
            -Customer $Customer -HaloTicketId $TicketId -ProductId $ProductId `
            -Message "Failed to provision $($Product.Name): $($ErrorMessage.NormalizedError)" `
            -Sev Error -LogData $ErrorMessage

        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
```

Rules:

- **`$Headers = $Request.Headers` at the top, always passed as `-Headers $Headers`.** This is the audit
  trail — who did it, from where. Without it every row says `Username = 'AG'`.
  *(CIPP's own central audit log is broken by exactly this mistake: `New-CippCoreRequest.ps1:172`
  passes an undefined `$Headers` variable, so its one per-request audit row is unattributed.)*
- **`$APIName` set once** and used for every call in the function, so all rows from one endpoint share
  a filterable channel.
- **Write operations log; read operations generally do not.** A `List*` endpoint that logs at `Info`
  fills the log with records of people reading it. Trace at `Debug` if useful.
- **Always set `-Source` and `-Target`.** They default to `'None'`, and a row with no direction is much
  less useful.

### 7.2 The catch-block idiom

The single most important convention. Memorise it:

```powershell
try {
    # ... the operation ...
} catch {
    $ErrorMessage = Get-AgException -Exception $_
    Write-LogMessage -API $APIName -Source $Source -Target $Target -Customer $Customer `
        -Message "Failed to <do the thing>: $($ErrorMessage.NormalizedError)" `
        -Sev Error -LogData $ErrorMessage
}
```

`NormalizedError` in the message (human-readable), the whole object in `LogData` (stack trace, position,
category). When the detail is large, keep the message short and end it with **"see Log Data for
details"**.

Two traps:

- **Never `$($_.Exception.Message)` inside a `ForEach-Object` catch block.** `$_` there is the pipeline
  item, not the error. CIPP has live instances of this bug where the error text is silently empty. Use
  a `foreach` statement, or capture `$Err = $_` first.
- **Do not log and rethrow at every level.** Log where you have the context to say something useful,
  then rethrow. Logging the same failure at four levels produces four rows for one event.

### 7.3 Background jobs — the RunId idiom

```powershell
function Invoke-AgBillingImportRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Vendor,
        [Parameter(Mandatory)][string]$Period
    )

    $RunId = (New-Guid).Guid
    Set-AgRunContext -RunId $RunId

    try {
        Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
            -Message "Starting billing import for $Period" -Sev Info

        # Everything called from here - vendor client, mapper, Halo client, any depth -
        # produces rows stamped with this RunId. None of them know about RunId.
        Import-AgVendorBilling -Vendor $Vendor -Period $Period

    } finally {
        # MUST clear. Runspaces are reused; a leaked RunId contaminates the next invocation.
        Set-AgRunContext -RunId $null
    }
}
```

Queue workers, durable activity functions and timers have **no request headers**, so their rows carry
`Username = 'AG'`. That is correct and expected — the attribution for background work is the `RunId`
plus whatever queued it, not a user.

If a background job was originally triggered by a user (a provisioning request from Halo that got
queued), persist the four relevant headers onto the queue item and replay them. CIPP prunes to an
allowlist before storing, which is the right instinct — never persist a whole header collection:

```powershell
$HeaderAllowlist = @(
    'x-ms-client-principal'
    'x-ms-client-principal-id'
    'x-ms-client-principal-name'
    'x-forwarded-for'
)
$StoredHeaders = $Request.Headers | Select-Object -Property $HeaderAllowlist -ErrorAction SilentlyContinue
```

### 7.4 When to skip logging

| Situation | What to do |
|---|---|
| Per-item success inside a large loop | Log the aggregate, not the items. `"Imported 4 812 of 4 830 lines"` plus one `Error` row per failure beats 4 830 `Info` rows. See [§11.2](#112-partition-throughput) |
| Read-only list endpoints | No log, or `Debug` |
| Rerun / duplicate-execution guards | `Write-Information`, not the table — a skipped run is not an event worth keeping for 90 days |
| Dense development tracing | `Debug`. Free in production |
| Retry attempts | Log the final outcome. One `Warning` for "succeeded after 3 attempts" beats three rows |

### 7.5 Message-writing style

- Present or past tense, active, specific: `"Imported 42 billing lines for Acme A/S"`, not
  `"Processing complete"`.
- Include the numbers. `"Skipped 3 lines with unmapped SKUs"` is actionable; `"Some lines skipped"` is
  not.
- Do not repeat what the columns already say. `-Customer 'Acme A/S'` is already a column; the message
  does not need to start with "For customer Acme A/S".
- Do not put JSON in the message. That is what `LogData` is for.

---

## 8. Severity semantics

Six levels. The distinction that matters most is **`Error` versus `Critical`**: did one unit of work
fail while the run continued, or is the integration itself broken?

| Severity | Meaning | agintegrator examples |
|---|---|---|
| `Debug` | Development tracing. Discarded unless `AG_DEBUG_MODE` is set | `'Accessed this API'`; "mapped vendor SKU X to Halo product Y"; per-field mapping decisions |
| `Info` | Normal successful work | Run started / completed; "imported 42 billing lines"; "provisioned Microsoft 365 Business Premium ×5"; "created BC document 108423" |
| `Warning` | Degraded, but the operation continued | Line skipped because the SKU is unmapped; a retry that eventually succeeded; product already existed so creation was a no-op; a billing line with a zero quantity |
| `Error` | **One unit of work failed. The run continued.** | Halo rejected one invoice line; one provisioning call failed for one customer; one product failed to sync to BC |
| `Critical` | **The run or the integration is broken.** Nothing more will succeed until someone acts | Vendor credentials rejected; refresh token expired; vendor API unreachable; the whole import aborted; the BC company is not found; a required mapping table is empty |
| `Alert` | Needs a human to look, even though nothing technically failed | Billing total deviates more than X% from last period; a provisioning request has been pending for more than N hours; a vendor reported a subscription agintegrator has no record of |

Practical rules:

- **`Error` is per-item; `Critical` is per-run.** A billing import that logs 12 `Error` rows and one
  `Info` "completed with 12 failures" is working correctly. A billing import that logs one `Critical`
  "aborted: credentials rejected" needs someone now.
- **`Critical` should be rare.** In CIPP it is 19 call sites out of 4 026 — reserved for "the platform
  itself is degraded". Keep that ratio.
- **`Alert` is for business-rule anomalies**, not technical failures. It exists so the future alert
  dispatcher has a severity that means "notify a human" independent of whether code threw.
- **Casing is canonicalised by the logger**, so `-Sev error` and `-Sev Error` both store `Error`. Write
  it however you like; it lands consistent.

---

## 9. Worked examples

### 9.1 Billing import — the primary use case

One run, one `RunId`, aggregate success plus per-failure detail.

```powershell
function Invoke-AgBillingImport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Vendor,
        [Parameter(Mandatory)][string]$Period
    )

    $RunId = (New-Guid).Guid
    Set-AgRunContext -RunId $RunId

    $Imported = 0
    $Skipped = 0
    $Failed = 0

    try {
        Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
            -Message "Starting billing import for period $Period" -Sev Info

        # A Critical failure here aborts the whole run - see the outer catch.
        $Lines = Get-AgVendorBillingLines -Vendor $Vendor -Period $Period

        Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
            -Message "Retrieved $($Lines.Count) billing lines from $Vendor" -Sev Info

        foreach ($Line in $Lines) {
            try {
                $Mapping = Get-AgProductMapping -Vendor $Vendor -VendorSku $Line.Sku
                if (-not $Mapping) {
                    # Degraded but continuing: Warning, per line, because each needs a human fix.
                    $Skipped++
                    Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
                        -Customer $Line.CustomerName -CustomerId $Line.HaloClientId `
                        -VendorRef $Line.SubscriptionId `
                        -Message "Skipped line: vendor SKU '$($Line.Sku)' has no Halo product mapping" `
                        -Sev Warning -LogData $Line
                    continue
                }

                $Invoice = New-AgHaloInvoiceLine -Line $Line -Mapping $Mapping
                $Imported++

                # Per-line success at Debug, not Info - see §11.2 on partition throughput.
                Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
                    -Customer $Line.CustomerName -CustomerId $Line.HaloClientId `
                    -VendorRef $Line.SubscriptionId -HaloInvoiceId $Invoice.Id `
                    -ProductId $Mapping.HaloProductId `
                    -Message "Imported line $($Line.Sku) x$($Line.Quantity)" -Sev Debug

            } catch {
                # One line failed. The run continues: Error, not Critical.
                $Failed++
                $ErrorMessage = Get-AgException -Exception $_
                Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
                    -Customer $Line.CustomerName -CustomerId $Line.HaloClientId `
                    -VendorRef $Line.SubscriptionId `
                    -Message "Failed to import line $($Line.Sku): $($ErrorMessage.NormalizedError)" `
                    -Sev Error -LogData @{ Error = $ErrorMessage; Line = $Line }
            }
        }

        # The summary row. Severity reflects the outcome.
        $Outcome = if ($Failed -gt 0) { 'Warning' } else { 'Info' }
        Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
            -Message "Billing import for $Period completed: $Imported imported, $Skipped skipped, $Failed failed" `
            -Sev $Outcome `
            -LogData @{ Period = $Period; Imported = $Imported; Skipped = $Skipped; Failed = $Failed }

    } catch {
        # The run itself broke. Critical.
        $ErrorMessage = Get-AgException -Exception $_
        Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
            -Message "Billing import for $Period aborted: $($ErrorMessage.NormalizedError). See Log Data for details." `
            -Sev Critical `
            -LogData @{ Error = $ErrorMessage; Period = $Period; Imported = $Imported; Failed = $Failed }
        throw
    } finally {
        Set-AgRunContext -RunId $null
    }
}
```

What the log looks like afterwards, filtered by `RunId`:

| DateTime | Severity | Source → Target | Customer | Message |
|---|---|---|---|---|
| 02:00:03 | Info | Sherweb → HaloPSA | None | Starting billing import for period 2026-07 |
| 02:00:11 | Info | Sherweb → HaloPSA | None | Retrieved 4830 billing lines from Sherweb |
| 02:01:47 | Warning | Sherweb → HaloPSA | Acme A/S | Skipped line: vendor SKU 'CSP-EXO-P2' has no Halo product mapping |
| 02:03:12 | Error | Sherweb → HaloPSA | Beta ApS | Failed to import line CSP-M365-BP: Halo rejected the line — client has no active contract |
| 02:07:55 | Warning | Sherweb → HaloPSA | None | Billing import for 2026-07 completed: 4812 imported, 17 skipped, 1 failed |

Five rows to read, one `Error` to act on, and `?RunId=<guid>` reproduces the whole run — including the
4 812 `Debug` rows if `AG_DEBUG_MODE` was on.

### 9.2 Provisioning, triggered from HaloPSA

Direction reverses; a user is attributable; the Halo ticket is the ref.

```powershell
$RunId = (New-Guid).Guid
Set-AgRunContext -RunId $RunId
try {
    Write-LogMessage -Headers $Headers -API 'Provisioning' `
        -Source 'HaloPSA' -Target $Vendor `
        -Customer $Customer -CustomerId $HaloClientId -HaloTicketId $TicketId `
        -Message "Provisioning request received for $($Product.Name) x$Quantity" -Sev Info

    $Order = New-AgVendorSubscription -Vendor $Vendor -Product $Product -Quantity $Quantity

    Write-LogMessage -Headers $Headers -API 'Provisioning' `
        -Source 'HaloPSA' -Target $Vendor `
        -Customer $Customer -CustomerId $HaloClientId -HaloTicketId $TicketId `
        -ProductId $Product.Id -VendorRef $Order.SubscriptionId `
        -Message "Provisioned $($Product.Name) x$Quantity, vendor subscription $($Order.SubscriptionId)" `
        -Sev Info
} catch {
    $ErrorMessage = Get-AgException -Exception $_
    Write-LogMessage -Headers $Headers -API 'Provisioning' `
        -Source 'HaloPSA' -Target $Vendor `
        -Customer $Customer -CustomerId $HaloClientId -HaloTicketId $TicketId -ProductId $Product.Id `
        -Message "Failed to provision $($Product.Name): $($ErrorMessage.NormalizedError)" `
        -Sev Error -LogData $ErrorMessage
    throw
} finally {
    Set-AgRunContext -RunId $null
}
```

### 9.3 Internal event — product sync HaloPSA → Business Central

No customer. `Customer` stays `'None'`; direction carries the meaning.

```powershell
$RunId = (New-Guid).Guid
Set-AgRunContext -RunId $RunId
try {
    Write-LogMessage -API 'ProductSync' -Source 'HaloPSA' -Target 'BusinessCentral' `
        -Message 'Starting product sync' -Sev Info

    foreach ($Product in $HaloProducts) {
        try {
            $Existing = Get-AgBcItem -ItemNo $Product.Code
            if ($Existing) {
                if (Test-AgProductChanged -Halo $Product -Bc $Existing) {
                    Update-AgBcItem -ItemNo $Product.Code -From $Product
                    Write-LogMessage -API 'ProductSync' -Source 'HaloPSA' -Target 'BusinessCentral' `
                        -ProductId $Product.Id -BcDocumentNo $Product.Code `
                        -Message "Updated BC item $($Product.Code)" -Sev Info
                } else {
                    Write-LogMessage -API 'ProductSync' -Source 'HaloPSA' -Target 'BusinessCentral' `
                        -ProductId $Product.Id -BcDocumentNo $Product.Code `
                        -Message "BC item $($Product.Code) already up to date" -Sev Debug
                }
            } else {
                New-AgBcItem -From $Product
                Write-LogMessage -API 'ProductSync' -Source 'HaloPSA' -Target 'BusinessCentral' `
                    -ProductId $Product.Id -BcDocumentNo $Product.Code `
                    -Message "Created BC item $($Product.Code)" -Sev Info
            }
        } catch {
            $ErrorMessage = Get-AgException -Exception $_
            Write-LogMessage -API 'ProductSync' -Source 'HaloPSA' -Target 'BusinessCentral' `
                -ProductId $Product.Id -BcDocumentNo $Product.Code `
                -Message "Failed to sync product $($Product.Code): $($ErrorMessage.NormalizedError)" `
                -Sev Error -LogData @{ Error = $ErrorMessage; Product = $Product }
        }
    }
} finally {
    Set-AgRunContext -RunId $null
}
```

### 9.4 A business-rule anomaly — `Alert`

Nothing failed. Someone still needs to look.

```powershell
$Deviation = [math]::Abs(($ThisPeriodTotal - $LastPeriodTotal) / $LastPeriodTotal) * 100
if ($Deviation -gt 20) {
    Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
        -Message "Billing total for $Period deviates $([math]::Round($Deviation, 1))% from the previous period" `
        -Sev Alert `
        -LogData @{
            Period       = $Period
            ThisPeriod   = $ThisPeriodTotal
            LastPeriod   = $LastPeriodTotal
            DeviationPct = [math]::Round($Deviation, 1)
        }
}
```

---

## 10. Query cookbook

The OData `$filter` behind each frontend view. **Every one of these should include a
`PartitionKey` term** — see the warning below.

| View | Filter | Client-side |
|---|---|---|
| Today's activity | `PartitionKey eq '20260726'` | severity ∈ default set |
| Today's problems | `PartitionKey eq '20260726'` | severity ∈ `Error, Critical, Alert` |
| One run, end to end | `PartitionKey eq '20260726' and RunId eq '<guid>'` | severity: all, including `Debug` |
| Everything for one customer, last 7 days | `PartitionKey ge '20260720' and PartitionKey le '20260726' and Customer eq 'Acme A/S'` | — |
| Everything that touched Halo invoice 4471 | `PartitionKey ge '20260701' and PartitionKey le '20260731' and HaloInvoiceId eq '4471'` | — |
| One vendor subscription's history | `PartitionKey ge '20260501' and PartitionKey le '20260726' and VendorRef eq 'SUB-99182'` | — |
| Halo → BC syncs this month | `PartitionKey ge '20260701' and PartitionKey le '20260731' and Source eq 'HaloPSA' and Target eq 'BusinessCentral'` | — |
| One vendor's billing imports | `PartitionKey ge '20260701' and PartitionKey le '20260731' and Source eq 'Sherweb'` | `API` matches `BillingImport` |
| One provisioning ticket | `PartitionKey ge '20260720' and PartitionKey le '20260726' and HaloTicketId eq '88213'` | — |
| What did user X do today | `PartitionKey eq '20260726'` | `Username -like '*psh@*'` |
| Available dates, for the picker | (no filter, project `PartitionKey` only) | — |

> **Any filter without a `PartitionKey` term is a full table scan.** Azure Table indexes only
> `PartitionKey` and `RowKey`; a query on `RunId` alone reads every row in the table and filters
> server-side, which gets slow and expensive as retention accumulates. Always carry the date range
> through from the UI. The frontend has it: the list view returns `DateFilter` on every row, so
> "show me this whole run" can pass both `RunId` and the row's own `DateFilter`.
>
> The one legitimate exception is the date-picker query, which projects only `PartitionKey` — cheap
> per row, but still proportional to total retained rows. Cache it in the frontend.

---

## 11. Operational concerns

### 11.1 Azure Table limits

| Limit | Value | What it means here |
|---|---|---|
| Property size | 64 KB | A large `LogData` hits this. The storage helper's property-splitting is what keeps the write from failing — this is why [§2](#2-before-you-implement-review-what-already-exists) treats splitting as a hard requirement |
| Entity size | 1 MB | Enforced by entity-splitting into `-part<N>` rows |
| Properties per entity | 255 (252 usable) | The schema uses ~25. Ample headroom |
| Batch operation | 100 entities, one partition | Relevant to retention deletes, not to the logger |
| `PartitionKey` / `RowKey` | 1 KB each | Not a constraint |

The practical guidance: **cap what you put in `LogData`.** A rejected 5 MB vendor payload should be
truncated, or summarised, or written to blob storage with a reference in `LogData` — not stored inline
across 170 split properties.

```powershell
$Payload = $Response.Content
if ($Payload.Length -gt 20000) {
    $Payload = $Payload.Substring(0, 20000) + "`n... truncated, original length $($Payload.Length)"
}
```

### 11.2 Partition throughput

Day partitioning means **one hot partition per day**. Azure Table's documented target is ~2 000
entities/second per partition, and a single partition is served by one server.

A billing import over 50 000 lines that logs one `Info` row per line writes 50 000 rows into today's
partition. That will throttle, and it will make "today's activity" a 50 000-row query.

Mitigations, in order of preference:

1. **Log per-item success at `Debug`, not `Info`** (as in [§9.1](#91-billing-import--the-primary-use-case)). Free in production, available when investigating.
2. **Log the aggregate at `Info`.** One summary row with counts in `LogData`.
3. **Log per-item only on failure.** `Warning` / `Error` rows are bounded by how much is actually wrong.
4. If you genuinely need per-item durable records of successes, that is a **data store, not a log** —
   put it in its own table keyed by run and line, not in `AgLogs`.

### 11.3 Timezone consistency

Three places must agree on the clock: the writer's `PartitionKey`, the retention cutoff, and the
frontend's date picker. All three use `$env:AG_TIMEZONE`.

- **Changing `AG_TIMEZONE` later does not rewrite history.** Existing partitions keep the boundaries
  they were written with. Expect a one-day seam. Pick a timezone at deployment and leave it.
- **An invalid timezone id must not lose log lines.** Both `Write-LogMessage` and the cleanup fall back
  to UTC on `FindSystemTimeZoneById` failure rather than throwing.
- **Windows vs IANA ids.** `[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId` on Linux-hosted Functions
  accepts IANA ids (`Europe/Copenhagen`); on Windows it wants Windows ids (`Romance Standard Time`).
  Verify against your actual hosting OS.

### 11.4 Cost

Azure Table bills per transaction and per stored GB. Rough shape:

- **Writes:** one transaction per log row. This is the dominant cost, and it is why [§11.2](#112-partition-throughput) matters commercially as well as technically.
- **Reads:** `Invoke-ListLogs` bills per entity returned by the *server-side* filter, not per row after
  client-side filtering. A wide date range with a narrow severity filter still pays for every row in
  every partition it scanned. Keep default date ranges tight.
- **Deletes:** one transaction per row deleted, batched 100 at a time. A 90-day retention on a
  high-volume install deletes a lot of rows; that is a real, if small, recurring cost.

### 11.5 What is deliberately not solved

- **No paging.** `Top` caps the result and `Metadata.Truncated` tells the frontend it was capped.
  Genuine paging over Azure Table needs continuation tokens threaded through the API. Add it if
  operators actually hit the cap.
- **No full-text search.** `Message` is only matched by whatever the client-side pass does. If you need
  to search message text, that is a search index, not a table query.
- **No log-write auditing.** Nothing records that a log row was deleted by retention.

---

## 12. Deviations from CIPP, and why

Every one of these is a defect found in CIPP's live implementation while deriving this design. They are
listed so that a reviewer comparing the two does not "fix" agintegrator back to CIPP's behaviour.

| # | CIPP behaviour | agintegrator | Rationale |
|---|---|---|---|
| 1 | No `ValidateSet` on the severity parameter. Stored values include `Warn`, `Information`, and every casing of `info` / `error` | `ValidateSet` + canonicalisation to TitleCase | Severity is a primary filter dimension. Unvalidated, typos produce rows no filter matches — silently invisible |
| 2 | The log-read endpoint calls the *raw* table reader, bypassing the reassembling wrapper it has | Always read through the reassembling helper | Rows whose `LogData` was split come back as `LogData_Part0`, `LogData_Part1` with no `LogData`. Precisely the large error payloads you most need to read |
| 3 | Single-entry mode returns a `Standard` property; list mode returns `StandardInfo` | One projection, one shape, all modes | The frontend needs one renderer, not two |
| 4 | No result cap and no metadata. A wide date range scans every partition and sorts in memory | `Top` (default 5 000, max 50 000) + `Metadata.Truncated` | A frontend that cannot tell it got a partial result shows wrong data confidently |
| 5 | Retention deletes on `Timestamp lt datetime'...'` (UTC) while rows are partitioned by *local* date | Delete on `PartitionKey lt '<cutoff>'`, same clock as the writer | Two clocks disagree at day boundaries. `PartitionKey` is also indexed, `Timestamp` is not |
| 6 | Every log write builds two table contexts and issues a lookup query against a `Tenants` table | One cached context, no lookup query | Two round trips per log line. At import volumes that is the difference between logging freely and logging carefully |
| 7 | The `Debug` gate returns *after* the header decode, tenant lookup and context construction | Gate first, before any work | ~400 debug call sites in CIPP pay full cost even when discarded |
| 8 | The SWA-principal base64 decode in the first identity branch is unguarded | Every decode branch in `try`/`catch` | A malformed or absent principal header throws out of the logger |
| 9 | `Write-LogMessage` can throw, and callers do not expect it to | Whole body guarded; degrades to `Write-Warning` | Observability must not be able to fail a billing import. Loud fallback, never an empty catch |
| 10 | The one central per-request audit row passes an undefined `$Headers` variable, so it is unattributed — and is written at `Debug`, so it is discarded anyway | Endpoints pass `$Request.Headers` explicitly | CIPP has no working record of who called what |
| 11 | Two different partition-key conventions coexist: the main logger uses the configured timezone, sibling writers use `Get-Date -UFormat '%Y%m%d'` (server local) | One convention, one helper path | Rows that should share a partition do not |
| 12 | A `SkipLog` property is set on orchestrator/activity input objects in 53 places and read in none of them. (A separate, genuinely working `-SkipLog` *switch* exists on the license-check helper — the dead one is the input-object property) | Not carried over | Dead code that reads like a feature. If you want a "do not log this" flag, make it a real parameter that something reads |

Two CIPP behaviours worth **keeping** even though they look wrong at first:

- **Client-side severity filtering.** It looks like a performance bug. It is a deliberate workaround for
  unreliable OData OR-chain handling, and the in-code comment says so. The partition is already narrow.
- **GUID row keys.** They prevent server-side "most recent N" queries. They also prevent collisions
  between concurrent workers and hot-spotting on a monotonic key, which matters more.

---

## 13. Implementation checklist

**Phase 0 — review (do this first, report before writing code)**

- [ ] Locate agintegrator's existing table-context and table-entity functions in `AgCore`. Record the
      real names.
- [ ] Confirm the core module name is `AgCore`; if not, note the actual name.
- [ ] Check each requirement in [§2](#2-before-you-implement-review-what-already-exists): connection
      string source, create-if-not-exists, context caching, property splitting on write, entity
      splitting on write, reassembly on read.
- [ ] Confirm no OData filter-value sanitiser already exists under another name.
- [ ] Report: real names, requirements already met, gaps to close.

**Phase 1 — storage prerequisites**

- [ ] Close any gaps found in phase 0, **inside the existing helpers** — no parallel implementations.
- [ ] Add `ConvertTo-AgODataFilterValue`.

**Phase 2 — the logger**

- [ ] `Set-AgRunContext` and `Get-AgRunContext`, in the same module as the logger.
- [ ] `Get-NormalizedError`, seeded with agintegrator's real error strings.
- [ ] `Get-AgException`.
- [ ] `Write-LogMessage`.
- [ ] Confirm `Debug` rows are discarded with `AG_DEBUG_MODE` unset and written when it is `true`.
- [ ] Confirm a forced storage failure produces a `Write-Warning` and does **not** throw.

**Phase 3 — read and retain**

- [ ] `Invoke-ListLogs`, all three modes, one row shape.
- [ ] `Start-LogRetentionCleanup` + its daily timer registration at `0 30 2 * * *`.
- [ ] `Invoke-ExecLogRetentionConfig`.

**Phase 4 — adopt**

- [ ] Add the `$APIName` / `$Headers` boilerplate to existing HTTP endpoints.
- [ ] Wrap billing import, provisioning and product sync in `Set-AgRunContext` with a `finally` clear.
- [ ] Replace existing ad-hoc error handling with the `Get-AgException` catch idiom.
- [ ] Audit for the `ForEach-Object` `$_`-shadowing trap ([§7.2](#72-the-catch-block-idiom)).
- [ ] Set `AG_TIMEZONE` in app settings.

**Phase 5 — verify** (see the companion prompt document for the runnable script)

- [ ] A row written at each severity lands with correct casing.
- [ ] `PartitionKey` matches today's *local* date.
- [ ] Conditional columns are absent, not empty, when not supplied.
- [ ] A `>30 KB` `LogData` round-trips through write and read intact.
- [ ] `RunId` appears on rows written by nested functions that never mention it.
- [ ] `RunId` is absent again after the `finally` clears it.
- [ ] All three `Invoke-ListLogs` modes return the documented envelope.
- [ ] Retention deletes back-dated partitions and leaves recent ones alone.

---

## Appendix: CIPP source references

For anyone who wants to read the original. Paths are relative to the CIPP-API repository root and were
verified against it while writing this document.

| Concern | CIPP file |
|---|---|
| The logger | `Modules/CIPPCore/Public/GraphHelper/Write-LogMessage.ps1` |
| Table context factory | `Modules/CIPPCore/Public/GraphHelper/Get-CIPPTable.ps1` |
| Write wrapper, with property/entity splitting | `Modules/CIPPCore/Public/Add-CIPPAzDataTableEntity.ps1` |
| Read wrapper, with reassembly | `Modules/CIPPCore/Public/Get-CIPPAzDatatableEntity.ps1` |
| Exception → `LogData` object | `Modules/CIPPCore/Public/GraphHelper/Get-CippException.ps1` |
| Error message translation table | `Modules/CIPPCore/Public/GraphHelper/Get-NormalizedError.ps1` |
| OData injection guard | `Modules/CIPPCore/Public/ConvertTo-CIPPODataFilterValue.ps1` |
| AsyncLocal correlation holders | `Modules/CIPPCore/Public/Set-CippScheduledTaskContext.ps1`, `Modules/CIPPCore/Public/Set-CippStandardInfoContext.ps1` |
| Setting and clearing correlation in a job | `Modules/CIPPActivityTriggers/Public/Entrypoints/Activity Triggers/Push-ExecScheduledCommand.ps1`, `.../Standards/Push-CIPPStandard.ps1` |
| The log-read endpoint | `Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Invoke-ListLogs.ps1` |
| Retention timer | `Modules/CIPPCore/Public/Entrypoints/Timer Functions/Start-LogRetentionCleanup.ps1` |
| Retention timer schedule (`0 30 2 * * *`) | `Config/CIPPTimers.json` |
| Retention settings endpoint | `Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/CIPP/Settings/Invoke-ExecLogRetentionConfig.ps1` |
| Header allowlist for deferred execution | `Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/CIPP/Scheduler/Invoke-AddScheduledItem.ps1` |
| The unattributed central audit row (deviation 10) | `Modules/CIPPCore/Public/Entrypoints/HTTP Functions/New-CippCoreRequest.ps1` |
| Alert dispatcher, for when you add one (out of scope here) | `Modules/CIPPActivityTriggers/Public/Entrypoints/Activity Triggers/Push-SchedulerCIPPNotifications.ps1` |
