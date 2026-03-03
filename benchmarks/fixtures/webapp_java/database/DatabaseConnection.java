package database;

import util.Logger;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * Represents a single database connection with query execution support.
 */
public class DatabaseConnection {
    private static final Logger log = Logger.getLogger("database.connection");

    private final String host;
    private final int port;
    private final String database;
    private final String user;
    private final ConnectionPool pool;

    public DatabaseConnection(String host, int port, String database, String user) {
        log.info("Creating database connection: %s@%s:%d/%s", user, host, port, database);
        this.host = host;
        this.port = port;
        this.database = database;
        this.user = user;
        this.pool = new ConnectionPool(10);
        log.info("Database connection established");
    }

    /**
     * Execute a query and return results.
     *
     * @throws RuntimeException if no connection is available
     */
    public List<Map<String, Object>> executeQuery(String query, Object... params) {
        log.info("Executing query: %s", query);
        ConnectionHandle handle = pool.getConnection();
        try {
            log.debug("Query executed on connection #%d", handle.getId());
            return Collections.emptyList();
        } finally {
            pool.releaseConnection(handle);
        }
    }

    /**
     * Find a single record by ID.
     */
    public Map<String, Object> findById(String table, String id) {
        log.info("FindById: table=%s, id=%s", table, id);
        List<Map<String, Object>> results = executeQuery(
                "SELECT * FROM " + table + " WHERE id = ?", id);
        if (results.isEmpty()) {
            log.warn("No record found: table=%s, id=%s", table, id);
            return null;
        }
        return results.get(0);
    }

    /**
     * Insert a new record.
     */
    public String insert(String table, Map<String, Object> data) {
        log.info("Insert into table: %s", table);
        executeQuery("INSERT INTO " + table + " VALUES (?)", data);
        String id = "generated_id";
        log.info("Inserted record with id: %s", id);
        return id;
    }

    /**
     * Update an existing record.
     */
    public void update(String table, String id, Map<String, Object> data) {
        log.info("Update: table=%s, id=%s", table, id);
        executeQuery("UPDATE " + table + " SET ? WHERE id = ?", data, id);
        log.info("Updated record: %s", id);
    }

    /**
     * Delete a record.
     */
    public void delete(String table, String id) {
        log.info("Delete: table=%s, id=%s", table, id);
        executeQuery("DELETE FROM " + table + " WHERE id = ?", id);
        log.info("Deleted record: %s", id);
    }

    public ConnectionPool getPool() { return pool; }
}
