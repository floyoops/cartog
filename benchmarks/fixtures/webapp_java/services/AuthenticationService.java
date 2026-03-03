package services;

import auth.AuthService;
import auth.TokenService;
import auth.User;
import database.DatabaseConnection;
import errors.AuthenticationException;
import errors.TokenException;
import util.Logger;
import java.util.HashMap;
import java.util.Map;

/**
 * Orchestrates the full authentication workflow.
 *
 * Deep call chain entry point:
 * authenticate() -> login() -> generateToken() -> executeQuery() -> getConnection()
 */
public class AuthenticationService extends BaseService {
    private static final Logger log = Logger.getLogger("services.authentication");

    private final AuthService authService;
    private final DatabaseConnection db;

    public AuthenticationService(DatabaseConnection db) {
        super("authentication", "1.0");
        log.info("Creating AuthenticationService");
        this.authService = new AuthService(new TokenService());
        this.db = db;
    }

    /**
     * Perform the full authentication flow.
     *
     * @throws AuthenticationException if credentials are invalid
     */
    public String authenticate(String email, String password)
            throws AuthenticationException {
        requireInitialized();
        log.info("Authenticating user: %s", email);

        // Step 1: login via AuthService -> TokenService.generateToken
        String token = authService.login(email, password);

        // Step 2: persist session -> DatabaseConnection.executeQuery -> ConnectionPool.getConnection
        Map<String, Object> session = new HashMap<>();
        session.put("token", token);
        session.put("email", email);
        db.insert("sessions", session);

        log.info("Authentication successful for: %s", email);
        return token;
    }

    public void logout(String token) throws TokenException {
        log.info("Logging out");
        authService.logout(token);
    }

    public User getCurrentUser(String token) throws TokenException {
        log.info("Getting current user");
        return authService.getCurrentUser(token);
    }
}
