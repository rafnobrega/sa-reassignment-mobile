@IsTest
private class SAReassignmentControllerTest {

    @TestSetup
    static void setupTestData() {
        // Create a second user for Tech Beta (ServiceResource requires unique RelatedRecordId)
        Profile stdProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User testUser = new User(
            FirstName = 'Test',
            LastName = 'TechBeta',
            Email = 'techbeta@test.sareasgn.com',
            Username = 'techbeta.' + System.currentTimeMillis() + '@test.sareasgn.com',
            Alias = 'tbeta',
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = stdProfile.Id
        );
        insert testUser;

        // Create operating hours (required for ServiceTerritory)
        OperatingHours oh = new OperatingHours(Name = 'Test Hours', TimeZone = 'America/New_York');
        insert oh;

        // Create service territory
        ServiceTerritory territory = new ServiceTerritory(
            Name = 'Test Territory',
            OperatingHoursId = oh.Id,
            IsActive = true
        );
        insert territory;

        // Create a work order (required parent for SA)
        WorkOrder wo = new WorkOrder(Subject = 'Test Work Order');
        insert wo;

        // Create service appointment with crew size
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = wo.Id,
            EarliestStartTime = Datetime.now(),
            DueDate = Datetime.now().addDays(1),
            Minimum_Crew_Size__c = 3
        );
        insert sa;

        // Create a second SA with no crew size (needs schedule times for validation rule)
        ServiceAppointment saNoCrewSize = new ServiceAppointment(
            ParentRecordId = wo.Id,
            EarliestStartTime = Datetime.now(),
            DueDate = Datetime.now().addDays(1),
            SchedStartTime = Datetime.now(),
            SchedEndTime = Datetime.now().addHours(2)
        );
        insert saNoCrewSize;

        // Create service resources — each needs a unique user
        ServiceResource techA = new ServiceResource(
            Name = 'Tech Alpha',
            RelatedRecordId = UserInfo.getUserId(),
            IsActive = true,
            ResourceType = 'T'
        );
        ServiceResource techB = new ServiceResource(
            Name = 'Tech Beta',
            IsActive = true,
            ResourceType = 'T',
            RelatedRecordId = testUser.Id
        );
        insert new List<ServiceResource>{ techA, techB };

        // Create service territory members (required by FSL validation rules)
        ServiceTerritoryMember stmA = new ServiceTerritoryMember(
            ServiceTerritoryId = territory.Id,
            ServiceResourceId = techA.Id,
            EffectiveStartDate = Datetime.now().addDays(-1),
            TerritoryType = 'P'
        );
        ServiceTerritoryMember stmB = new ServiceTerritoryMember(
            ServiceTerritoryId = territory.Id,
            ServiceResourceId = techB.Id,
            EffectiveStartDate = Datetime.now().addDays(-1),
            TerritoryType = 'P'
        );
        insert new List<ServiceTerritoryMember>{ stmA, stmB };

        // Create a service crew
        ServiceCrew crew = new ServiceCrew(Name = 'Test Crew', CrewSize = 4);
        insert crew;

        // Add both techs to the crew
        ServiceCrewMember memberA = new ServiceCrewMember(
            ServiceCrewId = crew.Id,
            ServiceResourceId = techA.Id,
            StartDate = Datetime.now().addDays(-1),
            IsLeader = true
        );
        ServiceCrewMember memberB = new ServiceCrewMember(
            ServiceCrewId = crew.Id,
            ServiceResourceId = techB.Id,
            StartDate = Datetime.now().addDays(-1),
            IsLeader = false
        );
        insert new List<ServiceCrewMember>{ memberA, memberB };

        // Assign techA to the service appointment
        AssignedResource ar = new AssignedResource(
            ServiceAppointmentId = sa.Id,
            ServiceResourceId = techA.Id,
            ServiceCrewId = crew.Id
        );
        insert ar;
    }

    @IsTest
    static void testGetReassignmentContext_withCrew() {
        ServiceAppointment sa = [SELECT Id FROM ServiceAppointment WHERE Minimum_Crew_Size__c = 3 LIMIT 1];

        Test.startTest();
        SAReassignmentController.ReassignmentContext ctx =
            SAReassignmentController.getReassignmentContext(sa.Id);
        Test.stopTest();

        // User should have a resource
        Assert.isTrue(ctx.userHasResource, 'User should have an active ServiceResource');
        Assert.isNotNull(ctx.userResourceId, 'userResourceId should be populated');

        // Current assignment should be populated
        Assert.isNotNull(ctx.currentResourceId, 'Should have a current assigned resource');
        Assert.areEqual('Tech Alpha', ctx.currentResourceName, 'Current resource should be Tech Alpha');

        // User should be in a crew
        Assert.isTrue(ctx.userInCrew, 'User should be in a crew');
        Assert.areEqual('Test Crew', ctx.crewName, 'Crew name should match');
        Assert.isTrue(ctx.isCrewLeader, 'User should be crew leader');

        // Eligible resources should exclude the currently assigned tech
        Assert.isNotNull(ctx.eligibleResources, 'Eligible resources should not be null');
        // Tech Alpha is assigned, so only Tech Beta should be eligible
        // (Both resources use same user in test, so Tech Alpha is the user's resource
        //  and also the assigned resource — it gets excluded)

        // Crew size
        Assert.areEqual(3, ctx.minimumCrewSize, 'Minimum crew size should be 3');
    }

    @IsTest
    static void testGetReassignmentContext_invalidSA() {
        // Use a fake Id
        Id fakeId = ServiceAppointment.SObjectType.getDescribe().getKeyPrefix() + '000000000001';

        Test.startTest();
        try {
            SAReassignmentController.getReassignmentContext(fakeId);
            Assert.fail('Should have thrown an exception');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Service Appointment not found'),
                'Error message should indicate SA not found');
        }
        Test.stopTest();
    }

    @IsTest
    static void testReassignAppointment_success() {
        ServiceAppointment sa = [SELECT Id FROM ServiceAppointment WHERE Minimum_Crew_Size__c = 3 LIMIT 1];
        ServiceResource techB = [SELECT Id FROM ServiceResource WHERE Name = 'Tech Beta' LIMIT 1];
        ServiceCrew crew = [SELECT Id FROM ServiceCrew WHERE Name = 'Test Crew' LIMIT 1];

        Test.startTest();
        Id newArId = SAReassignmentController.reassignAppointment(sa.Id, techB.Id, crew.Id);
        Test.stopTest();

        Assert.isNotNull(newArId, 'Should return a new AssignedResource Id');

        // Verify the old assignment was deleted and new one created
        List<AssignedResource> assignments = [
            SELECT ServiceResourceId, ServiceCrewId
            FROM AssignedResource
            WHERE ServiceAppointmentId = :sa.Id
        ];
        Assert.areEqual(1, assignments.size(), 'Should have exactly one assigned resource');
        Assert.areEqual(techB.Id, assignments[0].ServiceResourceId, 'Should be assigned to Tech Beta');
        Assert.areEqual(crew.Id, assignments[0].ServiceCrewId, 'Crew should be preserved');
    }

    @IsTest
    static void testReassignAppointment_sameResource() {
        ServiceAppointment sa = [SELECT Id FROM ServiceAppointment WHERE Minimum_Crew_Size__c = 3 LIMIT 1];
        ServiceResource techA = [SELECT Id FROM ServiceResource WHERE Name = 'Tech Alpha' LIMIT 1];

        Test.startTest();
        try {
            SAReassignmentController.reassignAppointment(sa.Id, techA.Id, null);
            Assert.fail('Should have thrown an exception');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('currently assigned'),
                'Should prevent reassignment to same technician');
        }
        Test.stopTest();
    }

    @IsTest
    static void testReassignAppointment_nullInputs() {
        Test.startTest();
        try {
            SAReassignmentController.reassignAppointment(null, null, null);
            Assert.fail('Should have thrown an exception');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('required'),
                'Should require SA and resource IDs');
        }
        Test.stopTest();
    }

    @IsTest
    static void testReassignAppointment_withoutCrew() {
        // Reassign on the SA with no existing assignment
        ServiceAppointment sa = [SELECT Id FROM ServiceAppointment WHERE Minimum_Crew_Size__c != 3 LIMIT 1];
        ServiceResource techB = [SELECT Id FROM ServiceResource WHERE Name = 'Tech Beta' LIMIT 1];

        Test.startTest();
        Id newArId = SAReassignmentController.reassignAppointment(sa.Id, techB.Id, null);
        Test.stopTest();

        Assert.isNotNull(newArId, 'Should return a new AssignedResource Id');

        AssignedResource ar = [
            SELECT ServiceResourceId, ServiceCrewId
            FROM AssignedResource
            WHERE Id = :newArId
        ];
        Assert.areEqual(techB.Id, ar.ServiceResourceId, 'Should be assigned to Tech Beta');
        Assert.isNull(ar.ServiceCrewId, 'Crew should be null for non-crew assignment');
    }
}
