package api.v1;

import database.DatabaseConnection;
import errors.AuthenticationException;
import errors.ValidationException;
import routes.AuthRoutes;
import validators.UserValidator;
import util.Logger;
import java.util.Map;

/**
 * API v1 authentication controller.
 */
public class AuthController {
    private static final Logger log = Logger.getLogger("api.v1.auth");
    private final AuthRoutes routes;

    public AuthController(DatabaseConnection db) {
        this.routes = new AuthRoutes(db);
    }

    /**
     * POST /api/v1/auth/login
     * Name collision: same method name as api.v2.AuthController.handleLogin.
     */
    public Map<String, Object> handleLogin(Map<String, Object> request)
            throws AuthenticationException, ValidationException {
        log.info("API v1 handleLogin");
        UserValidator.validateLogin(request);
        return routes.handleLogin(request);
    }

    public Map<String, Object> handleLogout(Map<String, Object> request)
            throws Exception {
        log.info("API v1 handleLogout");
        return routes.handleLogout(request);
    }
}
