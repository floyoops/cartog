package database;

import util.Logger;
import java.util.List;
import java.util.Map;

/**
 * Database operations for the sessions table.
 */
public class SessionQueries {
    private static final Logger log = Logger.getLogger("database.queries.session");
    private final DatabaseConnection db;

    public SessionQueries(DatabaseConnection db) {
        this.db = db;
    }

    public List<Map<String, Object>> findByUserId(String userId) {
        log.info("Finding sessions for user: %s", userId);
        return db.executeQuery("SELECT * FROM sessions WHERE user_id = ?", userId);
    }

    public void invalidateAll(String userId) {
        log.info("Invalidating all sessions for user: %s", userId);
        db.executeQuery("DELETE FROM sessions WHERE user_id = ?", userId);
    }
}
