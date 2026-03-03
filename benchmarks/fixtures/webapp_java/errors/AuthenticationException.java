package errors;

import util.Logger;

/**
 * Thrown when authentication fails.
 */
public class AuthenticationException extends AppException {
    private static final Logger log = Logger.getLogger("errors.auth");

    public AuthenticationException(String message) {
        super(message, 401);
        log.warn("AuthenticationException: %s", message);
    }
}
