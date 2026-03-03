package models;

import errors.PaymentException;
import util.Logger;
import java.util.HashMap;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Domain model representing a financial transaction.
 */
public class PaymentModel {
    private static final Logger log = Logger.getLogger("models.payment");

    public enum Status { PENDING, PROCESSING, COMPLETED, FAILED, REFUNDED, CANCELLED }

    private final String id;
    private final String userId;
    private final double amount;
    private final String currency;
    private Status status;
    private String transactionId;
    private final String description;
    private final Map<String, Object> metadata;

    public PaymentModel(String userId, double amount, String currency, String description) {
        log.info("Creating payment: user=%s, amount=%.2f %s", userId, amount, currency);
        this.id = "pay_" + userId;
        this.userId = userId;
        this.amount = amount;
        this.currency = currency;
        this.status = Status.PENDING;
        this.description = description;
        this.metadata = new HashMap<>();
    }

    /**
     * Validate payment fields.
     */
    public List<String> validate() {
        log.debug("Validating payment: %s", id);
        List<String> errors = new ArrayList<>();
        if (amount <= 0) errors.add("amount must be positive");
        if (currency == null || currency.isEmpty()) errors.add("currency is required");
        if (userId == null || userId.isEmpty()) errors.add("user ID is required");
        if (!errors.isEmpty()) log.warn("Payment validation failed: %d errors", errors.size());
        return errors;
    }

    /**
     * Transition payment to processing state.
     *
     * @throws PaymentException if not in PENDING state
     */
    public void process() throws PaymentException {
        log.info("Processing payment: %s", id);
        if (status != Status.PENDING) {
            throw new PaymentException(id, "Cannot process payment in " + status + " state");
        }
        this.status = Status.PROCESSING;
    }

    public void complete(String txnId) {
        log.info("Completing payment: %s, txn=%s", id, txnId);
        this.status = Status.COMPLETED;
        this.transactionId = txnId;
    }

    public void fail(String reason) {
        log.error("Payment failed: %s, reason=%s", id, reason);
        this.status = Status.FAILED;
        this.metadata.put("failure_reason", reason);
    }

    /**
     * Refund a completed payment.
     *
     * @throws PaymentException if not in COMPLETED state
     */
    public void refund() throws PaymentException {
        log.info("Refunding payment: %s", id);
        if (status != Status.COMPLETED) {
            throw new PaymentException(id, "Cannot refund payment in " + status + " state");
        }
        this.status = Status.REFUNDED;
    }

    public String getId()            { return id; }
    public String getUserId()        { return userId; }
    public double getAmount()        { return amount; }
    public String getCurrency()      { return currency; }
    public Status getStatus()        { return status; }
    public String getTransactionId() { return transactionId; }
}
