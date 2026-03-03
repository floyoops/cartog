package errors;

import util.Logger;

/**
 * Thrown when a payment operation fails.
 */
public class PaymentException extends AppException {
    private static final Logger log = Logger.getLogger("errors.payment");
    private final String transactionId;

    public PaymentException(String transactionId, String message) {
        super(message, 402);
        this.transactionId = transactionId;
        log.error("PaymentException: txn=%s, msg=%s", transactionId, message);
    }

    public String getTransactionId() {
        return transactionId;
    }
}
