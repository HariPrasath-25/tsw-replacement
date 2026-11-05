# Technical architecture and development roadmap

For Vijay and the Omniconn team

19 October 2026 \| Version 1.2 \| For technical review

## Delivery objective

Deliver the Omniconn TSW replacement in-house by 31 December 2026. Reuse the existing gateway investment, provide dependable local monitoring and control without a cloud dependency, and enable an integration engineer to commission a site without a developer.

The preferred first deployment connects the FACP over Ethernet to the MS-01 workstation, with the common gateway runtime hosted in an Ubuntu virtual machine under Hyper-V. The alternative places the same gateway software on the existing CM4 8GB gateway between the FACP and the MS-01. The application and customer interface remain on the MS-01 in both arrangements.

## Decisions for the team

| **Decision**       | **Position for review**                                                                                                               |
|--------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| Delivery ownership | In-house Omniconn development. Vijay to coordinate named owners, evidence and delivery gates.                                         |
| Gateway reuse      | One common gateway codebase, deployed on Ubuntu x86-64 and CM4 ARM64; configuration and packaging vary by target.                     |
| Database           | SQLite versus PostgreSQL remains open. Decide from deployment simplicity, measured workload, recovery and support evidence.           |
| Deadline           | 31 December 2026. Scope and staffing must be rebaselined against the shorter remaining window.                                        |
| Acceptance         | Working code alone is insufficient. Demonstrate both topologies, safe controls, offline commissioning, recovery and release evidence. |

## How to use this document

Sections 1 to 13 set out the proposed architecture, status, responsibilities and dated roadmap. Section 13 adds the Gateway Management Application for local health, critical settings, RBAC, centrally authorised one-time administrator access and controlled module installation. Appendix A retains all 123 numbered SOW requirements and their priorities as editable text; Appendix B retains targets T1 to T18. The change register explains where the later deployment and delivery direction supersedes the original SOW.

# 1 Scope and source reconciliation

The product is an installed Windows 11 desktop application on the MS-01, supported by a background Windows monitoring service. The same executable includes the fire operator screens and a separately permissioned Gateway Management area. Monitoring continues when the application window is closed, no user is signed in or there is no internet route. Additional operator PCs, if required, use an installed desktop client on the site LAN.

| **Source**                       | **Use in this roadmap**                                                                                                                     |
|----------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| Saleem Fire and Safety v1.2 DOCX | Business context, lean gateway, five topologies, commercial boundaries and ThingsBoard limitations.                                         |
| Saleem application SOW v1.0 PDF  | Numbered requirements 1 to 123, targets T1 to T18, phase gates, acceptance and dependencies.                                                |
| Saleem business case v1.2 PDF    | Commercial baseline, cost assumptions, gateway specification and certification sequencing.                                                  |
| Subsequent deployment direction  | MS-01 i9 with 32GB RAM and 1TB NVMe; Ubuntu Hyper-V runtime; CM4 8GB alternative; common codebase; in-house delivery and December deadline. |

## Changes that must be reflected in the implementation baseline

| **Original SOW position**                                                       | **Updated direction and consequence**                                                                                                                                                 |
|---------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| External development partner and supplier obligations                           | Internal team owns development. Supplier warranty, response times and commercial change clauses are not internal commitments unless separately adopted.                               |
| Direct connector speaks panel protocol inside the application integration layer | Physical direct connection still runs the common gateway software in Ubuntu Hyper-V. Application consumes normalised events; no second protocol implementation is planned.            |
| Requirement 97 mandates an embedded database with no separate server            | SQLite fits this wording. PostgreSQL is an expressly open alternative and would require an approved revision to requirement 97.                                                       |
| Original browser and site web service delivery                                  | Superseded by installed Windows 11 executable plus background monitoring service. No dashboard web hosting. Original IDs are retained with effective desktop revisions in Appendix A. |
| Five phases over four months                                                    | Retain the gates but replan dates. Approximately 10.5 weeks remain from 19 October to 31 December; existing work must be evidenced to justify compression.                            |
| Full SOW scale and three-year retention                                         | December single-instance workload may be much smaller. Preserve the targets and obtain an explicit scope/sizing decision rather than quietly reducing them.                           |

# Windows 11 installed application architecture

Install a signed Omniconn executable on the Windows 11 MS-01. It provides the fire dashboard, plans, alarms, reporting and commissioning, with a separately permissioned Gateway Management area for CM4 and Ubuntu runtime targets. The delivered product is a desktop application; it requires no browser dashboard, IIS, reverse proxy, web-domain hosting or HTTP listener for its user interface.

## Processes and communication

Keep continuous monitoring, event ingestion, persistence, audit and security enforcement in a Windows service that starts before interactive sign-in. The desktop executable is a separate standard-user process. Closing, crashing, updating or locking the UI must not stop source supervision. The service remains authoritative for role checks, tenant/site scope, session locks and command validation. The application never connects directly to the database or gains root access on a gateway.

Use an authenticated local IPC channel between the executable and Windows service; Windows named pipes with restrictive ACLs are the proposed starting point, subject to design approval. The service manages normalised events through the existing integration/MQTT contract. For gateway settings and module operations it talks to a narrow management agent on the CM4 or Ubuntu VM over a versioned, authenticated and encrypted RPC protocol. The agent checks the identity, permission and central grant before each protected action. Exact transport, certificate provisioning, ports and firewall rules remain design-gate decisions; a web dashboard is not required.

## What still runs on the gateway

The common gateway drivers, Node-RED, event buffer and restricted management agent remain on CM4 ARM64 or Ubuntu x86-64. The dashboard is rendered on Windows. An executable cannot by itself read or change a remote Linux gateway safely: the agent supplies health and performs only authorised settings, service and module operations. This is a bounded device-management component, with no general-purpose web administration console. Both deployment targets use the same agent contract and release tests.

## Installation and additional workstations

Ship the MS-01 with the desktop application, Windows service, licence and required runtime components installed. Provide a signed offline-capable installer, shortcuts, repair/uninstall, activation and signed updates. An optional additional operator PC must have the signed Windows client installed and connect through an approved encrypted site-LAN protocol; unauthenticated database or broker access is prohibited. No additional per-client licence is introduced by this architecture change. Confirm whether additional PCs are in the December delivery scope and validate the retained concurrent-session target accordingly.

Select the Windows desktop framework at the design gate, including accessibility, English/Arabic RTL, offline dependencies, long-term support and distribution licences. The user-interface technology must not require a hosted browser application. Sign the executable and installer, protect local IPC, and apply role checks even when the Windows user has local machine access. A local OS administrator is a privileged threat model requiring explicit review, not a security boundary that the application can assume away.

## Recovery and client version compatibility

The UI reconnects to the monitoring service and refreshes its state after a service or network interruption, without duplicating events or repeating commands. An unattended control-room display starts after the configured Windows interactive sign-in or approved kiosk setup; the background service starts without it. Do not promise that a visible desktop window exists before any Windows session. Version the client/service and service/agent contracts, reject incompatible control clients safely and provide coordinated rollback. Client updates must not require an alarm-path outage; service changes use the separately tested maintenance and recovery procedure.

# 2 Overall architecture

The same normalised event and command contract sits between the gateway runtime and the application in both physical arrangements. Protocol knowledge stays in the common gateway drivers. Presentation, application services and domain logic remain independent of hardware placement and transport.

Figure 1 Overall logical architecture. Arrows identify integration paths; events travel upward and permitted commands travel downward. All drawing labels and boxes are editable in Word.

## Application layers

Presentation renders views and receives push updates. Application services orchestrate use cases. The framework-free domain owns alarm precedence, tenancy, permissions and device state. Integration adapts the gateway contract. Data services persist operational and audit records. Platform services provide security, licensing, updates, diagnostics and unattended recovery. Build checks enforce the permitted dependency directions.

MQTT broker placement, exact topic schema, QoS, retained-message semantics and command acknowledgement contract must be recorded at the design gate. The local broker is proposed on the MS-01; the application integration contract must support a configured local, customer-hosted or shared broker without a code fork.

# 3 Direct Ethernet deployment on MS 01

Option A is preferred for the first release. Connect the FACP Ethernet interface to the MS-01 site or panel network. The physical gateway box is absent; the gateway software remains present inside the Ubuntu virtual machine.

Figure 2 Direct FACP Ethernet to MS-01 with Ubuntu Hyper-V gateway runtime. The horizontal link carries normalised events and authorised commands.

## Implementation and verification

Configure the Hyper-V virtual switch, panel IP addressing, firewall rules and routing explicitly. Confirm the chosen Windows edition supports the required Hyper-V configuration. Start the VM, gateway processes, broker and background monitoring service automatically without operator sign-in; prove dependency recovery after reboot and power loss. Launch the desktop interface after approved Windows sign-in or kiosk startup.

Package gateway dependencies for x86-64, attach durable storage for buffering, and isolate driver failures from the application service. Set resource reservations and limits from measurements, leaving capacity for the database, desktop application, exports and backup. The stated MS-01 capacity supports flexibility but does not replace a load or retention sizing exercise.

Prove discovery, normalisation, real panel events, control confirmation and reconnect/backfill on a physical panel. Determine what event recovery the panel itself supports during VM downtime; a gateway buffer cannot recover events never received. The MS-01 is a shared failure domain for operator interface and gateway runtime, so power protection, restore procedures and supervised health are required design work.

# 4 CM4 gateway deployment

Option B uses the standard Omniconn fire gateway currently deployed in the field, built around a CM4 module with 8GB RAM. The gateway runs the drivers and Node-RED; the MS-01 runs the application, local database, operator interface and proposed local broker.

Figure 3 FACP via CM4 8GB gateway to MS-01. Cloud access is unnecessary for the on-site alarm path.

## Interchangeability and deployment boundary

Use the same driver logic, normalisation rules, Node-RED flows, contract version and regression fixtures for Options A and B. Build separate x86-64 and ARM64 packages from the same versioned source. Hardware-specific serial ports, GPIO and device paths belong behind configuration or adapters; avoid topology-specific branches in domain logic.

Gateway capture and buffering can continue while the MS-01 is unavailable, subject to gateway storage capacity and the agreed overflow policy. The operator interface still depends on the MS-01. Test gateway-to-broker loss, gateway reboot, workstation reboot, disk-full behaviour and backfill without event duplication or state regression.

# 5 Common gateway codebase and data contracts

## Reuse the existing investment

The existing fire gateway work is the starting point. Inventory repositories, deployed driver versions, Node-RED flows, service definitions, dependencies, licences and configuration before changing them. A common release identifier must link source, packages, contract version and deployed configuration on both target platforms.

Do not recreate panel protocol handling in the Windows application simply because the panel cable terminates at the workstation. In Option A, the Ubuntu VM provides the gateway runtime. The application integration layer maps the common contract into its internal model. New panel families extend drivers and integration mappings without changing operator-facing alarm or permission logic.

## Proposed contract content to agree at the design gate

| **Contract** | **Required content or behaviour**                                                                                                                                                              |
|--------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Identity     | Tenant, site, source, gateway, panel, loop and device identifiers; stable event identity; contract and software version.                                                                       |
| Events       | Source event time and receipt time, alarm type and raw vendor condition, device state and metadata, sequence or ordering information where supported.                                          |
| Health       | Last contact and heartbeat, per-panel connection state, firmware/runtime version, buffer depth/capacity and storage/processing health. Final fields belong in the interface specification.     |
| Commands     | Unique correlation identifier, target and scope, requested action, actor context, expiration/timeout and explicit panel success or rejection evidence.                                         |
| Recovery     | Schema validation and quarantine; idempotent persistence; replay deduplication; late marking; snapshot versus event reconciliation; no stale retained event presented as a new live condition. |

## Control semantics

The service enforces permission and tenant/site scope for every action. Require panel-named confirmation for silence and reset, with optional PIN policy. Show pending until the panel confirms or rejects; show failed with a reason on timeout. Transport delivery is not panel execution. Refuse control when the source is unreachable; never queue it for later or automatically retry it on reconnection.

Agree duplicate-command suppression, timeout values, ordering, restart recovery and unknown-outcome presentation. Preserve source and receipt timestamps in UTC, display the zone, order history by source time and live view by receipt time. Backfill must not re-annunciate old conditions as new without an explicit agreed rule.

## Gateway hardware baseline from the business case

| **Area**              | **Source requirement**                                                                                       |
|-----------------------|--------------------------------------------------------------------------------------------------------------|
| Compute and enclosure | CM4 or equivalent; current target uses 8GB RAM; branded metal enclosure and included PSU.                    |
| Interfaces            | 1 × 1Gbps and 1 × 10/100Mbps Ethernet; Bluetooth; RS-232; RS-485; 2 DI and 1 DO.                             |
| Connectivity          | Wi-Fi and 4G GSM options for applicable deployments; neither is required for local-only operation.           |
| Cost                  | 1,105 AED landed volume target including shipping and duty. Confirm the present CM4 BOM against this target. |

# 6 SQLite versus PostgreSQL decision

No database selection is made in this document. The stated December use case is minimal, single instance and local. The SOW nevertheless contains a much larger scale and retention envelope. Decide the actual supported envelope first, then validate both candidate operation and recovery against it.

| **Criterion**   | **SQLite**                                                                                          | **PostgreSQL**                                                                                               |
|-----------------|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| Deployment      | Embedded; no separate database service. Closest fit to SOW requirement 97.                          | Separate service with installation, credentials, upgrades and operational ownership.                         |
| Concurrency     | Candidate for a small local workload; validate write contention during ingest, reporting and audit. | Candidate where concurrent operations or measured growth justify the additional service.                     |
| Resilience      | Validate transaction settings, durable commit, live backup, restore and power-cut recovery.         | Validate transaction durability, service recovery, backup, restore and migration under the same fault tests. |
| Support         | Fewer services to maintain on an isolated single workstation.                                       | More administrative capability and a larger support/configuration surface.                                   |
| Gateway store   | May be assessed independently for gateway buffering.                                                | Application choice does not require a database server on the gateway.                                        |
| Decision effect | Confirm sizing and acceptance evidence before approval.                                             | Approve a change to requirement 97 if selected; record why the operational cost is justified.                |

## Decision gate and evidence

Vijay should assign the application/data lead and DevOps owner to record an architecture decision by 23 October. Use representative event volume, retention, indexed queries, concurrent sessions, report/export activity and disk capacity. Exercise power interruption under load and a restore on replacement hardware. Keep the application data access boundary separate from domain rules; this limits coupling but does not promise cost-free database interchangeability.

Specify commit and acknowledgement order so no event is called recorded or acknowledged as committed before it is durable. The one-year alarm-log floor and installation-life audit floor remain mandatory unless formally changed; the three-year history target needs a sizing decision. At 50 events per second continuously for three years, the event count is about 4.73 billion, so the sustained-load test rate must not be mistaken for an assumed everyday workload.

# 7 Existing work and outstanding development

The available material supports the reported existing capability below. It does not establish feature-level completion of the replacement application. Vijay and the leads should attach repository references, release versions, demonstrations and passing tests before marking an item accepted.

| **Work package**                           | **Evidence based status**                                                                                                  | **Outstanding work**                                                                                                                     |
|--------------------------------------------|----------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| Field fire gateways                        | Reported operational base of more than 300 gateways. Current gateway is CM4 8GB; drivers and Node-RED are reported in use. | Inventory exact versions and supported panels; verify reuse, ownership, regression coverage and buffer behaviour.                        |
| Gateway development                        | Substantial in-house work reported complete; not itemised by source.                                                       | Demonstrate normalisation, controls, discovery, recovery and platform-specific dependencies.                                             |
| Ubuntu Hyper-V target                      | Proposed deployment; completion not evidenced.                                                                             | Port/package x86-64 runtime, configure network and unattended recovery, pass physical-panel tests.                                       |
| Desktop application and monitoring service | Required replacement product; completion not evidenced.                                                                    | Dashboard, alarm lifecycle, controls, device register, push updates, stale state and health.                                             |
| Commissioning and plans                    | Required; completion not evidenced.                                                                                        | No-code onboarding, uploads, hierarchy, bulk mapping/placement and unaided commissioning test.                                           |
| Local persistence                          | Decision open.                                                                                                             | Choose SQLite or PostgreSQL, implement schema, audit, retention, live backup and tested restore.                                         |
| Platform integrations                      | SOW describes licensing/update/cloud services as existing; API readiness unverified.                                       | Confirm owners, API contracts, offline activation and signed package integration.                                                        |
| Security and release                       | Acceptance evidence not supplied.                                                                                          | Permissions, tenancy, authentication, PINs, TLS, redaction, security assessment, installer and rollback.                                 |
| Gateway Management Application             | No gateway frontend currently exists.                                                                                      | New Windows gateway dashboard, restricted agent, settings, RBAC, central one-time elevation and controlled module lifecycle; Section 13. |
| Certification and mobile                   | Future work in business case; excluded from application SOW.                                                               | Scope certification now; separate delivery plan for certification and mobile.                                                            |

## Status control

Maintain a register with one row per SOW requirement and target: owner, current status, source commit/build, test ID, test result, defect and increment allocation. Use Not started, In progress, Implemented awaiting test and Accepted. Existing field use is valuable evidence but does not by itself establish acceptance of the new workstation deployment.

# 8 Functional and operational release scope

## Monitoring and safe operation

Deliver fixed precedence of Fire, Priority 2, Supervisory and Trouble, using colour and a distinct non-colour indicator. Provide live counts, filtered active alarms, acknowledgement, panel silence/reset, pending/failed control states, per-session audible annunciation, stale indicators and source-loss Trouble alarms. Application sound silence remains separate from panel silence. Monitoring and persistence continue while controls are locked.

## Devices and commissioning

Maintain the panel/loop/address register, current state, raw vendor attributes and separate local labels/spaces. Missing discovery results require review and do not silently delete commissioned devices. Provide disabled-device distinction/counts and audited supported device control. Floor plans support PNG, JPEG, WebP and SVG, up to 20MB and 8,192 pixels on the longer side; CAD/BIM files are excluded. Include at least three hierarchy levels, bulk mapping, group placement and completeness tracking.

## Administration and reporting

Use monitoring-service-enforced tenant/site isolation and granular roles. Support Windows integrated authentication, Active Directory sign-on and local accounts, including a nominated, audited local fallback. Inactivity locks protect control actions without obscuring alarm state. PIN/password verification uses approved memory-hard hashing with salts and rate limits; protected secrets never appear in support bundles.

Keep append-only alarm, audit and separate technical logs. Retain both source and receipt times, refused/failed/successful actions and before/after setting values. Reports and exports must match requested filters and carry scope, user and time provenance. Long exports are cancellable, do not leave partial files and cannot delay alarm display. Enforce retention floors and readable archives.

## Deployment and support

Provide a signed installer, licence entitlement validation, offline package installation and request/response activation with terms/privacy acceptance. No recurring online licence check is needed to keep local operation running. Install and update the signed executable on each authorised Windows PC. Keep workstation data authoritative in the background service rather than duplicated in clients. Support signed manual updates, a verified restorable backup, post-update health checks and automatic rollback after failure or interruption at every stage.

English and Arabic, including right-to-left UI and exports, accessibility at 200% zoom, light/dark themes and controlled white labelling remain in the requirement baseline. P2 work is committed unless explicitly renegotiated; P3 can be deferred by agreement and P4 is not a final-acceptance date commitment. Appendix A retains the individual priorities for allocation.

# 9 Dated in house development roadmap

The following dates are a proposed internal execution baseline, not evidence of a committed team capacity. They preserve the source phase gates while overlapping work to meet 31 December 2026. The original four-month estimate cannot be assumed to fit this window. Confirm resources and demonstrated reuse in the first week.

Figure 4 Proposed dated roadmap. Installer, test automation, security and documentation work must start alongside the core build.

Start the 30-day continuous acceptance run no later than 20 November so it can finish by 20 December. Any alarm-path change restarts the run under the SOW acceptance rule. A change after 1 December leaves insufficient time for a fresh 30-day run by the deadline; escalation must occur immediately rather than silently shortening the evidence period.

Retain the 72-hour resource soak and 24-hour connectivity demonstration. The 90-day continuous-operation target remains a product target; as in the SOW, initial acceptance uses the 30-day run, with continued evidence after release. Internal support ownership must replace the supplier warranty language.

# 10 Phase gates and responsibilities

<table>
<colgroup>
<col style="width: 33%" />
<col style="width: 33%" />
<col style="width: 33%" />
</colgroup>
<thead>
<tr class="header">
<th><strong>Gate and date</strong></th>
<th><strong>Exit evidence</strong></th>
<th><strong>Proposed accountable owner</strong></th>
</tr>
</thead>
<tbody>
<tr class="odd">
<td>1 Design<br />
23 October</td>
<td>Source inventory and status baseline; architecture/data/contract decisions; component licences; named owners; test plan; increment allocation.</td>
<td>Vijay with technical leads</td>
</tr>
<tr class="even">
<td>2 Connectivity<br />
6 November</td>
<td>Real CM4 and direct Ethernet/Ubuntu paths; 24-hour sustained ingest without loss; each disconnected/reconnected; backfill and deduplication.</td>
<td>Gateway and application leads</td>
</tr>
<tr class="odd">
<td>3 Operations<br />
20 November</td>
<td>Physical-panel alarm lifecycle and supported controls, including refusal, timeout and rejection; health/staleness; stable build begins 30-day run.</td>
<td>Application lead with QA</td>
</tr>
<tr class="even">
<td>4 Commissioning<br />
4 December</td>
<td>Engineer unfamiliar with the build commissions a site from the guide alone; no developer; plans/bulk mapping, permissions and Arabic demonstrated.</td>
<td>Application and commissioning leads</td>
</tr>
<tr class="odd">
<td>5 Acceptance<br />
23 December</td>
<td>Passing allocated requirements and targets; clean build; offline operation; hybrid merge; security remediation; interrupted rollback; 30-day run evidence.</td>
<td>QA lead with Vijay</td>
</tr>
<tr class="even">
<td>Release<br />
31 December</td>
<td>No open Critical/Major defects; signed packages, tested restore, documentation, support owners and release approval.</td>
<td>Vijay and release owner</td>
</tr>
</tbody>
</table>

## Team ownership to confirm at kick off

| **Role**                         | **Responsibilities**                                                                                                       |
|----------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| Vijay                            | Accountable for delivery, scope decisions, staffing, unresolved risks and acceptance recommendation.                       |
| Gateway lead                     | Common drivers/Node-RED, CM4 and Ubuntu packages, interface specification, physical-panel access and regression evidence.  |
| Application and data lead        | Windows service, domain model, desktop UI, integration, database decision, migration, tenancy and audit.                   |
| DevOps and release engineer      | Hyper-V configuration, unattended startup, build/signing, installers, backup/restore, update safety and deployment guides. |
| QA lead                          | Traceability, real hardware tests, load/soak, fault injection, defects and independent acceptance evidence.                |
| Commissioning and product owners | Graphics workflow, no-developer commissioning, English/Arabic validation, commercial entitlement and operational sign-off. |

# 11 Testing and acceptance evidence

| **Test stream**                | **Required evidence**                                                                                                                                                                                                                             |
|--------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Topology equivalence           | Run the same event/control fixtures on CM4 ARM64 and Ubuntu x86-64. Compare internal events, alarm state, audit and error semantics.                                                                                                              |
| Event integrity                | Malformed input quarantined and visible; duplicate/replayed/retained messages deduplicated; source/receipt times retained; no committed-event loss after power interruption.                                                                      |
| Alarm and control              | Fixed precedence, independent audio, stale/source loss, permissions at every route, named confirmations, pending/success/rejection/timeout and offline refusal without delayed execution.                                                         |
| Performance                    | T1 while a 100,000-record export runs; 50 events/s sustained; 500 events/s for 60 seconds; 1,000 symbols at 30fps; measured concurrency and scale sizing.                                                                                         |
| Recovery and endurance         | 24-hour physical-source run; 72-hour reconnect/memory soak; 30-day sustained continuous run with source interruptions. Power loss, disk full and process termination included.                                                                    |
| Security                       | Tenant isolation across views/APIs/exports; PIN lock bypass attempts; fallback account audit; authenticated local IPC and encrypted remote channels; redacted diagnostics; independent assessment with Critical/High findings fixed and retested. |
| Deployment                     | Air-gapped install/activation; unattended boot recovery; interrupted update at each stage; automatic rollback; restore to replacement hardware; signed package rejection tests.                                                                   |
| Commissioning and localisation | Unaided engineer commissioning; large bulk mapping; supported plan limits; English/Arabic RTL and mixed strings; both themes, keyboard and 200% zoom.                                                                                             |
| Architecture and handover      | Layer enforcement in build; no panel logic outside common driver/integration boundary; clean checkout build on a clean machine; guides and support bundle validated.                                                                              |

## Release gates

Map every allocated requirement and target to a passing test. No Critical defects may remain: these affect detection, display, control or recording of alarms. No Major defects may remain: these remove an allocated P1 or P2 capability. Product ownership resolves severity disagreements and approves any explicit increment deferral.

Perform the five final demonstrations: unaided commissioning; 30-day sustained run with no event loss; interrupted updates with automatic rollback; complete operation with no internet route; and two-broker hybrid operation with a merged view and a documented reconciliation rule. If hybrid is deferred, record the acceptance change explicitly. Preserve the original requirement IDs throughout.

# 12 Risks commercial boundaries and immediate actions

| **Risk**                                    | **Response and proposed owner**                                                                                                            |
|---------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| Deadline compression and unknown completion | Vijay verifies reused work and available capacity by 23 October; decide increment allocation. Escalate any P1/P2 or soak-period shortfall. |
| Code divergence across CM4 and VM           | Gateway lead builds both targets from one source version and runs identical contract regressions.                                          |
| MS-01 shared failure domain                 | DevOps validates power protection, durable buffer/storage, unattended recovery and tested external backup.                                 |
| SQLite/PostgreSQL and retention mismatch    | Data lead records an approved decision, measured storage envelope and any requirement 97 or scale revision.                                |
| Unsafe or ambiguous controls                | Application/gateway leads require panel confirmation, correlation, expiry, audit and offline refusal; QA tests unknown outcomes.           |
| Developer still needed to commission        | Commissioning owner makes unaided setup and bulk graphics a release gate.                                                                  |
| Gateway cost or platform licence creep      | Commercial/DevOps owners confirm landed volume BOM, MS-01/Windows/backup costs and redistribution licences.                                |
| Certification uncertainty                   | Product owner scopes UL/Intertek assessment now. Do not represent this internal release as certified; track certification separately.      |
| Existing site regressions                   | Gateway lead pilots versioned releases with rollback; no automatic fleet migration implied by workstation release.                         |

## Commercial and topology boundaries

The source business case assumes a 1,105 AED landed gateway, 1,750 AED monitoring sale and 39,000 AED monitoring/control sale, producing gateway-only gross margins of 645 AED and 37,895 AED. It models 3.5 people for four months at 60,000 AED per month, or 240,000 AED, excluding certification. These are source planning assumptions, not a revised budget for the December programme. Include MS-01, Windows, deployment labour, support, power protection and backup before approving full solution margin; absence of a physical gateway does not remove workstation or delivery cost.

All five topologies stay in the architecture: local gateway/local broker; direct Ethernet with hosted gateway runtime; customer-hosted broker; Omniconn shared cloud; and hybrid. Only routing through Omniconn shared cloud carries the source annual subscription; local and customer-hosted paths remain perpetual. Hybrid must define authoritative sources, duplicate reconciliation and scope isolation. The local service is reachable only on the site LAN; permitted cloud connections are outbound.

## Immediate actions

Vijay should confirm owners and staffing, obtain gateway/interface repositories and hardware, baseline completed work, approve the two runtime packages, decide the database and release scope, and book the lab and independent security assessment. Obtain licensing/update APIs, signing certificate, brand assets, reference gateways and simulator as tracked dependencies. Add the Gateway Management Application, central access-authorisation service and module catalogue to the delivery and capacity baseline in Section 13. Certification scoping runs in parallel; mobile, whole-device firmware delivery, incumbent data migration and unrelated BMS/CCTV/access integrations remain separate scope.

# 13 Gateway Management Application

The gateway currently has no management frontend. Provide its dashboard and management screens in the installed Windows 11 executable on the MS-01. Use a restricted management agent on both the CM4 gateway and the common Ubuntu Hyper-V gateway runtime; neither target hosts a browser dashboard. Provide a detailed first-login health dashboard and a restricted set of critical settings, similar in purpose to the relevant parts of Webmin. A general-purpose server administration console is outside this requirement.

## Purpose and management boundary

The Gateway Management area in the Windows application manages the gateway runtime and approved protocol modules. Its permissions are separate from fire-panel control permissions. A fire-application administrator does not automatically become a gateway administrator. Use the common codebase on both targets, with hardware-specific capabilities exposed through adapters. Prominently show gateway ID, site, CM4 or VM target and runtime version.

Do not deploy an HTTP dashboard, web server or browser UI on the gateway or MS-01. The installed desktop application uses the Windows service over authenticated local IPC; the service communicates with the gateway agent over a restricted, authenticated and encrypted management protocol. Prefer local-only VM management where practical. Agent listeners are restricted to authorised site/management interfaces. Central authorisation uses authenticated outbound communication. Define resource limits so dashboard refreshes, logins and management tasks cannot delay panel supervision or event buffering. Use a narrow privileged helper for approved actions; the gateway agent must not have unrestricted root authority.

| **Area**                 | **Required dashboard and settings**                                                                                                                                                                                    |
|--------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Gateway dashboard        | Identity/site, hardware or VM target, OS/runtime versions, uptime, clock synchronisation, CPU, temperature where available, RAM, disk use and storage health. Display freshness and unavailable values explicitly.     |
| Runtime and sources      | Service health, module versions, per-panel/source connectivity, broker connection, event throughput, last event/contact, buffer depth/capacity, quarantined events and faults.                                         |
| IP and networking        | Interface/link state, DHCP or static IP, subnet, default gateway, DNS and approved management binding. Validate changes and use a timed confirmation/rollback process to prevent lockout.                              |
| Services                 | View dependencies and status. Start/stop/restart only allowlisted services under explicit permissions. Show affected panel sources and operational interruption before confirmation.                                   |
| OS and runtime variables | Allowlist only critical values such as hostname, timezone, approved time servers and selected service configuration. Specify validation, ownership, restart impact and rollback per field. Never expose secret values. |
| Diagnostics              | Recent service/management failures, connectivity history, resource trends and a redacted support bundle. Audit configuration and maintenance actions.                                                                  |

Do not expose arbitrary shell commands, an unrestricted environment editor, package manager or unrestricted Node-RED editor to ordinary users. Service restarts and module changes require operational impact warnings and an approved maintenance window or an explicitly audited emergency override. Define safe apply, health check and rollback behaviour before enabling writes.

# Gateway Management Application roles and one time access

Use named logins and service/agent-enforced role-based access control on every management request. Hiding controls in the desktop application is insufficient. A modified or untrusted client must not bypass these checks. The initial role split below is proposed for approval; network changes are a separate permission that can be granted to a normal commissioning user.

| **Role**                               | **Permitted access**                                                                                                | **Restrictions**                                                                                                          |
|----------------------------------------|---------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| Gateway Viewer                         | Read dashboard and non-sensitive health/status.                                                                     | No settings, services, user/role changes or module installation.                                                          |
| Gateway Operator or Commissioning User | Viewer access; IP/network changes only with an explicitly granted network-configure permission.                     | No privileged OS/service administration, module installation or role escalation.                                          |
| Omniconn Gateway Administrator         | Time-limited centrally authorised session; approved settings/services and module operations within the grant scope. | No unsigned/unentitled modules, arbitrary root/shell access or unapproved gateways.                                       |
| Central Access or Module Approver      | Omniconn server-side approval of named access requests and module entitlements for specified gateways/sites.        | Approval authority does not itself grant a local administrator session. Keep approval and execution permissions distinct. |

## Centrally authorised one time administrator access

Privileged access must be under Omniconn server control rather than a shared permanent administrator password. Require a named identity and centrally authorised one-time exchange before granting an administrator session. An OTP is part of the access flow, not permission for unlimited administration.

Proposed flow: the engineer signs in and requests elevation for a specific gateway and task. The gateway submits its identity and a fresh challenge through an authenticated outbound connection. The Omniconn service checks the engineer, role, site/gateway entitlement, approval policy and requested operations. It issues an expiring, single-use authorisation bound to that request. Successful OTP or approved challenge-response validation creates a bounded session with only the authorised permissions.

Bind grants to subject, gateway, request ID, permitted actions and expiry; record the approver where applicable. Enforce single use, rate limiting, session timeout, logout and replay protection. Test use on a different gateway, after expiry and after reboot. Protect device identity and signing keys; never log OTP seeds, raw tokens or other credentials. Define certificate/key rotation, clock-health checks and access-service trust at the security design gate.

The exact OTP method, identity provider, MFA policy, approval workflow, session duration and server synchronisation mechanism remain design decisions. A time-generated OTP alone does not prove approval for a specific gateway or operation. Check central policy at every new privileged grant and before high-impact operations; define revalidation and revocation behaviour for active sessions.

# Gateway module catalogue and lifecycle

The installed Windows application must allow controlled selection and installation of gateway protocol modules, initially BACnet, Modbus, CIP, Simplex and SNMP. These are proposed catalogue entries, not a statement that every module is already developed, licensed or accepted. Record each supported protocol variant and version, including the exact meaning and scope of CIP. Installation, configuration and activation are separate permissions.

| **Stage**                | **Required control**                                                                                                                                                                           |
|--------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| View catalogue           | Show approved modules, purpose, installed/available version, compatible architecture/runtime, entitlement, dependencies and resource needs. Normal users can view status but cannot install.   |
| Authorise installation   | Require administrator role, module-install permission and a valid scoped central grant. Omniconn controls eligible modules and approved versions by gateway or site.                           |
| Obtain and verify        | Use approved repositories or signed offline packages. Validate signature, hash, manifest, entitlement, target architecture and dependency/runtime compatibility before applying changes.       |
| Stage and configure      | Snapshot recoverable configuration, validate settings and stage the package. Distinguish installed, configured, enabled and running states; do not activate an unconfigured driver implicitly. |
| Check and commit         | Verify module/source health and data flow without breaching alarm-path targets; record module version and outcome. Existing supervision must remain protected.                                 |
| Fail and recover         | Reject invalid/unauthorised packages without changes. Restore the previous working module/configuration after failed installation or startup, with a visible fault and reason.                 |
| Update disable or remove | Apply separate permissions and the same central authorisation, audit and rollback rules. Warn of affected sources and require confirmation before interrupting live panel supervision.         |

## Disconnected operation and recovery

Approved local authentication must keep routine dashboard access available when central servers cannot be reached. Existing module execution, monitoring and buffering must not depend on the authorisation or catalogue service being online. An explicitly permitted local commissioning user should be able to repair network settings under the approved site policy, avoiding a circular dependency on central connectivity.

Proposed default: refuse new privileged elevation and module installation when central authorisation cannot be validated. Decide whether isolated deployments require signed, short-lived offline grants and signed offline packages. If permitted, bind the grant to one gateway, named engineer, exact operations/package digest, expiry and one-use ID; protect consumed-grant state across reboot and synchronise audit on reconnection. Copying a package locally must not bypass permission or entitlement.

Any emergency access path needs an explicit decision covering physical verification, approval, expiry, audit and review. Do not introduce an undocumented default password. Define bounded revalidation for active privileged sessions and refuse module changes if authority cannot be confirmed. Immediate central revocation is unavailable during complete disconnection; any offline grant must have a deliberately limited residual lifetime.

# Gateway Management Application delivery and acceptance

This is new outstanding development for the 31 December 2026 baseline. Vijay must confirm capacity and dependencies at the design gate. The central gateway authorisation service and controlled module catalogue are additional work beyond existing application integrations. Protocol-module package management is included; whole-device OS/firmware distribution remains a separate decision.

| **Gate** | **Additional exit evidence**                                                                                                                                       | **Proposed owner**                    |
|----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------|
| 23 Oct   | Approve setting/service allowlists, RBAC, gateway identity and OTP protocol, online/offline policy, module manifest/catalogue, resources and test IDs.             | Gateway, security and product leads   |
| 6 Nov    | Windows executable communicates with the common agent on CM4 and Ubuntu VM; dashboard, named login, validated network changes and process isolation.               | Gateway and DevOps leads              |
| 20 Nov   | Centrally authorised one-time elevation, API permission/audit/replay tests and module install/rollback prototype. Freeze alarm-path changes for the endurance run. | Gateway lead and access-service owner |
| 4 Dec    | Unaided network configuration and approved module commissioning; safe IP recovery, role-specific workflows and guide.                                              | Commissioning lead and QA             |
| 23 Dec   | Desktop application and both agent targets pass security, outage, interrupted module lifecycle and resource tests; signed installation guide ready.                | QA and security leads                 |
| 31 Dec   | No blocking defects; signed packages, approved offline policy and named central-service/support owners.                                                            | Vijay and release owner               |

# Gateway Management Application acceptance tests

| **ID** | **Acceptance evidence**                                                                                                                                                                              |
|--------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| G01    | Installed Windows executable displays identity, resources, services, modules, sources and freshness from both gateway-agent targets; no hosted dashboard is deployed.                                |
| G02    | Viewer cannot write; permitted network user can change only approved fields. Direct agent requests cannot bypass RBAC or gateway/site scope.                                                         |
| G03    | Invalid IP/subnet/DNS rejected. Network changes use tested timed confirmation and rollback if access is lost.                                                                                        |
| G04    | Only allowlisted service and OS/runtime operations available; no arbitrary command execution or secret disclosure.                                                                                   |
| G05    | Central single-use elevation rejects wrong user/gateway, expiry, replay and reboot reuse; session limits and rate limiting verified.                                                                 |
| G06    | Central outage, revocation and clock faults follow approved policy while monitoring, buffering and permitted dashboard access continue.                                                              |
| G07    | Only a currently authorised administrator installs/updates/removes an entitled module. Normal or expired accounts are refused and audited.                                                           |
| G08    | Reject altered, unsigned, incompatible, wrong-architecture or unentitled packages. Interrupt each lifecycle stage and verify safe recovery.                                                          |
| G09    | Protected audit records actor, approver/grant, gateway, action, non-secret before/after values, module/version, time and outcome; synchronisation loses or duplicates no records.                    |
| G10    | Desktop dashboard/login load and module management respect agreed resource limits and preserve alarm ingestion, buffering and source supervision.                                                    |
| G11    | A non-developer with the correct role configures network and an approved module from the guide; Windows 11 installation, authenticated IPC and encrypted agent connections documented.               |
| G12    | Security assessment covers desktop application, IPC/agent protocol, privileged helper, central authorisation, module supply chain and offline paths; Critical/High findings remediated and retested. |

Track G01 to G12 alongside the original SOW IDs without renumbering them. Confirm gateway-audit retention/storage, account provisioning and recovery, certificate renewal and central-service availability in the design register. The detailed earlier zero-trust design has not yet been supplied; product and security owners must review these proposed controls before implementation.

# Appendix A Complete numbered requirement baseline

The following editable requirements retain the Saleem SOW numbering and priority. Entries marked Desktop revision supersede the original browser, hosting, installation and related wording. The change register in Section 1 governs the in-house ownership, common hosted gateway and open database decision. Retaining an item here does not assert that it is implemented. Assign every item to a release increment and a passing acceptance test.

## Dashboard and alarm handling

**1 P1** System dashboard Default screen after sign-in. Live alarm state across all sites visible to the user, with fire given unconditional visual precedence, live counts per alarm type, and one- click drill-through to the filtered list.

**2 P1** Push refresh Screens update on receipt of an event, within the alarm latency in target T1 , with no refresh button and no operator action of any kind required.

**3 P1** Staleness indication Where a source is disconnected, its data is marked stale everywhere it appears with the time of last contact. Stale data is never presented as current.

**4 P1** Desktop revision Audible annunciation in each signed-in desktop client session for each new alarm, configurable by type and independently silenceable per session. Application audio silence remains separate from panel silence.

**5 P1** Active alarm list Alarm type, site, panel, device address and label, space, time raised and current state, with filter and sort on every column.

**6 P1** Alarm types Fire, Priority 2, Supervisory and Trouble, classified from the source event as supplied by the gateway or, for direct connections, the Simplex connector, and selected through a dropdown drawn from one shared definition. Precedence order is fixed , applied everywhere, and is Fire, Priority 2, Supervisory, Trouble in descending order.

**7 P1** Type distinction Each type carries a distinct colour and a distinct non-colour indicator, so type is readable without relying on colour.

**8 P1** Acknowledge Individually or across a selected group, with the acknowledging user and time recorded against the alarm.

**9 P1** Silence Silence sounders at panel scope, subject to permission, with confirmation naming the panel . Every silence action is written to the audit log with the user, the panel and the time.

**10 P1** Reset Reset an alarm condition at panel scope. Always requires confirmation naming the panel and scope; confirmation cannot be suppressed. Where PIN re-entry is enabled in settings, reset also requires the PIN.

**11 P1** Pending and failed states A control action shows as pending until the panel confirms or rejects it, and as failed with the reason if it times out. It is never shown as complete on the strength of the request alone.

**12 P1** Refusal when offline Control actions attempted while a source is unreachable are refused with a clear reason. They are never queued, silently or otherwise, and are never retried automatically once the source returns.

**13 P3** Operator notes Free-text note attached to an alarm, retained with the record and carried into reports.

**14 P2** Wallboard mode Full-screen display with no chrome, for an unattended control room screen. Live alarm state remains visible while the session is locked.

## Devices fire network and gateways

**15 P1** Device register Every device known to each panel within the user's tenant and site scope, with its current state, navigable by panel, loop and address, and searchable by label, space, type and state.

**16 P2** Full device metadata Everything the panel or gateway reports about a device, including analogue values, sensitivity, dirtiness and vendor-specific attributes. An attribute the source does not report is shown as not reported, and one reported with a value the application does not recognise is shown with the raw value. Neither is hidden, defaulted or guessed.

**17 P2** Device state history Every state change per device with timestamps, over a configurable retention window subject to the floor in requirement 51.

**18 P2** Device discovery Requested from the application; results reconciled against the register with additions and absences presented for review rather than applied silently. A device absent from a discovery is retained in the register and marked missing until an operator confirms its removal.

**19 P1** Device control Disable, enable and where supported test an individual device, with confirmation and audit. Disabled devices are visually distinct everywhere and carry a standing count on the dashboard for as long as any device remains disabled.

**20 P1** Local labels and spaces Labels and space assignments editable in the application and held separately from panel-reported values, so a rediscovery does not overwrite commissioning work.

**21 P2** Fire network view Panel node topology per site with communication state, last-contact time, and navigation from a node to its devices and alarms. A site with a single panel and no panel network shows that one node rather than an empty or hidden view.

**22 P1** Network alarms Node communication loss and network faults raised in the alarm list as Trouble, not buried in a separate screen.

**23 P2** Gateway health All configured gateways with connection state, firmware version, identity, per-panel connection state and the health telemetry defined in the gateway interface specification.

**24 P1** Source loss alarm Loss of contact with any source raises a Trouble alarm on the dashboard in real time . This applies to a gateway, a directly connected panel and a broker alike.

**25 P1** Late delivery marking Events delivered from a buffer after a reconnection are marked late, showing both event time and receipt time. Late events are ordered by event time in history and by receipt time in the live view.

**26 P3** Firmware version tracking Current firmware and gateway-side software versions recorded per gateway, with the version history retained so a change is visible after the fact. The application does not push or apply firmware.

**27 P3** Outdated version flagging Where an available version is known, gateways running an older version are flagged in the gateway health view, with the available version shown alongside the installed one. A site with no route to the Omniconn platform shows the installed version and states that no comparison is available, rather than implying the version is up to date.

**28 P2** Firmware change audit A firmware or gateway software version change is written to the audit log with the gateway identity, the previous and new versions and the time observed, whoever performed the upgrade and by whatever means.

## Floor plans and mapping

**29 P1** Floor plan upload PNG, JPEG, WebP and SVG plans uploaded and attached to a space, with a maximum file size of 20 MB and a maximum pixel dimension of 8,192 pixels on the longer side , and a rejection message naming which limit was exceeded and the actual value. CAD and BIM formats, including DXF and DWG, are not imported; a plan drawn in CAD is exported to one of the supported formats first.

**30 P1** Space hierarchy At least three levels per site, typically building, floor and zone, created and maintained in the application.

**31 P1** Drag-and-drop placement Devices dragged from an unplaced list onto the plan and repositioned by dragging, with live state shown in position.

**32 P2** Plan performance Pan and zoom hold the frame rate in target T5 with 1,000 placed devices on a single plan. Across all plans in a site, placement is supported for the full device count in the Section 6 scale target , with no per-site limit on placed devices below that figure.

**33 P1** Bulk mapping Select devices by panel, loop, address range or filter and assign them to a space in one action.

**34 P1** Bulk placement Place a selected device group onto a plan as a group, then adjust individually.

**35 P2** Mapping completeness Per site and per space, how many devices are mapped and how many remain, so commissioning progress is visible. The unmapped devices are listable and openable directly from the count.

**36 P2** Control from the plan Invoke the device control actions in requirement 19 directly from the plan, under the same permission , confirmation and audit rules, with the same pending and failed states.

**37 P2** Navigate to alarm From an alarm, open the plan showing that device, centred and highlighted.

**38 P3** Geographic view Sites on a map with alarm state rolled up per site, and drill-down to spaces and plans. With no internet connection the alarm state, the site list and the drill-down all continue to work against a locally held base map or a plain positional layout, and the view states that live map data is unavailable.

**39 P3** Plan replacement Replace a plan image while retaining device placements. W here the aspect ratio or dimensions differ, placements are shown against the new image for confirmation before the replacement is committed, and the previous image and placements are recoverable if it is rejected.

**40 P2** Mapping import Import device-to-space mappings from a spreadsheet, with validation and preview before applying.

## Reporting statistics and logs

**41 P2** Condition statistics Counts and trends for the conditions defined in the gateway interface specification, at minimum Head Missing, No Answer, Abnormal, Output Abnormal, Bad Answer, Disabled Device, Sensor Dirty and Open Circuit Reporting, each tracked separately rather than collapsed into a generic fault count. A condition reported by a source but not in the list is counted under its reported name rather than discarded.

**42 P3** Drill-through Every count opens the list of devices or events behind it, and from there the individual device and its plan.

**43 P2** Filtering Statistics and lists filterable by site, space, panel, device type, alarm type, condition and date range, and by tenant where the user is scoped to more than one. A tenant the user is not scoped to is not offered as a filter value and cannot be reached by supplying one.

**44 P2** Bulk export A filtered set of alarms exported to PDF, Excel and CSV. The filters available for export are identical to those on screen and produce the same rows , and the export reflects the filter at the moment it was requested rather than any later change.

**45 P2** Individual alarm report A single alarm as PDF, Excel and CSV, including the full event timeline, every control action taken, and the plan extract showing the device location. Where the device is not placed on a plan the report states that and still reports the space and panel address, rather than failing or omitting the location entirely.

**46 P2** Export provenance Every export carries tenant, site scope, filter criteria, period, generating user and generation time, in the file itself rather than only in the file name. Excel and CSV carry it in a header block or a separate sheet, and PDF output carries it together with the configured branding.

**47 P3** Register and health exports Device register, gateway health and statistics views exported to Excel and CSV , under the same provenance and non-blocking rules as requirements 46 and 48.

**48 P2** Non-blocking export A long export reports progress, can be cancelled, and does not block the interface. A cancelled or failed export leaves no partial file, and the Section 6 export target is met without delaying alarm ingestion or display.

**49 P1** Alarm log Append-only history of every event received from a source, with both source event time and receipt time retained. This log holds what the fire system reported; operator actions are held in the audit log, and where an action appears in both the audit log is authoritative.

**50 P1** Audit log Append-only record of sign-in and sign-out, failed sign-in, control actions, configuration and user changes, licence events and exports, with user, client identity, target and outcome. Refused and failed actions are recorded alongside successful ones . Not editable or deletable at any permission level.

**51 P1** Retention and archiving Configurable retention per log , which cannot be set below one year for the alarm log or below the life of the installation for the audit log, and archiving to a format readable without the application. Archived data remains reachable from the application for the periods in the Section 6 retention target.

**52 P3** Scheduled reports Recurring reports written automatically to a configured local or network folder. A failure to write, including an unreachable network folder, raises a Trouble alarm and is recorded in the audit log rather than failing silently.

**53 P4** Response analytics Mean and maximum time to acknowledge, per site and per operator, over a selected period. Per-operator figures are behind a separate permission, and whether they are available at all is configurable per installation so a customer whose staff agreements or local law prohibit individual performance monitoring can disable them while keeping the per-site figures.

## Administration users and security

**54 P1** Tenant management Multiple tenants in one installation, each owning sites. Create, edit, suspend and archive tenants; the active tenant is visible on screen at all times. Suspending or archiving a tenant removes its users' access but never stops ingesting or recording events from its sites, and its historical data remains available for reporting.

**55 P1** Tenant isolation A user scoped to one tenant cannot reach another tenant’s data through any view, search, export, report or log. Demonstrable by test at acceptance.

**56 P1** Roles Administrator, Engineer, Operator and Viewer as delivered, composed from granular permissions so custom roles can be created and existing ones amended without a code change. The installation cannot be left with no account holding the manage-users permission.

**57 P1** Granular permissions Separate permissions for view, acknowledge, silence, reset, disable device, request device discovery, edit plans and mapping, manage users, tenants, settings and licence, export , view per-operator analytics, and read the audit log.

**58 P1** Single enforcement point Permission is checked in one place and every route to a protected action passes through it. Unavailable actions are visibly unavailable rather than failing after the attempt.

**59 P1** User scoping Users scoped to one or more tenants and sites, independently of their role.

**60 P1** Authentication Windows integrated authentication, Active Directory single sign-on and local accounts, selectable per installation.

**61 P1** Directory fallback Where the directory is unreachable, a designated local account can still sign in, so a control room is never locked out by a domain problem. The account is nominated explicitly rather than defaulted, its use is written to the audit log, and it is subject to the same permissions and PIN rules as any other account.

**62 P1** Inactivity lock After a configurable idle period the controls lock while live alarm state stays on display. Unlocking requires the user PIN and restores on-screen context. Every user has an application-held PIN, set on first sign-in and independent of how they authenticate, so a user signed in through the directory can still unlock when the directory is unreachable.

**63 P2** PIN on control actions Optionally require PIN re-entry for silence and reset regardless of lock state, configurable in settings.

**64 P1** Failed PIN handling A configurable number of failed attempts ends the session, returns to full sign-in and is written to the audit log.

**65 P1** Credential storage Passwords and PINs stored with a memory-hard password hashing function and per-credential salt, with the algorithm and parameters stated in the architecture document and approved at the design gate. Reversible storage and general-purpose hash functions are not acceptable. Verification attempts are rate-limited so a PIN cannot be attacked by repetition.

**66 P3** Directory group mapping Map directory groups to roles so membership is managed in the directory rather than duplicated in the application.

## Settings branding and licensing

**67 P1** Settings One permission-restricted area holding every configurable behaviour in this document, with every change audited showing previous and new values.

**68 P2** Light and dark themes Both themes meet the contrast and non-colour indicator requirements in target T13 independently, with identical alarm colour semantics and precedence in each. The dark theme is a separate palette and is not produced by inverting the light theme. Theme choice is made by each user and remembered across sessions.

**69 P2** White labelling Logo, product name, accent colours and report branding configurable, applied consistently to sign-in, application chrome, about screen and all generated reports. Alarm type colours are not brandable, and accent colours are rejected where they would collide with the alarm palette or fall below the contrast target in Section 6.

**70 P1** Licence activation A valid licence key is required before any operational function is available. Validation happens at activation; no recurring online check is required to keep running.

**71 P1** Terms and privacy acceptance Terms and conditions and the privacy policy presented before activation completes, requiring explicit unticked acceptance of each.

**72 P1** Acceptance recording The acceptance record, covering user, timestamp, licence key and the version of each document shown, is stored on the Omniconn licensing platform.

**73 P1** Offline activation A request artefact produced on the isolated machine and a response artefact applied to it, carrying the acceptance record. Offline activation is a supported procedure and is documented in the deployment guide.

**74 P2** Licence status Current licence, entitlements, and the accepted document versions with their acceptance dates, visible to an administrator.

**75 P2** Settings portability Export and import of a commissioned configuration, so a setup can be reproduced on another installation. The export excludes credentials, PINs, licence material and source secrets, and states what it omits so the engineer knows what must be re-entered.

**76 P3** Licence re-hosting Move a licence to replacement hardware through a defined, audited procedure.

## Technical requirements

**77 P1** Desktop revision Installed Windows 11 desktop executable on the MS-01, with a separate background Windows monitoring service. Additional authorised PCs require an installed client if included in scope. Supersedes the browser/no-client-installation requirement.

**78 P2** Desktop revision Desktop platform support for Windows 11 x64, including approved runtime dependencies supplied in the signed offline installer. No Chrome, browser extension or hosted browser interface is required.

**79 P1** Desktop revision No internet exposure of the application or gateway management agent. Local desktop-to-service communication is authenticated IPC. Any additional client or gateway-agent traffic is limited to approved site networks over authenticated encrypted channels; central licensing, access and update connections are outbound as needed.

**80 P2** Desktop revision Administrators configure approved site-LAN and gateway-management addresses/ports and local IPC permissions. Do not expose a web-dashboard listener. Changes are validated, audited and reversible without reinstalling.

**81 P1** Desktop revision Protect local IPC with Windows access controls and authenticated identity. Remote client/service and service/agent links require encryption, authenticated endpoints and certificate validation. Document provisioning, trust, renewal and rotation without reinstalling. Central authorisation connections use validated secure transport.

**82 P1** Unattended start The service starts automatically at machine start-up, before and without any user logging in, and restarts automatically if it stops. It re-establishes source connections on its own after a restart or a power cut.

**83 P1** Desktop revision Capture, persistence, alarm classification and audit continue while the desktop window is closed, no interactive Windows user is signed in, or every UI client is disconnected.

**84 P1** Desktop revision The nominated control-room PC launches the installed application full screen after approved interactive sign-in or kiosk startup. It reconnects and restores the permitted display after interruption. Background monitoring starts before user sign-in; control actions remain locked until authorised.

**85 P1** Desktop revision The background service and gateway agent enforce session lock and permissions. Relaunching the executable, opening another window, modifying the client or calling the agent directly cannot bypass the lock; sessions lock independently.

**86 P2** Desktop revision Retain the source target of at least 50 concurrent authenticated operator sessions on the minimum monitoring-service configuration, now using installed desktop clients. Each has independent user/site scope and lock state. Confirm December scope and measure supported topology/sizing; do not assume a single-PC test proves remote concurrency.

**87 P3** Desktop revision Document minimum supported Windows 11 build, desktop runtime and client/service/agent protocol versions. Use supported platform features without experimental or browser-specific dependencies.

**88 P2** Desktop revision Verify the executable against the supported Windows 11 servicing baseline at every phase exit and acceptance. Test runtime updates and client/service/agent compatibility, including safe refusal of incompatible control clients.

**89 P2** Layered architecture Presentation, application services, domain, integration, data and platform services, with dependencies pointing inward and downward only. Layer rules enforced in the build; a violation fails the build.

**90 P2** Framework-free domain Alarm classification, precedence, permissions, tenancy and the device model carry no dependency on UI framework, storage or transport, and are testable without any of them.

**91 P2** Single internal model One event and command model above the connectivity layer, independent of topology and panel manufacturer.

**92 P1** MQTT subscription Client subscription over TCP and TLS with certificate validation, configurable broker address, credentials and topic scope, honouring the quality of service and retained-message behaviour in the gateway interface specification.

**93 P1** Automatic reconnection Reconnects after connection loss with exponential backoff, re-establishes subscriptions and reconciles state. Repeated reconnection cycles do not accumulate memory , threads, handles or duplicate subscriptions, verified over the 72-hour soak in Section 6.

**94 P1** Direct panel connection Connects directly to Simplex panels over Ethernet with no gateway, producing the same internal events. Panel protocol code is confined to the integration layer.

**95 P1** Event integrity Inbound messages validated against schema; failures quarantined, counted and surfaced, never silently discarded. Duplicates from replay or retained messages are deduplicated.

**96 P1** Time handling Both source event time and receipt time persisted. History orders by event time; the live view presents by arrival with late events marked. All times stored in UTC and displayed local with the zone shown.

**97 P1** Local store Embedded transactional database requiring no separate server, recovering to a consistent state after power loss with no committed event lost , demonstrated by deliberate power interruption under sustained load. An event is treated as committed only once it is durable, so nothing is acknowledged to a source or shown as recorded before it survives a power cut. Backup and restore available through the interface, with backup possible while the service is running.

**98 P1** Encryption at rest Credentials, PINs, licence material and source secrets encrypted using platform key protection, and never written to logs or diagnostics.

**99 P1** Alarm path isolation Reporting, exports, plan rendering, statistics and updates cannot delay ingestion or display of an alarm, verified by meeting target T1 while an export at the Section 6 export target runs concurrently.

**100 P1** Component licensing All third-party components licensed compatibly with perpetual commercial distribution, with no runtime activation or network check. Inventory delivered at the design gate and kept current.

**101 P2** Extensibility Adding a source type or panel family changes only the integration layer, verified at final acceptance by a code review against this document rather than by demonstration.

**102 P2** Diagnostics Technical log separate from alarm and audit logs, level changeable at runtime without restart, and a one-action support bundle containing logs, redacted configuration, version and connectivity history. The bundle contains no credentials, PINs, licence material or source secrets, states what it redacted, and is produced without internet access so it can be carried off an isolated site.

**103 P1** Fault containment A fault in one source is contained to that source. Unhandled exceptions are caught at defined boundaries, written to the technical log with a correlation identifier, and surfaced to the operator as a Trouble condition naming the affected source. The service does not terminate without a log entry.

**104 P1** Desktop revision Least privilege, no hard-coded credentials/endpoints, validated external input, pinned/scanned dependencies and independent security assessment before acceptance. Include the executable, local IPC, background service, gateway-agent protocol, access authorisation, module management, activation and updates; remediate and retest Critical/High findings.

**105 P3** Certification- aware design The supplier identifies in the architecture document at the design gate each design decision bearing on a future UL 864 assessment or IEC 62443 alignment, states the option chosen and the alternative rejected, and records any such decision arising later in the same register before implementing it. The register is delivered at final acceptance. Neither certification is sought in this engagement.

## Deployment licensing and updates

**106 P1** Desktop revision Signed Windows installer deploys the executable, background service and required runtime dependencies on the MS-01. Provide a signed client-only installation mode for approved additional operator PCs. Signing keys remain with Omniconn.

**107 P1** Licence before download Where the installer downloads packages, it requests and validates the licence key first and then downloads only what the licence entitles. Where packages are supplied locally under requirement 108, the same entitlement check is applied to the supplied set before installation proceeds.

**108 P1** Offline installation Install and activate from a pre-obtained package set and offline activation response, with no connectivity on the target machine.

**109 P1** Safe installation Prerequisites checked before changes are made; a failed installation leaves the machine in its prior state with nothing partially installed.

**110 P1** Guided first run Terms and privacy acceptance per requirement 71, first administrator account and first source configured through a guided sequence. Any step already completed before delivery is shown as complete rather than repeated, and the sequence can be resumed if it is interrupted.

**111 P1** Package verification Signature and manifest verified before any package is applied. Verification failure aborts the operation and is written to the audit log.

**112 P2** Subscribed updates Checks the Omniconn platform on a configurable interval and notifies administrators with version, release notes and size. Availability never means automatic installation.

**113 P1** Desktop revision Coordinate signed executable, service and agent updates through explicit version compatibility. Clients require installation of their updated executable; a browser reload does not apply. Updating or closing a client must not stop monitoring. Test rollback and safe refusal of incompatible clients.

**114 P2** Scheduled updates Updates applied only within a maintenance window defined by the customer, with an administrator able to apply one immediately where a fix cannot wait. An update that cannot complete within the remaining window is not started, and one already in progress runs to completion or rollback rather than stopping at the window boundary.

**115 P1** Manual update Update from a locally supplied package for installations with no connectivity, with identical verification and rollback behaviour.

**116 P1** Backup before update Complete backup of binaries, configuration and local store taken before the update is applied , verified by confirming it restores rather than only that it reads, retained until the next successful update, and written to a location that survives loss of the machine.

**117 P1** Post-update health check The updated installation must start, read its store and re-establish source connections before the update is committed.

**118 P1** Automatic rollback Failure at any stage, including a failed health check, restores the last known good state automatically without waiting for a person.

**119 P1** Interruption tolerance An update interrupted by power loss, reboot or process kill is detected at next start and rolled back automatically. Tested by deliberate interruption at every stage.

**120 P2** Update history Current version, available version and the history of updates including failed and rolled-back attempts, all audited.

**121 P2** Repair and migration Repair reinstalls binaries while preserving configuration, store and licence. Migration to another machine by backup, restore and licence re-hosting.

**122 P2** Clean removal Uninstallation removes the application cleanly and asks explicitly whether operational data is retained or removed. Removal requires an administrator, states that the site will no longer be monitored, and is written to the audit log before the application is removed. Where data is removed, the retention floors in requirement 51 are honoured by archiving first rather than deleting.

**123 P3** Desktop revision Unattended installer parameters support workstation/service installation and, where required, client-only deployment, without exposing credentials or bypassing licence/role checks.

# Appendix B Performance and assurance targets

| **ID** | **Area**             | **Acceptance target**                                                                                                                                                                                                            |
|--------|----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| T1     | Alarm latency        | Every event visible within 1 second of receipt at sustained load and within 2 seconds during burst.                                                                                                                              |
| T2     | Control dispatch     | Sent to the source within 500ms of operator confirmation.                                                                                                                                                                        |
| T3     | Startup              | Service accepts sessions within 15 seconds of service start; dashboard populated with live state within a further 5 seconds of sign-in, at stated volumes on minimum configuration.                                              |
| T4     | Queries              | Navigation under 1 second; filtered alarm list under 2 seconds at full volume.                                                                                                                                                   |
| T5     | Plans                | At least 30fps with 1,000 placed devices.                                                                                                                                                                                        |
| T6     | Export               | 100,000 alarm records within 60 seconds without blocking interface or alarm path.                                                                                                                                                |
| T7     | Sustained load       | 50 events per second across all sources.                                                                                                                                                                                         |
| T8     | Burst                | 500 events per second for 60 seconds, no loss and burst recorded.                                                                                                                                                                |
| T9     | Scale                | 100 panels, 100 tenants, 100,000 devices, 100 concurrent sources; measured on stated deployment sizing.                                                                                                                          |
| T10    | Retention            | Three years of alarm history, subject to configured retention and requirement 51 floors; measured on stated sizing.                                                                                                              |
| T11    | Continuous operation | 90 days without restart; stable memory over 72-hour soak. Initial acceptance uses 30-day run and subsequent support evidence per Section 9.                                                                                      |
| T12    | Source loss          | Detected and shown on dashboard within 15 seconds.                                                                                                                                                                               |
| T13    | Accessibility        | WCAG 2.1 AA in both themes; non-colour alarm indicators; all actions keyboard reachable; alarm controls verified; readable at 200% zoom.                                                                                         |
| T14    | Localisation         | English and Arabic at first release; externalised text; RTL, configured Arabic numerals, mixed Latin/Arabic, both themes, dashboard, alarms, register, plans, settings and PDF/Excel/CSV verified.                               |
| T15    | Coverage             | 70% line coverage in domain/application layers and 90% branch coverage for alarm classification, precedence, permissions and update rollback; reported per module.                                                               |
| T16    | Minimum host         | Desktop revision: Windows 11 x64; 4 cores, 8GB RAM, 256GB SSD minimum for the monitoring service and desktop application. MS-01 target remains i9/32GB/1TB. Scale, retention and VM sizing need separate measured configuration. |
| T17    | Desktop client       | Desktop revision: installed signed Windows 11 x64 application, 1920×1080 or higher and working audio. Additional client PCs need installation; no separate per-client licence. Declare runtime, service and agent compatibility. |
| T18    | Unattended recovery  | Service accepts sessions within 60 seconds of machine startup with no user logged in.                                                                                                                                            |

# Appendix C Source rationale and scope boundaries

## Why the platform is being replaced

The Saleem documents identify ThingsBoard constraints in four areas. Commercial concerns include the reported 18,500 AED offline licence, per-instance high availability licensing, update charges, separately priced Edge/analytics/mobile white labelling, device-count pricing and vendor repricing. Dependency concerns include supplier support, limited code accountability and lock-in through dashboards, rule chains and entity models.

Product concerns include generic rather than fire-specific alarm precedence, weak command-confirmation semantics, floor-plan/bulk mapping limitations and maintenance of customised platform code. The source describes difficulty versioning, reviewing, testing and deploying rule-chain logic consistently across the installed fleet. Operations concerns include reported silent processing/live-screen failures, heavy components such as Kafka, complex single-site support and upgrade/schema migration risk. These are the source rationale for owning the core code and reducing local moving parts.

## Delivery dependencies and exclusions

Required dependencies are the gateway interface specification, two reference gateways, a load simulator, panel protocol documentation, physical panel or simulator access, brand guidelines, licensing/update service APIs, signing certificate, lab environment and authorised test access. Each needs an owner and a required-by date in the plan. The source treats discovery as a gateway/panel function and control as executed by the panel, never simulated in the application.

Application release scope excludes a mobile app, certification delivery, panel firmware/programming, CAD/BIM import or automatic placement, BMS/CCTV/access/notification integration, incumbent data migration, non-Windows application builds, internet publication. Broad cloud-platform redevelopment remains separate; Section 13 explicitly adds the central gateway access-authorisation service and controlled module catalogue. Existing gateway adaptation and packaging are included in this internal roadmap even though gateway firmware/software development was excluded from the outsourced application SOW. The Gateway Management Application and controlled protocol-module installation/update/removal are now included. Whole-device OS/firmware deployment remains separate unless expressly added.

## Source register

S1 Omniconn Fire and Safety v1.2 DOCX, supplied file labelled Omniconn_Fire & Safety_v1.2 (3).docx. Used for business rationale, gateway specification and commercial/topology boundaries.

S2 Omniconn Fire and Safety Application SOW v1.0 PDF, supplied file Omniconn_F&S_APP_SOW_v1.0.pdf, 25 pages. Requirements in pages 5 to 21, targets in pages 22 to 23, delivery/acceptance in pages 23 to 24, exclusions/dependencies in page 25.

S3 Omniconn Fire and Safety Business Case v1.2 PDF, supplied file Omniconn_Fire & Safety_Business-Case_v1.2.pdf, 16 pages. Business/financial case, gateway minimum specification, five topologies and ThingsBoard limitations.

S5 Windows desktop architecture direction: installed Windows 11 executable replaces the browser interfaces. Gateway settings and module control use a restricted agent; the background service preserves unattended monitoring. Effective requirement revisions retain original IDs and priorities.

S4 Subsequent user deployment and delivery direction in the Omniconn TSW Architecture Roadmap conversation and this document request. Governs in-house ownership, MS-01/Hyper-V and CM4 options, common gateway reuse, open database decision and 31 December 2026 deadline.
