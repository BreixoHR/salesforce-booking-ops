@IsTest
private class OctoBookingWebhookTest {
    private static final String SECRET = 'webhook-secret';

    private static Product_Mapping__mdt mapping(String productId, String optionId, String code) {
        return (Product_Mapping__mdt) JSON.deserialize(
            JSON.serialize(
                new Map<String, Object>{
                    'Platform__c' => 'OCTO',
                    'External_Product_Id__c' => productId,
                    'External_Option_Id__c' => optionId,
                    'Product_Code__c' => code
                }
            ),
            Product_Mapping__mdt.class
        );
    }

    @TestSetup
    static void setup() {
        insert new List<Product2>{
            new Product2(Name = 'Entrada general', ProductCode = 'GENERAL'),
            new Product2(Name = 'Entrada con guía', ProductCode = 'GUIDED')
        };
    }

    private static Integer post(String secret, String body) {
        OctoBookingWebhook.secretHashOverride = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(SECRET))
        );
        OctoBookingWebhook.mappingsOverride = new List<Product_Mapping__mdt>{
            mapping('prod-1', null, 'GENERAL'),
            mapping('prod-1', 'guided', 'GUIDED')
        };
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/octo/bookings';
        req.httpMethod = 'POST';
        if (secret != null) {
            req.addHeader('X-Webhook-Secret', secret);
        }
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        OctoBookingWebhook.receive();
        return RestContext.response.statusCode;
    }

    private static String event(String type, String ts, String status, String optionId) {
        return JSON.serialize(
            new Map<String, Object>{
                'eventType' => type,
                'timestamp' => ts,
                'booking' => new Map<String, Object>{
                    'uuid' => 'a1b2c3d4-0000-4000-8000-000000000001',
                    'supplierReference' => 'SUP-77',
                    'status' => status,
                    'productId' => 'prod-1',
                    'optionId' => optionId,
                    'utcConfirmedAt' => '2026-03-20T10:30:00Z',
                    'availability' => new Map<String, Object>{ 'localDateTimeStart' => '2026-04-02T09:30:00Z' },
                    'contact' => new Map<String, Object>{
                        'fullName' => 'Ana García',
                        'emailAddress' => 'ana@example.com',
                        'phoneNumber' => '+34600000000'
                    },
                    'voucher' => new Map<String, Object>{ 'pdfUrl' => 'https://vouchers.example/abc.pdf' },
                    'unitItems' => new List<Object>{
                        new Map<String, Object>{ 'unitId' => 'adult' },
                        new Map<String, Object>{ 'unitId' => 'adult' },
                        new Map<String, Object>{ 'unitId' => 'child' }
                    }
                }
            }
        );
    }

    private static Booking__c booking() {
        return [
            SELECT
                Status__c,
                Integration_Platform__c,
                Supplier_Reference__c,
                Attendees__c,
                Start_Date_Time__c,
                Visit_Date__c,
                Contact_Name__c,
                Contact_Email__c,
                Contact_Phone__c,
                Voucher_Url__c,
                Product__r.ProductCode,
                Last_Event_At__c
            FROM Booking__c
        ];
    }

    @IsTest
    static void confirmedEventCreatesBookingWithIsoDates() {
        Test.startTest();
        Integer status = post(SECRET, event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', 'DEFAULT'));
        Test.stopTest();

        Assert.areEqual(200, status);
        Booking__c b = booking();
        Assert.areEqual('Confirmed', b.Status__c);
        Assert.areEqual('OCTO', b.Integration_Platform__c);
        Assert.areEqual('SUP-77', b.Supplier_Reference__c);
        Assert.areEqual(3, b.Attendees__c.intValue());
        Assert.areEqual(Datetime.newInstanceGmt(2026, 4, 2, 9, 30, 0), b.Start_Date_Time__c);
        Assert.areEqual(Date.newInstance(2026, 4, 2), b.Visit_Date__c);
        Assert.areEqual('ana@example.com', b.Contact_Email__c);
        Assert.areEqual('https://vouchers.example/abc.pdf', b.Voucher_Url__c);
        Assert.areEqual('GENERAL', b.Product__r.ProductCode, 'opción sin regla propia → regla genérica del producto');
        Assert.areEqual('Applied', [SELECT Result__c FROM Webhook_Event__c].Result__c);
    }

    @IsTest
    static void optionSpecificMappingWins() {
        post(SECRET, event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', 'guided'));
        Assert.areEqual('GUIDED', booking().Product__r.ProductCode);
    }

    @IsTest
    static void repeatedEventIsIdempotent() {
        post(SECRET, event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', 'DEFAULT'));
        post(SECRET, event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', 'DEFAULT'));
        Assert.areEqual(1, [SELECT COUNT() FROM Booking__c]);
        Assert.areEqual(2, [SELECT COUNT() FROM Webhook_Event__c]);
    }

    @IsTest
    static void cancellationUpdatesTheBooking() {
        post(SECRET, event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', 'DEFAULT'));
        post(SECRET, event('booking.cancelled', '2026-03-21T08:00:00Z', 'CANCELLED', 'DEFAULT'));
        Assert.areEqual('Cancelled', booking().Status__c);
    }

    @IsTest
    static void outOfOrderOlderEventIsIgnored() {
        post(SECRET, event('booking.cancelled', '2026-03-21T08:00:00Z', 'CANCELLED', 'DEFAULT'));
        // Llega tarde el "confirmed" (anterior): no debe resucitar la reserva cancelada
        Integer status = post(SECRET, event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', 'DEFAULT'));

        Assert.areEqual(200, status);
        Assert.areEqual('Cancelled', booking().Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Webhook_Event__c WHERE Result__c = 'Ignored']);
    }

    @IsTest
    static void wrongOrMissingSecretIsRejected() {
        Assert.areEqual(401, post('otro', event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', null)));
        Assert.areEqual(401, post(null, event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', null)));
        Assert.areEqual(0, [SELECT COUNT() FROM Booking__c]);
        Assert.areEqual(2, [SELECT COUNT() FROM Webhook_Event__c WHERE Result__c = 'Rejected']);
    }

    @IsTest
    static void malformedOrUnknownInput() {
        Assert.areEqual(400, post(SECRET, 'no es json'));
        Assert.areEqual(400, post(SECRET, event('booking.confirmed', '2026-03-20T10:30:00Z', 'RARO', null)));
        Assert.areEqual(200, post(SECRET, event('availability.updated', '2026-03-20T10:30:00Z', 'CONFIRMED', null)));
        Assert.areEqual(0, [SELECT COUNT() FROM Booking__c]);
        Assert.areEqual(1, [SELECT COUNT() FROM Webhook_Event__c WHERE Result__c = 'Ignored']);
    }

    @IsTest
    static void unmappedProductIsSavedWithWarning() {
        String body = event('booking.confirmed', '2026-03-20T10:30:00Z', 'CONFIRMED', null)
            .replace('prod-1', 'prod-nuevo');
        Assert.areEqual(200, post(SECRET, body));
        Assert.isNull(booking().Product__r);
        Webhook_Event__c e = [SELECT Result__c, Detail__c FROM Webhook_Event__c];
        Assert.areEqual('Warning', e.Result__c);
        Assert.isTrue(e.Detail__c.contains('prod-nuevo'));
    }
}
