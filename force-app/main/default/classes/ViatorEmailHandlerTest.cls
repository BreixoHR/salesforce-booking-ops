@IsTest
private class ViatorEmailHandlerTest {
    private static final String EN_BODY =
        'New Booking ' +
        'Booking Reference: BR-123456789 ' +
        'Tour Name: Guided Tour of the Old Town ' +
        'Travel Date: Thu, Oct 15, 2026 ' +
        'Lead Traveler Name: Ana García ' +
        'Traveler Names: Ana García, Luis Pérez, Sofía Pérez ' +
        'Travelers: 2 Adults, 1 Child ' +
        'Product Code: 12345P6 ' +
        'Tour Grade Code: TG1~10:30 ' +
        'Phone: +34 600 000 000 Send the customer a message ' +
        'Net Rate: EUR €1.234,50';

    private static final String ES_BODY =
        '<p>Nueva reserva</p><p>Referencia de la reserva: BR-987654321</p>' +
        '<p>Nombre del Tour: Visita guiada al casco antiguo</p>' +
        '<p>Fecha del viaje: jue., 15 oct. 2026</p>' +
        '<p>Nombre del viajero principal: Marta Ruiz</p>' +
        '<p>Nombres de los viajeros: Marta Ruiz, Pablo Ruiz</p>' +
        '<p>Viajeros: 1 Adulto, 1 Niño</p>' +
        '<p>Código del producto: 12345P6</p>' +
        '<p>Código de la categoría del tour: TG1~09:00</p>' +
        '<p>Teléfono: +34 611 111 111 Envíe un mensaje al cliente</p>';

    private static Messaging.InboundEmail email(String subject, String plain, String html) {
        Messaging.InboundEmail e = new Messaging.InboundEmail();
        e.subject = subject;
        e.plainTextBody = plain;
        e.htmlBody = html;
        return e;
    }

    private static Messaging.InboundEmailResult receive(Messaging.InboundEmail e) {
        ViatorEmailHandler.mappingsOverride = new List<Product_Mapping__mdt>{
            (Product_Mapping__mdt) JSON.deserialize(
                JSON.serialize(
                    new Map<String, Object>{
                        'Platform__c' => 'VIATOR',
                        'External_Product_Id__c' => '12345P6',
                        'Product_Code__c' => 'OLDTOWN'
                    }
                ),
                Product_Mapping__mdt.class
            )
        };
        return new ViatorEmailHandler().handleInboundEmail(e, new Messaging.InboundEnvelope());
    }

    @TestSetup
    static void setup() {
        insert new Product2(Name = 'Old town', ProductCode = 'OLDTOWN');
    }

    @IsTest
    static void parsesEnglishEmail() {
        ViatorEmailParser.Parsed p = ViatorEmailParser.parse('New Booking', EN_BODY);
        Assert.areEqual('BR-123456789', p.reference);
        Assert.areEqual('Confirmed', p.status);
        Assert.areEqual('12345P6', p.productCode);
        Assert.areEqual('Ana García', p.leadTraveler);
        Assert.areEqual(3, p.travelerNames.size());
        Assert.areEqual(2, p.adults);
        Assert.areEqual(1, p.children);
        Assert.areEqual(Datetime.newInstance(2026, 10, 15, 10, 30, 0), p.startDateTime);
        Assert.areEqual(1234.50, p.netRate);
        Assert.areEqual('+34 600 000 000', p.phone);
        Assert.isTrue(p.warnings.isEmpty(), String.valueOf(p.warnings));
    }

    @IsTest
    static void parsesSpanishHtmlEmail() {
        // La versión anterior no reconocía meses en español y leía los nombres desde la etiqueta del viajero principal
        ViatorEmailParser.Parsed p = ViatorEmailParser.parse('Solicitud de reserva', ES_BODY);
        Assert.areEqual('BR-987654321', p.reference);
        Assert.areEqual('Pending', p.status);
        Assert.areEqual(Datetime.newInstance(2026, 10, 15, 9, 0, 0), p.startDateTime);
        Assert.areEqual(new List<String>{ 'Marta Ruiz', 'Pablo Ruiz' }, p.travelerNames);
        Assert.areEqual(1, p.adults);
        Assert.areEqual(1, p.children);
        Assert.isNull(p.netRate, 'sin tarifa: null, no 0');
        Assert.isTrue(p.warnings[0].contains('Tarifa'));
    }

    @IsTest
    static void amountsInBothFormats() {
        Assert.areEqual(1234.50, ViatorEmailParser.parseAmount('1.234,50'));
        Assert.areEqual(1234.50, ViatorEmailParser.parseAmount('1,234.50'));
        Assert.areEqual(45, ViatorEmailParser.parseAmount('45,00'));
        Assert.isNull(ViatorEmailParser.parseAmount(''));
    }

    @IsTest
    static void createsBookingAndTicketsIdempotently() {
        Test.startTest();
        receive(email('New Booking', EN_BODY, null));
        receive(email('New Booking', EN_BODY, null)); // reenvío
        Test.stopTest();

        Booking__c b = [
            SELECT
                Status__c,
                Integration_Platform__c,
                Attendees__c,
                Start_Date_Time__c,
                Contact_Name__c,
                Product__r.ProductCode
            FROM Booking__c
        ];
        Assert.areEqual('Confirmed', b.Status__c);
        Assert.areEqual('VIATOR', b.Integration_Platform__c);
        Assert.areEqual(3, b.Attendees__c.intValue());
        Assert.areEqual('OLDTOWN', b.Product__r.ProductCode);
        Assert.areEqual(3, [SELECT COUNT() FROM Ticket__c], 'una entrada por viajero, sin duplicar en el reenvío');
        Assert.areEqual(2, [SELECT COUNT() FROM Webhook_Event__c WHERE Result__c = 'Applied']);
    }

    @IsTest
    static void requestThenConfirmationUpdatesSameBooking() {
        receive(email('Solicitud de reserva', ES_BODY, null));
        Assert.areEqual('Pending', [SELECT Status__c FROM Booking__c].Status__c);
        receive(email('Nueva reserva', ES_BODY, null));
        Assert.areEqual(1, [SELECT COUNT() FROM Booking__c]);
        Assert.areEqual('Confirmed', [SELECT Status__c FROM Booking__c].Status__c);
    }

    @IsTest
    static void nonBookingEmailsAreLoggedNotLost() {
        Messaging.InboundEmailResult r = receive(email('Newsletter', 'Hola, novedades de la plataforma', null));
        Assert.isTrue(r.success);
        Assert.areEqual(0, [SELECT COUNT() FROM Booking__c]);
        Webhook_Event__c e = [SELECT Result__c, Detail__c, Payload__c FROM Webhook_Event__c];
        Assert.areEqual('Error', e.Result__c);
        Assert.isTrue(e.Payload__c.contains('novedades'), 'se guarda el contenido para reprocesar');
    }

    @IsTest
    static void unmappedProductIsAWarning() {
        receive(email('New Booking', EN_BODY.replace('12345P6', '99999X1'), null));
        Assert.isNull([SELECT Product__c FROM Booking__c].Product__c);
        Webhook_Event__c e = [SELECT Result__c, Detail__c FROM Webhook_Event__c];
        Assert.areEqual('Warning', e.Result__c);
        Assert.isTrue(e.Detail__c.contains('99999X1'));
    }
}
