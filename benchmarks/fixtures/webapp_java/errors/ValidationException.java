package errors;

import util.Logger;

/**
 * Thrown when input validation fails.
 */
public class ValidationException extends AppException {
    private static final Logger log = Logger.getLogger("errors.validation");
    private final String field;

    public ValidationException(String field, String message) {
        super(message, 400);
        this.field = field;
        log.warn("Validation failed: field=%s, msg=%s", field, message);
    }

    public String getField() {
        return field;
    }
}
