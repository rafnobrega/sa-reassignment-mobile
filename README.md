# SA Reassignment Mobile

A Lightning Web Component for Salesforce Field Service that enables field technicians to reassign a Service Appointment to another crew member — directly from the record page or as a screen action.

## Overview

When a field technician needs to hand off a job to a teammate, this component provides a crew-aware reassignment flow. It automatically detects the logged-in user's crew membership and presents only valid reassignment targets.

### Key Features

- **Crew-aware**: Automatically detects the logged-in user's Service Crew and shows eligible crew members
- **Non-crew fallback**: If the user isn't in a crew, shows all active technicians with configurable warnings based on Minimum Crew Size
- **Status-aware**: Automatically detects terminal SA statuses (Completed, Canceled, Cannot Complete) and shows a locked banner instead of the reassignment UI
- **Guard rails**: Prevents reassignment to the currently assigned technician, validates inputs, and displays clear error states
- **Mobile-optimized**: Touch-friendly card-based selection UI designed for the Field Service Mobile App
- **Accessible**: Keyboard navigation support, ARIA roles, and focus management

## Architecture

```
┌─────────────────────────────────────┐
│  saReassignment (LWC)               │
│  - Record page / Screen action      │
│  - Crew member selection cards      │
│  - Non-crew warning flow            │
│  - Success/error states             │
└──────────────┬──────────────────────┘
               │ @wire + imperative Apex
               ▼
┌─────────────────────────────────────┐
│  SAReassignmentController (Apex)    │
│  - getReassignmentContext()         │
│  - reassignAppointment()            │
└─────────────────────────────────────┘
```

### Reassignment Strategy

The component uses a **delete + create** pattern for `AssignedResource` records rather than updating the existing record. This is the recommended approach for Field Service because:

- The FSL scheduling engine fires triggers on `AssignedResource` insert/delete, not on field-level updates to `ServiceResourceId`
- The `ServiceCrewId` lookup on `AssignedResource` is set correctly for the new resource
- Provides a cleaner audit trail — the exact reassignment timestamp is captured
- Uses `Database.setSavepoint()` for safe rollback if the insert fails

### Crew Lookup Logic

The component resolves crew membership through a chain of standard FSL objects:

```
User (logged-in)
  └─► ServiceResource (via RelatedRecordId)
        └─► ServiceCrewMember (via ServiceResourceId, filtered by StartDate/EndDate)
              └─► ServiceCrew (via ServiceCrewId)
                    └─► All ServiceCrewMembers in the same crew (eligible targets)
```

**Date filtering**: Crew memberships are filtered by `StartDate <= NOW` and `EndDate = null OR EndDate >= NOW` to ensure only active memberships are considered.

## Prerequisites

- Salesforce org with **Field Service** (FSL managed package) installed and configured
- Service Crews and Service Crew Members configured
- Service Resources linked to Users via `RelatedRecordId`
- Service Territory Members defined for resources (required by FSL validation rules)

## Installation

### Deploy to your org

```bash
# Clone the repository
git clone https://github.com/rafnobrega/sa-reassignment-mobile.git
cd sa-reassignment-mobile

# Authenticate to your target org
sf org login web --set-default --alias myorg

# Deploy all metadata
sf project deploy start --target-org myorg

# Run tests to verify
sf force apex test run -n SAReassignmentControllerTest -u myorg -w 5 -r human -c
```

### What gets deployed

| Component | Type | Description |
|-----------|------|-------------|
| `SAReassignmentController` | Apex Class | Controller with crew lookup and reassignment logic |
| `SAReassignmentControllerTest` | Apex Test Class | 7 test methods, 82%+ coverage |
| `saReassignment` | LWC Bundle | HTML, JS, CSS, and meta XML |
| `Minimum_Crew_Size__c` | Custom Field | Number field on ServiceAppointment for crew size warnings |

## Setup

### 1. Add to Service Appointment Record Page

1. Navigate to a Service Appointment record
2. Open **Setup > Edit Page** (App Builder)
3. Find **SA Reassignment** in the custom components panel
4. Drag it onto the record page layout
5. Save and activate

The component is also available as a **Screen Action** (`lightning__RecordAction`) — you can add it as a quick action on the ServiceAppointment object.

### 2. Configure the Custom Field

The `Minimum_Crew_Size__c` field on ServiceAppointment controls warning behavior for non-crew users:

| Value | Behavior |
|-------|----------|
| `> 1` | Amber warning: "This job may require a crew-based assignment." User must check a bypass box to proceed. |
| `1`, `null`, or blank | Info notice: "No crew requirement detected." User can proceed directly. |

Set this field on your Service Appointments to control the warning threshold. Default value is `1`.

### 3. Field-Level Security

Ensure the `Minimum_Crew_Size__c` field is visible to relevant profiles/permission sets. The Apex controller uses `SYSTEM_MODE` for this specific query to avoid FLS issues, but the field should still be visible in the UI if you want users to edit it.

## Data Model Assumptions

This component relies on standard Salesforce Field Service objects:

| Object | Role | Key Fields Used |
|--------|------|-----------------|
| `ServiceAppointment` | Record page context | `Id`, `Status`, `StatusCategory`, `Minimum_Crew_Size__c` |
| `AssignedResource` | Junction: SA ↔ Resource | `ServiceAppointmentId`, `ServiceResourceId`, `ServiceCrewId` |
| `ServiceResource` | Represents a technician | `RelatedRecordId` (→ User), `IsActive`, `ResourceType` |
| `ServiceCrew` | A crew/team | `Name` |
| `ServiceCrewMember` | Junction: Crew ↔ Resource | `ServiceCrewId`, `ServiceResourceId`, `StartDate`, `EndDate`, `IsLeader` |

## Component States

| State | Description |
|-------|-------------|
| **Loading** | Spinner while fetching context from Apex |
| **Terminal Status** | Red locked banner — SA is Completed/Canceled/Cannot Complete, reassignment blocked |
| **No Resource** | Error: logged-in user has no active ServiceResource |
| **Crew Mode** | User belongs to a crew — shows selectable crew member cards |
| **Non-Crew Mode** | User doesn't belong to a crew — shows warning + all active technicians |
| **Success** | Reassignment completed — shows confirmation and fires record refresh |
| **Error** | Toast notification with the error message from Apex |

## Security

- All SOQL queries use `WITH USER_MODE` except the `Minimum_Crew_Size__c` query (uses `SYSTEM_MODE` due to FLS considerations on new custom fields)
- All DML operations use `as user` for CRUD/FLS enforcement
- The Apex controller uses `with sharing` to respect org sharing rules
- Input validation prevents null parameters and same-resource reassignment
- Terminal status check blocks reassignment before any DML, preventing FSL managed trigger errors

## Test Coverage

The test class `SAReassignmentControllerTest` includes 7 test methods:

| Test | What it validates |
|------|-------------------|
| `testGetReassignmentContext_withCrew` | Crew detection, eligible members, crew size, leader flag |
| `testGetReassignmentContext_invalidSA` | Error handling for non-existent Service Appointment |
| `testReassignAppointment_success` | Full reassignment flow with crew context |
| `testReassignAppointment_sameResource` | Prevents reassignment to currently assigned tech |
| `testReassignAppointment_nullInputs` | Input validation for null parameters |
| `testReassignAppointment_withoutCrew` | Reassignment without crew context (no ServiceCrewId) |
| `setupTestData` | Creates full test fixture: Users, ServiceResources, ServiceTerritoryMembers, ServiceCrew, ServiceCrewMembers, WorkOrder, ServiceAppointments, AssignedResource |

## File Structure

```
force-app/main/default/
├── classes/
│   ├── SAReassignmentController.cls
│   ├── SAReassignmentController.cls-meta.xml
│   ├── SAReassignmentControllerTest.cls
│   └── SAReassignmentControllerTest.cls-meta.xml
├── lwc/
│   └── saReassignment/
│       ├── saReassignment.html
│       ├── saReassignment.js
│       ├── saReassignment.css
│       └── saReassignment.js-meta.xml
└── objects/
    └── ServiceAppointment/
        └── fields/
            └── Minimum_Crew_Size__c.field-meta.xml
```

## API Version

All metadata targets Salesforce API version **62.0** (Spring '25).

## License

MIT
