trigger BookingTrigger on Booking__c(before insert, before update) {
    if (Trigger.isInsert) {
        PurchaseGroupingService.beforeInsert(Trigger.new);
    } else {
        PurchaseGroupingService.beforeUpdate(Trigger.new, Trigger.oldMap);
    }
}
