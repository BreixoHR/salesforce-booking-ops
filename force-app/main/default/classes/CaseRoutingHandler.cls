/**
 * Lógica de Case:
 *
 *  1. Enrutado (before insert/update): las incidencias que llegan a la cola genérica se mueven a
 *     la cola del producto que tiene reservado el cliente (buscado por su email). Las reglas
 *     producto → cola están en Case_Routing_Rule__mdt, sin IDs en el código.
 *
 *  2. Reseñas (after insert): los casos marcados como reseña (Is_Review__c) cuyo asunto es el nombre de una reserva
 *     generan un Review__c enlazado a la reserva y al producto.
 *
 * Totalmente bulkificado: 1 consulta de colas, 1 de reglas y 1 de reservas por transacción,
 * independientemente del número de casos o de colas.
 */
public with sharing class CaseRoutingHandler {
    @TestVisible
    private static List<Case_Routing_Rule__mdt> rulesOverride;

    public static void beforeInsertOrUpdate(List<Case> cases) {
        Map<String, Id> queueIds = loadQueueIds();
        Id genericQueue = queueIds.get(genericQueueName());
        if (genericQueue == null) {
            return;
        }

        Set<String> emails = new Set<String>();
        for (Case c : cases) {
            if (c.OwnerId == genericQueue && String.isNotBlank(c.SuppliedEmail)) {
                emails.add(c.SuppliedEmail.toLowerCase());
            }
        }
        if (emails.isEmpty()) {
            return;
        }

        // La reserva más reciente de cada cliente decide la cola
        Map<String, String> subfamilyByEmail = new Map<String, String>();
        for (Booking__c b : [
            SELECT Contact_Email__c, Product_Subfamily__c
            FROM Booking__c
            WHERE Contact_Email__c IN :emails AND Product_Subfamily__c != NULL
            ORDER BY CreatedDate DESC
        ]) {
            String key = b.Contact_Email__c.toLowerCase();
            if (!subfamilyByEmail.containsKey(key)) {
                subfamilyByEmail.put(key, b.Product_Subfamily__c);
            }
        }

        Map<String, String> queueBySubfamily = new Map<String, String>();
        for (Case_Routing_Rule__mdt rule : rules()) {
            queueBySubfamily.put(rule.Product_Subfamily__c, rule.Queue_Developer_Name__c);
        }

        for (Case c : cases) {
            if (c.OwnerId != genericQueue || String.isBlank(c.SuppliedEmail)) {
                continue;
            }
            String subfamily = subfamilyByEmail.get(c.SuppliedEmail.toLowerCase());
            Id target = subfamily == null ? null : queueIds.get(queueBySubfamily.get(subfamily));
            if (target != null) {
                c.OwnerId = target; // before trigger: se modifica el registro, sin DML
            }
        }
    }

    public static void afterInsert(List<Case> cases) {
        Set<String> bookingNames = new Set<String>();
        for (Case c : cases) {
            if (c.Is_Review__c && String.isNotBlank(c.Subject)) {
                bookingNames.add(c.Subject.trim());
            }
        }
        if (bookingNames.isEmpty()) {
            return;
        }

        Map<String, Booking__c> bookingByName = new Map<String, Booking__c>();
        for (Booking__c b : [SELECT Id, Name, Product__c FROM Booking__c WHERE Name IN :bookingNames]) {
            bookingByName.put(b.Name, b);
        }

        List<Review__c> reviews = new List<Review__c>();
        List<Case> caseUpdates = new List<Case>();
        for (Case c : cases) {
            Booking__c booking = c.Is_Review__c && c.Subject != null ? bookingByName.get(c.Subject.trim()) : null;
            if (booking == null) {
                continue;
            }
            reviews.add(
                new Review__c(
                    Booking__c = booking.Id,
                    Product__c = booking.Product__c,
                    Case__c = c.Id,
                    Comment__c = c.Description,
                    Guide_Score__c = c.Guide_Score__c,
                    Activity_Score__c = c.Activity_Score__c,
                    Published__c = false
                )
            );
            caseUpdates.add(new Case(Id = c.Id, Booking__c = booking.Id));
        }
        insert reviews;
        update caseUpdates;
    }

    private static Map<String, Id> loadQueueIds() {
        Set<String> names = new Set<String>{ genericQueueName() };
        for (Case_Routing_Rule__mdt rule : rules()) {
            names.add(rule.Queue_Developer_Name__c);
        }
        Map<String, Id> ids = new Map<String, Id>();
        for (Group g : [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND DeveloperName IN :names]) {
            ids.put(g.DeveloperName, g.Id);
        }
        return ids;
    }

    @TestVisible
    private static String genericQueueName() {
        return 'Urgent_Incidents';
    }

    private static List<Case_Routing_Rule__mdt> rules() {
        if (rulesOverride != null) {
            return rulesOverride;
        }
        return [
            SELECT Product_Subfamily__c, Queue_Developer_Name__c
            FROM Case_Routing_Rule__mdt
            WHERE Active__c = TRUE
        ];
    }
}
