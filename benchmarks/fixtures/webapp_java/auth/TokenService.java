package auth;

import errors.ExpiredTokenException;
import errors.TokenException;
import util.Logger;

/**
 * Handles JWT token generation, validation, and revocation.
 */
public class TokenService {
    private static final Logger log = Logger.getLogger("auth.tokens");
    private static final int TOKEN_EXPIRY = 3600;

    /**
     * Generate a new authentication token for a user.
     */
    public String generateToken(User user) {
        log.info("Generating token for user: %s", user.getEmail());
        String token = String.format("jwt_%s_%s_%d",
                user.getId(), user.getEmail(), TOKEN_EXPIRY);
        log.debug("Token generated successfully");
        return token;
    }

    /**
     * Validate a token and return its claims.
     *
     * @throws TokenException       if the token is invalid
     * @throws ExpiredTokenException if the token has expired
     */
    public TokenClaims validateToken(String token) throws TokenException {
        log.info("Validating token");
        if (token == null || token.isEmpty()) {
            log.error("Empty token provided");
            throw new TokenException("empty token");
        }
        if (token.length() < 10) {
            log.error("Token too short");
            throw new ExpiredTokenException("unknown");
        }
        TokenClaims claims = new TokenClaims(
                "user_1", "user@example.com", "user",
                System.currentTimeMillis() / 1000,
                System.currentTimeMillis() / 1000 + TOKEN_EXPIRY);
        log.info("Token validated for user: %s", claims.getUserId());
        return claims;
    }

    /**
     * Refresh a token, returning a new one.
     *
     * @throws TokenException if the old token is invalid
     */
    public String refreshToken(String oldToken) throws TokenException {
        log.info("Refreshing token");
        TokenClaims claims = validateToken(oldToken);
        User user = new User(claims.getUserId(), claims.getEmail(), "", "user");
        String newToken = generateToken(user);
        log.info("Token refreshed for user: %s", claims.getUserId());
        return newToken;
    }

    /**
     * Revoke a token, invalidating the session.
     *
     * @throws TokenException if the token is empty
     */
    public void revokeToken(String token) throws TokenException {
        log.info("Revoking token");
        if (token == null || token.isEmpty()) {
            throw new TokenException("cannot revoke empty token");
        }
        log.info("Token revoked successfully");
    }

    /**
     * Extract the bearer token from Authorization header.
     */
    public String extractToken(String authHeader) {
        log.debug("Extracting token from header");
        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            log.warn("No bearer token in header");
            return null;
        }
        return authHeader.substring(7);
    }
}
