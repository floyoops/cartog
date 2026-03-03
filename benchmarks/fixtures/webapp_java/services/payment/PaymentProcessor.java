package services.payment;

import database.DatabaseConnection;
import errors.PaymentException;
import errors.ValidationException;
import models.PaymentModel;
import services.BaseService;
import util.Logger;
import java.util.HashMap;
import java.util.Map;

/**
 * Handles the full payment processing lifecycle.
 */
public class PaymentProcessor extends BaseService {
    private static final Logger log = Logger.getLogger("services.payment.processor");

    private final DatabaseConnection db;
    private final PaymentGateway gateway;

    public PaymentProcessor(DatabaseConnection db) {
        super("payment_processor", "1.0");
        log.info("Creating PaymentProcessor");
        this.db = db;
        this.gateway = new PaymentGateway("stripe");
    }

    /**
     * Process a payment end-to-end.
     *
     * @throws ValidationException if payment data is invalid
     * @throws PaymentException    if the gateway charge fails
     */
    public PaymentModel process(String userId, double amount, String currency)
            throws ValidationException, PaymentException {
        requireInitialized();
        log.info("Processing payment: user=%s, amount=%.2f %s", userId, amount, currency);

        PaymentModel payment = new PaymentModel(userId, amount, currency, "charge");
        java.util.List<String> errors = payment.validate();
        if (!errors.isEmpty()) {
            throw new ValidationException("payment", errors.toString());
        }

        payment.process();
        String txnId = gateway.charge(amount, currency);
        payment.complete(txnId);

        Map<String, Object> data = new HashMap<>();
        data.put("id", payment.getId());
        data.put("amount", amount);
        data.put("txn_id", txnId);
        db.insert("payments", data);

        log.info("Payment completed: %s", txnId);
        return payment;
    }

    /**
     * Refund a completed payment.
     *
     * @throws PaymentException if refund fails
     */
    public void refund(PaymentModel payment) throws PaymentException {
        log.info("Refunding payment: %s", payment.getId());
        gateway.refund(payment.getTransactionId());
        payment.refund();
        Map<String, Object> data = new HashMap<>();
        data.put("status", "refunded");
        db.update("payments", payment.getId(), data);
    }
}
