package api.v2;

import database.DatabaseConnection;
import errors.AuthenticationException;
import errors.ValidationException;
import routes.AuthRoutes;
import validators.UserValidator;
import util.Logger;
import java.util.Map;

/**
 * API v2 authentication controller — adds MFA support.
 */
public class AuthController {
    private static final Logger log = Logger.getLogger("api.v2.auth");
    private final AuthRoutes routes;

    public AuthController(DatabaseConnection db) {
        this.routes = new AuthRoutes(db);
    }

    /**
     * POST /api/v2/auth/login
     * Name collision: same method name as api.v1.AuthController.handleLogin.
     */
    public Map<String, Object> handleLogin(Map<String, Object> request)
            throws AuthenticationException, ValidationException {
        log.info("API v2 handleLogin");
        UserValidator.validateLogin(request);
        // V2 includes additional MFA step (stub)
        request.put("mfa_verified", true);
        return routes.handleLogin(request);
    }

    public Map<String, Object> handleLogout(Map<String, Object> request)
            throws Exception {
        log.info("API v2 handleLogout");
        return routes.handleLogout(request);
    }
}
