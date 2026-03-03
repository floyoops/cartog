package errors;

/**
 * Raised when a token has expired.
 */
public class ExpiredTokenException extends TokenException {
    private final String expiredAt;

    public ExpiredTokenException(String expiredAt) {
        super("Token has expired");
        this.expiredAt = expiredAt;
    }

    public String getExpiredAt() {
        return expiredAt;
    }
}
