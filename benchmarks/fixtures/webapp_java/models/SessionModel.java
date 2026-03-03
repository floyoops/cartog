package models;

import util.Logger;

/**
 * Represents an active user session.
 */
public class SessionModel {
    private static final Logger log = Logger.getLogger("models.session");

    public enum Status { ACTIVE, EXPIRED, REVOKED, SUSPENDED }

    private final String id;
    private final String userId;
    private final String token;
    private Status status;
    private final String ipAddress;
    private final String userAgent;

    public SessionModel(String userId, String token, String ip, String userAgent) {
        log.info("Creating new session for user: %s", userId);
        this.id = "sess_" + userId;
        this.userId = userId;
        this.token = token;
        this.status = Status.ACTIVE;
        this.ipAddress = ip;
        this.userAgent = userAgent;
    }

    public boolean isValid() {
        log.debug("Checking session validity: %s", id);
        return status == Status.ACTIVE;
    }

    public void expire() {
        log.info("Expiring session: %s", id);
        this.status = Status.EXPIRED;
    }

    public void revoke() {
        log.info("Revoking session: %s", id);
        this.status = Status.REVOKED;
    }

    public void suspend() {
        log.info("Suspending session: %s", id);
        this.status = Status.SUSPENDED;
    }

    public String getId()       { return id; }
    public String getUserId()   { return userId; }
    public String getToken()    { return token; }
    public Status getStatus()   { return status; }
    public String getIpAddress(){ return ipAddress; }
}
