package routes;

import database.DatabaseConnection;
import errors.AuthenticationException;
import errors.TokenException;
import services.AuthenticationService;
import util.Logger;
import java.util.HashMap;
import java.util.Map;

/**
 * HTTP route handlers for authentication endpoints.
 */
public class AuthRoutes {
    private static final Logger log = Logger.getLogger("routes.auth");

    private final AuthenticationService authService;

    public AuthRoutes(DatabaseConnection db) {
        this.authService = new AuthenticationService(db);
        this.authService.initialize();
    }

    /**
     * Handle POST /login — entry point for deep call chain.
     *
     * Call chain: handleLogin -> authenticate -> login -> generateToken
     *             -> executeQuery -> getConnection
     */
    public Map<String, Object> handleLogin(Map<String, Object> request)
            throws AuthenticationException {
        log.info("POST /login");
        String email = (String) request.get("email");
        String password = (String) request.get("password");

        String token = authService.authenticate(email, password);

        Map<String, Object> response = new HashMap<>();
        response.put("token", token);
        response.put("status", 200);
        log.info("Login successful: %s", email);
        return response;
    }

    public Map<String, Object> handleLogout(Map<String, Object> request)
            throws TokenException {
        log.info("POST /logout");
        String token = (String) request.get("token");
        authService.logout(token);
        Map<String, Object> response = new HashMap<>();
        response.put("status", 200);
        return response;
    }

    public Map<String, Object> handleRefresh(Map<String, Object> request)
            throws TokenException {
        log.info("POST /refresh");
        // handled by TokenService
        Map<String, Object> response = new HashMap<>();
        response.put("status", 200);
        return response;
    }
}
