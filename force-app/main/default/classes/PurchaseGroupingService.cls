/**
 * Agrupación de compras: reúne las reservas confirmadas de un mismo producto que empiezan dentro
 * de una ventana de N minutos, hasta un máximo de reservas por grupo, para que operaciones compre
 * las entradas en bloque (precio de grupo, un único pedido al proveedor).
 *
 * Las reglas por producto están en Purchase_Grouping_Rule__mdt (código de producto → máximo y
 * ventana). Cuando un grupo se llena pasa a "Full" y aparece en la vista de compras pendientes.
 *
 * Se ejecuta en el before trigger de Booking__c y es bulk-safe: una consulta de grupos abiertos
 * para todo el lote, bloqueados con FOR UPDATE para que dos transacciones simultáneas no llenen
 * el mismo grupo por encima de su máximo.
 */
public with sharing class PurchaseGroupingService {
    public static final String STATUS_CONFIRMED = 'Confirmed';
    public static final String GROUP_OPEN = 'Open';
    public static final String GROUP_FULL = 'Full';
    public static final String GROUP_PURCHASED = 'Purchased';

    @TestVisible
    private static List<Purchase_Grouping_Rule__mdt> rulesOverride;

    public static void beforeInsert(List<Booking__c> bookings) {
        assign(eligible(bookings));
    }

    public static void beforeUpdate(List<Booking__c> bookings, Map<Id, Booking__c> oldMap) {
        List<Booking__c> leaving = new List<Booking__c>();
        List<Booking__c> toRegroup = new List<Booking__c>();

        Set<Id> oldGroupIds = new Set<Id>();
        for (Booking__c b : bookings) {
            if (oldMap.get(b.Id).Purchase_Group__c != null) {
                oldGroupIds.add(oldMap.get(b.Id).Purchase_Group__c);
            }
        }
        Set<Id> purchasedGroups = new Map<Id, Purchase_Group__c>(
                [SELECT Id FROM Purchase_Group__c WHERE Id IN :oldGroupIds AND Status__c = :GROUP_PURCHASED]
            )
            .keySet();

        for (Booking__c b : bookings) {
            Booking__c old = oldMap.get(b.Id);
            Boolean relevantChange =
                b.Status__c != old.Status__c ||
                b.Product__c != old.Product__c ||
                b.Start_Date_Time__c != old.Start_Date_Time__c ||
                b.Attendees__c != old.Attendees__c;
            if (!relevantChange) {
                continue;
            }
            // Una reserva de un grupo ya comprado no se mueve: la entrada existe
            if (purchasedGroups.contains(old.Purchase_Group__c)) {
                continue;
            }
            if (old.Purchase_Group__c != null) {
                leaving.add(old);
                b.Purchase_Group__c = null;
            }
            toRegroup.add(b);
        }
        release(leaving);
        assign(eligible(toRegroup));
    }

    /** Reservas confirmadas, con fecha y con regla para su producto. */
    private static List<Booking__c> eligible(List<Booking__c> bookings) {
        List<Booking__c> result = new List<Booking__c>();
        for (Booking__c b : bookings) {
            if (b.Status__c == STATUS_CONFIRMED && b.Product__c != null && b.Start_Date_Time__c != null) {
                result.add(b);
            }
        }
        return result;
    }

    private static void assign(List<Booking__c> bookings) {
        if (bookings.isEmpty()) {
            return;
        }
        Map<Id, Purchase_Grouping_Rule__mdt> ruleByProduct = rulesFor(bookings);
        if (ruleByProduct.isEmpty()) {
            return;
        }

        Set<Id> productIds = ruleByProduct.keySet();
        Datetime minStart;
        Datetime maxStart;
        Integer maxWindow = 0;
        List<Booking__c> toAssign = new List<Booking__c>();
        for (Booking__c b : bookings) {
            if (!ruleByProduct.containsKey(b.Product__c)) {
                continue;
            }
            toAssign.add(b);
            minStart = minStart == null || b.Start_Date_Time__c < minStart ? b.Start_Date_Time__c : minStart;
            maxStart = maxStart == null || b.Start_Date_Time__c > maxStart ? b.Start_Date_Time__c : maxStart;
            maxWindow = Math.max(maxWindow, ruleByProduct.get(b.Product__c).Window_Minutes__c.intValue());
        }
        if (toAssign.isEmpty()) {
            return;
        }

        // Grupos abiertos que podrían admitir alguna reserva del lote (bloqueados hasta el commit)
        Map<Id, List<Purchase_Group__c>> openByProduct = new Map<Id, List<Purchase_Group__c>>();
        for (Purchase_Group__c g : [
            SELECT
                Id,
                Product__c,
                Window_Start__c,
                Window_End__c,
                Max_Bookings__c,
                Booking_Count__c,
                Total_Attendees__c,
                Status__c
            FROM Purchase_Group__c
            WHERE
                Product__c IN :productIds
                AND Status__c = :GROUP_OPEN
                AND Window_Start__c <= :maxStart
                AND Window_End__c >= :minStart
            ORDER BY Window_Start__c
            FOR UPDATE
        ]) {
            if (!openByProduct.containsKey(g.Product__c)) {
                openByProduct.put(g.Product__c, new List<Purchase_Group__c>());
            }
            openByProduct.get(g.Product__c).add(g);
        }

        // Las reservas más tempranas abren grupo: así la ventana se ancla al primer pase
        toAssign.sort(new ByStart());

        List<Purchase_Group__c> created = new List<Purchase_Group__c>();
        // Listas paralelas: un Map con claves sObject cambia de hash si cambian sus campos
        List<Booking__c> pendingBookings = new List<Booking__c>();
        List<Purchase_Group__c> pendingGroups = new List<Purchase_Group__c>();
        Map<Id, Purchase_Group__c> touched = new Map<Id, Purchase_Group__c>();

        for (Booking__c b : toAssign) {
            Purchase_Grouping_Rule__mdt rule = ruleByProduct.get(b.Product__c);
            if (!openByProduct.containsKey(b.Product__c)) {
                openByProduct.put(b.Product__c, new List<Purchase_Group__c>());
            }
            Purchase_Group__c target;
            for (Purchase_Group__c g : openByProduct.get(b.Product__c)) {
                if (
                    g.Status__c == GROUP_OPEN &&
                    b.Start_Date_Time__c >= g.Window_Start__c &&
                    b.Start_Date_Time__c <= g.Window_End__c &&
                    g.Booking_Count__c < g.Max_Bookings__c
                ) {
                    target = g;
                    break;
                }
            }
            if (target == null) {
                target = new Purchase_Group__c(
                    Product__c = b.Product__c,
                    Window_Start__c = b.Start_Date_Time__c,
                    Window_End__c = b.Start_Date_Time__c.addMinutes(rule.Window_Minutes__c.intValue()),
                    Max_Bookings__c = rule.Max_Bookings__c,
                    Booking_Count__c = 0,
                    Total_Attendees__c = 0,
                    Status__c = GROUP_OPEN
                );
                created.add(target);
                openByProduct.get(b.Product__c).add(target);
            }
            target.Booking_Count__c += 1;
            target.Total_Attendees__c += b.Attendees__c == null ? 0 : b.Attendees__c;
            if (target.Booking_Count__c >= target.Max_Bookings__c) {
                target.Status__c = GROUP_FULL;
            }
            if (target.Id == null) {
                pendingBookings.add(b);
                pendingGroups.add(target);
            } else {
                b.Purchase_Group__c = target.Id;
                touched.put(target.Id, target);
            }
        }

        insert created;
        for (Integer i = 0; i < pendingBookings.size(); i++) {
            pendingBookings[i].Purchase_Group__c = pendingGroups[i].Id;
        }
        update touched.values();
    }

    /** Las reservas que salen de un grupo liberan su plaza (y lo reabren si estaba lleno). */
    private static void release(List<Booking__c> oldBookings) {
        if (oldBookings.isEmpty()) {
            return;
        }
        Map<Id, Integer> countByGroup = new Map<Id, Integer>();
        Map<Id, Decimal> paxByGroup = new Map<Id, Decimal>();
        for (Booking__c old : oldBookings) {
            Id g = old.Purchase_Group__c;
            countByGroup.put(g, (countByGroup.containsKey(g) ? countByGroup.get(g) : 0) + 1);
            paxByGroup.put(
                g,
                (paxByGroup.containsKey(g) ? paxByGroup.get(g) : 0) + (old.Attendees__c == null ? 0 : old.Attendees__c)
            );
        }
        List<Purchase_Group__c> groups = [
            SELECT Id, Booking_Count__c, Total_Attendees__c, Status__c
            FROM Purchase_Group__c
            WHERE Id IN :countByGroup.keySet() AND Status__c != :GROUP_PURCHASED
            FOR UPDATE
        ];
        for (Purchase_Group__c g : groups) {
            g.Booking_Count__c = Math.max((Decimal) 0, g.Booking_Count__c - countByGroup.get(g.Id));
            g.Total_Attendees__c = Math.max((Decimal) 0, g.Total_Attendees__c - paxByGroup.get(g.Id));
            g.Status__c = GROUP_OPEN;
        }
        update groups;
    }

    private static Map<Id, Purchase_Grouping_Rule__mdt> rulesFor(List<Booking__c> bookings) {
        Set<Id> productIds = new Set<Id>();
        for (Booking__c b : bookings) {
            productIds.add(b.Product__c);
        }
        Map<String, Purchase_Grouping_Rule__mdt> ruleByCode = new Map<String, Purchase_Grouping_Rule__mdt>();
        List<Purchase_Grouping_Rule__mdt> rules = rulesOverride != null
            ? rulesOverride
            : [
                  SELECT Product_Code__c, Max_Bookings__c, Window_Minutes__c
                  FROM Purchase_Grouping_Rule__mdt
                  WHERE Active__c = TRUE
              ];
        for (Purchase_Grouping_Rule__mdt r : rules) {
            ruleByCode.put(r.Product_Code__c, r);
        }
        Map<Id, Purchase_Grouping_Rule__mdt> result = new Map<Id, Purchase_Grouping_Rule__mdt>();
        for (Product2 p : [
            SELECT Id, ProductCode
            FROM Product2
            WHERE Id IN :productIds AND ProductCode IN :ruleByCode.keySet()
        ]) {
            result.put(p.Id, ruleByCode.get(p.ProductCode));
        }
        return result;
    }

    /** Exportación CSV de un grupo para el pedido al proveedor (localizador, titular, asistentes, hora). */
    public static String toCsv(Id groupId) {
        List<String> lines = new List<String>{ 'Localizador,Titular,Asistentes,Inicio' };
        for (Booking__c b : [
            SELECT Platform_Reference__c, Contact_Name__c, Attendees__c, Start_Date_Time__c
            FROM Booking__c
            WHERE Purchase_Group__c = :groupId
            ORDER BY Start_Date_Time__c, Platform_Reference__c
        ]) {
            lines.add(
                String.join(
                    new List<String>{
                        csv(b.Platform_Reference__c),
                        csv(b.Contact_Name__c),
                        String.valueOf(b.Attendees__c == null ? 0 : b.Attendees__c.intValue()),
                        b.Start_Date_Time__c == null ? '' : b.Start_Date_Time__c.format('yyyy-MM-dd HH:mm')
                    },
                    ','
                )
            );
        }
        return String.join(lines, '\n');
    }

    private static String csv(String value) {
        String v = value == null ? '' : value;
        // Evita inyección de fórmulas al abrir el CSV en Excel
        if (v.length() > 0 && '=+-@'.contains(v.left(1))) {
            v = '\'' + v;
        }
        return v.containsAny(',"\n') ? '"' + v.replace('"', '""') + '"' : v;
    }

    private class ByStart implements Comparator<Booking__c> {
        public Integer compare(Booking__c a, Booking__c b) {
            return a.Start_Date_Time__c == b.Start_Date_Time__c
                ? 0
                : (a.Start_Date_Time__c < b.Start_Date_Time__c ? -1 : 1);
        }
    }
}
