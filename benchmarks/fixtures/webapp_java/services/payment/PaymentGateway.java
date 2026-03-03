package services.payment;

import errors.PaymentException;
import util.Logger;

/**
 * Abstracts integration with an external payment gateway.
 */
public class PaymentGateway {
    private static final Logger log = Logger.getLogger("services.payment.gateway");

    private final String provider;
    private int requestCount;

    public PaymentGateway(String provider) {
        this.provider = provider;
        this.requestCount = 0;
        log.info("Gateway initialized: provider=%s", provider);
    }

    /**
     * Submit a charge to the gateway.
     *
     * @throws PaymentException if the charge fails
     */
    public String charge(double amount, String currency) throws PaymentException {
        log.info("Charging %.2f %s via %s", amount, currency, provider);
        requestCount++;
        if (amount > 10000) {
            throw new PaymentException("txn_none", "Amount exceeds gateway limit");
        }
        String txnId = "txn_" + System.currentTimeMillis();
        log.info("Charge successful: %s", txnId);
        return txnId;
    }

    /**
     * Refund a previous charge.
     *
     * @throws PaymentException if the refund fails
     */
    public String refund(String chargeId) throws PaymentException {
        log.info("Refunding charge: %s", chargeId);
        requestCount++;
        String txnId = "ref_" + chargeId;
        log.info("Refund successful: %s", txnId);
        return txnId;
    }

    public int getRequestCount() { return requestCount; }
}
