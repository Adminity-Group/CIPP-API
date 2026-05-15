# Drift Remediation Task Flow

This document visualizes how a Drift Remediation task is created and executed in CIPP-API.

## Flow Chart

```mermaid
flowchart TD
    A[Drift deviation action submitted\nfrom tenant drift management] --> B[Invoke-ExecUpdateDriftDeviation]
    B --> C[Set-CIPPDriftDeviation\nstore status and reason]
    C --> D{Deviation status}

    D -->|DeniedRemediate| E[Resolve setting/template\nfrom Get-CIPPTenantAlignment]
    D -->|deniedDelete| X[Delete policy directly via Graph\nno scheduled remediation task]
    D -->|Other status| Y[Update deviation only\nreturn API result]

    E --> F[Build remediation settings\nset remediate=true, report=true]
    F --> G[Add-CIPPScheduledTask\nName: One Off Drift Remediation\nCommand: Invoke-CIPPStandard*\nTaskState: Planned]
    G --> H{Persistent deny enabled?}
    H -->|Yes| I[Add second task\nName: Persistent Drift Remediation\nRecurrence: 12h\nTaskState: Planned]
    H -->|No| J[Wait for scheduler pickup]
    I --> J

    J --> K[Timer in CIPPTimers.json\nStart-UserTasksOrchestrator every 15 min]
    K --> L[Query ScheduledTasks\nfind due Planned tasks]
    L --> M[Set task state: Pending\ncreate orchestrator batch item]
    M --> N[Push-ExecScheduledCommand]

    N --> O{Guard checks}
    O -->|Blocked command / command missing\nor duplicate rerun| P[Skip or mark Failed]
    O -->|Pass| Q[Set task state: Running\ninvoke Invoke-CIPPStandard*]

    Q --> R{Execution result}
    R -->|Success| S[Store results\nScheduledTasks or ScheduledTaskResults]
    R -->|Error| T[Set Failed\nif recurring: Failed - Planned\nwith next ScheduledTime]

    S --> U{Recurring task?}
    U -->|No| V[Set task state: Completed]
    U -->|Yes| W[Set task state: Planned\ncompute next ScheduledTime]

    P --> Z[Finish]
    T --> Z
    V --> Z
    W --> Z
    X --> Z
    Y --> Z
```

## Source Path

1. Drift decision endpoint and remediation task creation:
   - Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Tenant/Standards/Invoke-ExecUpdateDriftDeviation.ps1
2. Scheduled task creation and persistence:
   - Modules/CIPPCore/Public/Add-CIPPScheduledTask.ps1
3. Scheduler cadence:
   - Config/CIPPTimers.json
4. Scheduled task pickup and orchestration:
   - Modules/CIPPCore/Public/Entrypoints/Orchestrator Functions/Start-UserTasksOrchestrator.ps1
5. Scheduled command execution and state transitions:
   - Modules/CIPPActivityTriggers/Public/Entrypoints/Activity Triggers/Push-ExecScheduledCommand.ps1
