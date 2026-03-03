package auth;

import errors.AuthenticationException;
import errors.TokenException;
import util.Logger;
import java.util.ArrayList;
import java.util.List;

/**
 * Extended authentication service for admin operations.
 * Inherits from AuthService and adds privilege management.
 */
public class AdminService extends AuthService {
    private static final Logger log = Logger.getLogger("auth.admin");
    private final List<String> adminUsers = new ArrayList<>();

    public AdminService(TokenService tokenService) {
        super(tokenService);
    }

    public boolean isAdmin(String userId) {
        log.debug("Checking admin status for: %s", userId);
        return adminUsers.contains(userId);
    }

    public void promoteToAdmin(String userId) {
        log.info("Promoting user to admin: %s", userId);
        adminUsers.add(userId);
    }

    public String impersonate(String adminToken, String targetUserId)
            throws TokenException, AuthenticationException {
        log.info("Admin impersonation: target=%s", targetUserId);
        User admin = getCurrentUser(adminToken);
        if (!admin.isAdmin()) {
            throw new AuthenticationException("Not authorized to impersonate");
        }
        User target = new User(targetUserId, targetUserId + "@example.com", "", "user");
        // We need the token service here; re-use from parent via composition
        AuthService svc = new AuthService(new TokenService());
        return svc.login(target.getEmail(), "impersonate");
    }
}
