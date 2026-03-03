package errors;

import util.Logger;

/**
 * Base exception for token-related errors.
 */
public class TokenException extends AppException {
    private static final Logger log = Logger.getLogger("errors.token");

    public TokenException(String message) {
        super(message, 401);
        log.warn("TokenException: %s", message);
    }
}
