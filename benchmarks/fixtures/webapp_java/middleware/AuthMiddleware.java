package middleware;

import auth.TokenClaims;
import auth.TokenService;
import errors.AuthenticationException;
import errors.TokenException;
import util.Logger;
import java.util.List;
import java.util.Map;

/**
 * Verifies authentication token on incoming requests.
 */
public class AuthMiddleware {
    private static final Logger log = Logger.getLogger("middleware.auth");
    private static final List<String> PUBLIC_PATHS =
            java.util.Arrays.asList("/health", "/login", "/register");

    private final TokenService tokenService;

    public AuthMiddleware(TokenService tokenService) {
        this.tokenService = tokenService;
    }

    /**
     * Authenticate the request, attaching user claims to the context.
     *
     * @throws AuthenticationException if the token is missing or invalid
     */
    public Map<String, Object> authenticate(Map<String, Object> request)
            throws AuthenticationException {
        String path = (String) request.getOrDefault("path", "");
        if (PUBLIC_PATHS.contains(path)) return request;

        String authHeader = (String) request.getOrDefault("Authorization", "");
        String token = tokenService.extractToken(authHeader);
        if (token == null) {
            log.warn("No token on request to %s", path);
            throw new AuthenticationException("Missing authentication token");
        }

        try {
            TokenClaims claims = tokenService.validateToken(token);
            request.put("user", claims);
            log.info("Authenticated user: %s", claims.getUserId());
        } catch (TokenException e) {
            log.warn("Token validation failed: %s", e.getMessage());
            throw new AuthenticationException("Invalid or expired token");
        }

        return request;
    }
}
