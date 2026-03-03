package database;

/**
 * Wraps a database connection with pool metadata.
 */
public class ConnectionHandle {
    private final int id;
    private final String database;
    private boolean inUse;

    public ConnectionHandle(int id, String database) {
        this.id = id;
        this.database = database;
        this.inUse = false;
    }

    public int getId()        { return id; }
    public String getDatabase(){ return database; }
    public boolean isInUse()  { return inUse; }
    public void setInUse(boolean inUse) { this.inUse = inUse; }
}
