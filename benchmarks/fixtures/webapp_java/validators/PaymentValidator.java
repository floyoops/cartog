package validators;

import errors.ValidationException;
import util.Logger;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

/**
 * Validates payment input data.
 */
public class PaymentValidator {
    private static final Logger log = Logger.getLogger("validators.payment");
    private static final List<String> SUPPORTED_CURRENCIES =
            Arrays.asList("USD", "EUR", "GBP", "JPY", "CAD");

    /**
     * Validate payment request data.
     * Name collision: same method name as UserValidator.validate.
     */
    public static Map<String, Object> validate(Map<String, Object> data)
            throws ValidationException {
        log.info("Validating payment data");
        double amount = CommonValidator.validatePositiveNumber(
                (double) data.getOrDefault("amount", 0.0), "amount");
        String currency = (String) data.get("currency");
        if (!SUPPORTED_CURRENCIES.contains(currency))
            throw new ValidationException("currency", "Unsupported currency: " + currency);
        data.put("amount", amount);
        return data;
    }

    public static Map<String, Object> validateRefund(Map<String, Object> data)
            throws ValidationException {
        log.info("Validating refund data");
        if (!data.containsKey("transaction_id"))
            throw new ValidationException("transaction_id", "Transaction ID is required");
        return data;
    }
}
