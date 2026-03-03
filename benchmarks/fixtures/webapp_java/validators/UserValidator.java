package validators;

import errors.ValidationException;
import util.Logger;
import java.util.Map;

/**
 * Validates user input for registration and updates.
 */
public class UserValidator {
    private static final Logger log = Logger.getLogger("validators.user");

    /**
     * Validate user registration data.
     * Name collision: same method name as PaymentValidator.validate,
     * and route-level validate* helpers.
     */
    public static Map<String, Object> validate(Map<String, Object> data)
            throws ValidationException {
        log.info("Validating user data");
        String email = CommonValidator.validateEmail((String) data.get("email"));
        String name  = CommonValidator.validateString(
                (String) data.get("name"), "name", 1, 100);
        data.put("email", email);
        data.put("name", name);
        return data;
    }

    public static Map<String, Object> validateLogin(Map<String, Object> data)
            throws ValidationException {
        log.info("Validating login data");
        String email    = CommonValidator.validateEmail((String) data.get("email"));
        String password = (String) data.get("password");
        if (password == null || password.isEmpty())
            throw new ValidationException("password", "Password is required");
        data.put("email", email);
        return data;
    }
}
