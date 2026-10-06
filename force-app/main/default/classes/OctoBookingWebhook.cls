/**
 * Webhook de reservas en formato OCTO (estándar abierto de la industria de actividades y entradas,
 * usado por Ventrata, Bókun y otros). La plataforma envía cada alta, cambio o cancelación y
 * Salesforce solo tiene que mapearla a Booking__c.
 *
 *   POST /services/apexrest/octo/bookings
 *   X-Webhook-Secret: <secreto compartido>     (se guarda solo su SHA-256)
 *   { "eventType": "booking.confirmed", "timestamp": "2026-03-20T10:30:00Z", "booking": { ...OCTO Booking... } }
 *
 * - Idempotente: upsert por uuid de la reserva (Platform_Reference__c).
 * - Eventos fuera de orden: si llega uno más antiguo que el último aplicado, se ignora.
 * - Fechas ISO 8601 deserializadas por el parser JSON (DateTime.valueOfGmt no admite "T…Z").
 * - Cada evento queda en Webhook_Event__c (resultado, motivo, payload) para auditoría y reproceso.
 */
@RestResource(urlMapping='/octo/bookings')
global without sharing class OctoBookingWebhook {
    public static final String PLATFORM = 'OCTO';

    @TestVisible
    private static String secretHashOverride;
    @TestVisible
    private static List<Product_Mapping__mdt> mappingsOverride;

    // ---- Modelo OCTO (solo los campos que se usan) ----
    public class Payload {
        public String eventType;
        public Datetime timestamp;
        public OctoBooking booking;
    }
    public class OctoBooking {
        public String uuid;
        public String supplierReference;
        public String resellerReference;
        public String status; // ON_HOLD, CONFIRMED, CANCELLED, EXPIRED, REDEEMED
        public String productId;
        public String optionId;
        public Datetime utcConfirmedAt;
        public Availability availability;
        public OctoContact contact;
        public String notes;
        public Voucher voucher;
        public List<UnitItem> unitItems;
    }
    public class Availability {
        public Datetime localDateTimeStart;
    }
    public class OctoContact {
        public String fullName;
        public String emailAddress;
        public String phoneNumber;
    }
    public class Voucher {
        public String pdfUrl;
    }
    public class UnitItem {
        public String unitId;
    }

    @TestVisible
    private static final Map<String, String> STATUS_MAP = new Map<String, String>{
        'CONFIRMED' => 'Confirmed',
        'REDEEMED' => 'Confirmed',
        'ON_HOLD' => 'Pending',
        'PENDING' => 'Pending',
        'CANCELLED' => 'Cancelled',
        'EXPIRED' => 'Cancelled'
    };

    @HttpPost
    global static void receive() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        String raw = req.requestBody == null ? '' : req.requestBody.toString();
        Webhook_Event__c log = new Webhook_Event__c(Platform__c = PLATFORM, Payload__c = raw.left(131072));

        if (!authorized(header(req, 'x-webhook-secret'))) {
            respond(res, 401, 'unauthorized');
            log.Result__c = 'Rejected';
            log.Detail__c = 'Secreto ausente o incorrecto';
            insert log;
            return;
        }

        Payload p;
        try {
            p = (Payload) JSON.deserialize(raw, Payload.class);
        } catch (Exception e) {
            respond(res, 400, 'invalid-json');
            log.Result__c = 'Error';
            log.Detail__c = 'JSON no válido: ' + e.getMessage().left(200);
            insert log;
            return;
        }
        log.Event_Type__c = p == null ? null : p.eventType;

        try {
            String outcome = apply(p, log);
            respond(res, 200, outcome);
        } catch (WebhookException e) {
            respond(res, 400, e.getMessage());
            log.Result__c = 'Error';
            log.Detail__c = e.getMessage();
        }
        insert log;
    }

    public class WebhookException extends Exception {
    }

    @TestVisible
    private static String apply(Payload p, Webhook_Event__c log) {
        if (p == null || p.booking == null || String.isBlank(p.booking.uuid)) {
            throw new WebhookException('booking.uuid obligatorio');
        }
        if (p.eventType == null || !p.eventType.startsWith('booking.')) {
            log.Result__c = 'Ignored';
            log.Detail__c = 'Evento no gestionado: ' + p.eventType;
            return 'ignored';
        }
        OctoBooking ob = p.booking;
        String status = STATUS_MAP.get(ob.status);
        if (p.eventType == 'booking.cancelled') {
            status = 'Cancelled';
        }
        if (status == null) {
            throw new WebhookException('Estado OCTO desconocido: ' + ob.status);
        }
        Datetime eventAt = p.timestamp != null ? p.timestamp : System.now();

        List<Booking__c> existing = [
            SELECT Id, Last_Event_At__c
            FROM Booking__c
            WHERE Platform_Reference__c = :ob.uuid
            LIMIT 1
            FOR UPDATE
        ];
        if (!existing.isEmpty() && existing[0].Last_Event_At__c != null && eventAt < existing[0].Last_Event_At__c) {
            log.Booking__c = existing[0].Id;
            log.Result__c = 'Ignored';
            log.Detail__c =
                'Evento anterior al último aplicado (' +
                existing[0].Last_Event_At__c.formatGmt('yyyy-MM-dd HH:mm:ss') +
                ' UTC)';
            return 'stale';
        }

        Booking__c b = new Booking__c(
            Platform_Reference__c = ob.uuid,
            Integration_Platform__c = PLATFORM,
            Supplier_Reference__c = ob.supplierReference,
            Status__c = status,
            Last_Event_At__c = eventAt,
            Notes__c = ob.notes,
            Attendees__c = ob.unitItems == null ? null : ob.unitItems.size()
        );
        if (ob.availability != null && ob.availability.localDateTimeStart != null) {
            b.Start_Date_Time__c = ob.availability.localDateTimeStart;
            b.Visit_Date__c = ob.availability.localDateTimeStart.dateGmt();
        }
        if (ob.contact != null) {
            b.Contact_Name__c = ob.contact.fullName;
            b.Contact_Email__c = ob.contact.emailAddress;
            b.Contact_Phone__c = ob.contact.phoneNumber;
        }
        if (ob.voucher != null) {
            b.Voucher_Url__c = ob.voucher.pdfUrl;
        }
        Id productId = mapProduct(ob.productId, ob.optionId);
        if (productId != null) {
            b.Product__c = productId;
        }

        upsert b Platform_Reference__c;
        log.Booking__c = b.Id;
        if (productId == null && String.isNotBlank(ob.productId)) {
            log.Result__c = 'Warning';
            log.Detail__c = 'Producto sin mapear: ' + ob.productId + '/' + ob.optionId;
        } else {
            log.Result__c = 'Applied';
        }
        return existing.isEmpty() ? 'created' : 'updated';
    }

    /** Producto OCTO (productId + optionId opcional) → Product2 por código, vía Product_Mapping__mdt. */
    private static Id mapProduct(String productId, String optionId) {
        if (String.isBlank(productId)) {
            return null;
        }
        List<Product_Mapping__mdt> all = mappingsOverride != null
            ? mappingsOverride
            : Product_Mapping__mdt.getAll().values();
        String code;
        for (Product_Mapping__mdt m : all) {
            if (m.Platform__c != PLATFORM || m.External_Product_Id__c != productId) {
                continue;
            }
            // Una regla con opción concreta gana a la genérica del producto
            if (m.External_Option_Id__c == optionId) {
                code = m.Product_Code__c;
                break;
            }
            if (String.isBlank(m.External_Option_Id__c)) {
                code = m.Product_Code__c;
            }
        }
        if (code == null) {
            return null;
        }
        List<Product2> p = [SELECT Id FROM Product2 WHERE ProductCode = :code LIMIT 1];
        return p.isEmpty() ? null : p[0].Id;
    }

    private static Boolean authorized(String secret) {
        String expected = secretHashOverride;
        if (expected == null) {
            Webhook_Setting__mdt s = Webhook_Setting__mdt.getInstance(PLATFORM);
            expected = s == null ? null : s.Secret_Hash__c;
        }
        if (String.isBlank(secret) || String.isBlank(expected)) {
            return false;
        }
        // Se comparan hashes: no se guarda el secreto ni se compara carácter a carácter
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(secret))) ==
            expected.toLowerCase();
    }

    private static String header(RestRequest req, String name) {
        for (String k : req.headers.keySet()) {
            if (k != null && k.equalsIgnoreCase(name)) {
                return req.headers.get(k);
            }
        }
        return null;
    }

    private static void respond(RestResponse res, Integer code, String outcome) {
        res.statusCode = code;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'result' => outcome }));
    }
}
