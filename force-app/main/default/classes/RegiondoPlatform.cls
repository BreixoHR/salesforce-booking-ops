/**
 * Cliente de la API de proveedores de Regiondo (GET /v1/supplier/bookings).
 *
 * Autenticación: HMAC-SHA256 de (timestamp + publicKey + querystring) con la clave secreta,
 * enviada en X-API-HASH junto con X-API-TIME y X-API-ID.
 * Las claves se leen de Booking_Platform_Account__mdt, nunca del código.
 */
public with sharing class RegiondoPlatform implements BookingPlatform {
    @TestVisible
    private static final String BASE_URL = 'https://api.regiondo.com/v1/supplier/bookings';
    @TestVisible
    private static final Integer PAGE_SIZE = 250;
    private static final Integer MAX_PAGES = 30;

    public class PlatformException extends Exception {
    }

    public Set<String> listOrderReferences(Booking_Platform_Account__mdt account, Date day) {
        Set<String> references = new Set<String>();
        String isoDay = DateTime.newInstanceGmt(day, Time.newInstance(0, 0, 0, 0)).formatGmt('yyyy-MM-dd');

        for (Integer page = 1; page <= MAX_PAGES; page++) {
            String query =
                'date_range_by=date_bought' +
                '&date_range=' +
                EncodingUtil.urlEncode(isoDay + ',' + isoDay, 'UTF-8') +
                '&page=' +
                page +
                '&limit=' +
                PAGE_SIZE;

            HttpResponse res = new Http().send(signedRequest(account, query));
            if (res.getStatusCode() != 200) {
                throw new PlatformException(
                    'Regiondo HTTP ' + res.getStatusCode() + ' (' + account.DeveloperName + ')'
                );
            }

            List<Object> rows = extractRows(res.getBody());
            for (Object row : rows) {
                Object ref = ((Map<String, Object>) row).get('order_number');
                if (ref != null && String.isNotBlank(String.valueOf(ref))) {
                    references.add(String.valueOf(ref).trim());
                }
            }
            if (rows.size() < PAGE_SIZE) {
                break;
            }
        }
        return references;
    }

    @TestVisible
    private static HttpRequest signedRequest(Booking_Platform_Account__mdt account, String query) {
        String timestamp = String.valueOf(DateTime.now().getTime() / 1000);
        Blob mac = Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(timestamp + account.Public_Key__c + query),
            Blob.valueOf(account.Secret_Key__c)
        );

        HttpRequest req = new HttpRequest();
        req.setEndpoint(BASE_URL + '?' + query);
        req.setMethod('GET');
        req.setTimeout(60000);
        req.setHeader('Accept', 'application/json');
        req.setHeader('Accept-Language', 'en-US');
        req.setHeader('X-API-ID', account.Public_Key__c);
        req.setHeader('X-API-TIME', timestamp);
        req.setHeader('X-API-HASH', EncodingUtil.convertToHex(mac));
        return req;
    }

    private static List<Object> extractRows(String body) {
        Object parsed = JSON.deserializeUntyped(body);
        if (parsed instanceof Map<String, Object>) {
            Object data = ((Map<String, Object>) parsed).get('data');
            return data instanceof List<Object> ? (List<Object>) data : new List<Object>();
        }
        return parsed instanceof List<Object> ? (List<Object>) parsed : new List<Object>();
    }
}
