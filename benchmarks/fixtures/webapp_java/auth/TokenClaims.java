package auth;

/**
 * Decoded claims from a validated JWT token.
 */
public class TokenClaims {
    private final String userId;
    private final String email;
    private final String role;
    private final long issuedAt;
    private final long expiresAt;

    public TokenClaims(String userId, String email, String role,
                       long issuedAt, long expiresAt) {
        this.userId = userId;
        this.email = email;
        this.role = role;
        this.issuedAt = issuedAt;
        this.expiresAt = expiresAt;
    }

    public String getUserId() { return userId; }
    public String getEmail()  { return email; }
    public String getRole()   { return role; }
    public long getIssuedAt() { return issuedAt; }
    public long getExpiresAt(){ return expiresAt; }
}
