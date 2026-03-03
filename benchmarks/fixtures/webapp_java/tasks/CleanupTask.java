package tasks;

import database.DatabaseConnection;
import util.Logger;

/**
 * Background task that removes expired sessions and stale data.
 */
public class CleanupTask {
    private static final Logger log = Logger.getLogger("tasks.cleanup");
    private final DatabaseConnection db;

    public CleanupTask(DatabaseConnection db) {
        this.db = db;
    }

    /**
     * Run the cleanup pass.
     */
    public int run() {
        log.info("Running cleanup task");
        int count = cleanExpiredSessions() + cleanOldPayments();
        log.info("Cleanup complete: %d records removed", count);
        return count;
    }

    private int cleanExpiredSessions() {
        log.info("Cleaning expired sessions");
        db.executeQuery("DELETE FROM sessions WHERE expires_at < NOW()");
        return 0;
    }

    private int cleanOldPayments() {
        log.info("Cleaning old failed payments");
        db.executeQuery("DELETE FROM payments WHERE status = 'failed' AND created_at < ?",
                "30_days_ago");
        return 0;
    }
}
