package services;

import database.DatabaseConnection;
import models.SessionModel;
import util.Logger;
import java.util.HashMap;
import java.util.Map;

/**
 * Manages user session lifecycle.
 */
public class SessionService extends BaseService {
    private static final Logger log = Logger.getLogger("services.session");
    private final DatabaseConnection db;

    public SessionService(DatabaseConnection db) {
        super("session", "1.0");
        log.info("Creating SessionService");
        this.db = db;
    }

    public SessionModel create(String userId, String token, String ip, String userAgent) {
        log.info("Creating session for user: %s", userId);
        SessionModel session = new SessionModel(userId, token, ip, userAgent);
        Map<String, Object> data = new HashMap<>();
        data.put("user_id", userId);
        data.put("token", token);
        db.insert("sessions", data);
        return session;
    }

    public void invalidate(String sessionId) {
        log.info("Invalidating session: %s", sessionId);
        db.delete("sessions", sessionId);
    }

    public void invalidateAll(String userId) {
        log.info("Invalidating all sessions for user: %s", userId);
        db.executeQuery("DELETE FROM sessions WHERE user_id = ?", userId);
    }

    public SessionModel findByToken(String token) {
        log.info("Finding session by token");
        db.executeQuery("SELECT * FROM sessions WHERE token = ?", token);
        return null;
    }
}
