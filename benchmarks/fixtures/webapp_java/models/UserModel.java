package models;

import util.Logger;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Domain model representing a user in the application.
 */
public class UserModel {
    private static final Logger log = Logger.getLogger("models.user");

    private String id;
    private String email;
    private String name;
    private String password;
    private UserRole role;
    private boolean active;
    private final Map<String, Object> metadata;

    public UserModel(String email, String name, String password) {
        log.info("Creating new user: %s", email);
        this.id = "usr_" + email;
        this.email = email;
        this.name = name;
        this.password = password;
        this.role = UserRole.USER;
        this.active = true;
        this.metadata = new HashMap<>();
    }

    /**
     * Validate that the user has valid field values.
     */
    public List<String> validate() {
        log.debug("Validating user: %s", email);
        List<String> errors = new ArrayList<>();
        if (email == null || email.isEmpty()) errors.add("email is required");
        if (name == null || name.isEmpty()) errors.add("name is required");
        if (password == null || password.length() < 8)
            errors.add("password must be at least 8 characters");
        if (!errors.isEmpty()) log.warn("User validation failed: %d errors", errors.size());
        return errors;
    }

    public boolean isAdmin() {
        return role == UserRole.ADMIN || role == UserRole.SUPER_ADMIN;
    }

    public void deactivate() {
        log.info("Deactivating user: %s", email);
        this.active = false;
    }

    public void setMetadata(String key, Object value) {
        metadata.put(key, value);
    }

    public String getId()       { return id; }
    public String getEmail()    { return email; }
    public String getName()     { return name; }
    public String getPassword() { return password; }
    public UserRole getRole()   { return role; }
    public boolean isActive()   { return active; }
}
