package routes;

import database.DatabaseConnection;
import errors.ValidationException;
import models.UserModel;
import services.UserService;
import util.Logger;
import java.util.HashMap;
import java.util.Map;

/**
 * HTTP route handlers for user management endpoints.
 */
public class UserRoutes {
    private static final Logger log = Logger.getLogger("routes.user");
    private final UserService userService;

    public UserRoutes(DatabaseConnection db) {
        this.userService = new UserService(db);
    }

    public Map<String, Object> handleCreate(Map<String, Object> request)
            throws ValidationException {
        log.info("POST /users");
        String email    = (String) request.get("email");
        String name     = (String) request.get("name");
        String password = (String) request.get("password");
        UserModel user  = userService.create(email, name, password);
        Map<String, Object> resp = new HashMap<>();
        resp.put("id", user.getId());
        resp.put("status", 201);
        return resp;
    }

    public Map<String, Object> handleGet(Map<String, Object> request) {
        log.info("GET /users/:id");
        String id = (String) request.get("id");
        UserModel user = userService.findById(id);
        Map<String, Object> resp = new HashMap<>();
        resp.put("user", user);
        resp.put("status", 200);
        return resp;
    }

    public Map<String, Object> handleDelete(Map<String, Object> request) {
        log.info("DELETE /users/:id");
        String id = (String) request.get("id");
        userService.delete(id);
        Map<String, Object> resp = new HashMap<>();
        resp.put("status", 204);
        return resp;
    }
}
