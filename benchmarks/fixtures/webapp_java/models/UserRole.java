package models;

import util.Logger;

/**
 * Represents the role of a user in the system.
 */
public enum UserRole {
    GUEST, USER, MODERATOR, ADMIN, SUPER_ADMIN;

    private static final Logger log = Logger.getLogger("models.user_role");

    public String display() {
        switch (this) {
            case GUEST:      return "guest";
            case USER:       return "user";
            case MODERATOR:  return "moderator";
            case ADMIN:      return "admin";
            case SUPER_ADMIN:return "super_admin";
            default:
                log.warn("Unknown role: %s", this);
                return "unknown";
        }
    }
}
