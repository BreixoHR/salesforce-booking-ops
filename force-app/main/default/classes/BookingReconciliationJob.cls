/**
 * Conciliación diaria: ¿todas las ventas de ayer en la plataforma han llegado a Salesforce?
 *
 * Detecta reservas perdidas por fallos de webhooks o integraciones antes de que el cliente
 * se presente sin entrada. Una ejecución por cuenta de plataforma (cada una con sus propios
 * límites de callouts), encadenadas; cada resultado queda en un Reconciliation_Run__c.
 *
 * Programación (cada día a las 06:00):
 *   System.schedule('Conciliación de reservas', '0 0 6 * * ?', new BookingReconciliationJob());
 */
public with sharing class BookingReconciliationJob implements Schedulable, Queueable, Database.AllowsCallouts {
    @TestVisible
    private static Map<String, BookingPlatform> platforms = new Map<String, BookingPlatform>{
        'Regiondo' => new RegiondoPlatform()
    };
    @TestVisible
    private static List<Booking_Platform_Account__mdt> accountsOverride;

    private final List<Booking_Platform_Account__mdt> pending;
    private final Date day;

    public BookingReconciliationJob() {
        this(null, Date.today().addDays(-1));
    }

    public BookingReconciliationJob(List<Booking_Platform_Account__mdt> pending, Date day) {
        this.pending = pending;
        this.day = day;
    }

    public void execute(SchedulableContext context) {
        System.enqueueJob(new BookingReconciliationJob(activeAccounts(), day));
    }

    public void execute(QueueableContext context) {
        List<Booking_Platform_Account__mdt> queue = pending == null ? activeAccounts() : pending;
        if (queue.isEmpty()) {
            return;
        }
        Booking_Platform_Account__mdt account = queue.remove(0);
        insert reconcile(account, day);

        if (!queue.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new BookingReconciliationJob(queue, day));
        }
    }

    @TestVisible
    private static Reconciliation_Run__c reconcile(Booking_Platform_Account__mdt account, Date day) {
        Reconciliation_Run__c run = new Reconciliation_Run__c(
            Account_Name__c = account.DeveloperName,
            Platform__c = account.Platform__c,
            Sales_Date__c = day
        );
        try {
            BookingPlatform platform = platforms.get(account.Platform__c);
            if (platform == null) {
                throw new RegiondoPlatform.PlatformException('Plataforma sin implementar: ' + account.Platform__c);
            }
            Set<String> remote = platform.listOrderReferences(account, day);
            Set<String> local = salesforceReferences(account, remote);

            Set<String> missing = new Set<String>(remote);
            missing.removeAll(local);
            List<String> sortedMissing = new List<String>(missing);
            sortedMissing.sort();

            run.Platform_Count__c = remote.size();
            run.Salesforce_Count__c = local.size();
            run.Missing_Count__c = missing.size();
            run.Missing_References__c = String.join(sortedMissing, '\n').left(131072);
            run.Status__c = missing.isEmpty() ? 'OK' : 'Missing';
        } catch (Exception e) {
            run.Status__c = 'Error';
            run.Error__c = e.getMessage().left(255);
        }
        return run;
    }

    /**
     * Se busca por referencia (no por fecha de creación): una venta de ayer puede haber
     * entrado hoy por un reintento del webhook y no debe contar como perdida.
     */
    private static Set<String> salesforceReferences(Booking_Platform_Account__mdt account, Set<String> remote) {
        Set<String> found = new Set<String>();
        if (remote.isEmpty()) {
            return found;
        }
        for (Booking__c b : [
            SELECT Platform_Reference__c
            FROM Booking__c
            WHERE Integration_Platform__c = :account.Platform__c AND Platform_Reference__c IN :remote
        ]) {
            found.add(b.Platform_Reference__c);
        }
        return found;
    }

    private static List<Booking_Platform_Account__mdt> activeAccounts() {
        if (accountsOverride != null) {
            return accountsOverride.clone();
        }
        return [
            SELECT DeveloperName, Platform__c, Public_Key__c, Secret_Key__c
            FROM Booking_Platform_Account__mdt
            WHERE Active__c = TRUE
            ORDER BY DeveloperName
        ];
    }
}
