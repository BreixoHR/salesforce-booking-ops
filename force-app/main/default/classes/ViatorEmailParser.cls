/**
 * Parser de los emails de reserva de Viator (inglés y español). Clase pura: texto → datos,
 * sin SOQL ni DML, para poder probar cada formato.
 *
 * Viator no ofrece webhook a todos los operadores: notifica cada reserva por email
 * ("New booking" / "Nueva reserva", "Booking request" / "Solicitud de reserva").
 */
public with sharing class ViatorEmailParser {
    public class Parsed {
        public String reference;
        public String status; // Confirmed | Pending
        public String productCode;
        public String tourName;
        public Datetime startDateTime;
        public String leadTraveler;
        public String phone;
        public List<String> travelerNames = new List<String>();
        public Integer adults = 0;
        public Integer children = 0;
        public Integer infants = 0;
        public Decimal netRate; // null si el email no lo trae (no se inventa un 0)
        public List<String> warnings = new List<String>();
    }

    // Etiquetas en los dos idiomas en que llegan los emails
    private static final String L_REFERENCE = '(?:Booking Reference|Referencia de la reserva):';
    private static final String L_PRODUCT = '(?:Product Code|Código del producto):';
    private static final String L_TOUR = '(?:Tour Name|Nombre del Tour):';
    private static final String L_DATE = '(?:Travel Date|Fecha del viaje):';
    private static final String L_LEAD = '(?:Lead Traveler Name|Nombre del viajero principal):';
    private static final String L_NAMES = '(?:Traveler Names|Nombres de los viajeros):';
    private static final String L_TRAVELERS = '(?:Travelers|Viajeros):';
    private static final String L_GRADE = '(?:Tour Grade Code|Código de la categoría del tour):';
    private static final String L_PHONE = '(?:Phone|Teléfono):';
    private static final String L_NET = '(?:Net Rate|Tarifa neta):';
    private static final String L_PHONE_END = '(?:Send the customer|Envíe un mensaje al cliente)';

    private static final Map<String, Integer> MONTHS = new Map<String, Integer>{
        'jan' => 1,
        'ene' => 1,
        'feb' => 2,
        'mar' => 3,
        'apr' => 4,
        'abr' => 4,
        'may' => 5,
        'jun' => 6,
        'jul' => 7,
        'aug' => 8,
        'ago' => 8,
        'sep' => 9,
        'set' => 9,
        'oct' => 10,
        'nov' => 11,
        'dec' => 12,
        'dic' => 12
    };

    public static Parsed parse(String subject, String body) {
        String text = normalize(body);
        Parsed p = new Parsed();
        p.reference = find(text, L_REFERENCE + '\\s*([A-Z0-9-]+)');
        p.productCode = find(text, L_PRODUCT + '\\s*(\\S+)');
        p.tourName = find(text, L_TOUR + '\\s*(.+?)\\s*' + L_DATE);
        p.leadTraveler = find(text, L_LEAD + '\\s*(.+?)\\s*(?:' + L_NAMES + '|' + L_TRAVELERS + ')');
        p.phone = find(text, L_PHONE + '\\s*(.+?)\\s*' + L_PHONE_END);

        String names = find(text, L_NAMES + '\\s*(.+?)\\s*' + L_TRAVELERS);
        if (String.isNotBlank(names)) {
            for (String n : names.split(',')) {
                if (String.isNotBlank(n)) {
                    p.travelerNames.add(n.trim());
                }
            }
        }

        countTravelers(find(text, L_TRAVELERS + '\\s*(.+?)\\s*' + L_PRODUCT), p);

        p.startDateTime = parseStart(
            find(text, L_DATE + '\\s*(.+?)\\s*' + L_LEAD),
            find(text, L_GRADE + '\\s*\\S*?~(\\d{1,2}:\\d{2})')
        );
        if (p.startDateTime == null) {
            p.warnings.add('Fecha u hora de la actividad no reconocida');
        }

        String net = find(text, L_NET + '\\s*(?:EUR)?\\s*€?\\s*([\\d.,]+)');
        p.netRate = parseAmount(net);
        if (p.netRate == null) {
            p.warnings.add('Tarifa neta no encontrada');
        }

        String s = subject == null ? '' : subject.toLowerCase();
        p.status = (s.contains('request') ||
            s.contains('solicitud') ||
            s.contains('responda'))
            ? 'Pending'
            : 'Confirmed';
        return p;
    }

    private static String normalize(String body) {
        String t = body == null ? '' : body;
        if (t.contains('<')) {
            t = t.stripHtmlTags();
        }
        return t.replace(' ', ' ').replace('*', '').replace('#', '').replaceAll('\\s+', ' ');
    }

    private static String find(String text, String regex) {
        Matcher m = Pattern.compile('(?i)' + regex).matcher(text);
        return m.find() ? m.group(1).trim() : null;
    }

    private static void countTravelers(String text, Parsed p) {
        if (String.isBlank(text)) {
            return;
        }
        Matcher m = Pattern.compile(
                '(?i)(\\d+)\\s*(adult|adulto|child|children|niño|niños|nino|ninos|infant|bebé|bebe)'
            )
            .matcher(text);
        while (m.find()) {
            Integer n = Integer.valueOf(m.group(1));
            String type = m.group(2).toLowerCase();
            if (type.startsWith('adult')) {
                p.adults += n;
            } else if (type.startsWith('child') || type.startsWith('ni')) {
                p.children += n;
            } else {
                p.infants += n;
            }
        }
    }

    /** "Thu, Oct 15, 2026" · "jue., 15 oct. 2026" · "15 de octubre de 2026" + hora "10:30". */
    @TestVisible
    private static Datetime parseStart(String dateText, String timeText) {
        if (String.isBlank(dateText) || String.isBlank(timeText)) {
            return null;
        }
        String d = dateText.toLowerCase().replace('.', ' ');
        Integer day;
        Integer month;
        Integer year;
        Matcher en = Pattern.compile('([a-z]{3})[a-z]*\\s+(\\d{1,2}),?\\s+(\\d{4})').matcher(d);
        Matcher es = Pattern.compile('(\\d{1,2})\\s+(?:de\\s+)?([a-zé]{3})[a-zé]*\\s+(?:de\\s+)?(\\d{4})').matcher(d);
        if (es.find() && MONTHS.containsKey(es.group(2))) {
            day = Integer.valueOf(es.group(1));
            month = MONTHS.get(es.group(2));
            year = Integer.valueOf(es.group(3));
        } else if (en.find() && MONTHS.containsKey(en.group(1))) {
            month = MONTHS.get(en.group(1));
            day = Integer.valueOf(en.group(2));
            year = Integer.valueOf(en.group(3));
        } else {
            return null;
        }
        List<String> hm = timeText.split(':');
        return Datetime.newInstance(year, month, day, Integer.valueOf(hm[0]), Integer.valueOf(hm[1]), 0);
    }

    /** "1.234,50" · "1,234.50" · "45,00" · "45.00" → Decimal; null si no es un importe. */
    @TestVisible
    private static Decimal parseAmount(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String s = raw.trim();
        Integer lastComma = s.lastIndexOf(',');
        Integer lastDot = s.lastIndexOf('.');
        if (lastComma > lastDot) {
            s = s.replace('.', '').replace(',', '.'); // formato europeo
        } else {
            s = s.replace(',', '');
        }
        try {
            return Decimal.valueOf(s);
        } catch (TypeException e) {
            return null;
        }
    }
}
