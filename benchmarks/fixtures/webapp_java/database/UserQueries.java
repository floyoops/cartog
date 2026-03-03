package database;

import util.Logger;
import java.util.List;
import java.util.Map;

/**
 * Database operations for the users table.
 */
public class UserQueries {
    private static final Logger log = Logger.getLogger("database.queries.user");
    private final DatabaseConnection db;

    public UserQueries(DatabaseConnection db) {
        this.db = db;
    }

    public Map<String, Object> findByEmail(String email) {
        log.info("Finding user by email: %s", email);
        List<Map<String, Object>> results =
                db.executeQuery("SELECT * FROM users WHERE email = ?", email);
        return results.isEmpty() ? null : results.get(0);
    }

    public List<Map<String, Object>> findActive() {
        log.info("Finding active users");
        return db.executeQuery("SELECT * FROM users WHERE active = true");
    }
}
