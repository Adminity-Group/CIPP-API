# Implementation prompt — agintegrator event logging

> **How to use this file.** Paste it as the task prompt for an agent working in the **agintegrator**
> repository. It is self-contained: it needs no access to CIPP-API and no other document. If the
> companion `agintegrator-logging-design.md` is also available, read it as well — it carries annotated
> reference implementations and the rationale behind every decision below — but this prompt alone is
> sufficient to implement correctly.

---

## Your task

Implement a unified event-logging subsystem for agintegrator: one logging function called from
everywhere, one day-partitioned Azure Table, one HTTP endpoint that serves the log to the SWA frontend,
and a daily retention timer.

agintegrator is a PowerShell Azure Function App backed by Azure Table Storage with an Azure Static Web
App frontend. It integrates several vendors with **HaloPSA** and **Microsoft Dynamics Business
Central**. Its primary job is importing vendor billing data into HaloPSA; its secondary job is
provisioning vendor services, requested from HaloPSA. It also performs internal syncs, such as pushing
product definitions from HaloPSA to Business Central.

### Naming conventions — follow these exactly

- Prefix is **`Ag`**. Never `Agi`.
- The core PowerShell module is **`AgCore`** — confirm this is the actual module name and tell me if it
  is not.
- The log table is **`AgLogs`**.
- The logging function is named **`Write-LogMessage`** (no prefix — it is called thousands of times and
  brevity matters at the call site).

---

## STEP 1 — Review before you build. Do not skip this.

**agintegrator already has Azure Table and table-entity functions. Do not write new ones.**

Find the existing helpers in `AgCore` and assess them against the requirements below. Extend the
existing functions where a requirement is unmet; do **not** add a parallel implementation.

| Requirement | Why the log path needs it |
|---|---|
| Builds a table context from `$env:AzureWebJobsStorage`, creating the table if it does not exist | `AgLogs` must materialise on first write in a fresh environment — new deployment, new dev machine, CI — with no manual provisioning step |
| Reuses or caches the context per table name | `Write-LogMessage` is on every hot path; rebuilding a context per call is measurable overhead at import volumes |
| **Write path splits oversized data:** a property over ~30 KB is split into `<Prop>_Part0`, `<Prop>_Part1`, … with the map recorded in a `SplitOverProps` property; an entity over ~500 KB is split into additional rows with `RowKey` suffixed `-part<N>`, each carrying `OriginalEntityId` and `PartIndex` | Azure Table caps a single property at 64 KB and an entity at 1 MB. `LogData` from a failed billing batch — a rejected payload plus a stack trace — routinely exceeds the property cap. Without splitting the write throws, and the failure that caused it goes unrecorded |
| **Read path reassembles both kinds of split** back into the original entity | Otherwise the log viewer shows a row with `LogData_Part0`, `LogData_Part1` and no `LogData` — exactly for the large error payloads you most need to read |
| Batched writes with per-entity fallback | Not needed by the logger (one row per call), but the retention cleanup deletes in batches |

Also confirm that **no OData filter-value sanitiser already exists** under some other name. One is
expected to be absent; you will add `ConvertTo-AgODataFilterValue` in step 2.

**Report back before writing any code:**

1. The real names of the existing table-context and table-entity functions.
2. Whether the module is actually called `AgCore`.
3. Which requirements above are already met.
4. What you need to add or change, and where.

Every code sample and signature below uses the placeholder names **`Get-AgTable`**,
**`Add-AgTableEntity`**, **`Get-AgTableEntity`**. Substitute the real names throughout.

---

## STEP 2 — What to build

### 2.1 Table schema: `AgLogs`

`PartitionKey` = `yyyyMMdd` in the configured local timezone. `RowKey` = a fresh GUID.

Azure Table is schemaless. Columns marked *conditional* must be **omitted entirely** when they have no
value — not written as an empty string. Absent means "not applicable", and that is information.

| Column | Always? | Content |
|---|---|---|
| `PartitionKey` | yes | `yyyyMMdd`, local date via `$env:AG_TIMEZONE` (default `UTC`) |
| `RowKey` | yes | `[guid]::NewGuid().ToString()` |
| `Timestamp` | auto | Azure Table populates it. This, not `PartitionKey`, is the precise event time |
| `API` | yes | The coarse channel. HTTP endpoint name, or a feature name: `BillingImport`, `Provisioning`, `ProductSync`, `LogRetentionCleanup`. Default `'None'` |
| `Message` | yes | One sentence for a human. Short — detail goes in `LogData` |
| `Severity` | yes | Exactly one of `Debug`, `Info`, `Warning`, `Error`, `Critical`, `Alert`, canonically cased |
| `Username` | yes | Resolved caller. `'AG'` when nothing is resolvable (background work) |
| `FunctionNode` | yes | `$env:WEBSITE_SITE_NAME` |
| `LogData` | yes | Compressed JSON at depth 10, or `''` |
| `sentAsAlert` | yes | Always `$false`. **Reserved** for a future alert dispatcher — do not remove it |
| `Source` | yes | Where the data or action came from: a vendor name (`Sherweb`, `Dropsuite`, …), `HaloPSA`, `BusinessCentral`, or `Internal`. Default `'None'` |
| `Target` | yes | Where it was written to. Same vocabulary. Default `'None'` |
| `Customer` | yes | HaloPSA client display name, or `'None'` for events not scoped to one customer |
| `RunId` | conditional | Correlation id for one run. **Supplied by ambient context, never a caller parameter** |
| `CustomerId` | conditional | HaloPSA client id |
| `HaloTicketId` | conditional | |
| `HaloInvoiceId` | conditional | |
| `BcDocumentNo` | conditional | Business Central document number |
| `VendorRef` | conditional | Vendor-side identity: subscription id, order id, billing line id |
| `ProductId` | conditional | Product / SKU identity |
| `IP` | conditional | First entry of `x-forwarded-for`, `:port` stripped, IPv6 brackets removed |
| `AppId` | conditional | Client app id, for machine-to-machine callers |

`Source` + `Target` are the primary scope pair. They express **direction**, which is what makes internal
events describable:

| Event | `Source` | `Target` | `Customer` |
|---|---|---|---|
| Import Sherweb billing into Halo | `Sherweb` | `HaloPSA` | the Halo client |
| Provision a vendor service, requested from Halo | `HaloPSA` | `Sherweb` | the Halo client |
| Sync a product definition Halo → BC | `HaloPSA` | `BusinessCentral` | `None` |
| Push an invoice Halo → BC | `HaloPSA` | `BusinessCentral` | the Halo client |
| Retention cleanup, startup, version check | `Internal` | `None` | `None` |

The record-reference columns are **discrete and queryable on purpose**, not bundled into `LogData`. The
primary forensic question is *"show me everything that touched Halo invoice 4471"*, and that must be a
server-side OData `$filter`.

### 2.2 Configuration rows

In agintegrator's existing `Config` table:

| PartitionKey | RowKey | Columns | Purpose |
|---|---|---|---|
| `LogRetention` | `Settings` | `RetentionDays` (Int32) | Retention window. Absent ⇒ 90. Clamp 7–365 on both read and write |
| `LogRetention` | `LastRun` | `LastRunUtc` (String, ISO 8601 round-trip) | Rerun guard for the cleanup timer |
| `TimeSettings` | `TimeSettings` | `Timezone` (String) | Windows/IANA timezone id, loaded into `$env:AG_TIMEZONE` at startup. Optional |

### 2.3 Environment variables

| Variable | Default | Effect |
|---|---|---|
| `AzureWebJobsStorage` | — | Storage connection string. Already required |
| `AG_TIMEZONE` | `UTC` | Timezone id used for `PartitionKey` |
| `AG_DEBUG_MODE` | unset | `true` or `1` ⇒ `Debug`-severity rows are written. Anything else ⇒ discarded |
| `WEBSITE_SITE_NAME` | — | Set by Azure; recorded as `FunctionNode` |

### 2.4 Functions to create

All new functions go in `AgCore`.

#### `Write-LogMessage`

```text
Write-LogMessage
    [-Message] <string>                  # mandatory, AllowEmptyString
    [-API <string>]                      # default 'None'
    [-Sev <string>]                      # ValidateSet Debug,Info,Warning,Error,Critical,Alert; default Info
    [-Source <string>]                   # default 'None'
    [-Target <string>]                   # default 'None'
    [-Customer <string>]                 # default 'None'
    [-CustomerId <string>]
    [-Headers <object>]                  # $Request.Headers from an HTTP trigger
    [-User <object>]                     # explicit identity, for paths with no headers
    [-LogData <object>]                  # any object; serialised to compressed JSON depth 10
    [-HaloTicketId <string>]
    [-HaloInvoiceId <string>]
    [-BcDocumentNo <string>]
    [-VendorRef <string>]
    [-ProductId <string>]
```

Required behaviour, in this order:

1. **Debug gate first, before any storage work.** If `$Sev` is `Debug` and `$env:AG_DEBUG_MODE` is not
   `true` or `1`, `return` immediately — before building a table context, decoding headers, or anything
   else. Debug tracing must be free in production.

2. **Canonicalise severity casing.** `ValidateSet` is case-insensitive but does *not* rewrite the value,
   so `-Sev error` would store `error` and the frontend's severity filter would silently miss the row.
   Map to TitleCase before writing.

3. **Resolve the caller identity, with every decode guarded by `try`/`catch`.**
   - `$Headers.'x-ms-client-principal-idp' -eq 'aad'` ⇒ machine-to-machine. `$AppId` and `$Username`
     both come from `x-ms-client-principal-name`. If agintegrator keeps a registry of API clients,
     resolve a friendly name for `$Username`.
   - Otherwise ⇒ Static Web Apps. Base64-decode `x-ms-client-principal`, parse as JSON, take
     `.userDetails`. On any failure fall back to `x-ms-client-principal-name`.
   - `-User` supplied without headers: accept either a plain name or a base64 principal.
   - Nothing resolvable ⇒ `'AG'`.
   - A malformed or absent principal header must never throw.

4. **Extract the client IP** from the first `x-forwarded-for` entry, stripping the `:port` suffix Azure
   appends and any IPv6 brackets.

5. **Serialise `LogData`** with `ConvertTo-Json -Depth 10 -Compress` — but pass a string through
   unchanged, so a caller supplying pre-serialised JSON does not get a JSON string containing an escaped
   JSON string.

6. **Build `PartitionKey`** as `yyyyMMdd` from
   `[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, $TzId)`. Wrap in `try`/`catch` and
   fall back to UTC — an invalid timezone id must not lose the log line.

7. **Read the ambient `RunId`** from the AsyncLocal holder (see below) and add it only if set.

8. **Add conditional columns only when non-empty.**

9. **Write exactly one entity**, synchronously, via the existing table helper.

10. **Never throw.** Wrap the whole body. On failure emit `Write-Warning` with both the failure reason
    and the unrecorded event — loudly, so a broken log path is visible in the Functions host log. **Do
    not use an empty catch block.**

#### `Set-AgRunContext` / `Get-AgRunContext`

The ambient correlation mechanism. A billing import calls a vendor client, which calls a mapper, which
calls a Halo client. All four layers log; all four rows must carry the same `RunId`. Threading a
`-RunId` parameter through every signature is invasive and easy to forget, so the run id lives in
module-scoped `AsyncLocal` storage that the logger reads.

```powershell
function Set-AgRunContext {
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

Three constraints, all of which will cause subtle bugs if ignored:

- **`AsyncLocal[string]`, not a plain `$script:` variable.** The Azure Functions PowerShell worker runs
  invocations concurrently across async continuations; only `AsyncLocal` gives a correct per-flow value.
- **Module `$script:` scope, not `$global:`.** Global scope is not reliable in the Functions worker.
  This means `Set-AgRunContext` and `Write-LogMessage` **must live in the same module** — `$script:`
  scope is per-module, so a setter in one module and a reader in another will never see each other's
  value.
- **Always clear in a `finally`.** Runspaces are reused between invocations. A `RunId` left set after a
  job finishes leaks onto unrelated rows written by the next invocation on that runspace.

`Get-AgRunContext` is a convenience reader returning the current value or `$null` — for code that wants
the run id as a value, e.g. to stamp it on a Halo ticket note so an external record points back at the
run that created it.

#### `Get-AgException`

Turn an `ErrorRecord` into the standard `-LogData` payload:

```powershell
[PSCustomObject]@{
    Message         = $Exception.Exception.Message
    NormalizedError = Get-NormalizedError -Message $Exception.Exception.Message
    Position        = $Exception.InvocationInfo.PositionMessage
    StackTrace      = ($Exception.ScriptStackTrace | Out-String)
    ScriptName      = $Exception.InvocationInfo.ScriptName
    LineNumber      = $Exception.InvocationInfo.ScriptLineNumber
    Category        = $Exception.CategoryInfo.ToString()
}
```

#### `Get-NormalizedError`

Two jobs:

1. **Unwrap a JSON error envelope.** REST APIs bury the useful text at varying depths. Try, in order:
   `$Json.error.innererror.message`, `$Json.error.message`, `$Json.error.details.message`,
   `$Json.message`, `$Json.Message`, `$Json.detail`, `$Json.error_description`. Take the first
   non-empty. Extend with the shapes agintegrator's vendors, HaloPSA and Business Central actually
   return.
2. **Translate known-opaque messages** into an actionable sentence via a `switch -Wildcard`, with
   `default { $Message }` so unknown messages pass through unchanged.

**Seed the translation table with agintegrator's real error strings.** Grep the existing codebase and,
if you have them, existing log records for recurring vendor / Halo / BC error messages, and write an
entry for each one an operator would have to ask about. Starting points — replace with real observed
strings:

| Pattern | Translation |
|---|---|
| `*401*Unauthorized*` | Authentication failed. The stored credentials for this system are invalid or expired. |
| `*invalid_grant*` | The refresh token for this integration has expired. Re-authorise the connection. |
| `*429*` | Rate limited by the remote system. The operation will be retried. |
| `*The remote name could not be resolved*` | Could not reach the remote system — DNS resolution failed. Check the configured base URL. |
| `*The property value exceeds the maximum allowed size (64KB)*` | A value was too large to store. One of the logged fields exceeds the 64KB property limit. |

This table is the cheapest available improvement to support quality — every entry turns a support
question into a self-service fix.

#### `ConvertTo-AgODataFilterValue`

Sanitises a value before it is interpolated into an OData `$filter` string. Every user-supplied value
that reaches a filter must go through it.

```text
ConvertTo-AgODataFilterValue -Value <string> [-Type String|Guid|Date|Integer]
```

- `String` — escape single quotes by doubling them (`'` → `''`), per the OData spec. Return the escaped
  value.
- `Guid` — validate `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`,
  `throw` otherwise.
- `Date` — validate `^\d{4}-?\d{2}-?\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?)?$`, i.e. ISO
  8601 or `yyyyMMdd`. `throw` otherwise.
- `Integer` — validate `^\d+$`, `throw` otherwise.

`Type` defaults to `String`.

#### `Invoke-ListLogs`

The HTTP read endpoint. Three modes, **one row shape for all of them** so the frontend needs one
renderer.

| Query parameter | Mode | Filtering | Notes |
|---|---|---|---|
| `ListLogs=true` | partition list | — | Distinct day partitions, for the date dropdown. Project `PartitionKey` only |
| `logentryid=<guid>` | single entry | server-side | Pass `DateFilter` too when available, so it targets one partition instead of scanning the table |
| `DateFilter=yyyyMMdd` | list | server-side `PartitionKey eq` | Single day |
| `StartDate` / `EndDate` | list | server-side `PartitionKey ge` / `le` | Day range. Both absent ⇒ today. If equal, emit a single `eq` |
| `Severity` | list | **client-side** | CSV. Default `Info,Warning,Error,Critical,Alert` — `Debug` excluded |
| `User` | list | client-side | Supports `*` wildcards, via `-like` |
| `API` | list | client-side | Regex, via `-match` |
| `Source`, `Target`, `Customer` | list | server-side `eq` | Exact match; values come from frontend dropdowns |
| `RunId`, `CustomerId`, `HaloTicketId`, `HaloInvoiceId`, `BcDocumentNo`, `VendorRef`, `ProductId` | list | server-side `eq` | Exact, high-selectivity |
| `Top` | list | result cap | Default 5 000, clamp 1–50 000 |

Requirements:

- **Read through the reassembling table helper**, never the raw reader, so rows whose `LogData` was
  split come back whole.
- **Sanitise every interpolated value** with `ConvertTo-AgODataFilterValue` — `Date` for the partition
  keys, `Guid` for `logentryid`, `Integer` for `Top`, `String` for the rest.
- **Severity is filtered client-side deliberately.** It needs an OR chain, and Azure Table / Azurite
  handle long OR chains unreliably. The partition is already narrowed by date, so the client-side pass
  is over a bounded set. `User` and `API` are client-side because wildcard and regex matching cannot be
  expressed in OData.
- **Sort by `Timestamp` descending**, then apply `Top`.
- **Return `{ Results, Metadata }` in every mode.** `Metadata` carries `Count`, and for the list mode
  also `Total`, `Truncated`, `Top`, `Filter` and `Mode`. A frontend that cannot tell it received a
  partial result will display wrong data confidently.
- **Parse `LogData` back to an object** when it is valid JSON; return the raw string when it is not.
- **Do not log this endpoint's own invocation at `Info`.** A read endpoint that logs every call fills
  the log with records of people reading the log. `Debug` if you want it at all.

The row shape returned by every mode:

```
DateTime, DateFilter, RowKey, API, Message, Severity, User, Source, Target, Customer,
CustomerId, RunId, HaloTicketId, HaloInvoiceId, BcDocumentNo, VendorRef, ProductId,
IP, AppId, FunctionNode, LogData
```

`DateTime` is the row's `Timestamp`; `User` is the row's `Username`; `DateFilter` is the row's
`PartitionKey` — the frontend needs it so that "show me this whole run" can pass both `RunId` and the
partition.

#### `Start-LogRetentionCleanup`

A daily timer function.

1. **Rerun guard.** Read `Config` / `LogRetention` / `LastRun`. If `LastRunUtc` is under 24 hours old,
   `Write-Information` and return. Do not write a log row for a skipped run — a skip is not an event
   worth keeping for 90 days.
2. **Read the window** from `Config` / `LogRetention` / `Settings`. Default 90, clamp 7–365.
3. **Compute the cutoff** as `yyyyMMdd`, using **the same local clock as the writer**
   (`$env:AG_TIMEZONE`, UTC fallback).
4. **Delete on `PartitionKey lt '<cutoff>'`**, in batches of 5 000, projecting only
   `PartitionKey`/`RowKey` on the read. Loop until a batch returns fewer rows than the batch size.
   - **Delete by `PartitionKey`, not by `Timestamp`.** Two reasons: `PartitionKey` is indexed and
     `Timestamp` is not, so a `Timestamp` filter scans every row; and rows are partitioned by *local*
     date, so deleting on UTC `Timestamp` uses a different clock from the writer and the two disagree at
     day boundaries.
5. **Stamp `LastRunUtc`.**
6. **Log one `Info` summary row** with the deleted count, batch count and retention window. On failure,
   log `Error` with `-LogData` and rethrow.
7. Support `-WhatIf` via `[CmdletBinding(SupportsShouldProcess)]`.

Schedule it at **`0 30 2 * * *`** — 02:30 daily, clear of business-hours load. If agintegrator has a
timer registry (a JSON file of commands and cron expressions dispatched by a single timer function),
register the command there. Otherwise add a timer-trigger function folder:

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

#### `Invoke-ExecLogRetentionConfig`

- `GET ?List=true` ⇒ `{ Results = @{ RetentionDays = <int> } }`, defaulting to 90.
- `POST { RetentionDays }` ⇒ validate 7–365 (`throw` outside the range), upsert
  `Config`/`LogRetention`/`Settings`, log the change at `Info` with `-Headers`.
- Wrap in the standard catch idiom and return the error text in `Results` rather than a 500.

---

## STEP 3 — Call-site conventions

Consistency here is what makes the log queryable. Adopt these across the codebase.

### HTTP endpoints

```powershell
function Invoke-ExecProvisionService {
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = 'ExecProvisionService'
    $Headers = $Request.Headers

    Write-LogMessage -Headers $Headers -API $APIName -Message 'Accessed this API' -Sev Debug

    try {
        # ... work ...
        Write-LogMessage -Headers $Headers -API $APIName `
            -Source 'HaloPSA' -Target $Vendor `
            -Customer $Customer -CustomerId $CustomerId `
            -HaloTicketId $TicketId -ProductId $Product.Id `
            -Message "Provisioned $($Product.Name) for $Customer" -Sev Info

        $StatusCode = [HttpStatusCode]::OK
        $Body = @{ Results = 'Provisioned successfully' }
    } catch {
        $ErrorMessage = Get-AgException -Exception $_
        Write-LogMessage -Headers $Headers -API $APIName `
            -Source 'HaloPSA' -Target $Vendor `
            -Customer $Customer -HaloTicketId $TicketId -ProductId $Product.Id `
            -Message "Failed to provision $($Product.Name): $($ErrorMessage.NormalizedError)" `
            -Sev Error -LogData $ErrorMessage

        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
```

- `$APIName` and `$Headers = $Request.Headers` at the top; `-Headers $Headers` on every call. This is
  the audit trail. Without it every row says `Username = 'AG'`.
- Write operations log at `Info`; read-only `List*` endpoints generally log nothing, or `Debug`.
- Always set `-Source` and `-Target`. They default to `'None'`, and a row with no direction is much less
  useful.

### The catch-block idiom

The single most important convention:

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

`NormalizedError` in the message, the whole object in `LogData`. When the detail is large, keep the
message short and end it with **"see Log Data for details"**.

Two traps to avoid, and to audit the existing codebase for:

- **Never write `$($_.Exception.Message)` inside a `ForEach-Object` catch block.** `$_` there is the
  pipeline item, not the error, so the error text comes out empty. Use a `foreach` statement, or capture
  `$Err = $_` first.
- **Do not log-and-rethrow at every level.** Log where you have the context to say something useful,
  then rethrow. The same failure logged at four levels produces four rows for one event.

### Background jobs — the RunId idiom

```powershell
$RunId = (New-Guid).Guid
Set-AgRunContext -RunId $RunId
try {
    Write-LogMessage -API 'BillingImport' -Source $Vendor -Target 'HaloPSA' `
        -Message "Starting billing import for $Period" -Sev Info

    # Everything called from here, at any depth, produces rows stamped with this RunId.
    # None of those functions know RunId exists.
    Import-AgVendorBilling -Vendor $Vendor -Period $Period

} finally {
    Set-AgRunContext -RunId $null      # MUST clear: runspaces are reused
}
```

Queue workers, durable activities and timers have no request headers, so their rows carry
`Username = 'AG'`. That is correct — attribution for background work is the `RunId`, not a user.

If a background job was originally triggered by a user (a provisioning request from Halo that got
queued), persist an **allowlist** of headers onto the queue item and replay them. Never persist a whole
header collection:

```powershell
$HeaderAllowlist = @(
    'x-ms-client-principal'
    'x-ms-client-principal-id'
    'x-ms-client-principal-name'
    'x-forwarded-for'
)
$StoredHeaders = $Request.Headers | Select-Object -Property $HeaderAllowlist -ErrorAction SilentlyContinue
```

### Severity semantics

The distinction that matters most is **`Error` versus `Critical`**: did one unit of work fail while the
run continued, or is the integration itself broken?

| Severity | Meaning | agintegrator examples |
|---|---|---|
| `Debug` | Development tracing. Discarded unless `AG_DEBUG_MODE` is set | `'Accessed this API'`; "mapped vendor SKU X to Halo product Y"; per-line import success |
| `Info` | Normal successful work | Run started / completed; "imported 42 billing lines"; "created BC item 108423" |
| `Warning` | Degraded, but the operation continued | Line skipped — SKU unmapped; a retry that eventually succeeded; product already existed so creation was a no-op |
| `Error` | **One unit of work failed. The run continued** | Halo rejected one invoice line; one provisioning call failed for one customer; one product failed to sync |
| `Critical` | **The run or the integration is broken.** Nothing more will succeed until someone acts | Credentials rejected; refresh token expired; vendor API unreachable; the whole import aborted; BC company not found |
| `Alert` | Needs a human to look, even though nothing technically failed | Billing total deviates more than X% from last period; a provisioning request pending over N hours |

`Critical` should be rare — reserve it for "the platform itself is degraded". `Alert` is for
business-rule anomalies, not technical failures.

### When to skip logging

| Situation | What to do |
|---|---|
| Per-item success inside a large loop | Log the aggregate at `Info`, per-item at `Debug`. `"Imported 4 812 of 4 830 lines"` plus one `Error` per failure beats 4 830 `Info` rows |
| Read-only list endpoints | Nothing, or `Debug` |
| Rerun / duplicate-execution guards | `Write-Information`, not the table |
| Retry attempts | Log the final outcome only |

**Why per-item `Info` in a loop is a real problem, not a style preference:** day partitioning means one
hot partition per day, and Azure Table's throughput target is ~2 000 entities/second per partition. An
import over 50 000 lines logging one `Info` row each will throttle, will cost 50 000 write transactions,
and will make "today's activity" a 50 000-row query. If you genuinely need durable per-item records of
successes, that is a data store keyed by run and line — not the event log.

### Message style

- Active and specific: `"Imported 42 billing lines for Acme A/S"`, not `"Processing complete"`.
- Include the numbers. `"Skipped 3 lines with unmapped SKUs"` is actionable; `"Some lines skipped"` is
  not.
- Do not repeat what the columns already say — `-Customer 'Acme A/S'` is already a column.
- No JSON in the message. That is what `LogData` is for.

---

## Non-goals — do NOT build these

| Excluded | Why |
|---|---|
| Application Insights integration, or mirroring `Write-*` cmdlet output into telemetry | Orthogonal, and addable later without touching this design |
| Alert / notification dispatch — email, webhook, PSA ticket | A separate concern that *reads* the log. The `sentAsAlert` column reserves space for it |
| Run-progress tracking: parent-run + child-task tables, `% complete`, live status | A job-status store, not a log. `RunId` here is a correlation stamp only |
| Log archival to blob or cold storage | Retention is delete-only |
| Paging with continuation tokens | `Top` + `Metadata.Truncated` is the agreed scope |
| Full-text search over `Message` | That is a search index, not a table query |

---

## Acceptance criteria

Storage prerequisites:

- [ ] No new table-context or table-entity function was created; the existing ones were extended where
      needed, and the gaps closed were reported.
- [ ] A `LogData` payload over 30 KB round-trips through write and read intact — written split,
      returned whole, with no `*_Part0` properties visible to the caller.

The logger:

- [ ] `-Sev` rejects a value outside the six-item set.
- [ ] `-Sev error`, `-Sev Error` and `-Sev ERROR` all store `Error`.
- [ ] With `AG_DEBUG_MODE` unset, a `Debug` call writes nothing and issues no storage request.
- [ ] With `AG_DEBUG_MODE=true`, a `Debug` call writes a row.
- [ ] `PartitionKey` equals today's date **in `AG_TIMEZONE`**, not UTC, when the two differ.
- [ ] Conditional columns are **absent** from the entity, not empty, when not supplied.
- [ ] A malformed `x-ms-client-principal` header does not throw; `Username` falls back sensibly.
- [ ] No headers and no `-User` ⇒ `Username` is `'AG'`.
- [ ] An induced storage failure produces a `Write-Warning` and **does not throw**.
- [ ] `Set-AgRunContext` and `Write-LogMessage` are in the same module.
- [ ] A row written by a function three frames below `Set-AgRunContext` carries the `RunId`.
- [ ] After the `finally` clears the context, subsequent rows have no `RunId` property.

Read endpoint:

- [ ] All three modes return `{ Results, Metadata }`.
- [ ] List and single-entry modes return **identical property sets**.
- [ ] A `Severity` CSV filters correctly; `Debug` is excluded by default.
- [ ] `User` supports `*` wildcards; `API` supports regex.
- [ ] `Source`, `Target`, `Customer` and every ref column filter server-side.
- [ ] Exceeding `Top` sets `Metadata.Truncated = $true` and `Metadata.Total` above `Metadata.Count`.
- [ ] `Customer` containing an apostrophe (`O'Brien A/S`) does not break the filter — proving the
      sanitiser is wired in.
- [ ] An invalid `logentryid` or `DateFilter` is rejected, not interpolated.

Retention:

- [ ] Back-dated partitions older than the window are deleted; recent ones are untouched.
- [ ] A second run within 24 hours is skipped by the guard.
- [ ] `RetentionDays` is clamped to 7–365 on both read and write.
- [ ] `-WhatIf` deletes nothing.
- [ ] The timer is registered at `0 30 2 * * *`.

---

## Verification

Run locally against Azurite. Adapt the helper names to the real ones.

```powershell
# --- Setup -----------------------------------------------------------------------------------
# Terminal 1:  azurite --silent --location ./.azurite
# Terminal 2:  func start
$env:AzureWebJobsStorage = 'UseDevelopmentStorage=true'
$env:AG_TIMEZONE = 'Europe/Copenhagen'    # or 'Romance Standard Time' on Windows hosts
$env:WEBSITE_SITE_NAME = 'agintegrator-local'
Import-Module ./Modules/AgCore -Force

$Base = 'http://localhost:7071/api'
$Today = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(
    [DateTime]::UtcNow, $env:AG_TIMEZONE).ToString('yyyyMMdd')

# --- 1. One row per severity, and casing canonicalisation --------------------------------------
Remove-Item Env:\AG_DEBUG_MODE -ErrorAction SilentlyContinue
foreach ($Sev in 'Info', 'Warning', 'Error', 'Critical', 'Alert') {
    Write-LogMessage -API 'VerifyTest' -Source 'Internal' -Message "Test row at $Sev" -Sev $Sev
}
Write-LogMessage -API 'VerifyTest' -Source 'Internal' -Message 'lowercase sev' -Sev 'error'
Write-LogMessage -API 'VerifyTest' -Source 'Internal' -Message 'discarded debug' -Sev Debug

$Rows = (Invoke-RestMethod "$Base/ListLogs?Filter=True&DateFilter=$Today&API=VerifyTest&Severity=Info,Warning,Error,Critical,Alert,Debug").Results
'Expect 6 rows (Debug discarded): {0}' -f $Rows.Count
'Expect no lowercase severities: {0}' -f (($Rows.Severity | Where-Object { $_ -cne (Get-Culture).TextInfo.ToTitleCase($_) }).Count -eq 0)
'Expect PartitionKey = local today: {0}' -f (($Rows.DateFilter | Select-Object -Unique) -eq $Today)

# --- 2. Debug gate --------------------------------------------------------------------------
$env:AG_DEBUG_MODE = 'true'
Write-LogMessage -API 'VerifyDebug' -Source 'Internal' -Message 'debug now enabled' -Sev Debug
Remove-Item Env:\AG_DEBUG_MODE
$DebugRows = (Invoke-RestMethod "$Base/ListLogs?Filter=True&DateFilter=$Today&API=VerifyDebug&Severity=Debug").Results
'Expect 1 debug row: {0}' -f $DebugRows.Count

# --- 3. Conditional columns are absent, not empty ---------------------------------------------
Write-LogMessage -API 'VerifyCond' -Source 'Sherweb' -Target 'HaloPSA' `
    -Customer 'Acme A/S' -HaloInvoiceId '4471' -Message 'with refs' -Sev Info
Write-LogMessage -API 'VerifyCond' -Source 'Internal' -Message 'without refs' -Sev Info

$Table = Get-AgTable -TableName 'AgLogs'
$Raw = Get-AgTableEntity @Table -Filter "PartitionKey eq '$Today' and API eq 'VerifyCond'"
$Bare = $Raw | Where-Object { $_.Message -eq 'without refs' }
'Expect HaloInvoiceId absent on the bare row: {0}' -f (-not $Bare.PSObject.Properties['HaloInvoiceId'])

# --- 4. Ambient RunId, including the leak check -----------------------------------------------
function Test-AgDeepLog { Write-LogMessage -API 'VerifyRun' -Source 'Internal' -Message 'three frames deep' -Sev Info }
function Test-AgMiddle { Test-AgDeepLog }

$RunId = (New-Guid).Guid
Set-AgRunContext -RunId $RunId
try { Test-AgMiddle } finally { Set-AgRunContext -RunId $null }
Write-LogMessage -API 'VerifyRun' -Source 'Internal' -Message 'after clear' -Sev Info

$RunRows = (Invoke-RestMethod "$Base/ListLogs?Filter=True&DateFilter=$Today&API=VerifyRun").Results
'Expect deep row stamped with RunId: {0}' -f (($RunRows | Where-Object Message -eq 'three frames deep').RunId -eq $RunId)
'Expect post-clear row to have no RunId: {0}' -f ([string]::IsNullOrEmpty(($RunRows | Where-Object Message -eq 'after clear').RunId))
'Expect RunId filter to return exactly 1 row: {0}' -f `
    ((Invoke-RestMethod "$Base/ListLogs?Filter=True&DateFilter=$Today&RunId=$RunId").Results.Count -eq 1)

# --- 5. Oversized LogData round-trip ----------------------------------------------------------
$Big = @{ Payload = ('x' * 80000); Note = 'oversized on purpose' }
Write-LogMessage -API 'VerifyBig' -Source 'Internal' -Message 'oversized LogData' -Sev Error -LogData $Big

$BigRow = (Invoke-RestMethod "$Base/ListLogs?Filter=True&DateFilter=$Today&API=VerifyBig&Severity=Error").Results |
    Select-Object -First 1
'Expect payload length 80000 after reassembly: {0}' -f $BigRow.LogData.Payload.Length
'Expect no *_Part properties leaked: {0}' -f `
    (@($BigRow.LogData.PSObject.Properties.Name | Where-Object { $_ -like '*_Part*' }).Count -eq 0)

# --- 6. Injection safety ----------------------------------------------------------------------
Write-LogMessage -API 'VerifyQuote' -Source 'Internal' -Customer "O'Brien A/S" -Message 'apostrophe test' -Sev Info
$Quoted = Invoke-RestMethod ("$Base/ListLogs?Filter=True&DateFilter={0}&Customer={1}" -f `
    $Today, [uri]::EscapeDataString("O'Brien A/S"))
'Expect apostrophe customer filter to work: {0}' -f ($Quoted.Results.Count -ge 1)

try {
    Invoke-RestMethod "$Base/ListLogs?Filter=True&logentryid=not-a-guid" | Out-Null
    'FAIL: invalid GUID was accepted'
} catch { 'Expect invalid GUID rejected: True' }

# --- 7. Top / truncation ----------------------------------------------------------------------
1..25 | ForEach-Object { Write-LogMessage -API 'VerifyTop' -Source 'Internal' -Message "row $_" -Sev Info }
$Capped = Invoke-RestMethod "$Base/ListLogs?Filter=True&DateFilter=$Today&API=VerifyTop&Top=10"
'Expect Count 10, Truncated true, Total 25: {0} / {1} / {2}' -f `
    $Capped.Metadata.Count, $Capped.Metadata.Truncated, $Capped.Metadata.Total

# --- 8. Mode parity and the partition list ----------------------------------------------------
$One = (Invoke-RestMethod ("$Base/ListLogs?logentryid={0}&DateFilter={1}" -f $BigRow.RowKey, $Today)).Results |
    Select-Object -First 1
$Diff = Compare-Object $One.PSObject.Properties.Name $BigRow.PSObject.Properties.Name
'Expect identical property sets between modes: {0}' -f ($null -eq $Diff)
'Expect today in the partition list: {0}' -f `
    ((Invoke-RestMethod "$Base/ListLogs?ListLogs=true").Results.value -contains $Today)

# --- 9. Retention -----------------------------------------------------------------------------
$OldPartition = [DateTime]::UtcNow.AddDays(-200).ToString('yyyyMMdd')
1..3 | ForEach-Object {
    Add-AgTableEntity @Table -Entity @{
        PartitionKey = $OldPartition
        RowKey       = [guid]::NewGuid().ToString()
        API          = 'VerifyRetention'
        Message      = "old row $_"
        Severity     = 'Info'
        Username     = 'AG'
        Source       = 'Internal'
        Target       = 'None'
        Customer     = 'None'
        LogData      = ''
        sentAsAlert  = $false
    } -Force
}

Invoke-RestMethod -Method Post -Uri "$Base/ExecLogRetentionConfig" `
    -Body (@{ RetentionDays = 90 } | ConvertTo-Json) -ContentType 'application/json'

Start-LogRetentionCleanup -WhatIf
'Expect 3 old rows still present after -WhatIf: {0}' -f `
    @(Get-AgTableEntity @Table -Filter "PartitionKey eq '$OldPartition'").Count

Start-LogRetentionCleanup
'Expect 0 old rows after real run: {0}' -f `
    @(Get-AgTableEntity @Table -Filter "PartitionKey eq '$OldPartition'").Count
'Expect today''s rows untouched: {0}' -f `
    (@(Get-AgTableEntity @Table -Filter "PartitionKey eq '$Today'").Count -gt 0)

Start-LogRetentionCleanup   # second run within 24h - expect a skip message, no log row

# --- 10. Logging never throws ------------------------------------------------------------------
$Saved = $env:AzureWebJobsStorage
$env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=https;AccountName=nonexistent;AccountKey=aaaa;EndpointSuffix=core.windows.net'
try {
    Write-LogMessage -API 'VerifyResilience' -Source 'Internal' -Message 'storage is broken' -Sev Error
    'Expect no throw on storage failure: True (check for a Write-Warning above)'
} catch {
    'FAIL: Write-LogMessage threw on storage failure'
} finally {
    $env:AzureWebJobsStorage = $Saved
}
```

---

## Deliverables

1. The functions listed in step 2, in `AgCore`.
2. The retention timer registration.
3. A short note recording the step 1 review: the real storage-helper names, what was already met, what
   you changed.
4. Any call-site adoption you made in step 3, and a list of the places you did **not** convert, so the
   remaining work is visible.
5. Verification output, with any failing check called out explicitly rather than omitted.
