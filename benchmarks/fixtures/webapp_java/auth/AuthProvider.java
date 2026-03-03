package auth;

import errors.AuthenticationException;
import errors.TokenException;

/**
 * Interface for authentication providers.
 */
public interface AuthProvider {
    String login(String email, String password) throws AuthenticationException;
    void logout(String token) throws TokenException;
}
