@IsTest
private class ServiceQueueServiceTest {
    @TestSetup
    static void setup() {
        insert new List<Booking__c>{
            new Booking__c(Platform_Reference__c = 'Q1'),
            new Booking__c(Platform_Reference__c = 'Q2'),
            new Booking__c(Platform_Reference__c = 'Q3')
        };
    }

    private static String name(String ref) {
        return [SELECT Name FROM Booking__c WHERE Platform_Reference__c = :ref].Name;
    }

    @IsTest
    static void checkInNumbersPerAreaAndIsIdempotent() {
        Test.startTest();
        ServiceQueueService.TicketView a1 = ServiceQueueService.checkIn(name('Q1'), 'G');
        ServiceQueueService.TicketView a2 = ServiceQueueService.checkIn(name('Q2'), 'G');
        ServiceQueueService.TicketView again = ServiceQueueService.checkIn(name('Q1'), 'G');
        ServiceQueueService.TicketView d1 = ServiceQueueService.checkIn(name('Q3'), 'D');
        Test.stopTest();

        Assert.areEqual('G-001', a1.code);
        Assert.areEqual('G-002', a2.code);
        Assert.areEqual(1, a2.waitingAhead);
        Assert.areEqual(a1.ticketId, again.ticketId, 'pulsar dos veces no genera otro turno');
        Assert.areEqual('D-001', d1.code, 'cada área numera por separado');
        Assert.areEqual(3, [SELECT COUNT() FROM Service_Queue_Ticket__c]);
    }

    @IsTest
    static void callNextServesInOrderPerArea() {
        ServiceQueueService.checkIn(name('Q1'), 'G');
        ServiceQueueService.checkIn(name('Q2'), 'G');
        ServiceQueueService.checkIn(name('Q3'), 'D');

        Test.startTest();
        ServiceQueueService.TicketView first = ServiceQueueService.callNext('G');
        ServiceQueueService.TicketView second = ServiceQueueService.callNext('G');
        ServiceQueueService.TicketView none = ServiceQueueService.callNext('G');
        Test.stopTest();

        Assert.areEqual('G-001', first.code);
        Assert.areEqual(name('Q1'), first.bookingName);
        Assert.areEqual('G-002', second.code);
        Assert.isNull(none, 'cola vacía');
        Assert.areEqual('G-002', ServiceQueueService.nowServing().get('G'));
        Assert.isNull(ServiceQueueService.nowServing().get('D'), 'D aún no ha llamado a nadie');

        Service_Queue_Ticket__c t = [
            SELECT Status__c, Called_At__c, Called_By__c
            FROM Service_Queue_Ticket__c
            WHERE Code__c = 'G-001'
        ];
        Assert.areEqual(ServiceQueueService.CALLED, t.Status__c);
        Assert.isNotNull(t.Called_At__c);
        Assert.areEqual(UserInfo.getUserId(), t.Called_By__c);
    }

    @IsTest
    static void unknownBookingOrMissingData() {
        try {
            ServiceQueueService.checkIn('NO-EXISTE', 'G');
            Assert.fail('debería fallar');
        } catch (ServiceQueueService.QueueException e) {
            Assert.isTrue(e.getMessage().contains('NO-EXISTE'));
        }
        try {
            ServiceQueueService.checkIn('', 'G');
            Assert.fail('debería fallar');
        } catch (ServiceQueueService.QueueException e) {
            Assert.isTrue(e.getMessage().contains('Indica'));
        }
    }
}
