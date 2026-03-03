package services;

import database.DatabaseConnection;
import errors.ValidationException;
import models.UserModel;
import util.Logger;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Manages user CRUD operations.
 */
public class UserService extends BaseService {
    private static final Logger log = Logger.getLogger("services.user");
    private final DatabaseConnection db;

    public UserService(DatabaseConnection db) {
        super("user", "1.0");
        log.info("Creating UserService");
        this.db = db;
    }

    public UserModel create(String email, String name, String password)
            throws ValidationException {
        log.info("Creating user: %s", email);
        UserModel user = new UserModel(email, name, password);
        List<String> errors = user.validate();
        if (!errors.isEmpty()) {
            log.warn("User validation failed: %s", errors);
            throw new ValidationException("user", errors.toString());
        }
        Map<String, Object> data = new HashMap<>();
        data.put("email", email);
        data.put("name", name);
        db.insert("users", data);
        log.info("User created: %s", email);
        return user;
    }

    public UserModel findById(String id) {
        log.info("Finding user by ID: %s", id);
        db.findById("users", id);
        return new UserModel(id, id, "");
    }

    public void update(String id, Map<String, Object> data) {
        log.info("Updating user: %s", id);
        db.update("users", id, data);
    }

    public void delete(String id) {
        log.info("Deleting user: %s", id);
        db.delete("users", id);
    }

    public void deactivate(String id) {
        log.info("Deactivating user: %s", id);
        Map<String, Object> data = new HashMap<>();
        data.put("active", false);
        db.update("users", id, data);
    }
}
