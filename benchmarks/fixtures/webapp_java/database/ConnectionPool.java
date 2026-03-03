package database;

import util.Logger;
import java.util.ArrayList;
import java.util.List;

/**
 * Manages a pool of reusable database connections.
 */
public class ConnectionPool {
    private static final Logger log = Logger.getLogger("database.pool");

    private final List<ConnectionHandle> connections;
    private final int maxSize;

    public ConnectionPool(int maxSize) {
        log.info("Creating connection pool with max size: %d", maxSize);
        this.maxSize = maxSize;
        this.connections = new ArrayList<>(maxSize);
        for (int i = 0; i < maxSize; i++) {
            connections.add(new ConnectionHandle(i, "default"));
        }
        log.info("Connection pool initialized with %d connections", maxSize);
    }

    /**
     * Acquire a free connection from the pool.
     *
     * @throws IllegalStateException if no connections are available
     */
    public synchronized ConnectionHandle getConnection() {
        log.debug("Requesting connection from pool");
        for (ConnectionHandle conn : connections) {
            if (!conn.isInUse()) {
                conn.setInUse(true);
                log.info("Acquired connection #%d", conn.getId());
                return conn;
            }
        }
        log.error("No available connections in pool");
        throw new IllegalStateException("Connection pool exhausted");
    }

    /**
     * Return a connection to the pool.
     */
    public synchronized void releaseConnection(ConnectionHandle handle) {
        log.debug("Releasing connection #%d", handle.getId());
        handle.setInUse(false);
    }

    public synchronized int activeCount() {
        int count = 0;
        for (ConnectionHandle c : connections) {
            if (c.isInUse()) count++;
        }
        return count;
    }

    public void shutdown() {
        log.info("Shutting down connection pool");
        connections.forEach(c -> c.setInUse(false));
        connections.clear();
    }
}
