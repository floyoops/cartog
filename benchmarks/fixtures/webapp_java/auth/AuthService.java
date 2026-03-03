package auth;

import errors.AuthenticationException;
import errors.TokenException;
import util.Logger;

/**
 * Handles user authentication flows.
 */
public class AuthService implements AuthProvider {
    private static final Logger log = Logger.getLogger("auth.service");

    private final TokenService tokenService;

    public AuthService(TokenService tokenService) {
        this.tokenService = tokenService;
    }

    @Override
    public String login(String email, String password) throws AuthenticationException {
        log.info("Login attempt for: %s", email);
        if (email == null || email.isEmpty()) {
            log.warn("Empty email on login");
            throw new AuthenticationException("email is required");
        }
        if (password == null || password.length() < 6) {
            log.warn("Invalid password for: %s", email);
            throw new AuthenticationException("invalid credentials");
        }
        User user = new User("user_1", email, password, "user");
        String token = tokenService.generateToken(user);
        log.info("Login successful for: %s", email);
        return token;
    }

    @Override
    public void logout(String token) throws TokenException {
        log.info("Logout request");
        tokenService.revokeToken(token);
    }

    public User getCurrentUser(String token) throws TokenException {
        log.info("Getting current user from token");
        TokenClaims claims = tokenService.validateToken(token);
        User user = new User(claims.getUserId(), claims.getEmail(), "", claims.getRole());
        log.info("Current user: %s", user.getEmail());
        return user;
    }
}
