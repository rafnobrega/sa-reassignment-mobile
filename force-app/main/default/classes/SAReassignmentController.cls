/**
 * Controller for the saReassignment LWC.
 * Provides crew-aware context and reassignment logic for Service Appointments.
 */
public with sharing class SAReassignmentController {

    /**
     * Returns everything the LWC needs to render:
     * current assignee, logged-in user's crew status, eligible reassignment targets,
     * and crew size warnings.
     */
    @AuraEnabled(cacheable=true)
    public static ReassignmentContext getReassignmentContext(Id serviceAppointmentId) {
        ReassignmentContext ctx = new ReassignmentContext();

        // 1. Get the Service Appointment details (crew size for warnings)
        // SYSTEM_MODE needed here: Minimum_Crew_Size__c may not have FLS for all profiles
        List<ServiceAppointment> saList = [
            SELECT Id, AppointmentNumber, Minimum_Crew_Size__c, Status, StatusCategory
            FROM ServiceAppointment
            WHERE Id = :serviceAppointmentId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (saList.isEmpty()) {
            AuraHandledException e = new AuraHandledException('Service Appointment not found.');
            e.setMessage('Service Appointment not found.');
            throw e;
        }
        ServiceAppointment sa = saList[0];
        ctx.minimumCrewSize = sa.Minimum_Crew_Size__c != null
            ? Integer.valueOf(sa.Minimum_Crew_Size__c) : null;
        ctx.saStatus = sa.Status;
        ctx.saStatusCategory = sa.StatusCategory;

        // Block reassignment on terminal statuses (FSL triggers will reject the DML)
        Set<String> terminalCategories = new Set<String>{ 'Completed', 'Canceled', 'CannotComplete' };
        if (terminalCategories.contains(sa.StatusCategory)) {
            ctx.isTerminalStatus = true;
            return ctx;
        }

        // 2. Get current assigned resource(s)
        List<AssignedResource> currentAssignments = [
            SELECT Id, ServiceResourceId, ServiceResource.Name, ServiceCrewId
            FROM AssignedResource
            WHERE ServiceAppointmentId = :serviceAppointmentId
            WITH USER_MODE
        ];
        if (!currentAssignments.isEmpty()) {
            AssignedResource primary = currentAssignments[0];
            ctx.currentResourceId = primary.ServiceResourceId;
            ctx.currentResourceName = primary.ServiceResource.Name;
            ctx.currentAssignedResourceId = primary.Id;
            ctx.currentCrewId = primary.ServiceCrewId;
        }

        // 3. Get logged-in user's Service Resource
        Id currentUserId = UserInfo.getUserId();
        List<ServiceResource> userResources = [
            SELECT Id, Name, IsActive
            FROM ServiceResource
            WHERE RelatedRecordId = :currentUserId AND IsActive = true
            WITH USER_MODE
            LIMIT 1
        ];
        if (userResources.isEmpty()) {
            ctx.userHasResource = false;
            return ctx;
        }
        ctx.userHasResource = true;
        ctx.userResourceId = userResources[0].Id;
        ctx.userResourceName = userResources[0].Name;

        // 4. Check if user belongs to a crew (active membership)
        Datetime now = Datetime.now();
        List<ServiceCrewMember> userCrewMemberships = [
            SELECT Id, ServiceCrewId, ServiceCrew.Name, IsLeader
            FROM ServiceCrewMember
            WHERE ServiceResourceId = :ctx.userResourceId
                AND StartDate <= :now
                AND (EndDate = null OR EndDate >= :now)
            WITH USER_MODE
            LIMIT 1
        ];

        if (!userCrewMemberships.isEmpty()) {
            // User is in a crew
            ctx.userInCrew = true;
            ctx.crewId = userCrewMemberships[0].ServiceCrewId;
            ctx.crewName = userCrewMemberships[0].ServiceCrew.Name;
            ctx.isCrewLeader = userCrewMemberships[0].IsLeader;

            // 5. Get eligible crew members (exclude currently assigned resource)
            Set<Id> excludeIds = new Set<Id>();
            if (ctx.currentResourceId != null) {
                excludeIds.add(ctx.currentResourceId);
            }

            List<ServiceCrewMember> crewMembers = [
                SELECT Id, ServiceResourceId, ServiceResource.Name, IsLeader
                FROM ServiceCrewMember
                WHERE ServiceCrewId = :ctx.crewId
                    AND ServiceResourceId NOT IN :excludeIds
                    AND ServiceResource.IsActive = true
                    AND StartDate <= :now
                    AND (EndDate = null OR EndDate >= :now)
                WITH USER_MODE
                ORDER BY ServiceResource.Name
            ];

            ctx.eligibleResources = new List<ResourceOption>();
            for (ServiceCrewMember cm : crewMembers) {
                ctx.eligibleResources.add(new ResourceOption(
                    cm.ServiceResourceId,
                    cm.ServiceResource.Name,
                    cm.IsLeader
                ));
            }
        } else {
            // User is NOT in a crew — fetch all active technicians as fallback
            ctx.userInCrew = false;

            Set<Id> excludeIds = new Set<Id>();
            if (ctx.currentResourceId != null) {
                excludeIds.add(ctx.currentResourceId);
            }

            List<ServiceResource> allTechs = [
                SELECT Id, Name
                FROM ServiceResource
                WHERE IsActive = true
                    AND ResourceType = 'T'
                    AND Id NOT IN :excludeIds
                WITH USER_MODE
                ORDER BY Name
                LIMIT 50
            ];

            ctx.eligibleResources = new List<ResourceOption>();
            for (ServiceResource sr : allTechs) {
                ctx.eligibleResources.add(new ResourceOption(
                    sr.Id, sr.Name, false
                ));
            }
        }

        return ctx;
    }

    /**
     * Performs the reassignment: deletes old AssignedResource, creates new one.
     * Returns the new AssignedResource Id on success.
     */
    @AuraEnabled
    public static Id reassignAppointment(Id serviceAppointmentId, Id newResourceId, Id crewId) {
        // Validate inputs
        if (serviceAppointmentId == null || newResourceId == null) {
            AuraHandledException e = new AuraHandledException('Service Appointment and new resource are required.');
            e.setMessage('Service Appointment and new resource are required.');
            throw e;
        }

        // Get existing assignment
        List<AssignedResource> existing = [
            SELECT Id, ServiceResourceId
            FROM AssignedResource
            WHERE ServiceAppointmentId = :serviceAppointmentId
            WITH USER_MODE
            LIMIT 1
        ];

        // Guard: don't reassign to the same person
        if (!existing.isEmpty() && existing[0].ServiceResourceId == newResourceId) {
            AuraHandledException e = new AuraHandledException('Cannot reassign to the currently assigned technician.');
            e.setMessage('Cannot reassign to the currently assigned technician.');
            throw e;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // Delete old assignment
            if (!existing.isEmpty()) {
                delete as user existing;
            }

            // Create new assignment
            AssignedResource newAr = new AssignedResource(
                ServiceAppointmentId = serviceAppointmentId,
                ServiceResourceId = newResourceId
            );
            if (crewId != null) {
                newAr.ServiceCrewId = crewId;
            }
            insert as user newAr;

            return newAr.Id;
        } catch (Exception e) {
            Database.rollback(sp);
            AuraHandledException ahe = new AuraHandledException(e.getMessage());
            ahe.setMessage(e.getMessage());
            throw ahe;
        }
    }

    // ── Wrapper Classes ──

    public class ReassignmentContext {
        @AuraEnabled public Id currentResourceId;
        @AuraEnabled public String currentResourceName;
        @AuraEnabled public Id currentAssignedResourceId;
        @AuraEnabled public Id currentCrewId;

        @AuraEnabled public Boolean userHasResource = false;
        @AuraEnabled public Id userResourceId;
        @AuraEnabled public String userResourceName;

        @AuraEnabled public Boolean userInCrew = false;
        @AuraEnabled public Id crewId;
        @AuraEnabled public String crewName;
        @AuraEnabled public Boolean isCrewLeader = false;

        @AuraEnabled public Integer minimumCrewSize;
        @AuraEnabled public String saStatus;
        @AuraEnabled public String saStatusCategory;
        @AuraEnabled public Boolean isTerminalStatus = false;
        @AuraEnabled public List<ResourceOption> eligibleResources;
    }

    public class ResourceOption {
        @AuraEnabled public Id resourceId;
        @AuraEnabled public String resourceName;
        @AuraEnabled public Boolean isLeader;

        public ResourceOption(Id resourceId, String resourceName, Boolean isLeader) {
            this.resourceId = resourceId;
            this.resourceName = resourceName;
            this.isLeader = isLeader;
        }
    }
}
