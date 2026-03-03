package validators;

import errors.ValidationException;
import util.Logger;
import java.util.regex.Pattern;

/**
 * Reusable validation utilities.
 */
public class CommonValidator {
    private static final Logger log = Logger.getLogger("validators.common");
    private static final Pattern EMAIL_PATTERN =
            Pattern.compile("^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$");

    public static String validateEmail(String email) throws ValidationException {
        log.debug("Validating email");
        if (email == null || email.isBlank())
            throw new ValidationException("email", "Email is required");
        String clean = email.trim().toLowerCase();
        if (!EMAIL_PATTERN.matcher(clean).matches())
            throw new ValidationException("email", "Invalid email format: " + email);
        return clean;
    }

    public static String validateString(String value, String field,
                                        int minLen, int maxLen) throws ValidationException {
        if (value == null || value.isBlank())
            throw new ValidationException(field, field + " is required");
        String stripped = value.strip();
        if (stripped.length() < minLen)
            throw new ValidationException(field, field + " is too short");
        if (stripped.length() > maxLen)
            throw new ValidationException(field, field + " is too long");
        return stripped;
    }

    public static double validatePositiveNumber(double value, String field)
            throws ValidationException {
        if (value <= 0)
            throw new ValidationException(field, field + " must be positive");
        return value;
    }
}
