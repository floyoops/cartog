package errors;

import util.Logger;

/**
 * Base application exception.
 */
public class AppException extends RuntimeException {
    private static final Logger log = Logger.getLogger("errors");

    private final int code;

    public AppException(String message, int code) {
        super(message);
        this.code = code;
        log.error("AppException: %s (code=%d)", message, code);
    }

    public AppException(String message, int code, Throwable cause) {
        super(message, cause);
        this.code = code;
    }

    public int getCode() {
        return code;
    }
}
