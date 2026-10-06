@IsTest
private class BookingReconciliationJobTest {
    // Los registros de Custom Metadata no se pueden insertar: se construyen en memoria
    private static Booking_Platform_Account__mdt account(String name, String platform) {
        return (Booking_Platform_Account__mdt) JSON.deserialize(
            JSON.serialize(
                new Map<String, Object>{
                    'DeveloperName' => name,
                    'Platform__c' => platform,
                    'Public_Key__c' => 'PUB-' + name,
                    'Secret_Key__c' => 'secret',
                    'Active__c' => true
                }
            ),
            Booking_Platform_Account__mdt.class
        );
    }

    /** Simula la API paginada de Regiondo y comprueba la firma de cada petición. */
    private class RegiondoMock implements HttpCalloutMock {
        final Integer total;
        final Integer status;
        Integer calls = 0;

        RegiondoMock(Integer total, Integer status) {
            this.total = total;
            this.status = status;
        }

        public HttpResponse respond(HttpRequest req) {
            calls++;
            Assert.isTrue(req.getEndpoint().startsWith(RegiondoPlatform.BASE_URL));
            Assert.isNotNull(req.getHeader('X-API-HASH'));
            Assert.areEqual(64, req.getHeader('X-API-HASH').length(), 'HMAC-SHA256 en hex');

            Integer page = Integer.valueOf(req.getEndpoint().substringAfter('&page=').substringBefore('&'));
            List<Object> rows = new List<Object>();
            Integer startIdx = (page - 1) * RegiondoPlatform.PAGE_SIZE;
            for (Integer i = startIdx; i < Math.min(total, startIdx + RegiondoPlatform.PAGE_SIZE); i++) {
                rows.add(new Map<String, Object>{ 'order_number' => 'ORD-' + i });
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(JSON.serialize(new Map<String, Object>{ 'data' => rows }));
            return res;
        }
    }

    @TestSetup
    static void setup() {
        // 300 pedidos en la plataforma; en Salesforce faltan ORD-7 y ORD-299
        List<Booking__c> bookings = new List<Booking__c>();
        for (Integer i = 0; i < 300; i++) {
            if (i == 7 || i == 299) {
                continue;
            }
            bookings.add(new Booking__c(Platform_Reference__c = 'ORD-' + i, Integration_Platform__c = 'Regiondo'));
        }
        // Misma referencia en otra plataforma: no debe contar
        bookings.add(new Booking__c(Platform_Reference__c = 'ORD-7', Integration_Platform__c = 'Otra'));
        insert bookings;
    }

    @IsTest
    static void detectsMissingBookingsAcrossPages() {
        RegiondoMock mock = new RegiondoMock(300, 200);
        Test.setMock(HttpCalloutMock.class, mock);
        BookingReconciliationJob.accountsOverride = new List<Booking_Platform_Account__mdt>{
            account('Main', 'Regiondo')
        };

        Test.startTest();
        System.enqueueJob(new BookingReconciliationJob(null, Date.today().addDays(-1)));
        Test.stopTest();

        Reconciliation_Run__c run = [
            SELECT
                Status__c,
                Platform_Count__c,
                Salesforce_Count__c,
                Missing_Count__c,
                Missing_References__c,
                Account_Name__c
            FROM Reconciliation_Run__c
        ];
        Assert.areEqual(2, mock.calls, '300 pedidos = 2 páginas de 250');
        Assert.areEqual('Missing', run.Status__c);
        Assert.areEqual(300, run.Platform_Count__c.intValue());
        Assert.areEqual(298, run.Salesforce_Count__c.intValue());
        Assert.areEqual(2, run.Missing_Count__c.intValue());
        Assert.areEqual('ORD-299\nORD-7', run.Missing_References__c);
        Assert.areEqual('Main', run.Account_Name__c);
    }

    @IsTest
    static void allPresentIsOk() {
        Test.setMock(HttpCalloutMock.class, new RegiondoMock(5, 200));

        Test.startTest();
        Reconciliation_Run__c run = BookingReconciliationJob.reconcile(
            account('Main', 'Regiondo'),
            Date.today().addDays(-1)
        );
        Test.stopTest();

        Assert.areEqual('OK', run.Status__c);
        Assert.areEqual(0, run.Missing_Count__c.intValue());
    }

    @IsTest
    static void apiErrorIsRecorded() {
        Test.setMock(HttpCalloutMock.class, new RegiondoMock(5, 401));

        Test.startTest();
        Reconciliation_Run__c run = BookingReconciliationJob.reconcile(
            account('Main', 'Regiondo'),
            Date.today().addDays(-1)
        );
        Test.stopTest();

        Assert.areEqual('Error', run.Status__c);
        Assert.isTrue(run.Error__c.contains('401'));
    }

    @IsTest
    static void unknownPlatformIsRecordedAsError() {
        Reconciliation_Run__c run = BookingReconciliationJob.reconcile(account('X', 'NoExiste'), Date.today());
        Assert.areEqual('Error', run.Status__c);
    }

    @IsTest
    static void schedulableEnqueuesJob() {
        BookingReconciliationJob.accountsOverride = new List<Booking_Platform_Account__mdt>();
        Test.startTest();
        String jobId = System.schedule('Conciliación test', '0 0 6 * * ?', new BookingReconciliationJob());
        Test.stopTest();
        Assert.isNotNull(jobId);
    }
}
