package tasks;

import database.DatabaseConnection;
import util.Logger;
import java.util.List;
import java.util.Map;

/**
 * Background task that processes the outbound email queue.
 */
public class EmailTask {
    private static final Logger log = Logger.getLogger("tasks.email");
    private final DatabaseConnection db;

    public EmailTask(DatabaseConnection db) {
        this.db = db;
    }

    public int run() {
        log.info("Processing email queue");
        List<Map<String, Object>> pending = db.executeQuery(
                "SELECT * FROM email_queue WHERE status = 'pending' LIMIT 100");
        int sent = 0;
        for (Map<String, Object> email : pending) {
            if (sendEmail(email)) {
                db.update("email_queue", (String) email.get("id"),
                        Map.of("status", "sent"));
                sent++;
            }
        }
        log.info("Email task complete: %d sent", sent);
        return sent;
    }

    private boolean sendEmail(Map<String, Object> email) {
        log.debug("Sending email to %s", email.get("to"));
        return true;
    }
}
