/**
 * Turnos de atención en el punto de encuentro (tótem de bienvenida + panel del personal).
 *
 *  - El cliente teclea su número de reserva en el tótem y elige el servicio: recibe un turno
 *    por área y día ("G-014").
 *  - El personal pulsa "Llamar siguiente" en su área y se llama al turno en espera más antiguo.
 *
 * La numeración y la llamada se hacen bloqueando el contador del área con FOR UPDATE: dos tótems
 * (o dos agentes) a la vez nunca obtienen el mismo número ni llaman al mismo cliente.
 */
public with sharing class ServiceQueueService {
    public static final String WAITING = 'Waiting';
    public static final String CALLED = 'Called';

    public class QueueException extends Exception {
    }

    public class TicketView {
        @AuraEnabled
        public Id ticketId;
        @AuraEnabled
        public String code;
        @AuraEnabled
        public String area;
        @AuraEnabled
        public String bookingName;
        @AuraEnabled
        public Integer waitingAhead;
    }

    /** Tótem: genera (o recupera) el turno de una reserva para un área. */
    @AuraEnabled
    public static TicketView checkIn(String bookingName, String area) {
        if (String.isBlank(bookingName) || String.isBlank(area)) {
            throw new QueueException('Indica el número de reserva y el servicio');
        }
        List<Booking__c> bookings = [SELECT Id, Name FROM Booking__c WHERE Name = :bookingName.trim() LIMIT 1];
        if (bookings.isEmpty()) {
            throw new QueueException('No encontramos la reserva ' + bookingName.trim());
        }
        Date today = Date.today();

        // Pulsar dos veces en el tótem no genera dos turnos
        List<Service_Queue_Ticket__c> existing = [
            SELECT Id, Code__c, Area__c, Number__c
            FROM Service_Queue_Ticket__c
            WHERE Booking__c = :bookings[0].Id AND Area__c = :area AND Service_Date__c = :today AND Status__c = :WAITING
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return view(existing[0], bookings[0].Name);
        }

        Service_Queue_Counter__c counter = lockCounter(area, today);
        counter.Last_Number__c += 1;
        update counter;

        Service_Queue_Ticket__c ticket = new Service_Queue_Ticket__c(
            Booking__c = bookings[0].Id,
            Area__c = area,
            Service_Date__c = today,
            Number__c = counter.Last_Number__c,
            Code__c = area + '-' + String.valueOf(counter.Last_Number__c.intValue()).leftPad(3, '0'),
            Status__c = WAITING
        );
        insert ticket;
        return view(ticket, bookings[0].Name);
    }

    /** Panel del personal: llama al siguiente turno del área (o null si no hay nadie esperando). */
    @AuraEnabled
    public static TicketView callNext(String area) {
        Date today = Date.today();
        lockCounter(area, today); // serializa las llamadas del área

        List<Service_Queue_Ticket__c> next = [
            SELECT Id, Code__c, Area__c, Number__c, Booking__r.Name
            FROM Service_Queue_Ticket__c
            WHERE Area__c = :area AND Service_Date__c = :today AND Status__c = :WAITING
            ORDER BY Number__c
            LIMIT 1
        ];
        if (next.isEmpty()) {
            return null;
        }
        Service_Queue_Ticket__c t = next[0];
        t.Status__c = CALLED;
        t.Called_At__c = System.now();
        t.Called_By__c = UserInfo.getUserId();
        update t;

        Service_Queue_Counter__c counter = lockCounter(area, today);
        counter.Now_Serving__c = t.Code__c;
        update counter;
        return view(t, t.Booking__r.Name);
    }

    /** Pantalla de llamadas: último turno llamado por área. */
    @AuraEnabled(cacheable=false)
    public static Map<String, String> nowServing() {
        Map<String, String> result = new Map<String, String>();
        for (Service_Queue_Counter__c c : [
            SELECT Area__c, Now_Serving__c
            FROM Service_Queue_Counter__c
            WHERE Service_Date__c = :Date.today()
        ]) {
            result.put(c.Area__c, c.Now_Serving__c);
        }
        return result;
    }

    private static Service_Queue_Counter__c lockCounter(String area, Date day) {
        String key = area + '|' + String.valueOf(day);
        List<Service_Queue_Counter__c> counters = [
            SELECT Id, Area__c, Last_Number__c, Now_Serving__c
            FROM Service_Queue_Counter__c
            WHERE Key__c = :key
            LIMIT 1
            FOR UPDATE
        ];
        if (!counters.isEmpty()) {
            return counters[0];
        }
        // Primer turno del día en el área. Key__c es único: si otra transacción lo crea a la vez,
        // el insert falla y se relee el contador ya existente.
        Service_Queue_Counter__c c = new Service_Queue_Counter__c(
            Key__c = key,
            Area__c = area,
            Service_Date__c = day,
            Last_Number__c = 0
        );
        try {
            insert c;
            return c;
        } catch (DmlException e) {
            return [
                SELECT Id, Area__c, Last_Number__c, Now_Serving__c
                FROM Service_Queue_Counter__c
                WHERE Key__c = :key
                LIMIT 1
                FOR UPDATE
            ];
        }
    }

    private static TicketView view(Service_Queue_Ticket__c t, String bookingName) {
        TicketView v = new TicketView();
        v.ticketId = t.Id;
        v.code = t.Code__c;
        v.area = t.Area__c;
        v.bookingName = bookingName;
        v.waitingAhead = [
            SELECT COUNT()
            FROM Service_Queue_Ticket__c
            WHERE
                Area__c = :t.Area__c
                AND Service_Date__c = :Date.today()
                AND Status__c = :WAITING
                AND Number__c < :t.Number__c
        ];
        return v;
    }
}
