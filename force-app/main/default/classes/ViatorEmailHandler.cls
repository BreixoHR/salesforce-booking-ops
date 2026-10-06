/**
 * Email Service: cada email de reserva de Viator se convierte en un Booking__c.
 *
 * - Idempotente: upsert por localizador. Un reenvío o una confirmación posterior a la solicitud
 *   actualizan la misma reserva en lugar de duplicarla.
 * - Nunca se pierde un email: si no se puede procesar, queda registrado en Webhook_Event__c
 *   con el motivo y el contenido, para reprocesarlo.
 * - Producto por Product_Mapping__mdt (plataforma "VIATOR"). Si no hay mapeo, la reserva se crea
 *   igualmente y queda como aviso.
 */
public with sharing class ViatorEmailHandler implements Messaging.InboundEmailHandler {
    public static final String PLATFORM = 'VIATOR';

    @TestVisible
    private static List<Product_Mapping__mdt> mappingsOverride;

    public Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email,
        Messaging.InboundEnvelope env
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        String body = String.isNotBlank(email.plainTextBody) ? email.plainTextBody : email.htmlBody;
        Webhook_Event__c log = new Webhook_Event__c(
            Platform__c = PLATFORM,
            Event_Type__c = ('email: ' + (email.subject == null ? '' : email.subject)).left(80),
            Payload__c = body == null ? null : body.left(131072)
        );

        Savepoint sp = Database.setSavepoint();
        try {
            ViatorEmailParser.Parsed p = ViatorEmailParser.parse(email.subject, body);
            if (String.isBlank(p.reference)) {
                log.Result__c = 'Error';
                log.Detail__c = 'Email sin localizador de reserva: no parece una reserva de Viator';
                insert log;
                result.success = true; // no rebotar al remitente: queda registrado para revisión
                return result;
            }

            List<Booking__c> existing = [
                SELECT Id
                FROM Booking__c
                WHERE Platform_Reference__c = :p.reference
                LIMIT 1
                FOR UPDATE
            ];
            Id productId = mapProduct(p.productCode);
            Booking__c b = new Booking__c(
                Platform_Reference__c = p.reference,
                Integration_Platform__c = PLATFORM,
                Status__c = p.status,
                Start_Date_Time__c = p.startDateTime,
                Visit_Date__c = p.startDateTime == null ? null : p.startDateTime.date(),
                Attendees__c = p.adults + p.children + p.infants,
                Contact_Name__c = p.leadTraveler,
                Contact_Phone__c = p.phone,
                Product__c = productId
            );
            upsert b Platform_Reference__c;

            // Una entrada por viajero, solo al crear (los reenvíos no duplican tickets)
            if (existing.isEmpty() && !p.travelerNames.isEmpty()) {
                List<Ticket__c> tickets = new List<Ticket__c>();
                for (String name : p.travelerNames) {
                    tickets.add(new Ticket__c(Name = (p.reference + ' · ' + name).left(80), Booking__c = b.Id));
                }
                insert tickets;
            }

            List<String> warnings = p.warnings.clone();
            if (productId == null) {
                warnings.add('Producto sin mapear: ' + p.productCode);
            }
            log.Booking__c = b.Id;
            log.Result__c = warnings.isEmpty() ? 'Applied' : 'Warning';
            log.Detail__c = String.join(warnings, '\n');
            insert log;
            result.success = true;
        } catch (Exception e) {
            Database.rollback(sp);
            log.Result__c = 'Error';
            log.Detail__c = (e.getTypeName() + ': ' + e.getMessage()).left(4000);
            insert log;
            result.success = true;
        }
        return result;
    }

    private static Id mapProduct(String productCode) {
        if (String.isBlank(productCode)) {
            return null;
        }
        List<Product_Mapping__mdt> all = mappingsOverride != null
            ? mappingsOverride
            : Product_Mapping__mdt.getAll().values();
        for (Product_Mapping__mdt m : all) {
            if (m.Platform__c == PLATFORM && m.External_Product_Id__c == productCode) {
                List<Product2> p = [SELECT Id FROM Product2 WHERE ProductCode = :m.Product_Code__c LIMIT 1];
                return p.isEmpty() ? null : p[0].Id;
            }
        }
        return null;
    }
}
